import AVFoundation
import Foundation
import Testing

@testable import TidyParrotCore

/// Runs the real Python helper and model. Opt-in because it needs `make setup` and takes a few seconds:
///     make integration WAV=path/to/speech.wav
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["TP_INTEGRATION_WAV"] != nil))
struct HelperIntegrationTests {
    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    @Test func transcribesARealClip() async throws {
        let wav = try #require(ProcessInfo.processInfo.environment["TP_INTEGRATION_WAV"])
        let clip = try Self.loadClip(URL(fileURLWithPath: wav))
        let engine = HelperProcessEngine(
            configuration: .init(
                python: Self.repoRoot.appendingPathComponent("helper/.venv/bin/python").path,
                script: Self.repoRoot.appendingPathComponent("helper/tidy_parrot_helper.py").path,
                arguments: []))

        let ready = await Self.waitForReadyOrFailure(engine)
        #expect(ready == .ready(cleanMode: true))

        // Two requests in flight at once: each reply must match its own clip.
        async let speech = engine.transcribe(clip)
        async let silence = engine.transcribe(AudioClip(samples: []))
        let (speechText, silenceText) = try await (speech.text, silence.text)
        #expect(!speechText.isEmpty)
        #expect(silenceText.isEmpty)

        engine.stop()
        await #expect(throws: TranscriptionError.notRunning) { try await engine.transcribe(clip) }
    }

    private static func waitForReadyOrFailure(_ engine: HelperProcessEngine) async -> EngineState {
        await withCheckedContinuation { continuation in
            var resumed = false
            engine.onStateChange = { state in
                guard !resumed, state != .loading else { return }
                resumed = true
                continuation.resume(returning: state)
            }
            engine.start()
        }
    }

    /// Reads any rate, keeps the first channel and resamples, the way the recorder does.
    private static func loadClip(_ url: URL) throws -> AudioClip {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = try #require(
            AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let channel = try #require(buffer.floatChannelData?[0])
        let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        return AudioClip(samples: Resampler.resample(samples, from: file.processingFormat.sampleRate))
    }
}
