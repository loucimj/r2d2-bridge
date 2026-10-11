import Foundation

/// User-defined phrases, matched before the model: an exact thing to say and exactly what happens.
/// File: ~/Library/Application Support/R2 Bridge/phrases.json (created with an example on first run).
struct Phrase: Decodable {
  var match: [String]          // any of these, matched as accent-insensitive substrings
  var reply: String?           // spoken, in whatever language you wrote it
  var mood: String?            // an R2 mood
  var spotify: String?         // a spotify:track:/album:/playlist: URI to play
  var open: String?            // a URL or an app name
  var animation: Int?          // a raw R2 animation id
}

enum Phrases {
  static let url = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/R2 Bridge/phrases.json")

  static let example = """
  [
    {
      "match": ["daddy is home", "daddy's home", "llegó papá", "llego papa", "papá llegó"],
      "reply": "Welcome home, boss.",
      "mood": "happy",
      "spotify": "spotify:track:2zYzyRzz6pRmhPzyfMEC8s"
    }
  ]
  """

  static func load() -> [Phrase] {
    if !FileManager.default.fileExists(atPath: url.path) {
      try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try? example.write(to: url, atomically: true, encoding: .utf8)
    }
    guard let data = try? Data(contentsOf: url) else { return [] }
    do {
      return try JSONDecoder().decode([Phrase].self, from: data)
    } catch {
      VoiceLog.write("phrases.json did not parse: \(error.localizedDescription)")
      return []
    }
  }

  static func normalize(_ s: String) -> String {
    s.lowercased().folding(options: .diacriticInsensitive, locale: nil)
      .replacingOccurrences(of: "[^a-z0-9 ]", with: " ", options: .regularExpression)
      .replacingOccurrences(of: "  +", with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespaces)
  }

  /// The first phrase any transcript contains.
  static func match(_ transcripts: [Listener.Language: String]) -> Phrase? {
    let heard = transcripts.values.map(normalize)
    return load().first { phrase in
      phrase.match.contains { key in heard.contains { $0.contains(normalize(key)) } }
    }
  }
}
