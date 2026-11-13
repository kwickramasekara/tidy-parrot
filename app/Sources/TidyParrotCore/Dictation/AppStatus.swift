import Foundation

/// What the app is doing, in priority order: a missing permission outranks everything else.
enum AppStatus: Equatable, Sendable {
    case needsAccessibility
    case listening
    case transcribing
    case loading
    case ready(cleanMode: Bool)
    case failed(String)

    /// SF Symbol and one-line description for the menu bar.
    func presentation(hotkey: ModifierKey) -> (symbol: String, text: String) {
        switch self {
        case .needsAccessibility:
            ("exclamationmark.triangle", "Needs Accessibility permission: System Settings → Privacy & Security")
        case .listening: ("mic.fill", "Listening… release \(hotkey.displayName) to insert")
        case .transcribing: ("ellipsis.circle", "Transcribing…")
        case .loading: ("hourglass", "Loading model…")
        case .ready(let clean):
            ("bird", "Ready: hold \(hotkey.displayName) to dictate" + (clean ? " (clean mode)" : ""))
        case .failed(let reason): ("exclamationmark.triangle", reason)
        }
    }
}
