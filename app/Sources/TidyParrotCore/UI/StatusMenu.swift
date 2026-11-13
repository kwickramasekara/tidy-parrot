import AppKit

/// The menu bar icon and menu. Shows whatever it's told; knows nothing about how the app got there.
@MainActor
final class StatusMenu: NSObject {
    private let hotkey: ModifierKey
    private let onRestartEngine: () -> Void
    private let onOpenLog: () -> Void

    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let messageLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")

    init(hotkey: ModifierKey, onRestartEngine: @escaping () -> Void, onOpenLog: @escaping () -> Void) {
        self.hotkey = hotkey
        self.onRestartEngine = onRestartEngine
        self.onOpenLog = onOpenLog
        super.init()

        let menu = NSMenu()
        statusLine.isEnabled = false
        messageLine.isEnabled = false
        messageLine.isHidden = true
        menu.addItem(statusLine)
        menu.addItem(messageLine)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Restart Helper", action: #selector(restartEngine), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Open Log", action: #selector(openLog), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Tidy Parrot", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
    }

    func show(_ status: AppStatus) {
        let (symbol, text) = status.presentation(hotkey: hotkey)
        statusLine.title = text
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: text)
        image?.isTemplate = true
        item.button?.image = image
        item.button?.toolTip = "Tidy Parrot: \(text)"
    }

    /// Second line for the outcome of the last dictation.
    func showMessage(_ text: String) {
        messageLine.title = text
        messageLine.isHidden = text.isEmpty
    }

    @objc private func restartEngine() { onRestartEngine() }
    @objc private func openLog() { onOpenLog() }
}
