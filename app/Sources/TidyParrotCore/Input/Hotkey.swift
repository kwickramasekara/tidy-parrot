import Foundation

enum HotkeyEvent: Equatable, Sendable {
    /// The hotkey went down on its own. It may yet turn out to be a shortcut, so nothing the user notices should
    /// happen. Followed by `toggle` or `pressAbandoned`.
    case pressBegan
    /// Another key was pressed while the hotkey was held: this press is a shortcut, not a tap. Sent once per press.
    case pressAbandoned
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

    /// The hotkey doubles as a modifier (fn+arrows, fn+Delete), so a press only counts as a tap if nothing else was
    /// pressed before it was released.
    private enum Press {
        case up, clean, usedAsModifier
    }

    let key: ModifierKey
    private var press = Press.up

    init(key: ModifierKey) {
        self.key = key
    }

    mutating func flagsChanged(keyCode: UInt16, modifierFlags: UInt) -> HotkeyEvent? {
        guard keyCode == key.keyCode else { return otherKeyPressed() }
        let down = modifierFlags & key.flagMask != 0
        switch (press, down) {
        case (.up, true):
            press = .clean
            return .pressBegan
        case (.clean, false):
            press = .up
            return .toggle
        case (.usedAsModifier, false):
            press = .up
            return nil
        // A repeated flags event for the state we're already in.
        case (.up, false), (.clean, true), (.usedAsModifier, true):
            return nil
        }
    }

    mutating func keyDown(keyCode: UInt16) -> HotkeyEvent? {
        guard press == .up else { return otherKeyPressed() }
        return keyCode == Self.escapeKeyCode ? .cancel : nil
    }

    private mutating func otherKeyPressed() -> HotkeyEvent? {
        guard press == .clean else { return nil }
        press = .usedAsModifier
        return .pressAbandoned
    }
}
