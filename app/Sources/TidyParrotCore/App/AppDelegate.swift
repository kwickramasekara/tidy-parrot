import AppKit

/// Composition root: builds the live collaborators, connects the controller to the menu, and nothing else.
@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let hotkey = ModifierKey.function

    private var controller: DictationController?
    private var menu: StatusMenu?
    private var indicator: RecordingIndicator?

    public override init() {
        super.init()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        Log.write("launched")

        let recorder = MicrophoneRecorder()
        let controller = DictationController(
            dependencies: .init(
                hotkey: GlobalHotkeyMonitor(key: Self.hotkey),
                recorder: recorder,
                engine: Self.makeEngine(),
                inserter: PasteboardTextInserter(),
                permissions: SystemPermissions(),
                play: SystemSounds.play
            ))
        let menu = StatusMenu(
            icon: Self.makeMenuBarIcon(),
            hotkey: Self.hotkey,
            onRestartEngine: { [weak controller] in controller?.restartEngine() },
            onOpenLog: { NSWorkspace.shared.open(Log.url) }
        )
        let indicator = RecordingIndicator(takeLevel: { [weak recorder] in recorder?.takeLevel() ?? 0 })
        controller.onStatusChange = { [weak menu, weak indicator] status in
            menu?.show(status)
            indicator?.setVisible(status == .listening)
        }
        controller.onMessage = { [weak menu] in menu?.showMessage($0) }

        self.controller = controller
        self.menu = menu
        self.indicator = indicator
        controller.start()
    }

    public func applicationWillTerminate(_ notification: Notification) {
        controller?.stop()
    }

    /// `scripts/build.sh` copies the parrot into the bundle. Without it (e.g. `swift run`), fall back to a system bird.
    private static func makeMenuBarIcon() -> NSImage {
        Bundle.main.image(forResource: "MenuBarIcon")
            ?? NSImage(systemSymbolName: "bird", accessibilityDescription: nil)
            ?? NSImage()
    }

    private static func makeEngine() -> any TranscriptionEngine {
        guard let configuration = HelperProcessEngine.Configuration(infoDictionary: Bundle.main.infoDictionary ?? [:])
        else {
            return UnavailableEngine(reason: "Helper paths missing from Info.plist; rebuild with make build")
        }
        return HelperProcessEngine(configuration: configuration)
    }
}
