import AppKit
import QuartzCore

/// The animated state of the bars: the levels they're heading for and the heights they show on the way there.
/// A new level enters on the right as a dot, grows to its height, and the bars slide left one slot per step.
struct LevelBars: Equatable {
    /// Time to slide one slot. It matches the audio each level covers, so the bars keep pace with the mic.
    static let stepDuration = AudioLevel.windowDuration
    /// A bar covers about 63% of the distance to its level in this time.
    static let easingTime: TimeInterval = 0.06
    /// A longer frame (a stalled display, a waking screen) counts as this, so the bars don't lurch forward.
    static let maximumFrameTime: TimeInterval = 0.1

    /// Oldest first, each from `AudioLevel.normalized`.
    private(set) var levels: [Float]
    private(set) var heights: [Float]
    /// 0 right after a step, rising to 1 as the bars slide one slot left.
    private(set) var scroll: Double = 0

    init(count: Int) {
        levels = Array(repeating: 0, count: count)
        heights = levels
    }

    mutating func push(_ level: Float) {
        levels.removeFirst()
        levels.append(level)
        heights.removeFirst()
        heights.append(0)
    }

    /// Moves the animation on by one frame, calling `sample` for each step it completes.
    mutating func advance(by frameTime: TimeInterval, sample: () -> Float) {
        let frameTime = min(max(frameTime, 0), Self.maximumFrameTime)
        scroll += frameTime / Self.stepDuration
        while scroll >= 1 {
            scroll -= 1
            push(sample())
        }
        let blend = Float(1 - exp(-frameTime / Self.easingTime))
        for index in heights.indices {
            heights[index] += (levels[index] - heights[index]) * blend
        }
    }
}

/// Draws one rounded red bar per level, centred vertically, redrawn every display frame while running.
/// Silence draws a row of dots.
final class LevelBarsView: NSView {
    private(set) var bars: LevelBars {
        didSet { needsDisplay = true }
    }
    private let barCount: Int
    private var sample: (@MainActor () -> Float)?
    private var link: CADisplayLink?
    private var lastTimestamp: CFTimeInterval?

    var isRunning: Bool { link != nil }

    init(barCount: Int) {
        self.barCount = barCount
        bars = LevelBars(count: barCount)
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Calls `sample` once per step for the next level, starting from the flat row `stop()` left.
    func start(sampling sample: @escaping @MainActor () -> Float) {
        stop()
        self.sample = sample
        let link = displayLink(target: self, selector: #selector(step))
        // The bars step every 50 ms, so 60 Hz is already smooth; the default is the display's maximum, 120 Hz on
        // ProMotion, which measured about a third more CPU for no visible gain.
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        // Common modes, so the bars keep moving while the status menu is open.
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    /// Stops the animation and flattens the bars, so the next recording can't open on a frame of this one.
    func stop() {
        // Also releases the link's strong reference to this view.
        link?.invalidate()
        link = nil
        sample = nil
        lastTimestamp = nil
        bars = LevelBars(count: barCount)
    }

    /// One display frame. Separate from the display link callback so tests can drive it.
    func frame(at timestamp: CFTimeInterval) {
        defer { lastTimestamp = timestamp }
        guard let lastTimestamp, let sample else { return }
        bars.advance(by: timestamp - lastTimestamp, sample: sample)
    }

    @objc private func step(_ link: CADisplayLink) {
        frame(at: link.timestamp)
    }

    override func draw(_ dirtyRect: NSRect) {
        let heights = bars.heights
        // One spare slot on the right for the newest bar to slide in from.
        let slot = bounds.width / CGFloat(heights.count + 1)
        let barWidth = slot * 0.6
        let scroll = CGFloat(bars.scroll)
        for (index, level) in heights.enumerated() {
            let height = max(barWidth, CGFloat(level) * bounds.height)
            let bar = NSRect(
                x: bounds.minX + (CGFloat(index) + 1 - scroll) * slot + (slot - barWidth) / 2,
                y: bounds.midY - height / 2,
                width: barWidth,
                height: height)
            // The oldest bar fades as it slides out, so it doesn't vanish abruptly on the next step.
            NSColor.systemRed.withAlphaComponent(index == 0 ? 1 - scroll : 1).setFill()
            NSBezierPath(roundedRect: bar, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
        }
    }
}
