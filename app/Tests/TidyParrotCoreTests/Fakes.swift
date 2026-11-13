import Foundation

@testable import TidyParrotCore

@MainActor
final class FakeHotkey: HotkeySource {
    let key = ModifierKey.rightOption
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

struct FakeError: LocalizedError {
    var errorDescription: String? { "fake failure" }
}
