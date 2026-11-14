import AVFoundation
import Synchronization

/// Each call takes its turn the moment it's made, and calls run in that order, so a `stop` or `cancel` never overtakes
/// an earlier `start`, and a later `cancel` never overtakes a `stop`. Results come back on the main actor. These are
/// completion handlers rather than `async` on purpose: an `async` call made from a new `Task` would take its turn
/// only when that task ran, after anything handled in between.
@MainActor
protocol AudioRecording: AnyObject {
    /// Opens the mic in the background ahead of a likely tap, unless the input is Bluetooth or unknown. Errors are
    /// left for `start` to report.
    func warmUp()
    /// Opens the mic, or waits for an earlier call to. `opened` gets whether it was already open.
    func start(_ opened: @escaping @MainActor @Sendable (Result<Bool, any Error>) -> Void)
    /// Stops recording. `stopped` gets the clip, already converted to `AudioClip.sampleRate`.
    func stop(_ stopped: @escaping @MainActor @Sendable (AudioClip) -> Void)
    /// Closes the mic and forgets what it heard.
    func cancel()
}

/// Records from the current default input only around a dictation: from fn key-down, if the press turns out to be a
/// tap, until the next tap. A fresh engine per recording means device changes between dictations (a Teams call
/// switching mics, AirPods connecting) never touch a long-lived engine, and the mic is closed the rest of the time.
@MainActor
final class MicrophoneRecorder: AudioRecording {
    private let session = MicrophoneSession()

    /// The next input level, from 0 to 1, for the on-screen meter. See `LevelMeter.take()`.
    func takeLevel() -> Float {
        session.meter.take()
    }

    func warmUp() {
        session.run { session in
            guard AudioInputTransport.allowsWarmUp(transportType: AudioInputTransport.defaultInputTransportType())
            else { return }
            // A failure here repeats when the tap calls `start`, which reports it.
            _ = try? session.open()
        }
    }

    func start(_ opened: @escaping @MainActor @Sendable (Result<Bool, any Error>) -> Void) {
        session.run { session in
            let result = Result { try session.open() }
            Task { @MainActor in opened(result) }
        }
    }

    func stop(_ stopped: @escaping @MainActor @Sendable (AudioClip) -> Void) {
        session.run { session in
            let clip = session.close()
            Task { @MainActor in stopped(clip) }
        }
    }

    func cancel() {
        session.run { $0.discard() }
    }
}

/// The engine and what it hears. Opening a mic blocks for 0.1–0.7 s, so all engine work runs on `queue`, off the
/// main actor, one call at a time.
private final class MicrophoneSession: @unchecked Sendable {
    // Safety: `engine` and `inputSampleRate` are used only on `queue`; `buffer` and `meter` are Sendable.
    let meter = LevelMeter()
    private let buffer = SampleBuffer()
    private var engine: AVAudioEngine?
    private var inputSampleRate: Double = 0
    private let queue = DispatchQueue(label: "tidyparrot.microphone")

    func run(_ work: @escaping @Sendable (MicrophoneSession) -> Void) {
        queue.async { [self] in work(self) }
    }

    /// Returns whether the mic was already open.
    func open() throws -> Bool {
        guard engine == nil else { return true }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw RecorderError.noInput }

        inputSampleRate = format.sampleRate
        buffer.reset()
        meter.reset(sampleRate: format.sampleRate)
        input.installTap(onBus: 0, bufferSize: 1024, format: format, block: Self.tap(into: buffer, meter: meter))
        engine.prepare()
        try engine.start()
        self.engine = engine
        return false
    }

    /// Closes the mic and returns what it recorded, or an empty clip if it wasn't open.
    func close() -> AudioClip {
        guard stopEngine() else { return AudioClip(samples: []) }
        return AudioClip(samples: Resampler.resample(buffer.drain(), from: inputSampleRate))
    }

    func discard() {
        stopEngine()
        buffer.reset()
    }

    @discardableResult
    private func stopEngine() -> Bool {
        guard let engine else { return false }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
        return true
    }

    /// Built outside any actor: the tap runs on the audio thread, and a closure formed in an actor-isolated method
    /// would inherit that isolation and trap when Core Audio calls it.
    private static func tap(into buffer: SampleBuffer, meter: LevelMeter) -> AVAudioNodeTapBlock {
        { pcm, _ in
            guard let channels = pcm.floatChannelData else { return }
            // First channel only: speech is mono, and multi-channel interfaces put the mic on channel 1.
            let chunk = UnsafeBufferPointer(start: channels[0], count: Int(pcm.frameLength))
            buffer.append(chunk)
            meter.record(chunk)
        }
    }
}

/// Samples shared between the audio thread (appending) and the recorder's queue (draining).
final class SampleBuffer: Sendable {
    private let samples = Mutex<[Float]>([])

    func append(_ chunk: UnsafeBufferPointer<Float>) {
        samples.withLock { $0.append(contentsOf: chunk) }
    }

    func reset() {
        samples.withLock { $0.removeAll(keepingCapacity: true) }
    }

    func drain() -> [Float] {
        samples.withLock { current in
            defer { current.removeAll(keepingCapacity: true) }
            return current
        }
    }
}

enum RecorderError: LocalizedError {
    case noInput

    var errorDescription: String? { "No microphone input available" }
}
