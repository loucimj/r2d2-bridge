import Foundation

/// Decides what a spoken command means. A local model on Ollama answers in well under a second;
/// if it is down, a few regexes keep the basics working.
struct Decision: Decodable {
  var intent: String
  var arg: String
  var reply: String
  var mood: String
  var language: String
  /// The transcript in the chosen language, for the Claude tier.
  var text = ""

  enum CodingKeys: String, CodingKey { case intent, arg, reply, mood, language }

  init(intent: String, arg: String, reply: String, mood: String, language: String) {
    (self.intent, self.arg, self.reply, self.mood, self.language) = (intent, arg, reply, mood, language)
  }

  // The model sometimes sends null or a number for a field; be lenient.
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    intent = (try? c.decode(String.self, forKey: .intent)) ?? "chat"
    arg = (try? c.decode(String.self, forKey: .arg)) ?? ""
    reply = (try? c.decode(String.self, forKey: .reply)) ?? ""
    mood = (try? c.decode(String.self, forKey: .mood)) ?? "attention"
    language = (try? c.decode(String.self, forKey: .language)) ?? "es"
  }
}

enum Router {
  static let model = "qwen3:4b"
  static let ollama = URL(string: "http://127.0.0.1:11434")!

  static let system = """
  You are the intent router for R2-D2, a desk robot. The user spoke ONE sentence, in Spanish or English. Usually you get the sentence with its language. When the language is unknown you get two transcripts, one from an English speech recognizer and one from a Spanish one: one is coherent, the other is the wrong language's best guess and reads like noise; decide which language the user spoke and route that transcript.
  Reply ONLY with JSON, fields in exactly this order: {"mood": string, "language": "en" or "es", "intent": string, "arg": string, "reply": string}
  intent is one of: spotify.play, spotify.pause, spotify.next, web.search, calendar.show, open.app, praise, chat, claude
  - web.search: arg is the search query. open.app: arg is the app name. spotify.play: arg is the song or artist ONLY if one is named, else "". Never copy the whole sentence into arg.
  - claude: anything needing information from the computer, files, email, calendar contents, or real reasoning.
  - chat: small talk. praise: the user is approving or thanking.
  reply: what R2 says back, at most 12 words, in the language you chose. Spanish must be rioplatense (vos, dale, bárbaro). Cheeky droid personality.
  mood comes FIRST and is one of: happy, excited, laugh, chatty, attention, thinking, sad, no, alarm, busy. happy or excited for praise and good news, laugh for jokes, chatty for small talk, no for refusals or teasing, attention for questions, thinking when handing off to claude, sad when you can't help.
  For chat and praise the reply is optional: R2 answers in beeps, so leave reply "" unless words add something.
  Examples:
  Spanish: estuvo bien eso, no -> {"mood":"happy","language":"es","intent":"praise","arg":"","reply":""}
  English: play some music on spotify -> {"mood":"happy","language":"en","intent":"spotify.play","arg":"","reply":"Music coming right up."}
  Spanish: buscá recetas de empanadas -> {"mood":"attention","language":"es","intent":"web.search","arg":"recetas de empanadas","reply":"Dale, buscando empanadas."}
  English: you are a lazy droid -> {"mood":"no","language":"en","intent":"chat","arg":"","reply":""}
  """

  static let moods: Set<String> = ["happy", "excited", "laugh", "chatty", "attention", "thinking", "sad", "no", "alarm", "busy"]

  /// The last few exchanges, so "¿y eso?" has something to refer to. Cheap: the prefix is cached by Ollama.
  private static var history: [[String: String]] = []

  static func remember(_ user: String, _ answer: String) {
    history.append(["role": "user", "content": user])
    history.append(["role": "assistant", "content": answer])
    if history.count > 6 { history.removeFirst(history.count - 6) }
  }

  /// `onMood` fires as soon as the streamed answer names the mood, well before the rest arrives.
  static func decide(_ transcripts: [Listener.Language: String], wokeBy: Listener.Language, onMood: ((String) -> Void)? = nil) async -> Decision {
    let started = Date()
    let sure = pickLanguage(transcripts, wokeBy: wokeBy)
    let prompt: String
    if let sure, let text = transcripts[sure] {
      prompt = "\(sure == .en ? "English" : "Spanish"): \(text)"
    } else {
      prompt = Listener.Language.allCases.compactMap { lang in
        transcripts[lang].map { "\(lang == .en ? "English" : "Spanish") recognizer: \($0)" }
      }.joined(separator: "\n")
    }
    do {
      var decision = try await ask(prompt, onMood: onMood)
      if !moods.contains(decision.mood) { decision.mood = "attention" }
      if let sure { decision.language = sure.rawValue }
      if decision.language != "en" && decision.language != "es" { decision.language = wokeBy.rawValue }
      decision.text = transcripts[Listener.Language(rawValue: decision.language)!] ?? transcripts[wokeBy] ?? ""
      VoiceLog.write("router \(String(format: "%.2f", Date().timeIntervalSince(started)))s: lang=\(decision.language) \(decision.intent) arg=\(decision.arg) mood=\(decision.mood) reply=\(decision.reply)")
      return decision
    } catch {
      VoiceLog.write("router failed (\(error.localizedDescription)), using fallback")
      let lang = sure ?? wokeBy
      var decision = fallback(transcripts[lang] ?? transcripts.values.first ?? "", lang)
      decision.text = transcripts[lang] ?? ""
      return decision
    }
  }

  /// Decides the language without the model when the evidence is clear. Each transcript is scored by
  /// the words only its own language's speaker would say (short words count half, since recognizers
  /// produce them for anything); an accent or ñ in the Spanish reading adds one point. Close calls
  /// return nil and the model sees both readings.
  static func pickLanguage(_ transcripts: [Listener.Language: String], wokeBy: Listener.Language) -> Listener.Language? {
    guard let es = transcripts[.es]?.lowercased(), let en = transcripts[.en]?.lowercased() else {
      return transcripts.keys.first
    }
    let esWords: Set<String> = ["que", "qué", "como", "cómo", "esta", "está", "estuvo", "bien", "eso", "pone", "poné", "poner", "abrí", "abre", "abrir", "busca", "buscá", "buscar", "mi", "mis", "el", "la", "los", "las", "un", "una", "en", "de", "del", "por", "para", "con", "no", "sí", "música", "musica", "calendario", "agenda", "gracias", "hola", "dale", "ahora", "che", "hora"]
    let enWords: Set<String> = ["the", "my", "is", "are", "play", "some", "music", "search", "open", "how", "what", "on", "in", "a", "an", "to", "for", "of", "calendar", "please", "thanks", "good", "that", "was", "it", "me", "and", "with", "time", "show"]
    let score = { (text: String, words: Set<String>) -> Double in
      text.split(whereSeparator: { !$0.isLetter })
        .filter { words.contains(String($0)) }
        .reduce(0.0) { $0 + ($1.count <= 2 ? 0.5 : 1) }
    }
    var esScore = score(es, esWords), enScore = score(en, enWords)
    if es.range(of: "[áéíóúñ¿¡]", options: .regularExpression) != nil { esScore += 1 }
    if esScore == 0 && enScore == 0 { return wokeBy }
    if esScore >= enScore + 1.5 { return .es }
    if enScore >= esScore + 1.5 { return .en }
    return nil
  }

  /// Loads the model into memory so the first command does not pay the 5 s cold start.
  static func warmUp() async {
    var request = URLRequest(url: ollama.appending(path: "api/chat"), timeoutInterval: 60)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try? JSONSerialization.data(withJSONObject: [
      "model": model, "stream": false, "think": false, "keep_alive": "30m",
      "messages": [["role": "system", "content": system], ["role": "user", "content": "Spanish: hola"]],
      "options": ["num_predict": 1],
    ])
    let started = Date()
    if (try? await URLSession.shared.data(for: request)) != nil {
      VoiceLog.write(String(format: "router warm (%.1f s)", Date().timeIntervalSince(started)))
    }
  }

  static var available: Bool {
    get async {
      guard let (data, _) = try? await URLSession.shared.data(from: ollama.appending(path: "api/tags")),
            let text = String(data: data, encoding: .utf8) else { return false }
      return text.contains("\"\(model)\"")
    }
  }

  private static func ask(_ text: String, onMood: ((String) -> Void)?) async throws -> Decision {
    var request = URLRequest(url: ollama.appending(path: "api/chat"), timeoutInterval: 20)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: [
      "model": model, "stream": true, "think": false, "format": "json", "keep_alive": "30m",
      "options": ["temperature": 0.2, "num_predict": 120],
      "messages": [["role": "system", "content": system]] + history + [["role": "user", "content": text]],
    ])
    struct Chunk: Decodable { struct Message: Decodable { var content: String }; var message: Message }
    let (bytes, _) = try await URLSession.shared.bytes(for: request)
    var content = ""
    var moodSent = false
    for try await line in bytes.lines {
      guard let chunk = try? JSONDecoder().decode(Chunk.self, from: Data(line.utf8)) else { continue }
      content += chunk.message.content
      // The mood is the first field; act on it the moment it is complete.
      if !moodSent, let m = content.range(of: "\"mood\"\\s*:\\s*\"([a-z]+)\"", options: .regularExpression) {
        moodSent = true
        let mood = String(content[m]).replacingOccurrences(of: "^.*\"([a-z]+)\"$", with: "$1", options: .regularExpression)
        if moods.contains(mood) { onMood?(mood) }
      }
    }
    do {
      return try JSONDecoder().decode(Decision.self, from: Data(content.utf8))
    } catch {
      VoiceLog.write("router: model answer did not parse: \(content.prefix(200))")
      throw error
    }
  }

  private static func fallback(_ text: String, _ lang: Listener.Language) -> Decision {
    let t = text.lowercased()
    let es = lang == .es
    if t.contains("spotify") || t.contains("música") || t.contains("music") {
      return Decision(intent: "spotify.play", arg: "", reply: es ? "Dale, música." : "Music coming up.", mood: "happy", language: lang.rawValue)
    }
    if t.contains("calendar") || t.contains("calendario") || t.contains("agenda") {
      return Decision(intent: "calendar.show", arg: "", reply: es ? "A ver tu agenda." : "Checking your calendar.", mood: "attention", language: lang.rawValue)
    }
    if let q = t.range(of: "(busc[aá]|search( for)?) ", options: .regularExpression) {
      return Decision(intent: "web.search", arg: String(t[q.upperBound...]), reply: es ? "Buscando." : "Searching.", mood: "attention", language: lang.rawValue)
    }
    if t.contains("bien") || t.contains("gracias") || t.contains("good") || t.contains("thanks") {
      return Decision(intent: "praise", arg: "", reply: es ? "¡Bárbaro!" : "Told you.", mood: "happy", language: lang.rawValue)
    }
    return Decision(intent: "claude", arg: "", reply: es ? "Dejame pensar." : "Let me think.", mood: "thinking", language: lang.rawValue)
  }
}
