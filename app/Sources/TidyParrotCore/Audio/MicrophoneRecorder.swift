import AVFoundation
import Synchronization

@MainActor
protocol AudioRecording: AnyObject {
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
final class MicrophoneRecorder: AudioRecording {
    private var engine: AVAudioEngine?
    private var inputSampleRate: Double = 0
    private let buffer = SampleBuffer()
    private let meter = LevelMeter()

    var isRecording: Bool { engine != nil }

    /// The next input level, from 0 to 1, for the on-screen meter. See `LevelMeter.take()`.
    func takeLevel() -> Float {
        meter.take()
    }

    func start() throws {
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
    }

    func stop() -> AudioClip {
        guard stopEngine() else { return AudioClip(samples: []) }
        return AudioClip(samples: Resampler.resample(buffer.drain(), from: inputSampleRate))
    }

    func cancel() {
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
    private nonisolated static func tap(into buffer: SampleBuffer, meter: LevelMeter) -> AVAudioNodeTapBlock {
        { pcm, _ in
            guard let channels = pcm.floatChannelData else { return }
            // First channel only: speech is mono, and multi-channel interfaces put the mic on channel 1.
            let chunk = UnsafeBufferPointer(start: channels[0], count: Int(pcm.frameLength))
            buffer.append(chunk)
            meter.record(chunk)
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

enum RecorderError: LocalizedError {
    case noInput

    var errorDescription: String? { "No microphone input available" }
}
