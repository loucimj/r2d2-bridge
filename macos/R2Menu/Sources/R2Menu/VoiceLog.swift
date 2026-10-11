import Foundation

/// Appends one line per event to ~/Library/Logs/r2d2-voice.log, for tuning recognition and routing.
enum VoiceLog {
  static let url = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Logs/r2d2-voice.log")
  private static let stamp: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return f
  }()

  static func write(_ line: String) {
    let text = "\(stamp.string(from: Date())) \(line)\n"
    if !FileManager.default.fileExists(atPath: url.path) {
      FileManager.default.createFile(atPath: url.path, contents: nil)
    }
    if let handle = try? FileHandle(forWritingTo: url) {
      handle.seekToEndOfFile()
      handle.write(Data(text.utf8))
      try? handle.close()
    }
  }
}
