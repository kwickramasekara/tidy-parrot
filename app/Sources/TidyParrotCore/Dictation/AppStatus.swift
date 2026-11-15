import Foundation

/// What the app is doing, in priority order: a missing permission outranks everything else.
enum AppStatus: Equatable, Sendable {
    case needsAccessibility
    /// A tap is in and the mic is starting, but it hasn't heard real audio yet.
    case starting
    case listening
    case transcribing
    case loading
    /// The model was unloaded after a while idle; the next tap loads it again while it records.
    case unloaded
    case ready(cleanMode: Bool)
    /// Ready, but the vocabulary file's latest save was rejected. The previous terms stay in use until the helper
    /// restarts (an idle unload, Restart Helper or relaunch), which leaves none.
    case vocabularyProblem(String)
    case failed(String)

    /// Whether the menu bar should flag a problem, and a one-line description for the menu.
    /// Only problems are flagged: recording already shows in the on-screen `RecordingIndicator`.
    func presentation(hotkey: ModifierKey) -> (needsAttention: Bool, text: String) {
        switch self {
        case .needsAccessibility:
            (true, "Needs Accessibility permission: System Settings → Privacy & Security")
        case .starting: (false, "Starting the mic… tap \(hotkey.displayName) or Esc to cancel")
        case .listening: (false, "Listening… tap \(hotkey.displayName) to insert, Esc to cancel")
        case .transcribing: (false, "Transcribing…")
        case .loading: (false, "Loading model…")
        case .unloaded: (false, "Model unloaded to save memory: tap \(hotkey.displayName) to dictate")
        case .ready(let clean):
            (false, "Ready: tap \(hotkey.displayName) to dictate" + (clean ? " (clean mode)" : ""))
        case .vocabularyProblem(let problem): (true, "Vocabulary file not applied: \(problem)")
        case .failed(let reason): (true, reason)
        }
    }
}
