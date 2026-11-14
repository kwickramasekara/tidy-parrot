import Accelerate
import Synchronization

/// Loudness of the microphone input for the on-screen meter, from 0 (silence) to 1 (loud speech).
enum AudioLevel {
    /// Each level covers this much audio. The meter's bars step at the same rate.
    static let windowDuration: TimeInterval = 0.05
    /// Quieter than this reads as silence, so room noise leaves the bars flat.
    static let floorDecibels: Float = -55
    /// Close speech into a laptop mic peaks around here, so normal talking fills the meter.
    static let ceilingDecibels: Float = -10

    static func normalized(rms: Float) -> Float {
        // Also rejects NaN, which a misbehaving input device could deliver.
        guard rms > 0 else { return 0 }
        let decibels = 20 * log10(rms)
        return min(max((decibels - floorDecibels) / (ceilingDecibels - floorDecibels), 0), 1)
    }
}

/// Turns the mic's audio into one level per `AudioLevel.windowDuration`, shared between the audio thread
/// (recording) and the main actor (taking). Windows are counted in samples because the tap's buffer size is only a
/// hint: AVAudioEngine typically delivers about 100 ms at a time.
final class LevelMeter: Sendable {
    private struct State {
        var windowFrames = 1
        var sumOfSquares: Float = 0
        var frames = 0
        /// The latest buffer's levels not yet taken.
        var ready: [Float] = []
        var last: Float = 0
    }

    private let state = Mutex(State())

    /// Clears everything and sizes the window for the input's sample rate.
    func reset(sampleRate: Double) {
        state.withLock { state in
            state = State(windowFrames: max(1, Int(sampleRate * AudioLevel.windowDuration)))
            // A 400 ms buffer, the largest AVAudioEngine documents for taps, makes 8 levels. Reserving them keeps the
            // audio thread from allocating.
            state.ready.reserveCapacity(8)
        }
    }

    func record(_ samples: UnsafeBufferPointer<Float>) {
        state.withLock { state in
            var offset = 0
            var completed = 0
            while offset < samples.count {
                let count = min(state.windowFrames - state.frames, samples.count - offset)
                state.sumOfSquares += vDSP.sumOfSquares(UnsafeBufferPointer(rebasing: samples[offset..<offset + count]))
                state.frames += count
                offset += count
                guard state.frames == state.windowFrames else { continue }

                // Levels left from an earlier buffer mean the reader fell behind (a main-thread stall). It reads at
                // the mic's rate, so it would never catch up; skip it ahead to this buffer instead.
                if completed == 0 { state.ready.removeAll(keepingCapacity: true) }
                let rms = (state.sumOfSquares / Float(state.frames)).squareRoot()
                state.ready.append(AudioLevel.normalized(rms: rms))
                state.sumOfSquares = 0
                state.frames = 0
                completed += 1
            }
        }
    }

    /// The next window's level. When none is ready yet, repeats the last one: no new audio isn't silence, and
    /// showing it as silence makes every other bar a dot.
    func take() -> Float {
        state.withLock { state in
            if !state.ready.isEmpty { state.last = state.ready.removeFirst() }
            return state.last
        }
    }
}
