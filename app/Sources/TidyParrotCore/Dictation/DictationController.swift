import Foundation

struct DictationSettings: Sendable {
    /// Shorter recordings are treated as accidental double taps.
    var minimumClipDuration: TimeInterval = 0.25
    /// Stops a recording that was left running or whose stopping tap was missed (a password field hides key events
    /// from global monitors), so the mic can't stay open indefinitely.
    var maximumClipDuration: Duration = .seconds(180)
    /// Appended to each dictation so consecutive ones don't run together ("Friday.Please").
    var trailingText = " "
}

/// Audible feedback, so you know the mic's state, or that dictation was refused, without looking at the menu bar.
enum FeedbackSound: Equatable, Sendable {
    case recordingStarted
    case recordingStopped
    /// Dictation refused because there's nowhere to paste. Distinct from `alert`: nothing is broken.
    case noFocusedInput
    /// A refused or failed dictation.
    case alert
}

/// The dictation pipeline: hotkey → recorder → engine → text inserter. Owns all app state and reports it as an
/// `AppStatus`; knows nothing about AppKit, so every collaborator can be swapped for a fake in tests.
@MainActor
final class DictationController {
    struct Dependencies {
        var hotkey: any HotkeySource
        var recorder: any AudioRecording
        var engine: any TranscriptionEngine
        var inserter: any TextInserting
        var permissions: any PermissionsProviding
        var focus: any FocusedInputChecking
        var play: @MainActor (FeedbackSound) -> Void
    }

    var onStatusChange: ((AppStatus) -> Void)?
    /// The last dictation's error, or an empty string once a dictation succeeds. Timings go to the log only.
    var onMessage: ((String) -> Void)?

    private let deps: Dependencies
    private let settings: DictationSettings
    private var engineState = EngineState.loading
    private var hasAccessibility = false
    private var inFlight = 0
    private var recordingLimit: Task<Void, Never>?
    /// Kept in memory only, never persisted, so it's gone on quit.
    private var lastDictation: String?
    private var lastTiming: Diagnostics.Timing?

    init(dependencies: Dependencies, settings: DictationSettings = DictationSettings()) {
        deps = dependencies
        self.settings = settings
    }

    var status: AppStatus {
        if !hasAccessibility { return .needsAccessibility }
        if deps.recorder.isRecording { return .listening }
        if inFlight > 0 { return .transcribing }
        switch engineState {
        case .loading: return .loading
        case .ready(let cleanMode, _): return .ready(cleanMode: cleanMode)
        case .failed(let reason): return .failed(reason)
        }
    }

    func start() {
        deps.engine.onStateChange = { [weak self] state in
            self?.engineState = state
            self?.publishStatus()
        }
        deps.engine.start()
        deps.permissions.requestMicrophoneAccess()
        startHotkey()
        publishStatus()
    }

    func stop() {
        cancelRecording()
        deps.engine.stop()
    }

    func restartEngine() {
        deps.engine.stop()
        deps.engine.start()
    }

    var canPasteLastDictation: Bool { lastDictation != nil }

    /// Read live, so a permission revoked since launch shows up.
    var diagnostics: Diagnostics {
        Diagnostics(
            engine: engineState, lastTiming: lastTiming,
            isMicrophoneAuthorized: deps.permissions.isMicrophoneAuthorized,
            isAccessibilityTrusted: deps.permissions.isAccessibilityTrusted)
    }

    /// For when the dictation went nowhere, e.g. an Electron app that hides its focus so the check couldn't refuse.
    /// Skips the focus check on purpose: the user has chosen the field, and the check, run from our own menu, may see
    /// the closing menu item as focused and refuse.
    func pasteLastDictation() {
        guard let lastDictation else { return }
        deps.inserter.insert(lastDictation + settings.trailingText)
    }

    // MARK: Hotkey → record → transcribe → insert

    private func startHotkey() {
        deps.hotkey.onEvent = { [weak self] event in self?.handle(event) }
        hasAccessibility = deps.permissions.promptForAccessibility()
        if hasAccessibility {
            deps.hotkey.start()
            return
        }
        Log.write("waiting for Accessibility permission")
        deps.permissions.waitForAccessibility { [weak self] in
            guard let self else { return }
            Log.write("Accessibility permission granted")
            hasAccessibility = true
            deps.hotkey.start()
            publishStatus()
        }
    }

    private func handle(_ event: HotkeyEvent) {
        switch event {
        case .toggle:
            if deps.recorder.isRecording { finishRecording() } else { startRecording() }
        case .cancel: cancelRecording()
        }
    }

    private func startRecording() {
        guard case .ready = engineState else {
            deps.play(.alert)
            return
        }
        // A quiet refusal, with no message: it's an everyday miss, not a fault to explain.
        guard deps.focus.hasFocusedTextInput() else {
            deps.play(.noFocusedInput)
            return
        }
        guard deps.permissions.isMicrophoneAuthorized else {
            fail("Microphone access is off: System Settings → Privacy & Security → Microphone")
            return
        }
        do {
            try deps.recorder.start()
        } catch {
            fail("Mic error: \(error.localizedDescription)")
            return
        }
        deps.play(.recordingStarted)
        let limit = settings.maximumClipDuration
        recordingLimit = Task { [weak self] in
            try? await Task.sleep(for: limit)
            guard !Task.isCancelled else { return }
            self?.finishRecording()
        }
        publishStatus()
    }

    /// Returns the transcription task, so tests can await it.
    @discardableResult
    func finishRecording() -> Task<Void, Never>? {
        guard deps.recorder.isRecording else { return nil }
        recordingLimit?.cancel()
        let clip = deps.recorder.stop()
        deps.play(.recordingStopped)
        guard clip.duration >= settings.minimumClipDuration else {
            publishStatus()
            return nil
        }

        inFlight += 1
        publishStatus()
        return Task { [weak self, engine = deps.engine] in
            let result: Result<Transcript, Error>
            do {
                result = .success(try await engine.transcribe(clip))
            } catch {
                result = .failure(error)
            }
            self?.complete(result, clip: clip)
        }
    }

    private func complete(_ result: Result<Transcript, Error>, clip: AudioClip) {
        inFlight -= 1
        switch result {
        case .success(let transcript):
            Log.write(
                String(
                    format: "%.1fs audio -> %d chars in %d ms", clip.duration, transcript.text.count,
                    transcript.milliseconds))
            lastTiming = Diagnostics.Timing(audioDuration: clip.duration, milliseconds: transcript.milliseconds)
            onMessage?("")
            if !transcript.text.isEmpty {
                lastDictation = transcript.text
                deps.inserter.insert(transcript.text + settings.trailingText)
            }
        case .failure(let error):
            fail("Error: \(error.localizedDescription)")
        }
        publishStatus()
    }

    private func cancelRecording() {
        guard deps.recorder.isRecording else { return }
        recordingLimit?.cancel()
        deps.recorder.cancel()
        deps.play(.recordingStopped)
        publishStatus()
    }

    private func fail(_ message: String) {
        Log.write(message)
        onMessage?(message)
        deps.play(.alert)
    }

    private func publishStatus() {
        onStatusChange?(status)
    }
}
