import AppKit

@MainActor
public protocol TextInserting {
    func insert(_ text: String)
}

/// Puts text into the focused field by pasting: works in nearly every app, unlike setting the field through
/// the Accessibility API. The user's clipboard is put back afterwards.
@MainActor
public struct PasteboardTextInserter: TextInserting {
    /// How long the target app gets to read the clipboard before it's restored.
    private static let restoreDelay: Duration = .milliseconds(500)
    /// V on QWERTY. Other layouts may need a different code.
    private static let vKeyCode: CGKeyCode = 9

    public init() {}

    public func insert(_ text: String) {
        let pasteboard = NSPasteboard.general
        let saved = Self.snapshot(pasteboard)

        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        // nspasteboard.org convention: clipboard managers skip transient entries, so dictations don't fill their history.
        item.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
        let ourChange = pasteboard.changeCount

        Self.postCommandV()

        Task { @MainActor in
            try? await Task.sleep(for: Self.restoreDelay)
            // If something else was copied meanwhile, leave it alone.
            guard pasteboard.changeCount == ourChange else { return }
            pasteboard.clearContents()
            if !saved.isEmpty { pasteboard.writeObjects(saved) }
        }
    }

    private static func snapshot(_ pasteboard: NSPasteboard) -> [NSPasteboardItem] {
        (pasteboard.pasteboardItems ?? []).map { original in
            let copy = NSPasteboardItem()
            for type in original.types {
                if let data = original.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
    }

    private static func postCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        for keyDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: keyDown)
            event?.flags = .maskCommand
            event?.post(tap: .cghidEventTap)
        }
    }
}
