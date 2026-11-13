import Foundation

public enum EngineState: Equatable, Sendable {
    case loading
    case ready(cleanMode: Bool)
    case failed(String)
}

public struct Transcript: Equatable, Sendable {
    public let text: String
    /// Time the engine spent on the clip, excluding transport.
    public let milliseconds: Int

    public init(text: String, milliseconds: Int) {
        self.text = text
        self.milliseconds = milliseconds
    }
}

/// Speech-to-text backend. `HelperProcessEngine` (Python + MLX) is the only real one today; a native engine
/// (e.g. Core ML) would conform to this and be chosen in `AppDelegate`.
@MainActor
public protocol TranscriptionEngine: AnyObject {
    /// Called on every state change, starting with `.loading` from `start()`.
    var onStateChange: ((EngineState) -> Void)? { get set }
    func start()
    func stop()
    func restart()
    /// Requests are answered in the order they were made.
    func transcribe(_ clip: AudioClip) async throws -> Transcript
}

extension TranscriptionEngine {
    public func restart() {
        stop()
        start()
    }
}

/// Stands in when no engine could be configured, so the rest of the app needn't handle a missing engine.
@MainActor
public final class UnavailableEngine: TranscriptionEngine {
    public var onStateChange: ((EngineState) -> Void)?
    private let reason: String

    public init(reason: String) {
        self.reason = reason
    }

    public func start() { onStateChange?(.failed(reason)) }
    public func stop() {}
    public func transcribe(_ clip: AudioClip) async throws -> Transcript {
        throw TranscriptionError.notRunning
    }
}

public enum TranscriptionError: LocalizedError, Equatable {
    case notRunning
    case invalidReply
    case engine(String)

    public var errorDescription: String? {
        switch self {
        case .notRunning: "Transcription helper isn't running"
        case .invalidReply: "Transcription helper sent an unreadable reply"
        case .engine(let message): message
        }
    }
}
