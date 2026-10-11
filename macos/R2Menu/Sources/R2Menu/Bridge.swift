import Foundation

/// Where the daemon lives. Written into the bundle by scripts/make-app.sh.
struct BridgeConfig: Decodable {
  var projectDir: String
  var nodeBin: String
  var url: String

  static func load() -> BridgeConfig {
    if let file = Bundle.main.url(forResource: "bridge", withExtension: "json"),
       let data = try? Data(contentsOf: file),
       let config = try? JSONDecoder().decode(BridgeConfig.self, from: data) {
      return config
    }
    return BridgeConfig(projectDir: NSHomeDirectory() + "/workspaces/loucimj/r2d2-bridge",
                        nodeBin: "/opt/homebrew/bin", url: "http://127.0.0.1:4242")
  }
}

/// Talks to the r2d2-bridge daemon and supervises its process.
@MainActor
final class Bridge: ObservableObject {
  enum State: String { case offline, starting, connecting, connected }

  static let shared = Bridge()
  static let moods = ["happy", "alarm", "attention", "thinking", "sad", "busy", "idle"]

  @Published private(set) var state: State = .offline
  @Published private(set) var lastError: String?
  let config = BridgeConfig.load()

  private var daemon: Process?
  private var timer: Timer?

  var ownsDaemon: Bool { daemon?.isRunning == true }
  var logURL: URL { URL(fileURLWithPath: NSHomeDirectory() + "/Library/Logs/r2d2-bridge.log") }
  var pageURL: URL { URL(string: config.url)! }

  private init() {
    timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.poll() }
    }
    Task { await pollOnce(); if state == .offline { startDaemon() } }
  }

  func poll() { Task { await pollOnce() } }

  private func pollOnce() async {
    struct Health: Decodable { var connected: Bool }
    do {
      let (data, _) = try await URLSession.shared.data(from: URL(string: config.url + "/health")!)
      let connected = (try? JSONDecoder().decode(Health.self, from: data))?.connected ?? false
      state = connected ? .connected : .connecting
    } catch {
      state = ownsDaemon ? .starting : .offline
    }
  }

  // MARK: commands

  func react(_ mood: String) { post("/react/\(mood)") }
  func cmd(_ method: String, _ args: [Int] = []) { post("/cmd", json: ["method": method, "args": args]) }

  private func post(_ path: String, json: [String: Any]? = nil) {
    var request = URLRequest(url: URL(string: config.url + path)!)
    request.httpMethod = "POST"
    if let json {
      request.httpBody = try? JSONSerialization.data(withJSONObject: json)
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    URLSession.shared.dataTask(with: request).resume()
  }

  // MARK: daemon process

  func startDaemon() {
    guard !ownsDaemon else { return }
    let process = Process()
    // node directly, not the tsx wrapper binary: a wrapper would sit between us and the daemon
    // and the SIGINT sent on quit would never reach it.
    process.executableURL = URL(fileURLWithPath: config.nodeBin + "/node")
    process.arguments = ["--import", "tsx", "src/index.ts"]
    process.currentDirectoryURL = URL(fileURLWithPath: config.projectDir)
    process.environment = ProcessInfo.processInfo.environment
      .merging(["PATH": config.nodeBin + ":/usr/bin:/bin"]) { $1 }
    if !FileManager.default.fileExists(atPath: logURL.path) {
      FileManager.default.createFile(atPath: logURL.path, contents: nil)
    }
    if let log = try? FileHandle(forWritingTo: logURL) {
      log.seekToEndOfFile()
      process.standardOutput = log
      process.standardError = log
    }
    process.terminationHandler = { [weak self] _ in
      Task { @MainActor in
        self?.daemon = nil
        self?.poll()
      }
    }
    do {
      try process.run()
      daemon = process
      state = .starting
      lastError = nil
    } catch {
      lastError = error.localizedDescription
    }
  }

  /// SIGINT, so the daemon puts R2 to sleep and disconnects cleanly.
  func stopDaemon() { daemon?.interrupt() }

  /// Stops the daemon and calls `done` once it has exited, or after `timeout` seconds.
  func stopDaemon(timeout: TimeInterval, done: @escaping () -> Void) {
    guard let process = daemon, process.isRunning else { return done() }
    var finished = false
    let finish = { if !finished { finished = true; done() } }
    process.terminationHandler = { _ in DispatchQueue.main.async(execute: finish) }
    process.interrupt()
    DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
      if process.isRunning { process.terminate() }
      finish()
    }
  }

  func restartDaemon() {
    stopDaemon()
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.startDaemon() }
  }
}
