import AVFoundation
import Synchronization

@MainActor
public protocol AudioRecording: AnyObject {
    var isRecording: Bool { get }
    func start() throws
    /// Stops recording and returns the clip, already converted to `AudioClip.sampleRate`.
    func stop() -> AudioClip
    func cancel()
}

/// Records from the current default input only while the hotkey is held.
/// A fresh engine per recording means device changes between dictations (a Teams call switching mics,
/// AirPods connecting) never touch a long-lived engine, and the mic is closed the rest of the time.
@MainActor
public final class MicrophoneRecorder: AudioRecording {
    private var engine: AVAudioEngine?
    private var inputSampleRate: Double = 0
    private let buffer = SampleBuffer()

    public init() {}

    public var isRecording: Bool { engine != nil }

    public func start() throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw RecorderError.noInput }

        inputSampleRate = format.sampleRate
        buffer.reset()
        input.installTap(onBus: 0, bufferSize: 1024, format: format, block: Self.tap(into: buffer))
        engine.prepare()
        try engine.start()
        self.engine = engine
    }

    public func stop() -> AudioClip {
        guard stopEngine() else { return AudioClip(samples: []) }
        return AudioClip(samples: Resampler.resample(buffer.drain(), from: inputSampleRate))
    }

    public func cancel() {
        stopEngine()
    }

    @discardableResult
    private func stopEngine() -> Bool {
        guard let engine else { return false }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
        return true
    }

    /// Built outside the main actor: the tap runs on the audio thread, and a closure formed in a main-actor
    /// method would inherit that isolation and trap when Core Audio calls it.
    private nonisolated static func tap(into buffer: SampleBuffer) -> AVAudioNodeTapBlock {
        { pcm, _ in
            guard let channels = pcm.floatChannelData else { return }
            // First channel only: speech is mono, and multi-channel interfaces put the mic on channel 1.
            buffer.append(UnsafeBufferPointer(start: channels[0], count: Int(pcm.frameLength)))
        }
    }
}

/// Samples shared between the audio thread (appending) and the main actor (draining).
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

public enum RecorderError: LocalizedError {
    case noInput

    public var errorDescription: String? { "No microphone input available" }
}
