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
  private var lastLogged: [Language: String] = [:]

  private let engine = AVAudioEngine()
  private var sessions: [Language: Session] = [:]
  private let feed = RequestFeed()
  private var pauseTimer: Timer?
  private var pushToTalk = false
  /// Set while R2's own voice plays, so it cannot wake or command itself.
  var muted = false {
    didSet { if muted != oldValue { VoiceLog.write(muted ? "muted while speaking" : "unmuted"); if !muted { for l in Language.allCases { restartSession(l) } } } }
  }

  private struct Session {
    let id = UUID()
    let recognizer: SFSpeechRecognizer
    var request: SFSpeechAudioBufferRecognitionRequest
    var task: SFSpeechRecognitionTask?
  }

  private static let locales: [Language: String] = [.en: "en-US", .es: "es-AR"]
  // Matched after lowercasing and stripping accents, so "Artú", "Arturo", "R-2", "Artoo" all count.
  // "Artú" often arrives as a bare "Tú"; that is accepted only at the start of a transcript.
  private static let wake = "(\\b(artu|arto|artur|arturo|arturito|artoo|ar2|r2|r 2|r two|are too|are two|erre dos)\\b|^ ?(tu|too|two)\\b)"

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
    // Append on the audio thread: the engine reuses the buffer once this block returns.
    let feed = self.feed
    input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in
      feed.append(buffer)
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
    // Server-side by default: on-device sessions on this Mac end with "no speech" 100 ms after
    // starting. Opt in with `defaults write com.loucimj.r2d2-bridge onDevice -bool true`.
    if recognizer.supportsOnDeviceRecognition && UserDefaults.standard.bool(forKey: "onDevice") {
      request.requiresOnDeviceRecognition = true
    }
    var session = Session(recognizer: recognizer, request: request, task: nil)
    let id = session.id
    session.task = recognizer.recognitionTask(with: request) { [weak self] result, error in
      Task { @MainActor in self?.handle(lang, session: id, result: result, error: error) }
    }
    sessions[lang] = session
    feed.set(lang.rawValue, request)
    VoiceLog.write("[\(lang.rawValue)] session started (on-device: \(request.requiresOnDeviceRecognition))")
  }

  private func endSession(_ lang: Language) {
    feed.set(lang.rawValue, nil)
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
      if text != lastLogged[lang] {
        lastLogged[lang] = text
        VoiceLog.write("[\(lang.rawValue)] \(phase == .idle ? "idle" : "partial"): \(text)")
      }
      consider(text, from: lang)
      if result.isFinal { finish(lang, text: text); restartSession(lang) }
    }
    // Sessions end on their own after silence (1110), after about a minute, or on error; keep listening.
    if let error {
      let code = (error as NSError).code
      VoiceLog.write("[\(lang.rawValue)] session ended, error \(code): \(error.localizedDescription) (fed \(feed.frames) frames so far)")
      restartSession(lang)
    }
  }

  private func consider(_ text: String, from lang: Language) {
    if muted { return }
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

  /// The words after the wake word, in the recognizer's own spelling, or nil when there is no wake word.
  static func afterWake(_ text: String, _ lang: Language) -> String? {
    let words = text.split(separator: " ").map(String.init)
    let plain = words.map {
      $0.lowercased().folding(options: .diacriticInsensitive, locale: nil)
        .replacingOccurrences(of: "[,.!?¿¡]", with: "", options: .regularExpression)
        .replacingOccurrences(of: "-", with: " ")
    }.joined(separator: " ")
    guard let range = plain.range(of: wake, options: .regularExpression) else { return nil }
    let consumed = plain[..<range.upperBound].split(separator: " ").count
    return words.dropFirst(consumed).joined(separator: " ")
  }
}

extension Listener.Language: CaseIterable {}

/// The live recognition requests, readable from the audio thread.
final class RequestFeed: @unchecked Sendable {
  private let lock = NSLock()
  private var requests: [String: SFSpeechAudioBufferRecognitionRequest] = [:]

  func set(_ key: String, _ request: SFSpeechAudioBufferRecognitionRequest?) {
    lock.lock()
    requests[key] = request
    lock.unlock()
  }

  private(set) var frames = 0

  func append(_ buffer: AVAudioPCMBuffer) {
    lock.lock()
    let current = Array(requests.values)
    frames += Int(buffer.frameLength)
    let first = frames == Int(buffer.frameLength)
    lock.unlock()
    if first { VoiceLog.write("audio flowing: first buffer \(buffer.frameLength) frames, \(buffer.format.sampleRate) Hz, requests: \(current.count)") }
    // Once a second, the peak level: 0 means the microphone is delivering silence.
    if frames / 44100 != (frames - Int(buffer.frameLength)) / 44100, let data = buffer.floatChannelData?[0] {
      var peak: Float = 0
      for i in 0..<Int(buffer.frameLength) { peak = max(peak, abs(data[i])) }
      VoiceLog.write(String(format: "level: peak %.4f", peak))
    }
    current.forEach { $0.append(buffer) }
  }
}
