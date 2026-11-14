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
        guard case .ready(let cleanMode, let loadMilliseconds) = ready else {
            Issue.record("expected ready, got \(ready)")
            return
        }
        #expect(cleanMode)
        #expect(loadMilliseconds > 0)

        // Two requests in flight at once: each reply must match its own clip.
        async let speech = engine.transcribe(clip)
        async let silence = engine.transcribe(AudioClip(samples: []))
        let (speechText, silenceText) = try await (speech.text, silence.text)
        #expect(!speechText.isEmpty)
        #expect(silenceText.isEmpty)

        engine.stop()
        await #expect(throws: TranscriptionError.notRunning) { try await engine.transcribe(clip) }
    }

    /// First launch seeds the default list; a bad save keeps it and is reported; fixing the file clears the problem.
    /// Uses a temporary folder, never the real vocabulary.
    @Test func seedsWatchesAndReportsTheVocabulary() async throws {
        let wav = try #require(ProcessInfo.processInfo.environment["TP_INTEGRATION_WAV"])
        let clip = try Self.loadClip(URL(fileURLWithPath: wav))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let file = folder.appendingPathComponent("vocabulary.txt")
        defer { try? FileManager.default.removeItem(at: folder) }
        let engine = HelperProcessEngine(
            configuration: .init(
                python: Self.repoRoot.appendingPathComponent("helper/.venv/bin/python").path,
                script: Self.repoRoot.appendingPathComponent("helper/tidy_parrot_helper.py").path,
                arguments: ["--vocabulary", file.path]))
        var latest: VocabularyStatus?
        engine.onVocabularyChange = { latest = $0 }
        defer { engine.stop() }

        guard case .ready = await Self.waitForReadyOrFailure(engine) else {
            Issue.record("helper didn't start")
            return
        }
        let defaults = try Self.termCount(Self.repoRoot.appendingPathComponent("helper/default_vocabulary.txt"))
        try await Self.transcribe(clip, with: engine) { latest?.loadedAt != nil }
        #expect(latest == VocabularyStatus(terms: defaults, loadedAt: latest?.loadedAt, problem: nil))
        #expect(try Self.termCount(file) == defaults)

        try Data("React\n---\n".utf8).write(to: file, options: .atomic)
        try await Self.transcribe(clip, with: engine) { latest?.problem != nil }
        #expect(latest?.problem == "line 2 has no letters or digits")
        #expect(latest?.terms == defaults)

        try Data("React\nVue\n".utf8).write(to: file, options: .atomic)
        try await Self.transcribe(clip, with: engine) { latest?.terms == 2 }
        #expect(latest?.problem == nil)
    }

    /// The vocabulary status only arrives with replies, so keep dictating until it shows what's expected.
    private static func transcribe(
        _ clip: AudioClip, with engine: HelperProcessEngine, until condition: () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + .seconds(15)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("vocabulary condition not met within 15 s")
                return
            }
            _ = try await engine.transcribe(clip)
            try await Task.sleep(for: .milliseconds(250))
        }
    }

    private static func termCount(_ url: URL) throws -> Int {
        try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .count
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
