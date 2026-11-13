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
        let engine = try Self.engine(running: #"echo '{"error": "model not found"}'; exit 1"#)
        #expect(await Self.firstSettledState(of: engine) == .failed("model not found"))
        // The exit that follows must not replace the helper's own message.
        try await Task.sleep(for: .milliseconds(200))
        await #expect(throws: TranscriptionError.notRunning) { try await engine.transcribe(AudioClip(samples: [])) }
    }

    @Test func silentExitReportsStatus() async throws {
        let engine = try Self.engine(running: "exit 3")
        #expect(await Self.firstSettledState(of: engine) == .failed("Helper stopped (status 3)"))
    }

    @Test func helperDyingMidRequestFailsTheRequest() async throws {
        let engine = try Self.engine(
            running: #"echo '{"ready": true, "load_ms": 1, "clean_mode": false}'; head -c 4 >/dev/null"#)
        #expect(await Self.firstSettledState(of: engine) == .ready(cleanMode: false))
        await #expect(throws: TranscriptionError.notRunning) {
            try await engine.transcribe(AudioClip(samples: [0, 0, 0]))
        }
    }

    @Test func stopIsQuiet() async throws {
        let engine = try Self.engine(running: #"echo '{"ready": true}'; cat >/dev/null"#)
        #expect(await Self.firstSettledState(of: engine) == .ready(cleanMode: false))
        var later: [EngineState] = []
        engine.onStateChange = { later.append($0) }
        engine.stop()
        try await Task.sleep(for: .milliseconds(200))
        #expect(later.isEmpty)  // a deliberate stop isn't reported as a failure
    }

    private static func engine(running script: String) throws -> HelperProcessEngine {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tp-helper-\(UUID().uuidString).sh")
        try script.write(to: url, atomically: true, encoding: .utf8)
        return HelperProcessEngine(configuration: .init(python: "/bin/sh", script: url.path, arguments: []))
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
