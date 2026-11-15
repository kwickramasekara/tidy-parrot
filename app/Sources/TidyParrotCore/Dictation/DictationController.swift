import Foundation

struct DictationSettings: Sendable {
    /// Shorter recordings are treated as accidental double taps.
    var minimumClipDuration: TimeInterval = 0.25
    /// Stops a recording that was left running or whose stopping tap was missed (a password field hides key events
    /// from global monitors), so the mic can't stay open indefinitely.
    var maximumClipDuration: Duration = .seconds(180)
    /// Closes a mic opened on fn key-down if no tap follows: fn held on its own, or a key-up a password field hid.
    var warmUpLimit: Duration = .seconds(2)
    /// Fails a start whose mic sends no real audio in this long: a muted mic, or AirPods another device holds. AirPods
    /// need about 1.1 s to start hearing.
    var readyLimit: Duration = .seconds(3)
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
    /// Where the controller is in a dictation. Transcriptions run alongside this (`inFlight`), so they aren't a phase.
    private enum Phase {
        case idle
        /// fn is down on its own and the mic is opening, but the press may yet be a shortcut, so nothing shows.
        /// `limit` closes the mic if no tap follows.
        case warming(pressedAt: ContinuousClock.Instant, limit: Task<Void, Never>)
        /// A tap is in and the pill shows a spinner while the mic starts; the chime waits until it hears real audio.
        /// `attempt` tells this start apart from one that was discarded, whose reply may still arrive. `pressedAt` is
        /// nil when there was no warm-up. `limit` fails a start that never hears anything.
        case starting(
            attempt: Int, pressedAt: ContinuousClock.Instant?, releasedAt: ContinuousClock.Instant,
            limit: Task<Void, Never>)
        /// The mic is open and the pill is showing. `limit` stops a recording that was left running.
        case recording(limit: Task<Void, Never>)
    }

    private var phase = Phase.idle
    private var attempts = 0
    private var inFlight = 0
    /// Kept in memory only, never persisted, so it's gone on quit.
    private var lastDictation: String?
    private var lastTiming: Diagnostics.Timing?
    private var vocabulary: VocabularyStatus?

    init(dependencies: Dependencies, settings: DictationSettings = DictationSettings()) {
        deps = dependencies
        self.settings = settings
    }

    var status: AppStatus {
        if !hasAccessibility { return .needsAccessibility }
        switch phase {
        case .starting: return .starting
        case .recording: return .listening
        case .idle, .warming: break
        }
        if inFlight > 0 { return .transcribing }
        switch engineState {
        case .loading: return .loading
        case .ready(let cleanMode, _):
            // Dictation still works with the previous terms, but a rejected save should be visible.
            if let problem = vocabulary?.problem { return .vocabularyProblem(problem) }
            return .ready(cleanMode: cleanMode)
        case .failed(let reason): return .failed(reason)
        }
    }

    func start() {
        deps.engine.onStateChange = { [weak self] state in
            self?.engineState = state
            self?.publishStatus()
        }
        deps.engine.onVocabularyChange = { [weak self] vocabulary in
            guard let self, vocabulary != self.vocabulary else { return }
            Log.write(
                "vocabulary: \(vocabulary.terms) terms" + (vocabulary.problem.map { ", rejected save: \($0)" } ?? ""))
            self.vocabulary = vocabulary
            publishStatus()
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
            engine: engineState, lastTiming: lastTiming, vocabulary: vocabulary,
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
        switch (event, phase) {
        case (.pressBegan, .idle): warmUp()
        case (.pressBegan, _): break
        case (.pressAbandoned, .warming): discard()
        case (.pressAbandoned, _): break
        // No warm-up to commit (refused, timed out, or its key-down was missed): start as a tap always has.
        case (.toggle, .idle): startRecording()
        case (.toggle, .warming(let pressed, let limit)):
            limit.cancel()
            commit(pressedAt: pressed)
        // A second tap before the mic opened: nothing was heard and no chime has played, so end without a sound.
        case (.toggle, .starting): discard()
        case (.toggle, .recording): finishRecording()
        case (.cancel, _): cancelRecording()
        }
    }

    private func startRecording() {
        let released = ContinuousClock.now
        if let refusal = refusal() {
            present(refusal)
            return
        }
        begin(pressedAt: nil, releasedAt: released)
    }

    /// Opens the mic while fn is still down, so it's ready sooner. Silent: a shortcut looks the same until its other
    /// key arrives, and a refused press leaves the refusal for its tap to report.
    private func warmUp() {
        let pressed = ContinuousClock.now
        guard refusal() == nil else { return }
        deps.recorder.warmUp()
        phase = .warming(
            pressedAt: pressed, limit: after(settings.warmUpLimit) { [weak self] in self?.warmUpExpired() })
    }

    private func warmUpExpired() {
        guard case .warming = phase else { return }
        discard()
    }

    private func commit(pressedAt pressed: ContinuousClock.Instant) {
        let released = ContinuousClock.now
        // The helper may have stopped since key-down. Focus and permission were checked then, moments ago.
        guard case .ready = engineState else {
            discard()
            present(.engineNotReady)
            return
        }
        begin(pressedAt: pressed, releasedAt: released)
    }

    private func begin(pressedAt pressed: ContinuousClock.Instant?, releasedAt released: ContinuousClock.Instant) {
        attempts += 1
        let attempt = attempts
        let limit = after(settings.readyLimit) { [weak self] in self?.startNeverHeard(attempt: attempt) }
        phase = .starting(attempt: attempt, pressedAt: pressed, releasedAt: released, limit: limit)
        publishStatus()
        deps.recorder.start { [weak self] result in self?.started(attempt: attempt, result) }
    }

    private func started(attempt: Int, _ result: Result<MicrophoneStart, any Error>) {
        guard case .starting(attempt, let pressed, let released, let limit) = phase else { return }
        limit.cancel()
        let start: MicrophoneStart
        switch result {
        case .success(let value): start = value
        case .failure(let error):
            phase = .idle
            publishStatus()
            fail("Mic error: \(error.localizedDescription)")
            return
        }
        deps.play(.recordingStarted)
        Log.write(Self.startLog(start, pressedAt: pressed, releasedAt: released, chimeAt: .now))
        phase = .recording(limit: after(settings.maximumClipDuration) { [weak self] in self?.finishRecording() })
        publishStatus()
    }

    /// Press-to-chime latency and where it went: building and starting the unit, then waiting for its first buffer and
    /// for real audio. To see what warming the mic on key-down saves and what each mic costs.
    static func startLog(
        _ start: MicrophoneStart, pressedAt pressed: ContinuousClock.Instant?,
        releasedAt released: ContinuousClock.Instant, chimeAt chime: ContinuousClock.Instant
    ) -> String {
        let warm = start.opened < released
        let keyDown = pressed.map { "key-down → chime \(milliseconds(chime - $0)) ms, " } ?? ""
        let steps = [
            "build \(milliseconds(start.built - start.opened)) ms",
            "start \(milliseconds(start.running - start.built)) ms",
            "first buffer +\(milliseconds(start.firstBuffer - start.running)) ms",
            "ready +\(milliseconds(start.ready - start.firstBuffer)) ms",
        ]
        return "start: \(keyDown)key-up → chime \(milliseconds(chime - released)) ms"
            + " (\(warm ? "warm" : "cold"); \(steps.joined(separator: ", ")))"
    }

    private func startNeverHeard(attempt: Int) {
        guard case .starting(attempt, _, _, _) = phase else { return }
        discard()
        fail("Mic error: no sound from the microphone. Check it isn't muted or in use on another device")
    }

    /// Why a dictation can't start, checked in this order. The engine comes first so a press while it loads costs no
    /// Accessibility call.
    private enum Refusal {
        case engineNotReady, noFocusedInput, microphoneOff
    }

    private func refusal() -> Refusal? {
        guard case .ready = engineState else { return .engineNotReady }
        guard deps.focus.hasFocusedTextInput() else { return .noFocusedInput }
        guard deps.permissions.isMicrophoneAuthorized else { return .microphoneOff }
        return nil
    }

    private func present(_ refusal: Refusal) {
        switch refusal {
        case .engineNotReady: deps.play(.alert)
        // A quiet refusal, with no message: it's an everyday miss, not a fault to explain.
        case .noFocusedInput: deps.play(.noFocusedInput)
        case .microphoneOff: fail("Microphone access is off: System Settings → Privacy & Security → Microphone")
        }
    }

    /// Returns the task that stops the mic and transcribes, so tests can await it.
    @discardableResult
    func finishRecording() -> Task<Void, Never>? {
        guard case .recording(let limit) = phase else { return nil }
        limit.cancel()
        phase = .idle
        deps.play(.recordingStopped)
        publishStatus()
        // Asked for now, not from the task below, so a shortcut pressed straight after can't close the mic first.
        let (clips, delivered) = AsyncStream.makeStream(of: AudioClip.self)
        deps.recorder.stop { clip in
            delivered.yield(clip)
            delivered.finish()
        }
        return Task { [weak self] in
            for await clip in clips { await self?.transcribe(clip) }
        }
    }

    private func transcribe(_ clip: AudioClip) async {
        guard clip.duration >= settings.minimumClipDuration else { return }
        inFlight += 1
        publishStatus()
        let result: Result<Transcript, Error>
        do {
            result = .success(try await deps.engine.transcribe(clip))
        } catch {
            result = .failure(error)
        }
        complete(result, clip: clip)
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
        switch phase {
        case .idle: return
        case .warming, .starting: discard()
        case .recording:
            discard()
            deps.play(.recordingStopped)
            publishStatus()
        }
    }

    /// Closes the mic and forgets the dictation without a sound. Publishes only when ending a start, whose pill shows
    /// a spinner: ending a recording plays the stop sound before its caller publishes.
    private func discard() {
        var wasStarting = false
        switch phase {
        case .idle: break
        case .warming(_, let limit), .recording(let limit): limit.cancel()
        case .starting(_, _, _, let limit):
            limit.cancel()
            wasStarting = true
        }
        phase = .idle
        deps.recorder.cancel()
        if wasStarting { publishStatus() }
    }

    private func fail(_ message: String) {
        Log.write(message)
        onMessage?(message)
        deps.play(.alert)
    }

    /// Runs `action` after `duration` unless the task is cancelled first.
    private func after(_ duration: Duration, do action: @escaping @MainActor () -> Void) -> Task<Void, Never> {
        Task {
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            action()
        }
    }

    private static func milliseconds(_ duration: Duration) -> Int {
        Int(duration / .milliseconds(1))
    }

    private func publishStatus() {
        onStatusChange?(status)
    }
}
