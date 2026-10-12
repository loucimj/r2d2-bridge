import AppKit
import ServiceManagement
import SwiftUI

@main
struct R2MenuApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
  @StateObject private var bridge = Bridge.shared
  @StateObject private var companion = Companion(bridge: Bridge.shared)

  var body: some Scene {
    MenuBarExtra {
      MenuContent(bridge: bridge, companion: companion)
    } label: {
      Image(systemName: icon)
    }
  }

  private var icon: String {
    if case .hearing = companion.listener.phase { return "waveform" }
    if companion.busy { return "ellipsis.bubble" }
    return bridge.state == .connected ? "antenna.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash"
  }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  /// Quit waits for the daemon to shut down (it sleeps R2 and disconnects), up to 5 s.
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard Bridge.shared.ownsDaemon else { return .terminateNow }
    Bridge.shared.stopDaemon(timeout: 5) { sender.reply(toApplicationShouldTerminate: true) }
    return .terminateLater
  }
}

struct MenuContent: View {
  @ObservedObject var bridge: Bridge
  @ObservedObject var companion: Companion
  @ObservedObject var listener: Listener
  @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
  @State private var listening = false

  init(bridge: Bridge, companion: Companion) {
    self.bridge = bridge
    self.companion = companion
    self.listener = companion.listener
    _listening = State(initialValue: companion.listening)
  }

  var body: some View {
    Text(statusText)
    if let error = bridge.lastError { Text(error) }
    Divider()

    Section("Voice") {
      Toggle("Listen for “R2” / “Artu”", isOn: $listening)
        .onChange(of: listening) { companion.setListening($0) }
      Text(voiceText)
      ForEach(companion.transcript.suffix(4), id: \.self) { Text($0) }
      Button("Show Voice Log") { NSWorkspace.shared.open(VoiceLog.url) }
      Button("Edit Phrases…") { _ = Phrases.load(); NSWorkspace.shared.open(Phrases.url) }
    }
    Divider()

    Section("Moods") {
      ForEach(Bridge.moods, id: \.self) { mood in
        Button(mood.capitalized) { bridge.react(mood) }
      }
    }
    .disabled(bridge.state != .connected)

    Menu("Controls") {
      Button("Center dome") { bridge.cmd("turnDome", [0]) }
      Button("Lights off") { bridge.cmd("setR2D2LEDColor", [0, 0, 0]) }
      Button("Idle LED animation") { bridge.cmd("startIdleLedAnimation") }
      Button("Bipod") { bridge.cmd("setStance", [2]) }
      Button("Tripod") { bridge.cmd("setStance", [1]) }
      Divider()
      Button("Wake") { bridge.cmd("wake") }
      Button("Sleep") { bridge.cmd("sleep") }
    }
    .disabled(bridge.state != .connected)

    Button("Open Demo Page") { NSWorkspace.shared.open(bridge.pageURL) }
      .disabled(bridge.state == .offline)
    Divider()

    Section("Daemon") {
      if bridge.ownsDaemon {
        Button("Restart") { bridge.restartDaemon() }
        Button("Stop") { bridge.stopDaemon() }
      } else {
        Button("Start") { bridge.startDaemon() }.disabled(bridge.state != .offline)
      }
      Button("Show Log") { NSWorkspace.shared.open(bridge.logURL) }
    }
    Toggle("Launch at Login", isOn: $launchAtLogin)
      .onChange(of: launchAtLogin) { on in
        try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
      }
    Divider()

    Button("Quit R2 Bridge") { NSApp.terminate(nil) }.keyboardShortcut("q")
  }

  private var voiceText: String {
    if case .denied(let why) = listener.phase { return why }
    if !companion.routerReady { return "Ollama model \(Router.model) not found: ollama pull \(Router.model)" }
    if case .hearing = listener.phase { return "Listening…" }
    if listening && !listener.isOn { return "Paused until R2-D2 is back" }
    return listening ? "Push to talk: ⌃⌥R" : "Off. Push to talk still works: ⌃⌥R"
  }

  private static let clock: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm"
    return f
  }()

  private var statusText: String {
    switch bridge.state {
    case .connected: return bridge.rssi.map { "R2-D2 connected (\($0) dBm)" } ?? "R2-D2 connected"
    case .connecting:
      if let since = bridge.awaySince { return "R2-D2 away since \(Self.clock.string(from: since)), looking…" }
      return "Daemon up, looking for R2-D2…"
    case .starting: return "Starting daemon…"
    case .offline: return "Daemon not running"
    }
  }
}
