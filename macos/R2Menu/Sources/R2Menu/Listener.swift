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
  /// Both recognizers' readings of the same sentence, keyed by language, plus the one that heard the wake word.
  var onCommand: ((_ transcripts: [Language: String], _ wokeBy: Language) -> Void)?
  var onWake: ((Language) -> Void)?
  private var heard: [Language: String] = [:]

  private let engine = AVAudioEngine()
  private var sessions: [Language: Session] = [:]
  private var pauseTimer: Timer?
  private var pushToTalk = false

  private struct Session {
    let id = UUID()
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
    VoiceLog.write("listening (input: \(format.sampleRate) Hz, \(format.channelCount) ch)")
    for lang in Language.allCases { startSession(lang) }
  }

  private func startSession(_ lang: Language) {
    guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: Self.locales[lang]!)), recognizer.isAvailable else {
      VoiceLog.write("[\(lang.rawValue)] recognizer unavailable")
      return
    }
    let request = SFSpeechAudioBufferRecognitionRequest()
    request.shouldReportPartialResults = true
    request.taskHint = .dictation
    if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
    var session = Session(recognizer: recognizer, request: request, task: nil)
    let id = session.id
    session.task = recognizer.recognitionTask(with: request) { [weak self] result, error in
      Task { @MainActor in self?.handle(lang, session: id, result: result, error: error) }
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
    startSession(lang)
  }

  private func handle(_ lang: Language, session id: UUID, result: SFSpeechRecognitionResult?, error: Error?) {
    // A cancelled session still reports back once; only the live session may drive anything.
    guard sessions[lang]?.id == id else { return }
    if let result {
      let text = result.bestTranscription.formattedString
      if case .hearing = phase { VoiceLog.write("[\(lang.rawValue)] partial: \(text)") }
      consider(text, from: lang)
      if result.isFinal { finish(lang, text: text); restartSession(lang) }
    }
    // Sessions end on their own after silence (1110), after about a minute, or on error; keep listening.
    if let error {
      let code = (error as NSError).code
      if code != 1110 && code != 216 && code != 301 {
        VoiceLog.write("[\(lang.rawValue)] recognizer error \(code): \(error.localizedDescription)")
      }
      restartSession(lang)
    }
  }

  private func consider(_ text: String, from lang: Language) {
    switch phase {
    case .idle:
      guard let command = Self.afterWake(text, lang) else { return }
      VoiceLog.write("[\(lang.rawValue)] wake word in: \(text)")
      phase = .hearing(lang)
      heard = [lang: command]
      onWake?(lang)
      lastHeard = command
      armPause(seconds: 1.4)
    case .hearing(let owner):
      // Both recognizers keep transcribing; the router picks the language that makes sense.
      heard[lang] = pushToTalk ? text : (Self.afterWake(text, lang) ?? text)
      if owner == lang || pushToTalk {
        lastHeard = heard[lang] ?? text
        armPause(seconds: 1.4)
      }
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
    heard[lang] = (pushToTalk ? text : (Self.afterWake(text, lang) ?? text))
    let transcripts = heard.compactMapValues { t -> String? in
      let clean = t.trimmingCharacters(in: .whitespacesAndNewlines)
      return clean.isEmpty ? nil : clean
    }
    VoiceLog.write("command\(pushToTalk ? " (push to talk)" : "") woke by \(lang.rawValue): " +
      transcripts.map { "[\($0.key.rawValue)] \($0.value)" }.sorted().joined(separator: " | "))
    pushToTalk = false
    phase = .idle
    heard = [:]
    // Start fresh so the next sentence does not carry this one.
    for l in Language.allCases { restartSession(l) }
    guard !transcripts.isEmpty else { return }
    onCommand?(transcripts, lang)
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
