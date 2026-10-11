import AVFoundation

/// Speaks replies with a system voice in the command's language.
final class Speaker: NSObject, AVSpeechSynthesizerDelegate {
  private let synth = AVSpeechSynthesizer()
  /// True from the first word to half a second after the last, so the microphone can ignore R2's own voice.
  var onSpeaking: ((Bool) -> Void)?

  override init() {
    super.init()
    synth.delegate = self
  }

  func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
    onSpeaking?(true)
  }

  func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
      if self?.synth.isSpeaking == false { self?.onSpeaking?(false) }
    }
  }

  func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
    onSpeaking?(false)
  }

  private var generation = 0

  func say(_ text: String, language: Listener.Language) {
    guard !text.isEmpty else { return }
    let utterance = AVSpeechUtterance(string: text)
    utterance.voice = Self.voice(for: language)
    VoiceLog.write("speak [\(utterance.voice?.name ?? "default voice")]: \(text)")
    utterance.rate = AVSpeechUtteranceDefaultSpeechRate
    synth.stopSpeaking(at: .immediate)
    synth.speak(utterance)
    // The delegate's didFinish is not always delivered; never leave the microphone muted.
    generation += 1
    let mine = generation
    let budget = 1.5 + Double(text.count) * 0.09
    DispatchQueue.main.asyncAfter(deadline: .now() + budget) { [weak self] in
      guard let self, self.generation == mine else { return }
      self.synth.stopSpeaking(at: .word)
      self.onSpeaking?(false)
    }
  }

  private static func voice(for language: Listener.Language) -> AVSpeechSynthesisVoice? {
    let preferred = language == .es ? ["es-AR", "es-MX", "es-ES"] : ["en-US", "en-GB"]
    let voices = AVSpeechSynthesisVoice.speechVoices()
    for code in preferred {
      // Prefer the higher quality voices when the user has downloaded any.
      if let best = voices.filter({ $0.language == code }).sorted(by: { $0.quality.rawValue > $1.quality.rawValue }).first {
        return best
      }
    }
    return nil
  }
}
