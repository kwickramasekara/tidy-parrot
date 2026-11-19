import AppKit

/// The pill at the top centre of the screen, shown from the tap until the recording ends: a spinner and flat bars
/// while the mic starts, then moving level bars and the elapsed time.
/// It must never take focus or activate the app: the paste after the stopping tap goes to whichever app is frontmost.
@MainActor
final class RecordingIndicator {
    /// What the pill shows.
    enum Mode: Equatable {
        case hidden, starting, listening

        init(status: AppStatus) {
            switch status {
            case .starting: self = .starting
            case .listening: self = .listening
            case .needsAccessibility, .transcribing, .loading, .unloaded, .ready, .vocabularyProblem, .failed:
                self = .hidden
            }
        }
    }

    static let size = NSSize(width: 132, height: 36)
    /// Gap between the menu bar and the pill.
    static let topMargin: CGFloat = 8
    private static let padding = NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)
    /// The label pads its text by a few points already, so the visible gap is wider than this.
    private static let gap: CGFloat = 4
    private static let barCount = 16

    private let takeLevel: @MainActor () -> Float
    private let bars = LevelBarsView(barCount: barCount)
    private let time = NSTextField(labelWithString: elapsedText(.zero))
    private let spinner = NSProgressIndicator()
    private lazy var pill = Self.makePill(bars: bars, time: time, spinner: spinner)
    /// A new panel for every showing. macOS can pin a hidden all-Spaces panel to one desktop (reportedly when a
    /// full-screen Space closes), and from then on it never shows over a full-screen app. Setting
    /// `collectionBehavior` again doesn't undo that; a new panel joins every Space.
    private var panel: NSPanel?
    private var startedAt = ContinuousClock.now
    private var mode = Mode.hidden

    init(takeLevel: @escaping @MainActor () -> Float) {
        self.takeLevel = takeLevel
    }

    func show(_ mode: Mode) {
        guard mode != self.mode else { return }
        if self.mode == .hidden { orderFront() }
        self.mode = mode
        switch mode {
        case .hidden: hide()
        case .starting:
            bars.stop()
            time.isHidden = true
            spinner.startAnimation(nil)
        case .listening:
            spinner.stopAnimation(nil)
            time.isHidden = false
            // The clock starts with the recording, not with the pill.
            startedAt = .now
            time.stringValue = Self.elapsedText(.zero)
            bars.start { [weak self] in self?.step() ?? 0 }
        }
    }

    /// Top centre of `visibleFrame`, which already excludes the menu bar and the notch.
    static func frame(in visibleFrame: NSRect) -> NSRect {
        NSRect(
            x: (visibleFrame.midX - size.width / 2).rounded(),
            y: visibleFrame.maxY - size.height - topMargin,
            width: size.width,
            height: size.height)
    }

    /// "0:09", "1:05".
    static func elapsedText(_ elapsed: Duration) -> String {
        let seconds = max(elapsed.components.seconds, 0)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    /// Before the bars start, so their display link syncs to the screen the panel is on.
    private func orderFront() {
        guard let screen = Self.screenUnderPointer() else { return }
        let panel = Self.makePanel(content: pill)
        panel.setFrame(Self.frame(in: screen.visibleFrame), display: true)
        // Not makeKeyAndOrderFront: that would make the panel key and take keyboard focus from the user's app.
        panel.orderFrontRegardless()
        self.panel = panel
    }

    private func hide() {
        bars.stop()
        spinner.stopAnimation(nil)
        panel?.orderOut(nil)
        panel = nil
    }

    /// One bar step: refreshes the clock, which needs no finer resolution, and returns the next level.
    private func step() -> Float {
        let text = Self.elapsedText(startedAt.duration(to: .now))
        if time.stringValue != text { time.stringValue = text }
        return takeLevel()
    }

    /// The screen the user is most likely looking at. An accessory app has no key window, so `NSScreen.main`
    /// can't say which screen holds the focused text field; the pointer is the best cheap signal.
    private static func screenUnderPointer() -> NSScreen? {
        let pointer = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.main
    }

    private static func makePill(bars: NSView, time: NSTextField, spinner: NSProgressIndicator) -> NSView {
        let pill = NSView(frame: NSRect(origin: .zero, size: size))
        pill.wantsLayer = true
        if let layer = pill.layer {
            layer.backgroundColor = NSColor.white.cgColor
            layer.cornerRadius = size.height / 2
            // A hairline keeps the pill visible on white pages.
            layer.borderColor = NSColor.black.withAlphaComponent(0.12).cgColor
            layer.borderWidth = 0.5
        }

        time.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        time.textColor = .black
        time.alignment = .right
        // Measured on "0:00": monospaced digits make every time up to "9:59" the same width, and recordings stop
        // at 3 minutes.
        let timeSize = time.fittingSize
        time.frame = NSRect(
            x: size.width - padding.right - timeSize.width, y: ((size.height - timeSize.height) / 2).rounded(),
            width: timeSize.width, height: timeSize.height)

        bars.frame = NSRect(
            x: padding.left, y: padding.bottom,
            width: size.width - padding.left - padding.right - timeSize.width - gap,
            height: size.height - padding.top - padding.bottom)

        // In the time's place while the mic starts, centred on it.
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        let spinnerSize = spinner.fittingSize
        spinner.frame = NSRect(
            x: (time.frame.midX - spinnerSize.width / 2).rounded(),
            y: ((size.height - spinnerSize.height) / 2).rounded(),
            width: spinnerSize.width, height: spinnerSize.height)

        pill.addSubview(bars)
        pill.addSubview(time)
        pill.addSubview(spinner)
        return pill
    }

    private static func makePanel(content: NSView) -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true)
        panel.contentView = content
        // The pill is always white, so draw the red in its light-mode shade even when the system is dark.
        panel.appearance = NSAppearance(named: .aqua)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.isFloatingPanel = true
        panel.level = .statusBar
        // Panels hide when their app deactivates by default, and this accessory app is never active.
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        return panel
    }
}
