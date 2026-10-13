import Foundation

/// Runs the local model server so nothing outside the app needs to be started by hand:
/// starts `ollama serve` when nothing answers on its port, pulls the model on first run,
/// and stops a server it started when the app quits.
@MainActor
final class Ollama: ObservableObject {
  enum Status: Equatable { case off, checking, notInstalled, starting, pulling(Int), ready, failed(String) }

  @Published private(set) var status: Status = .off
  private var server: Process?
  private var puller: Process?
  private let base = Router.ollama

  var ownsServer: Bool { server?.isRunning == true }
  var logURL: URL { URL(fileURLWithPath: NSHomeDirectory() + "/Library/Logs/r2d2-ollama.log") }

  static let candidates = [
    "/opt/homebrew/bin/ollama", "/usr/local/bin/ollama",
    "/Applications/Ollama.app/Contents/Resources/ollama", NSHomeDirectory() + "/.ollama/bin/ollama",
  ]
  static var binary: String? { candidates.first { FileManager.default.isExecutableFile(atPath: $0) } }

  /// Brings the server and the model up, then returns once the model can answer.
  func ensureReady() async {
    status = .checking
    if await serverAnswers() == false {
      guard startServer() else { return }
      for _ in 0..<40 where await serverAnswers() == false { try? await Task.sleep(for: .milliseconds(250)) }
    }
    if await Router.available {
      status = .ready
      return
    }
    await pullModel()
    status = await Router.available ? .ready : .failed("model \(Router.model) still missing")
  }

  /// Listening off: nothing needs the model, so a server this app started goes away with it.
  func stopIfOwned() {
    if let server, server.isRunning {
      server.terminate()
      VoiceLog.write("ollama serve stopped")
    }
    server = nil
    status = .off
  }

  /// R2 away: free the model's memory (about 2.5 GB) but keep the server, so coming back is quick.
  func unloadModel() {
    var request = URLRequest(url: base.appending(path: "api/generate"), timeoutInterval: 5)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try? JSONSerialization.data(withJSONObject: ["model": Router.model, "keep_alive": 0])
    URLSession.shared.dataTask(with: request).resume()
    VoiceLog.write("model unloaded")
  }

  private func serverAnswers() async -> Bool {
    var request = URLRequest(url: base.appending(path: "api/version"), timeoutInterval: 1)
    request.httpMethod = "GET"
    return (try? await URLSession.shared.data(for: request)) != nil
  }

  private func startServer() -> Bool {
    guard let bin = Self.binary else {
      status = .notInstalled
      return false
    }
    status = .starting
    let process = Process()
    process.executableURL = URL(fileURLWithPath: bin)
    process.arguments = ["serve"]
    process.environment = ProcessInfo.processInfo.environment.merging([
      "OLLAMA_HOST": "127.0.0.1:11434", "OLLAMA_KEEP_ALIVE": "30m",
    ]) { $1 }
    if !FileManager.default.fileExists(atPath: logURL.path) {
      FileManager.default.createFile(atPath: logURL.path, contents: nil)
    }
    if let log = try? FileHandle(forWritingTo: logURL) {
      log.seekToEndOfFile()
      process.standardOutput = log
      process.standardError = log
    }
    process.terminationHandler = { [weak self] _ in Task { @MainActor in self?.server = nil } }
    do {
      try process.run()
      server = process
      VoiceLog.write("ollama serve started (pid \(process.processIdentifier))")
      return true
    } catch {
      status = .failed("could not start ollama: \(error.localizedDescription)")
      return false
    }
  }

  /// `ollama pull`, reading its progress lines into the menu.
  private func pullModel() async {
    guard let bin = Self.binary else { return }
    status = .pulling(0)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: bin)
    process.arguments = ["pull", Router.model]
    process.environment = ProcessInfo.processInfo.environment.merging(["OLLAMA_HOST": "127.0.0.1:11434"]) { $1 }
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let text = String(decoding: handle.availableData, as: UTF8.self)
      guard let m = text.range(of: "[0-9]{1,3}%", options: [.regularExpression, .backwards]) else { return }
      let pct = Int(text[m].dropLast()) ?? 0
      Task { @MainActor in self?.status = .pulling(pct) }
    }
    do {
      try process.run()
      puller = process
      VoiceLog.write("pulling \(Router.model)")
    } catch {
      status = .failed("could not run ollama pull: \(error.localizedDescription)")
      return
    }
    await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
      process.terminationHandler = { _ in done.resume() }
    }
    pipe.fileHandleForReading.readabilityHandler = nil
    puller = nil
  }
}
