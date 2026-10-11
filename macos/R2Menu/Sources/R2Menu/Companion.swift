import AppKit
import Foundation

/// Ties the pieces together: wake word → chirp, command → router → intent → R2 reaction and voice.
@MainActor
final class Companion: ObservableObject {
  @Published private(set) var transcript: [String] = []
  @Published private(set) var busy = false
  @Published private(set) var routerReady = false

  let listener = Listener()
  private let speaker = Speaker()
  private let bridge: Bridge
  private var hotkey: Hotkey?

  init(bridge: Bridge) {
    self.bridge = bridge
    listener.onWake = { [weak self] _ in self?.acknowledgeWake() }
    listener.onCommand = { [weak self] transcripts, wokeBy in Task { await self?.handle(transcripts, wokeBy) } }
    hotkey = Hotkey(keyCode: 15 /* R */, modifiers: [.control, .option]) { [weak self] in self?.listener.captureNow() }
    speaker.onSpeaking = { [weak self] speaking in Task { @MainActor in self?.listener.muted = speaking } }
    Task {
      routerReady = await Router.available
      if routerReady { await Router.warmUp() }
    }
    // Keep the model resident: Ollama drops it after its keep_alive, and a cold start costs 5 s.
    Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { _ in Task { await Router.warmUp() } }
    if listening { listener.start() }
  }

  /// Remembered across launches.
  var listening: Bool {
    get { UserDefaults.standard.bool(forKey: "listening") }
    set { UserDefaults.standard.set(newValue, forKey: "listening") }
  }

  func setListening(_ on: Bool) {
    listening = on
    on ? listener.start() : listener.stop()
  }

  private func acknowledgeWake() {
    bridge.react("listening") // front LED blue, dome turns with a "hey" chirp
  }

  private func handle(_ transcripts: [Listener.Language: String], _ wokeBy: Listener.Language) async {
    busy = true
    defer { busy = false }
    let decision = await Router.decide(transcripts, wokeBy: wokeBy)
    let lang = Listener.Language(rawValue: decision.language) ?? wokeBy
    let text = decision.text
    log("🎤 \(text)")
    log("→ \(decision.intent) \(decision.arg.isEmpty ? "" : "“\(decision.arg)”")")
    speaker.say(decision.reply, language: lang)
    bridge.react(decision.mood)
    VoiceLog.write("acting: \(decision.intent)")

    switch decision.intent {
    case "spotify.play":
      if decision.arg.isEmpty { osascript(Self.spotifyPlay) }
      else { open("spotify:search:\(decision.arg.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")") }
    case "spotify.pause": osascript("tell application \"Spotify\" to pause")
    case "spotify.next": osascript("tell application \"Spotify\" to next track")
    case "web.search":
      let q = decision.arg.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
      launch(app: "Safari", url: "https://www.google.com/search?q=\(q)")
    case "open.app":
      launch(app: decision.arg)
    case "calendar.show":
      launch(app: "Calendar")
      await askClaude(lang == .es ? "Resumí mi agenda de hoy." : "Summarize my calendar for today.", lang)
    case "claude":
      await askClaude(text, lang)
    default:
      break // praise, chat: the reply and mood were the whole answer
    }
  }

  private func askClaude(_ prompt: String, _ lang: Listener.Language) async {
    bridge.react("thinking")
    guard let answer = await Assistant.ask(prompt, language: lang, config: bridge.config) else {
      speaker.say(lang == .es ? "Claude no me contestó." : "Claude did not answer.", language: lang)
      return bridge.react("sad")
    }
    log("🤖 \(answer.text)")
    speaker.say(answer.text, language: lang)
    bridge.react(answer.mood)
  }

  /// A bare `play` does nothing when Spotify has no track queued (fresh launch), so start a playlist then.
  /// Override with `defaults write com.loucimj.r2d2-bridge spotifyFallback spotify:playlist:...`.
  static var spotifyPlay: String {
    let fallback = UserDefaults.standard.string(forKey: "spotifyFallback") ?? "spotify:playlist:37i9dQZF1DXcBWIGoYBM5M"
    return """
    tell application "Spotify"
      activate
      play
      delay 1
      if player state is not playing then play track "\(fallback)"
    end tell
    """
  }

  /// `open -a`: finds apps by name the way Spotlight does, optionally with a URL to show.
  private func launch(app: String, url: String? = nil) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    p.arguments = ["-a", app] + (url.map { [$0] } ?? [])
    try? p.run()
  }

  private func osascript(_ source: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    p.arguments = ["-e", source]
    let err = Pipe()
    p.standardError = err
    p.terminationHandler = { proc in
      let text = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
      VoiceLog.write("osascript exit \(proc.terminationStatus)\(text.isEmpty ? "" : ": " + text.trimmingCharacters(in: .whitespacesAndNewlines))")
    }
    do { try p.run() } catch { VoiceLog.write("osascript failed to start: \(error.localizedDescription)") }
  }

  private func open(_ url: String) {
    if let u = URL(string: url) { NSWorkspace.shared.open(u) }
  }

  private func log(_ line: String) {
    transcript.append(line)
    if transcript.count > 8 { transcript.removeFirst() }
  }
}
