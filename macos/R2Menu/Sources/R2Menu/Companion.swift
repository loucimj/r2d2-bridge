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
    listener.onCommand = { [weak self] text, lang in Task { await self?.handle(text, lang) } }
    hotkey = Hotkey(keyCode: 15 /* R */, modifiers: [.control, .option]) { [weak self] in self?.listener.captureNow() }
    Task { routerReady = await Router.available }
  }

  func setListening(_ on: Bool) { on ? listener.start() : listener.stop() }

  private func acknowledgeWake() {
    bridge.cmd("setR2D2LogicDisplaysIntensity", [255])
    bridge.play(audio: 2813) // R2_HEY_1
  }

  private func handle(_ text: String, _ lang: Listener.Language) async {
    log("🎤 \(text)")
    busy = true
    defer { busy = false }
    let decision = await Router.decide(text, language: lang)
    log("→ \(decision.intent) \(decision.arg.isEmpty ? "" : "“\(decision.arg)”")")
    speaker.say(decision.reply, language: lang)
    bridge.react(decision.mood)

    switch decision.intent {
    case "spotify.play":
      if decision.arg.isEmpty { osascript("tell application \"Spotify\" to play") }
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
    try? p.run()
  }

  private func open(_ url: String) {
    if let u = URL(string: url) { NSWorkspace.shared.open(u) }
  }

  private func log(_ line: String) {
    transcript.append(line)
    if transcript.count > 8 { transcript.removeFirst() }
  }
}
