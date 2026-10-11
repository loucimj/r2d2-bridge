import AppKit
import ServiceManagement
import SwiftUI

@main
struct R2MenuApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
  @StateObject private var bridge = Bridge.shared

  var body: some Scene {
    MenuBarExtra {
      MenuContent(bridge: bridge)
    } label: {
      Image(systemName: bridge.state == .connected
        ? "antenna.radiowaves.left.and.right"
        : "antenna.radiowaves.left.and.right.slash")
    }
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
  @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

  var body: some View {
    Text(statusText)
    if let error = bridge.lastError { Text(error) }
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

  private var statusText: String {
    switch bridge.state {
    case .connected: return "R2-D2 connected"
    case .connecting: return "Daemon up, looking for R2-D2…"
    case .starting: return "Starting daemon…"
    case .offline: return "Daemon not running"
    }
  }
}
