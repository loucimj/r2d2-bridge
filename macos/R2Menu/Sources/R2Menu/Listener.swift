import AVFoundation
import Speech

/// Always-on listener. Two on-device recognizers (English and Spanish) share one microphone tap;
/// the first to hear its wake word ("R2" / "Artu") owns the utterance until a pause.
@MainActor
final class Listener: ObservableObject {
  enum Phase: Equatable { case off, idle, hearing(Language), denied(String) }
  enum Language: String { case en, es }

  @Published private(set) var phase: Phase = .off
  @Published private(set) var lastHeard = ""
  var onCommand: ((String, Language) -> Void)?
  var onWake: ((Language) -> Void)?

  private let engine = AVAudioEngine()
  private var sessions: [Language: Session] = [:]
  private var pauseTimer: Timer?
  private var pushToTalk = false

  private struct Session {
    let recognizer: SFSpeechRecognizer
    var request: SFSpeechAudioBufferRecognitionRequest
    var task: SFSpeechRecognitionTask?
  }

  private static let locales: [Language: String] = [.en: "en-US", .es: "es-AR"]
  private static let wake: [Language: [String]] = [
    .en: ["r2", "r 2", "artoo", "are two", "are too"],
    .es: ["artu", "arturo", "arturito", "r2", "erre dos"],
  ]

  var isOn: Bool { phase != .off }

  func start() {
    guard phase == .off else { return }
    SFSpeechRecognizer.requestAuthorization { [weak self] status in
      Task { @MainActor in
        guard let self else { return }
        guard status == .authorized else {
          self.phase = .denied("Speech recognition not allowed")
          return
        }
        let ok = await AVCaptureDevice.requestAccess(for: .audio)
        if ok { self.begin() } else { self.phase = .denied("Microphone not allowed") }
      }
    }
  }

  func stop() {
    pauseTimer?.invalidate()
    for lang in sessions.keys { endSession(lang) }
    engine.stop()
    engine.inputNode.removeTap(onBus: 0)
    phase = .off
  }

  /// Hotkey: take the next sentence as a command without a wake word.
  func captureNow() {
    guard isOn else { return }
    pushToTalk = true
    phase = .hearing(.es)
    onWake?(.es)
    armPause(seconds: 4)
  }

  private func begin() {
    let input = engine.inputNode
    let format = input.outputFormat(forBus: 0)
    input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
      Task { @MainActor in self?.sessions.values.forEach { $0.request.append(buffer) } }
    }
    do {
      try engine.start()
    } catch {
      return phase = .denied("Microphone failed: \(error.localizedDescription)")
    }
    phase = .idle
    for lang in Language.allCases { startSession(lang) }
  }

  private func startSession(_ lang: Language) {
    guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: Self.locales[lang]!)), recognizer.isAvailable else { return }
    let request = SFSpeechAudioBufferRecognitionRequest()
    request.shouldReportPartialResults = true
    request.taskHint = .dictation
    if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
    var session = Session(recognizer: recognizer, request: request, task: nil)
    session.task = recognizer.recognitionTask(with: request) { [weak self] result, error in
      Task { @MainActor in self?.handle(lang, result: result, error: error) }
    }
    sessions[lang] = session
  }

  private func endSession(_ lang: Language) {
    sessions[lang]?.request.endAudio()
    sessions[lang]?.task?.cancel()
    sessions[lang] = nil
  }

  private func restartSession(_ lang: Language) {
    endSession(lang)
    guard isOn else { return }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.startSession(lang) }
  }

  private func handle(_ lang: Language, result: SFSpeechRecognitionResult?, error: Error?) {
    if let result {
      let text = result.bestTranscription.formattedString
      consider(text, from: lang)
      if result.isFinal { finish(lang, text: text); restartSession(lang) }
    }
    // Recognition sessions end after about a minute or on error; keep listening.
    if error != nil { restartSession(lang) }
  }

  private func consider(_ text: String, from lang: Language) {
    switch phase {
    case .idle:
      guard let command = Self.afterWake(text, lang) else { return }
      phase = .hearing(lang)
      onWake?(lang)
      lastHeard = command
      armPause(seconds: 1.4)
    case .hearing(let owner) where owner == lang || pushToTalk:
      lastHeard = pushToTalk ? text : (Self.afterWake(text, lang) ?? text)
      armPause(seconds: 1.4)
    default:
      break
    }
  }

  private func armPause(seconds: TimeInterval) {
    pauseTimer?.invalidate()
    pauseTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
      Task { @MainActor in
        guard let self, case .hearing(let lang) = self.phase else { return }
        self.finish(lang, text: self.lastHeard)
      }
    }
  }

  private func finish(_ lang: Language, text: String) {
    guard case .hearing(let owner) = phase, owner == lang || pushToTalk else { return }
    pauseTimer?.invalidate()
    let command = (pushToTalk ? text : (Self.afterWake(text, lang) ?? text)).trimmingCharacters(in: .whitespacesAndNewlines)
    pushToTalk = false
    phase = .idle
    // Start fresh so the next sentence does not carry this one.
    for l in Language.allCases { restartSession(l) }
    guard !command.isEmpty else { return }
    onCommand?(command, lang)
  }

  /// The words after the wake word, or nil when the text has no wake word.
  static func afterWake(_ text: String, _ lang: Language) -> String? {
    let lower = text.lowercased()
      .replacingOccurrences(of: "[,.!?¿¡]", with: " ", options: .regularExpression)
      .replacingOccurrences(of: "  +", with: " ", options: .regularExpression)
    for word in wake[lang]! {
      guard let range = lower.range(of: "\\b\(word)\\b", options: .regularExpression) else { continue }
      return String(lower[range.upperBound...])
    }
    return nil
  }
}

extension Listener.Language: CaseIterable {}
