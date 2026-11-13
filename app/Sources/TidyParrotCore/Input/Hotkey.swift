import Foundation

enum HotkeyEvent: Equatable, Sendable {
    /// The hotkey was tapped on its own: start recording, or stop and insert.
    case toggle
    /// Esc was pressed: discard the recording, if any.
    case cancel
}

/// A single modifier key used as the dictation hotkey.
struct ModifierKey: Equatable, Sendable {
    let keyCode: UInt16
    /// The modifier-flags bit that is set while this key is down.
    let flagMask: UInt
    let displayName: String

    /// fn has no left and right variants, so the generic NX_SECONDARYFNMASK bit identifies it.
    static let function = ModifierKey(keyCode: 63, flagMask: 0x80_0000, displayName: "fn")
}

/// Tap-to-toggle logic, kept free of NSEvent so it can be tested directly.
struct TapToToggleDetector {
    private static let escapeKeyCode: UInt16 = 53

    let key: ModifierKey
    private var isDown = false
    /// The hotkey doubles as a modifier (fn+arrows, fn+Delete), so a press only counts as a tap if nothing else was
    /// pressed before it was released.
    private var usedAsModifier = false

    init(key: ModifierKey) {
        self.key = key
    }

    mutating func flagsChanged(keyCode: UInt16, modifierFlags: UInt) -> HotkeyEvent? {
        guard keyCode == key.keyCode else {
            if isDown { usedAsModifier = true }
            return nil
        }
        let down = modifierFlags & key.flagMask != 0
        guard down != isDown else { return nil }
        isDown = down
        if down {
            usedAsModifier = false
            return nil
        }
        return usedAsModifier ? nil : .toggle
    }

    mutating func keyDown(keyCode: UInt16) -> HotkeyEvent? {
        if isDown {
            usedAsModifier = true
            return nil
        }
        return keyCode == Self.escapeKeyCode ? .cancel : nil
    }
}
