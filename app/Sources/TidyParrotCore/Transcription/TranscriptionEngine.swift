import Foundation

enum EngineState: Equatable, Sendable {
    case loading
    case ready(cleanMode: Bool, loadMilliseconds: Int)
    case failed(String)
}

/// The user's vocabulary file as the engine last reported it.
struct VocabularyStatus: Equatable, Sendable {
    /// Terms in effect; 0 means the vocabulary is off (file empty or missing).
    let terms: Int
    /// Nil while the first load is still running.
    let loadedAt: Date?
    /// Why the latest save was rejected. The previous terms stay in effect.
    let problem: String?
}

struct Transcript: Equatable, Sendable {
    let text: String
    /// Time the engine spent on the clip, excluding transport.
    let milliseconds: Int
}

/// Speech-to-text backend. `HelperProcessEngine` (Python + MLX) is the only real one today; a native engine
/// (e.g. Core ML) would conform to this and be chosen in `AppDelegate`.
@MainActor
protocol TranscriptionEngine: AnyObject {
    /// Called on every state change, starting with `.loading` from `start()`.
    var onStateChange: ((EngineState) -> Void)? { get set }
    /// Called whenever the engine reports on the vocabulary, which can change at any time as the user edits it.
    var onVocabularyChange: ((VocabularyStatus) -> Void)? { get set }
    func start()
    func stop()
    func transcribe(_ clip: AudioClip) async throws -> Transcript
}

/// Stands in when no engine could be configured, so the rest of the app needn't handle a missing engine.
@MainActor
final class UnavailableEngine: TranscriptionEngine {
    var onStateChange: ((EngineState) -> Void)?
    var onVocabularyChange: ((VocabularyStatus) -> Void)?
    private let reason: String

    init(reason: String) {
        self.reason = reason
    }

    func start() { onStateChange?(.failed(reason)) }
    func stop() {}
    func transcribe(_ clip: AudioClip) async throws -> Transcript {
        throw TranscriptionError.notRunning
    }
}

enum TranscriptionError: LocalizedError, Equatable {
    case notRunning
    case invalidReply
    case engine(String)

    var errorDescription: String? {
        switch self {
        case .notRunning: "Transcription helper isn't running"
        case .invalidReply: "Transcription helper sent an unreadable reply"
        case .engine(let message): message
        }
    }
}
