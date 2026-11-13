import AppKit

@MainActor
enum SystemSounds {
    /// Bare names work because `NSSound(named:)` falls back to /System/Library/Sounds.
    static func play(_ sound: FeedbackSound) {
        switch sound {
        case .recordingStarted: _ = NSSound(named: "Tink")?.play()
        case .recordingStopped: _ = NSSound(named: "Pop")?.play()
        case .alert: NSSound.beep()
        }
    }
}
