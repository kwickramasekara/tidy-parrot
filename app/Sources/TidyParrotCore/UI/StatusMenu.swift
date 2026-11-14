import AppKit

/// The menu bar icon and menu. Shows whatever it's told; knows nothing about how the app got there.
@MainActor
final class StatusMenu: NSObject {
    private let hotkey: ModifierKey
    private let canPasteLastDictation: () -> Bool
    private let onPasteLastDictation: () -> Void
    private let onRestartEngine: () -> Void
    private let onOpenLog: () -> Void

    // Variable length so the warning emoji fits beside the icon when there's a problem.
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let messageLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")

    init(
        icon: NSImage, hotkey: ModifierKey, canPasteLastDictation: @escaping () -> Bool,
        onPasteLastDictation: @escaping () -> Void, onRestartEngine: @escaping () -> Void,
        onOpenLog: @escaping () -> Void
    ) {
        self.hotkey = hotkey
        self.canPasteLastDictation = canPasteLastDictation
        self.onPasteLastDictation = onPasteLastDictation
        self.onRestartEngine = onRestartEngine
        self.onOpenLog = onOpenLog
        super.init()

        // Template images get tinted by macOS to suit light and dark menu bars.
        icon.isTemplate = true
        item.button?.image = icon

        let menu = NSMenu()
        statusLine.isEnabled = false
        messageLine.isEnabled = false
        messageLine.isHidden = true
        menu.addItem(statusLine)
        menu.addItem(messageLine)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Paste Last Dictation", action: #selector(pasteLastDictation), keyEquivalent: "")
            .target = self
        menu.addItem(withTitle: "Restart Helper", action: #selector(restartEngine), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Open Log", action: #selector(openLog), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Tidy Parrot", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
    }

    func show(_ status: AppStatus) {
        let (needsAttention, text) = status.presentation(hotkey: hotkey)
        statusLine.title = text
        guard let button = item.button else { return }
        button.title = needsAttention ? "⚠️" : ""
        button.imagePosition = needsAttention ? .imageLeading : .imageOnly
        let label = "Tidy Parrot: \(text)"
        button.toolTip = label
        button.setAccessibilityLabel(label)
    }

    /// Second line for the outcome of the last dictation.
    func showMessage(_ text: String) {
        messageLine.title = text
        messageLine.isHidden = text.isEmpty
    }

    @objc private func pasteLastDictation() { onPasteLastDictation() }
    @objc private func restartEngine() { onRestartEngine() }
    @objc private func openLog() { onOpenLog() }
}

/// The menu auto-enables its items, so this greys out Paste Last Dictation until there's one to paste.
extension StatusMenu: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        menuItem.action == #selector(pasteLastDictation) ? canPasteLastDictation() : true
    }
}
