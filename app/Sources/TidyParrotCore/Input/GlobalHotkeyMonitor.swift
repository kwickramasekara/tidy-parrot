import AppKit

@MainActor
public protocol HotkeySource: AnyObject {
    var key: ModifierKey { get }
    var onEvent: ((HotkeyEvent) -> Void)? { get set }
    /// Only call once the app is trusted for Accessibility: monitors added earlier never receive events.
    func start()
}

/// Watches the hotkey system-wide with NSEvent monitors.
@MainActor
public final class GlobalHotkeyMonitor: HotkeySource {
    public var onEvent: ((HotkeyEvent) -> Void)?
    public var key: ModifierKey { detector.key }

    private var detector: HoldToTalkDetector
    private var monitors: [Any] = []

    public init(key: ModifierKey) {
        detector = HoldToTalkDetector(key: key)
    }

    public func start() {
        guard monitors.isEmpty else { return }
        let events: NSEvent.EventTypeMask = [.flagsChanged, .keyDown]
        if let global = NSEvent.addGlobalMonitorForEvents(
            matching: events,
            handler: { [weak self] event in
                MainActor.assumeIsolated { self?.handle(event) }
            })
        {
            monitors.append(global)
        }
        // The global monitor skips events aimed at our own app, e.g. while its menu is open.
        if let local = NSEvent.addLocalMonitorForEvents(
            matching: events,
            handler: { [weak self] event in
                MainActor.assumeIsolated { self?.handle(event) }
                return event
            })
        {
            monitors.append(local)
        }
    }

    private func handle(_ event: NSEvent) {
        let result: HotkeyEvent? =
            switch event.type {
            case .flagsChanged:
                detector.flagsChanged(keyCode: event.keyCode, modifierFlags: event.modifierFlags.rawValue)
            case .keyDown: detector.keyDown()
            default: nil
            }
        if let result { onEvent?(result) }
    }
}
