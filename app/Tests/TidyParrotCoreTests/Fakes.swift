import Foundation
import Testing

@testable import TidyParrotCore

@MainActor
final class FakeHotkey: HotkeySource {
    var onEvent: ((HotkeyEvent) -> Void)?
    private(set) var started = false

    func start() { started = true }
    func send(_ event: HotkeyEvent) { onEvent?(event) }
    /// What the detector sends for a plain fn tap.
    func tap() {
        send(.pressBegan)
        send(.toggle)
    }
}

/// Like the real recorder, each call takes effect when it's made and results arrive later on the main actor.
@MainActor
final class FakeRecorder: AudioRecording {
    enum Call: Equatable {
        case warmUp, start, stop, cancel
    }

    var clipToReturn = AudioClip(samples: [Float](repeating: 0, count: 16_000))
    var startError: Error?
    /// False stands in for an input that's skipped, like Bluetooth.
    var warmUpOpens = true
    /// Holds `start`'s result until `releaseStart()`, to test what arrives while the mic is still opening.
    var holdStart = false
    private(set) var calls: [Call] = []
    private(set) var isOpen = false
    private var heldStart: (() -> Void)?

    var cancelCount: Int { calls.filter { $0 == .cancel }.count }

    func warmUp() {
        calls.append(.warmUp)
        if warmUpOpens { isOpen = true }
    }

    func start(_ opened: @escaping @MainActor @Sendable (Result<Bool, any Error>) -> Void) {
        calls.append(.start)
        let result: Result<Bool, any Error>
        if let startError {
            result = .failure(startError)
        } else {
            result = .success(isOpen)
            isOpen = true
        }
        let deliver = { opened(result) }
        if holdStart { heldStart = deliver } else { Task { deliver() } }
    }

    func releaseStart() {
        heldStart?()
        heldStart = nil
    }

    func stop(_ stopped: @escaping @MainActor @Sendable (AudioClip) -> Void) {
        calls.append(.stop)
        isOpen = false
        let clip = clipToReturn
        Task { stopped(clip) }
    }

    func cancel() {
        calls.append(.cancel)
        isOpen = false
    }
}

@MainActor
final class FakeEngine: TranscriptionEngine {
    var onStateChange: ((EngineState) -> Void)?
    var onVocabularyChange: ((VocabularyStatus) -> Void)?
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
    func emit(_ vocabulary: VocabularyStatus) { onVocabularyChange?(vocabulary) }
}

@MainActor
final class FakeInserter: TextInserting {
    private(set) var inserted: [String] = []
    func insert(_ text: String) { inserted.append(text) }
}

@MainActor
final class FakePermissions: PermissionsProviding {
    var isMicrophoneAuthorized = true
    var isAccessibilityTrusted = true
    private(set) var microphoneRequested = false
    private var pendingGrant: (@MainActor () -> Void)?

    func requestMicrophoneAccess() { microphoneRequested = true }
    func promptForAccessibility() -> Bool { isAccessibilityTrusted }
    func waitForAccessibility(_ granted: @escaping @MainActor () -> Void) { pendingGrant = granted }

    func grantAccessibility() {
        isAccessibilityTrusted = true
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
