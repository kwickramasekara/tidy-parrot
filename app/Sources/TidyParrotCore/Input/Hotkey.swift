import Foundation

enum HotkeyEvent: Equatable, Sendable {
    case press
    case release
    /// Another key was pressed during the hold, e.g. ⌥E for an accent, so this wasn't dictation.
    case cancel
}

/// A single modifier key used for hold-to-talk, identified by its side-specific device mask.
struct ModifierKey: Equatable, Sendable {
    let keyCode: UInt16
    /// NX_DEVICE*KEYMASK bit for this key, which tells left and right modifiers apart.
    let deviceMask: UInt
    let displayName: String

    static let rightOption = ModifierKey(keyCode: 61, deviceMask: 0x40, displayName: "Right ⌥")
}

/// Hold-to-talk logic, kept free of NSEvent so it can be tested directly.
struct HoldToTalkDetector {
    let key: ModifierKey
    private var isHeld = false

    init(key: ModifierKey) {
        self.key = key
    }

    mutating func flagsChanged(keyCode: UInt16, modifierFlags: UInt) -> HotkeyEvent? {
        guard keyCode == key.keyCode else { return nil }
        let down = modifierFlags & key.deviceMask != 0
        if down && !isHeld {
            isHeld = true
            return .press
        }
        if !down && isHeld {
            isHeld = false
            return .release
        }
        return nil
    }

    mutating func keyDown() -> HotkeyEvent? {
        guard isHeld else { return nil }
        isHeld = false
        return .cancel
    }
}
