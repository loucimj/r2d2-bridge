import Foundation

/// The slow tier: hands a question to Claude Code headless, with a permissions file that only
/// allows read-only tools, `osascript` and `open`, and the r2-companion mod so R2 reacts while
/// Claude works. Returns the spoken answer and the mood Claude chose.
enum Assistant {
  struct Answer { var text: String; var mood: String }

  static func ask(_ text: String, language: Listener.Language, config: BridgeConfig) async -> Answer? {
    let spanish = language == .es
    let system = spanish
      ? "Sos el cerebro de R2-D2, un droide de escritorio en la Mac del usuario. Respondé en español rioplatense (vos), máximo dos frases, en texto hablado sin markdown ni listas. Podés usar osascript y open para consultar Calendario, Recordatorios, Mail, Spotify o Safari. Terminá SIEMPRE con una línea aparte: mood: <happy|alarm|attention|thinking|sad|busy>"
      : "You are the brain of R2-D2, a desk droid on the user's Mac. Answer in English, two sentences max, as spoken text with no markdown or lists. You may use osascript and open to query Calendar, Reminders, Mail, Spotify or Safari. ALWAYS end with a separate line: mood: <happy|alarm|attention|thinking|sad|busy>"
    let process = Process()
    process.executableURL = URL(fileURLWithPath: config.claudeBin)
    process.arguments = [
      "-p", text, "--output-format", "json", "--max-turns", "8",
      "--append-system-prompt", system,
      "--settings", config.projectDir + "/macos/claude-voice-settings.json",
      "--plugin-dir", config.projectDir + "/mod/r2-companion",
    ]
    process.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())
    // A clean environment: CLAUDE* variables from a parent Claude session make the CLI refuse to run.
    process.environment = ProcessInfo.processInfo.environment
      .filter { !$0.key.hasPrefix("CLAUDE") }
      .merging(["PATH": config.nodeBin + ":/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"]) { $1 }
    let out = Pipe()
    process.standardInput = FileHandle.nullDevice // otherwise the CLI waits 3 s for piped input
    process.standardOutput = out
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return nil }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    struct Result: Decodable { var result: String?; var is_error: Bool? }
    guard let decoded = try? JSONDecoder().decode(Result.self, from: data), let result = decoded.result else { return nil }
    // An auth or API failure comes back as a plain sentence; say it so the user knows what to fix.
    if decoded.is_error == true { return Answer(text: result, mood: "sad") }
    return parse(result)
  }

  static func parse(_ result: String) -> Answer {
    var lines = result.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    var mood = "attention"
    if let last = lines.last, let m = last.range(of: "^\\s*mood:\\s*([a-z]+)", options: .regularExpression) {
      mood = String(last[m]).replacingOccurrences(of: "^\\s*mood:\\s*", with: "", options: .regularExpression)
      lines.removeLast()
    }
    return Answer(text: lines.joined(separator: " ").trimmingCharacters(in: .whitespaces), mood: mood)
  }
}
