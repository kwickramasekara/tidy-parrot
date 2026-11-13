import AppKit

@MainActor
protocol TextInserting {
    func insert(_ text: String)
}

/// Puts text into the focused field by pasting: works in nearly every app, unlike setting the field through
/// the Accessibility API. The user's clipboard is put back afterwards.
@MainActor
final class PasteboardTextInserter: TextInserting {
    private let pasteboard: NSPasteboard
    private let paste: @MainActor () -> Void
    /// How long the target app gets to read the clipboard before it's restored.
    private let restoreDelay: Duration
    /// The user's clipboard and the change count of our dictation, while a restore is pending.
    private var pending: (saved: [NSPasteboardItem], ourChange: Int)?
    private var restoreTask: Task<Void, Never>?

    init(
        pasteboard: NSPasteboard = .general, restoreDelay: Duration = .milliseconds(500),
        paste: @escaping @MainActor () -> Void = PasteboardTextInserter.postCommandV
    ) {
        self.pasteboard = pasteboard
        self.restoreDelay = restoreDelay
        self.paste = paste
    }

    func insert(_ text: String) {
        // During a pending restore the clipboard holds our previous dictation, not the user's content, unless they
        // copied something since.
        let saved =
            if let pending, pending.ourChange == pasteboard.changeCount { pending.saved } else { snapshot() }

        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        // nspasteboard.org convention: clipboard managers skip transient entries, so dictations don't fill their history.
        item.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
        pending = (saved, pasteboard.changeCount)

        paste()

        restoreTask?.cancel()
        restoreTask = Task { [weak self, restoreDelay] in
            try? await Task.sleep(for: restoreDelay)
            guard !Task.isCancelled else { return }
            self?.restore()
        }
    }

    private func restore() {
        guard let pending else { return }
        self.pending = nil
        // If something else was copied meanwhile, leave it alone.
        guard pasteboard.changeCount == pending.ourChange else { return }
        pasteboard.clearContents()
        if !pending.saved.isEmpty { pasteboard.writeObjects(pending.saved) }
    }

    private func snapshot() -> [NSPasteboardItem] {
        (pasteboard.pasteboardItems ?? []).map { original in
            let copy = NSPasteboardItem()
            for type in original.types {
                if let data = original.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
    }

    private static func postCommandV() {
        /// V on QWERTY. Other layouts may need a different code.
        let vKeyCode: CGKeyCode = 9
        let source = CGEventSource(stateID: .combinedSessionState)
        for keyDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: keyDown)
            event?.flags = .maskCommand
            event?.post(tap: .cghidEventTap)
        }
    }
}
