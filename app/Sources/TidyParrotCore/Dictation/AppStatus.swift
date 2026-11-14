import Foundation

/// What the app is doing, in priority order: a missing permission outranks everything else.
enum AppStatus: Equatable, Sendable {
    case needsAccessibility
    case listening
    case transcribing
    case loading
    case ready(cleanMode: Bool)
    /// Ready, but the vocabulary file's latest save was rejected and the previous terms are still in use.
    case vocabularyProblem(String)
    case failed(String)

    /// Whether the menu bar should flag a problem, and a one-line description for the menu.
    /// Only problems are flagged: recording already shows in the on-screen `RecordingIndicator`.
    func presentation(hotkey: ModifierKey) -> (needsAttention: Bool, text: String) {
        switch self {
        case .needsAccessibility:
            (true, "Needs Accessibility permission: System Settings → Privacy & Security")
        case .listening: (false, "Listening… tap \(hotkey.displayName) to insert, Esc to cancel")
        case .transcribing: (false, "Transcribing…")
        case .loading: (false, "Loading model…")
        case .ready(let clean):
            (false, "Ready: tap \(hotkey.displayName) to dictate" + (clean ? " (clean mode)" : ""))
        case .vocabularyProblem(let problem): (true, "Vocabulary file not applied: \(problem)")
        case .failed(let reason): (true, reason)
        }
    }
}
