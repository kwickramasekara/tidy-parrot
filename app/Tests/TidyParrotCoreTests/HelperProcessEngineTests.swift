import Foundation
import Testing

@testable import TidyParrotCore

/// Failure paths of the helper process, using /bin/sh scripts in place of the Python helper.
@MainActor
struct HelperProcessEngineTests {
    @Test func missingExecutableFails() async {
        let engine = HelperProcessEngine(
            configuration: .init(python: "/nonexistent/python", script: "x", arguments: []))
        let state = await Self.firstSettledState(of: engine)
        guard case .failed(let reason) = state else {
            Issue.record("expected failure, got \(state)")
            return
        }
        #expect(reason.hasPrefix("Couldn't start helper"))
    }

    @Test func startupErrorIsReportedInsteadOfExitStatus() async throws {
        let engine = Self.engine(running: #"echo '{"error": "model not found"}'; exit 1"#)
        #expect(await Self.firstSettledState(of: engine) == .failed("model not found"))
        // The exit that follows must not replace the helper's own message.
        var later: [EngineState] = []
        engine.onStateChange = { later.append($0) }
        try await Task.sleep(for: .milliseconds(200))
        #expect(later.isEmpty)
        await #expect(throws: TranscriptionError.notRunning) { try await engine.transcribe(AudioClip(samples: [])) }
    }

    @Test func unexpectedStartupLineFailsInsteadOfHangingInLoading() async {
        // The script would wait forever on stdin; failing must also end it.
        let engine = Self.engine(running: "echo 'Loading weights...'; cat >/dev/null")
        #expect(await Self.firstSettledState(of: engine) == .failed("Helper started with an unexpected reply"))
    }

    @Test func silentExitReportsStatus() async {
        let engine = Self.engine(running: "exit 3")
        #expect(await Self.firstSettledState(of: engine) == .failed("Helper stopped (status 3)"))
    }

    @Test func helperDyingMidRequestFailsTheRequest() async {
        let engine = Self.engine(
            running: #"echo '{"ready": true, "load_ms": 1, "clean_mode": false}'; head -c 4 >/dev/null"#)
        #expect(await Self.firstSettledState(of: engine) == .ready(cleanMode: false, loadMilliseconds: 1))
        await #expect(throws: TranscriptionError.notRunning) {
            try await engine.transcribe(AudioClip(samples: [0, 0, 0]))
        }
    }

    @Test func vocabularyStatusIsForwardedFromReadyAndReplies() async throws {
        let engine = Self.engine(
            running: #"""
                echo '{"ready": true, "vocabulary": {"terms": 0, "loaded_at": null, "error": null}}'
                head -c 4 >/dev/null
                echo '{"text": "hi", "ms": 1, "vocabulary": {"terms": 2, "loaded_at": 10, "error": null}}'
                cat >/dev/null
                """#)
        var reported: [VocabularyStatus] = []
        engine.onVocabularyChange = { reported.append($0) }
        _ = await Self.firstSettledState(of: engine)
        #expect(try await engine.transcribe(AudioClip(samples: [])).text == "hi")
        #expect(
            reported == [
                VocabularyStatus(terms: 0, loadedAt: nil, problem: nil),
                VocabularyStatus(terms: 2, loadedAt: Date(timeIntervalSince1970: 10), problem: nil),
            ])
        engine.stop()
    }

    @Test func stopReportsUnloadedNotFailure() async throws {
        let engine = Self.engine(running: #"echo '{"ready": true}'; cat >/dev/null"#)
        #expect(await Self.firstSettledState(of: engine) == .ready(cleanMode: false, loadMilliseconds: 0))
        var later: [EngineState] = []
        engine.onStateChange = { later.append($0) }
        engine.stop()
        try await Task.sleep(for: .milliseconds(200))
        #expect(later == [.unloaded])  // the exit that follows isn't reported as a failure
        await #expect(throws: TranscriptionError.notRunning) { try await engine.transcribe(AudioClip(samples: [])) }
    }

    /// The first dictation after an unload sends its clip while the model is still loading.
    @Test func clipSentWhileLoadingWaitsForTheModel() async throws {
        let engine = Self.engine(
            running: #"""
                sleep 0.3
                echo '{"ready": true, "load_ms": 1, "clean_mode": true}'
                head -c 4 >/dev/null
                echo '{"text": "hi", "ms": 1}'
                cat >/dev/null
                """#)
        var states: [EngineState] = []
        engine.onStateChange = { states.append($0) }
        engine.start()
        #expect(try await engine.transcribe(AudioClip(samples: [])).text == "hi")
        try await waitUntil { states.count == 2 }
        #expect(states == [.loading, .ready(cleanMode: true, loadMilliseconds: 1)])
        engine.stop()
    }

    /// A helper that dies before its ready line closes the pipe the queued clip is written to.
    @Test func clipQueuedBehindAFailedLoadFailsAsNotRunning() async {
        let engine = Self.engine(running: "sleep 0.2; exit 3")
        engine.start()
        await #expect(throws: TranscriptionError.notRunning) {
            try await engine.transcribe(AudioClip(samples: [Float](repeating: 0, count: 16_000)))
        }
    }

    /// `sh -c script` stands in for `python helper.py`, so no temp files are needed.
    private static func engine(running script: String) -> HelperProcessEngine {
        HelperProcessEngine(configuration: .init(python: "/bin/sh", script: "-c", arguments: [script]))
    }

    private static func firstSettledState(of engine: HelperProcessEngine) async -> EngineState {
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
}
