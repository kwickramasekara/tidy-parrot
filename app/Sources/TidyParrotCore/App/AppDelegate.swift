import AppKit

/// Composition root: builds the live collaborators, connects the controller to the menu, and nothing else.
@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let hotkey = ModifierKey.rightOption

    private var controller: DictationController?
    private var menu: StatusMenu?

    public override init() {
        super.init()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        Log.write("launched")

        let controller = DictationController(
            dependencies: .init(
                hotkey: GlobalHotkeyMonitor(key: Self.hotkey),
                recorder: MicrophoneRecorder(),
                engine: Self.makeEngine(),
                inserter: PasteboardTextInserter(),
                permissions: SystemPermissions(),
                alert: { NSSound.beep() }
            ))
        let menu = StatusMenu(
            hotkey: Self.hotkey,
            onRestartEngine: { [weak controller] in controller?.restartEngine() },
            onOpenLog: { NSWorkspace.shared.open(Log.url) }
        )
        controller.onStatusChange = { [weak menu] in menu?.show($0) }
        controller.onMessage = { [weak menu] in menu?.showMessage($0) }

        self.controller = controller
        self.menu = menu
        controller.start()
    }

    public func applicationWillTerminate(_ notification: Notification) {
        controller?.stop()
    }

    private static func makeEngine() -> any TranscriptionEngine {
        guard let configuration = AppConfiguration.helper(from: Bundle.main.infoDictionary ?? [:]) else {
            return UnavailableEngine(reason: "Helper paths missing from Info.plist; rebuild with make build")
        }
        return HelperProcessEngine(configuration: configuration)
    }
}
