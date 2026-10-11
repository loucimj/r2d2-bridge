import AppKit
import Carbon
import Foundation

/// A global hotkey through Carbon's RegisterEventHotKey, which needs no Accessibility permission.
final class Hotkey {
  private var ref: EventHotKeyRef?
  private var handler: EventHandlerRef?
  private let action: () -> Void

  init?(keyCode: UInt32, modifiers: NSEvent.ModifierFlags, action: @escaping () -> Void) {
    self.action = action
    var mods: UInt32 = 0
    if modifiers.contains(.control) { mods |= UInt32(controlKey) }
    if modifiers.contains(.option) { mods |= UInt32(optionKey) }
    if modifiers.contains(.shift) { mods |= UInt32(shiftKey) }
    if modifiers.contains(.command) { mods |= UInt32(cmdKey) }
    var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    let me = Unmanaged.passUnretained(self).toOpaque()
    let status = InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
      guard let userData else { return noErr }
      Unmanaged<Hotkey>.fromOpaque(userData).takeUnretainedValue().action()
      return noErr
    }, 1, &spec, me, &handler)
    guard status == noErr else { return nil }
    let id = EventHotKeyID(signature: OSType(0x5232_4844) /* R2HD */, id: 1)
    guard RegisterEventHotKey(keyCode, mods, id, GetApplicationEventTarget(), 0, &ref) == noErr else { return nil }
  }

  deinit {
    if let ref { UnregisterEventHotKey(ref) }
    if let handler { RemoveEventHandler(handler) }
  }
}
