import Foundation

/// Decides what a spoken command means. A local model on Ollama answers in well under a second;
/// if it is down, a few regexes keep the basics working.
struct Decision: Decodable {
  var intent: String
  var arg: String
  var reply: String
  var mood: String
}

enum Router {
  static let model = "qwen3:4b"
  static let ollama = URL(string: "http://127.0.0.1:11434")!

  static let system = """
  You are the intent router for R2-D2, a desk robot. The user spoke a command in Spanish (wake word "Artu") or English (wake word "R2").
  Reply ONLY with JSON: {"intent": string, "arg": string, "reply": string, "mood": string}
  intent is one of: spotify.play, spotify.pause, spotify.next, web.search, calendar.show, open.app, praise, chat, claude
  - web.search: arg is the search query. open.app: arg is the app name. spotify.play: arg is the song or artist if named, else "".
  - claude: anything needing information from the computer, files, email, calendar contents, or real reasoning.
  - chat: small talk. praise: the user is approving or thanking.
  reply: what R2 says back, at most 12 words, same language as the command. Spanish must be rioplatense (vos, dale, bárbaro). Cheeky droid personality.
  mood is one of: happy, alarm, attention, thinking, sad, busy. happy for praise and fun actions, attention for questions, thinking when handing off to claude, sad when you can't help.
  """

  static func decide(_ text: String, language: Listener.Language) async -> Decision {
    if let decision = try? await ask(text) { return decision }
    return fallback(text, language)
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
    return try JSONDecoder().decode(Decision.self, from: Data(content.utf8))
  }

  private static func fallback(_ text: String, _ lang: Listener.Language) -> Decision {
    let t = text.lowercased()
    let es = lang == .es
    if t.contains("spotify") || t.contains("música") || t.contains("music") {
      return Decision(intent: "spotify.play", arg: "", reply: es ? "Dale, música." : "Music coming up.", mood: "happy")
    }
    if t.contains("calendar") || t.contains("calendario") || t.contains("agenda") {
      return Decision(intent: "calendar.show", arg: "", reply: es ? "A ver tu agenda." : "Checking your calendar.", mood: "attention")
    }
    if let q = t.range(of: "(busc[aá]|search( for)?) ", options: .regularExpression) {
      return Decision(intent: "web.search", arg: String(t[q.upperBound...]), reply: es ? "Buscando." : "Searching.", mood: "attention")
    }
    if t.contains("bien") || t.contains("gracias") || t.contains("good") || t.contains("thanks") {
      return Decision(intent: "praise", arg: "", reply: es ? "¡Bárbaro!" : "Told you.", mood: "happy")
    }
    return Decision(intent: "claude", arg: "", reply: es ? "Dejame pensar." : "Let me think.", mood: "thinking")
  }
}
