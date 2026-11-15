import Accelerate
import Synchronization

/// Whether a mic that just started is hearing anything yet. A started mic can send exact zeros first: AirPods for
/// about 1.1 s while their call-mode link comes up, the built-in mic for about 120 ms. A single non-zero sample isn't
/// enough, because AirPods send a few before the link is up. Ready is three buffers in a row, each with a peak above
/// `peakThreshold`, which a live mic's own noise normally clears.
struct MicrophoneReadiness {
    static let requiredBuffers = 3
    /// About -100 dBFS.
    static let peakThreshold: Float = 0.000_01

    private(set) var isReady = false
    private var loudInARow = 0

    /// Returns true for the buffer that makes the mic ready, and only for that one.
    mutating func observe(peak: Float) -> Bool {
        guard !isReady else { return false }
        // NaN compares false, so a garbled buffer counts as silence.
        loudInARow = peak > Self.peakThreshold ? loudInARow + 1 : 0
        isReady = loudInARow >= Self.requiredBuffers
        return isReady
    }
}

/// Holds the answer to `start` until the mic is ready. The audio thread reports buffers and the recorder's queue waits,
/// in either order: whichever comes second answers, once, outside the lock.
final class ReadinessGate: Sendable {
    typealias Waiter = @Sendable (_ firstBuffer: ContinuousClock.Instant, _ ready: ContinuousClock.Instant) -> Void

    private struct State {
        var readiness = MicrophoneReadiness()
        var firstBuffer: ContinuousClock.Instant?
        var ready: ContinuousClock.Instant?
        var waiter: Waiter?
    }

    private let state = Mutex(State())

    /// Called on the audio thread for every buffer.
    func observe(_ samples: UnsafeBufferPointer<Float>) {
        let now = ContinuousClock.now
        let peak = samples.isEmpty ? 0 : vDSP.maximumMagnitude(samples)
        let answer = state.withLock { state -> (Waiter, ContinuousClock.Instant)? in
            let firstBuffer = state.firstBuffer ?? now
            state.firstBuffer = firstBuffer
            guard state.readiness.observe(peak: peak) else { return nil }
            state.ready = now
            guard let waiter = state.waiter else { return nil }
            state.waiter = nil
            return (waiter, firstBuffer)
        }
        if let (waiter, firstBuffer) = answer { waiter(firstBuffer, now) }
    }

    /// Calls `waiter` once the mic is ready: now, if it already is.
    func whenReady(_ waiter: @escaping Waiter) {
        let times = state.withLock { state -> (ContinuousClock.Instant, ContinuousClock.Instant)? in
            guard let firstBuffer = state.firstBuffer, let ready = state.ready else {
                state.waiter = waiter
                return nil
            }
            return (firstBuffer, ready)
        }
        if let (firstBuffer, ready) = times { waiter(firstBuffer, ready) }
    }

    /// Forgets the readiness and any waiter, for the next mic.
    func reset() {
        state.withLock { $0 = State() }
    }
}
