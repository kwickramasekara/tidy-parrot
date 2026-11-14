import Foundation
import Testing

@testable import TidyParrotCore

@MainActor
final class FakeHotkey: HotkeySource {
    var onEvent: ((HotkeyEvent) -> Void)?
    private(set) var started = false

    func start() { started = true }
    func send(_ event: HotkeyEvent) { onEvent?(event) }
}

@MainActor
final class FakeRecorder: AudioRecording {
    var clipToReturn = AudioClip(samples: [Float](repeating: 0, count: 16_000))
    var startError: Error?
    private(set) var isRecording = false
    private(set) var cancelCount = 0

    func start() throws {
        if let startError { throw startError }
        isRecording = true
    }

    func stop() -> AudioClip {
        isRecording = false
        return clipToReturn
    }

    func cancel() {
        isRecording = false
        cancelCount += 1
    }
}

@MainActor
final class FakeEngine: TranscriptionEngine {
    var onStateChange: ((EngineState) -> Void)?
    var result: Result<Transcript, Error> = .success(Transcript(text: "hello", milliseconds: 42))
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var received: [AudioClip] = []

    func start() {
        startCount += 1
        onStateChange?(.loading)
    }

    func stop() { stopCount += 1 }

    func transcribe(_ clip: AudioClip) async throws -> Transcript {
        received.append(clip)
        return try result.get()
    }

    func emit(_ state: EngineState) { onStateChange?(state) }
}

@MainActor
final class FakeInserter: TextInserting {
    private(set) var inserted: [String] = []
    func insert(_ text: String) { inserted.append(text) }
}

@MainActor
final class FakePermissions: PermissionsProviding {
    var isMicrophoneAuthorized = true
    var accessibilityTrusted = true
    private(set) var microphoneRequested = false
    private var pendingGrant: (@MainActor () -> Void)?

    func requestMicrophoneAccess() { microphoneRequested = true }
    func promptForAccessibility() -> Bool { accessibilityTrusted }
    func waitForAccessibility(_ granted: @escaping @MainActor () -> Void) { pendingGrant = granted }

    func grantAccessibility() {
        accessibilityTrusted = true
        pendingGrant?()
        pendingGrant = nil
    }
}

@MainActor
final class FakeFocus: FocusedInputChecking {
    var hasTextInput = true
    private(set) var checkCount = 0

    func hasFocusedTextInput() -> Bool {
        checkCount += 1
        return hasTextInput
    }
}

struct FakeError: LocalizedError {
    var errorDescription: String? { "fake failure" }
}

/// Polls instead of sleeping a fixed time, so timing tests pass as soon as they can and fail only on a real hang.
@MainActor
func waitUntil(timeout: Duration = .seconds(2), _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < deadline else {
            Issue.record("condition not met within \(timeout)")
            return
        }
        try await Task.sleep(for: .milliseconds(5))
    }
}
