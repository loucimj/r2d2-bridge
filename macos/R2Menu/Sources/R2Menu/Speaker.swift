import AVFoundation

/// Speaks replies with a system voice in the command's language.
final class Speaker {
  private let synth = AVSpeechSynthesizer()

  func say(_ text: String, language: Listener.Language) {
    guard !text.isEmpty else { return }
    let utterance = AVSpeechUtterance(string: text)
    utterance.voice = Self.voice(for: language)
    utterance.rate = AVSpeechUtteranceDefaultSpeechRate
    synth.stopSpeaking(at: .immediate)
    synth.speak(utterance)
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
