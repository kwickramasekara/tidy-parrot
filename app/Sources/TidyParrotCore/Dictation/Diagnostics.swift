import Foundation

/// What Option-clicking the menu bar icon shows: enough to see why dictation is slow or refused without opening the
/// log. Never includes transcribed text.
struct Diagnostics: Equatable, Sendable {
    struct Timing: Equatable, Sendable {
        let audioDuration: TimeInterval
        let milliseconds: Int
    }

    var engine: EngineState
    /// The last successful transcription.
    var lastTiming: Timing?
    /// Nil until the helper first reports it.
    var vocabulary: VocabularyStatus?
    var isMicrophoneAuthorized: Bool
    var isAccessibilityTrusted: Bool

    var lines: [String] {
        var lines: [String] = []
        switch engine {
        case .loading:
            lines.append("Helper: loading model…")
        case .ready(_, let loadMilliseconds):
            lines.append("Helper: ready")
            lines.append("Model load: \(loadMilliseconds) ms")
        case .unloaded:
            lines.append("Helper: unloaded (loads when you dictate)")
        case .failed(let reason):
            // Repeats the status line on purpose: a missing Accessibility grant outranks it there.
            lines.append("Helper: failed (\(reason))")
        }
        if let lastTiming {
            lines.append(
                String(
                    format: "Last dictation: %.1fs of audio in %d ms", lastTiming.audioDuration,
                    lastTiming.milliseconds))
        } else {
            lines.append("Last dictation: none yet")
        }
        if let vocabulary { lines += Self.describe(vocabulary) }
        lines.append("Microphone: \(Self.describe(isMicrophoneAuthorized))")
        lines.append("Accessibility: \(Self.describe(isAccessibilityTrusted))")
        return lines
    }

    private static func describe(_ granted: Bool) -> String { granted ? "allowed" : "not allowed" }

    private static func describe(_ vocabulary: VocabularyStatus) -> [String] {
        let state =
            if let loadedAt = vocabulary.loadedAt {
                vocabulary.terms == 0
                    ? "off (file empty or missing)"
                    : "\(vocabulary.terms) terms, loaded \(loadedAt.formatted(date: .omitted, time: .standard))"
            } else {
                "loading…"
            }
        return ["Vocabulary: \(state)"] + (vocabulary.problem.map { ["Vocabulary file not applied: \($0)"] } ?? [])
    }
}
