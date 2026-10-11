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
  Reply ONLY with JSON: {"language": "en" or "es", "intent": string, "arg": string, "reply": string, "mood": string}
  intent is one of: spotify.play, spotify.pause, spotify.next, web.search, calendar.show, open.app, praise, chat, claude
  - web.search: arg is the search query. open.app: arg is the app name. spotify.play: arg is the song or artist ONLY if one is named, else "". Never copy the whole sentence into arg.
  - claude: anything needing information from the computer, files, email, calendar contents, or real reasoning.
  - chat: small talk. praise: the user is approving or thanking.
  reply: what R2 says back, at most 12 words, in the language you chose. Spanish must be rioplatense (vos, dale, bárbaro). Cheeky droid personality.
  mood is one of: happy, alarm, attention, thinking, sad, busy. happy for praise and fun actions, attention for questions, thinking when handing off to claude, sad when you can't help.
  Examples:
  Spanish: estuvo bien eso, no -> {"language":"es","intent":"praise","arg":"","reply":"¡Obvio que estuvo bien, soy un droide!","mood":"happy"}
  English: play some music on spotify -> {"language":"en","intent":"spotify.play","arg":"","reply":"Music coming right up.","mood":"happy"}
  Spanish: buscá recetas de empanadas -> {"language":"es","intent":"web.search","arg":"recetas de empanadas","reply":"Dale, buscando empanadas.","mood":"attention"}
  """

  static let moods: Set<String> = ["happy", "alarm", "attention", "thinking", "sad", "busy"]

  static func decide(_ transcripts: [Listener.Language: String], wokeBy: Listener.Language) async -> Decision {
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
      var decision = try await ask(prompt)
      if !moods.contains(decision.mood) { decision.mood = "attention" }
      if let sure { decision.language = sure.rawValue }
      if decision.language != "en" && decision.language != "es" { decision.language = wokeBy.rawValue }
      decision.text = transcripts[Listener.Language(rawValue: decision.language)!] ?? transcripts[wokeBy] ?? ""
      VoiceLog.write("router \(String(format: "%.2f", Date().timeIntervalSince(started)))s: lang=\(decision.language) \(decision.intent) arg=\(decision.arg) mood=\(decision.mood) reply=\(decision.reply)")
      return decision
    } catch {
      VoiceLog.write("router failed (\(error.localizedDescription)), using fallback")
      var decision = fallback(transcripts[wokeBy] ?? transcripts.values.first ?? "", wokeBy)
      decision.text = transcripts[wokeBy] ?? ""
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

  static var available: Bool {
    get async {
      guard let (data, _) = try? await URLSession.shared.data(from: ollama.appending(path: "api/tags")),
            let text = String(data: data, encoding: .utf8) else { return false }
      return text.contains("\"\(model)\"")
    }
  }

  private static func ask(_ text: String) async throws -> Decision {
    var request = URLRequest(url: ollama.appending(path: "api/chat"), timeoutInterval: 8)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: [
      "model": model, "stream": false, "think": false, "format": "json", "keep_alive": "30m",
      "options": ["temperature": 0.2, "num_predict": 120],
      "messages": [["role": "system", "content": system], ["role": "user", "content": text]],
    ])
    let (data, _) = try await URLSession.shared.data(for: request)
    struct Chat: Decodable { struct Message: Decodable { var content: String }; var message: Message }
    let content = try JSONDecoder().decode(Chat.self, from: data).message.content
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
