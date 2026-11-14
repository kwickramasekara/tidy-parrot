import AppKit

/// The menu bar icon and menu. Shows whatever it's told; knows nothing about how the app got there.
@MainActor
final class StatusMenu: NSObject {
    private let hotkey: ModifierKey
    private let diagnostics: () -> [String]
    private let canPasteLastDictation: () -> Bool
    private let onPasteLastDictation: () -> Void
    private let onRestartEngine: () -> Void
    private let onOpenLog: () -> Void

    // Variable length so the warning emoji fits beside the icon when there's a problem.
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let messageLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let headerSeparator = NSMenuItem.separator()
    /// Shown only when the menu is opened with Option held, like the system Wi-Fi menu.
    private var diagnosticItems: [NSMenuItem] = []

    init(
        icon: NSImage, hotkey: ModifierKey, diagnostics: @escaping () -> [String],
        canPasteLastDictation: @escaping () -> Bool, onPasteLastDictation: @escaping () -> Void,
        onRestartEngine: @escaping () -> Void, onOpenLog: @escaping () -> Void
    ) {
        self.hotkey = hotkey
        self.diagnostics = diagnostics
        self.canPasteLastDictation = canPasteLastDictation
        self.onPasteLastDictation = onPasteLastDictation
        self.onRestartEngine = onRestartEngine
        self.onOpenLog = onOpenLog
        super.init()

        // Template images get tinted by macOS to suit light and dark menu bars.
        icon.isTemplate = true
        item.button?.image = icon

        let menu = NSMenu()
        menu.delegate = self
        statusLine.isEnabled = false
        messageLine.isEnabled = false
        statusLine.isHidden = true
        messageLine.isHidden = true
        updateHeaderSeparator()
        menu.addItem(statusLine)
        menu.addItem(messageLine)
        menu.addItem(headerSeparator)
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
        // Routine states are noise in the menu; the space is kept for problems.
        statusLine.isHidden = !needsAttention
        updateHeaderSeparator()
        guard let button = item.button else { return }
        button.title = needsAttention ? "⚠️" : ""
        button.imagePosition = needsAttention ? .imageLeading : .imageOnly
        let label = "Tidy Parrot: \(text)"
        button.toolTip = label
        button.setAccessibilityLabel(label)
    }

    /// Second line for the last dictation's error. Empty hides it.
    func showMessage(_ text: String) {
        messageLine.title = text
        messageLine.isHidden = text.isEmpty
        updateHeaderSeparator()
    }

    /// Without this, a menu with no status lines would open on a bare separator.
    private func updateHeaderSeparator() {
        headerSeparator.isHidden = statusLine.isHidden && messageLine.isHidden
    }

    @objc private func pasteLastDictation() { onPasteLastDictation() }
    @objc private func restartEngine() { onRestartEngine() }
    @objc private func openLog() { onOpenLog() }
}

extension StatusMenu: NSMenuDelegate {
    // Not menuWillOpen: AppKit says not to change the menu's items there.
    func menuNeedsUpdate(_ menu: NSMenu) {
        diagnosticItems.forEach(menu.removeItem)
        diagnosticItems = []
        guard NSEvent.modifierFlags.contains(.option) else { return }

        diagnosticItems = diagnostics().map { line in
            let item = NSMenuItem(title: line, action: nil, keyEquivalent: "")
            item.isEnabled = false
            return item
        }
        diagnosticItems.append(.separator())
        let start = menu.index(of: headerSeparator) + 1
        for (offset, item) in diagnosticItems.enumerated() {
            menu.insertItem(item, at: start + offset)
        }
    }
}

/// The menu auto-enables its items, so this greys out Paste Last Dictation until there's one to paste.
extension StatusMenu: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        menuItem.action == #selector(pasteLastDictation) ? canPasteLastDictation() : true
    }
}
