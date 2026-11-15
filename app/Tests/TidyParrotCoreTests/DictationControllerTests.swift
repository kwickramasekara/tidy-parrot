import Foundation
import Testing

@testable import TidyParrotCore

@MainActor
struct DictationControllerTests {
    let hotkey = FakeHotkey()
    let recorder = FakeRecorder()
    let engine = FakeEngine()
    let inserter = FakeInserter()
    let permissions = FakePermissions()
    let focus = FakeFocus()
    let sounds = SoundLog()

    final class SoundLog {
        var played: [FeedbackSound] = []
    }

    func makeController(settings: DictationSettings = DictationSettings()) -> DictationController {
        DictationController(
            dependencies: .init(
                hotkey: hotkey, recorder: recorder, engine: engine, inserter: inserter, permissions: permissions,
                focus: focus, play: { sounds.played.append($0) }),
            settings: settings)
    }

    /// A started controller whose engine is ready and permissions granted.
    func makeReadyController(settings: DictationSettings = DictationSettings()) -> DictationController {
        let controller = makeController(settings: settings)
        controller.start()
        engine.emit(.ready(cleanMode: true, loadMilliseconds: 1))
        return controller
    }

    /// A ready controller whose engine has since been unloaded.
    func makeUnloadedController(settings: DictationSettings = DictationSettings()) -> DictationController {
        let controller = makeReadyController(settings: settings)
        engine.emit(.unloaded)
        return controller
    }

    /// Taps to start, then waits for the mic to open.
    func tapToStart(_ controller: DictationController) async throws {
        hotkey.tap()
        try await waitUntil { controller.status == .listening }
    }

    // MARK: Startup and status

    @Test func startStartsEngineHotkeyAndRequestsMic() {
        let controller = makeController()
        controller.start()
        #expect(engine.startCount == 1)
        #expect(hotkey.started)
        #expect(permissions.microphoneRequested)
        #expect(controller.status == .loading)
    }

    @Test func withoutAccessibilityHotkeyWaitsForGrant() {
        permissions.isAccessibilityTrusted = false
        let controller = makeController()
        controller.start()
        engine.emit(.ready(cleanMode: true, loadMilliseconds: 1))
        #expect(!hotkey.started)
        #expect(controller.status == .needsAccessibility)

        permissions.grantAccessibility()
        #expect(hotkey.started)
        #expect(controller.status == .ready(cleanMode: true))
    }

    @Test func publishesEngineStates() {
        let controller = makeController()
        var seen: [AppStatus] = []
        controller.onStatusChange = { seen.append($0) }
        controller.start()
        engine.emit(.ready(cleanMode: false, loadMilliseconds: 1))
        engine.emit(.failed("boom"))
        #expect(seen.contains(.ready(cleanMode: false)))
        #expect(seen.last == .failed("boom"))
    }

    @Test func restartRestartsEngine() {
        let controller = makeReadyController()
        controller.restartEngine()
        #expect(engine.stopCount == 1)
        #expect(engine.startCount == 2)
        #expect(controller.status == .loading)
    }

    // MARK: Happy path

    @Test func toggleRecordsAndSecondToggleInsertsTextWithTrailingSpace() async throws {
        let controller = makeReadyController()
        var seen: [AppStatus] = []
        controller.onStatusChange = { seen.append($0) }
        try await tapToStart(controller)

        hotkey.send(.toggle)
        try await waitUntil { !inserter.inserted.isEmpty }

        #expect(seen == [.starting, .listening, .ready(cleanMode: true), .transcribing, .ready(cleanMode: true)])
        #expect(recorder.calls == [.warmUp, .start, .stop])

        #expect(engine.received.count == 1)
        #expect(inserter.inserted == ["hello "])
        #expect(sounds.played == [.recordingStarted, .recordingStopped])
    }

    @Test func emptyTranscriptInsertsNothing() async throws {
        engine.result = .success(Transcript(text: "", milliseconds: 1))
        let controller = makeReadyController()
        try await tapToStart(controller)
        await controller.finishRecording()?.value
        #expect(inserter.inserted.isEmpty)
    }

    /// Timings go to the log only; a success just clears the previous dictation's error from the menu.
    @Test func successClearsPreviousErrorMessage() async throws {
        engine.result = .failure(FakeError())
        let controller = makeReadyController()
        var messages: [String] = []
        controller.onMessage = { messages.append($0) }
        try await tapToStart(controller)
        await controller.finishRecording()?.value
        engine.result = .success(Transcript(text: "hello", milliseconds: 42))
        try await tapToStart(controller)
        await controller.finishRecording()?.value
        #expect(messages == ["Error: fake failure", ""])
    }

    // MARK: Diagnostics

    @Test func diagnosticsRecordTheLastSuccessfulDictation() async throws {
        let controller = makeReadyController()
        #expect(controller.diagnostics.lastTiming == nil)
        try await tapToStart(controller)
        await controller.finishRecording()?.value
        #expect(controller.diagnostics.lastTiming == .init(audioDuration: 1.0, milliseconds: 42))
    }

    @Test func failedDictationKeepsThePreviousTiming() async throws {
        let controller = makeReadyController()
        try await tapToStart(controller)
        await controller.finishRecording()?.value
        engine.result = .failure(FakeError())
        try await tapToStart(controller)
        await controller.finishRecording()?.value
        #expect(controller.diagnostics.lastTiming == .init(audioDuration: 1.0, milliseconds: 42))
    }

    // MARK: Vocabulary

    @Test func rejectedVocabularySaveIsFlaggedUntilFixed() {
        let controller = makeReadyController()
        var seen: [AppStatus] = []
        controller.onStatusChange = { seen.append($0) }

        engine.emit(VocabularyStatus(terms: 154, loadedAt: Date(), problem: "line 3 has no letters or digits"))
        #expect(controller.status == .vocabularyProblem("line 3 has no letters or digits"))
        #expect(controller.diagnostics.vocabulary?.terms == 154)

        engine.emit(VocabularyStatus(terms: 154, loadedAt: Date(), problem: nil))
        #expect(controller.status == .ready(cleanMode: true))
        #expect(seen.count == 2)
    }

    @Test func vocabularyProblemDoesntHideBiggerOnes() async throws {
        let controller = makeReadyController()
        engine.emit(VocabularyStatus(terms: 1, loadedAt: Date(), problem: "bad line"))
        engine.emit(.failed("Helper stopped (status 1)"))
        #expect(controller.status == .failed("Helper stopped (status 1)"))

        engine.emit(.ready(cleanMode: true, loadMilliseconds: 1))
        try await tapToStart(controller)
    }

    @Test func vocabularyProblemStillAllowsDictation() async throws {
        let controller = makeReadyController()
        engine.emit(VocabularyStatus(terms: 1, loadedAt: Date(), problem: "bad line"))
        try await tapToStart(controller)
        await controller.finishRecording()?.value
        #expect(inserter.inserted == ["hello "])
    }

    @Test func repeatedVocabularyReportsDontRepublish() {
        let controller = makeReadyController()
        var published = 0
        controller.onStatusChange = { _ in published += 1 }
        let status = VocabularyStatus(terms: 3, loadedAt: Date(timeIntervalSince1970: 5), problem: nil)
        engine.emit(status)
        engine.emit(status)
        #expect(published == 1)
    }

    @Test func diagnosticsReflectEngineStateAndLivePermissions() {
        let controller = makeController()
        controller.start()
        #expect(controller.diagnostics.engine == .loading)
        engine.emit(.ready(cleanMode: false, loadMilliseconds: 900))
        #expect(controller.diagnostics.engine == .ready(cleanMode: false, loadMilliseconds: 900))
        #expect(controller.diagnostics.isMicrophoneAuthorized)
        #expect(controller.diagnostics.isAccessibilityTrusted)

        // Revoked after launch: the controller's own grant flag never goes back, so this must be read live.
        permissions.isMicrophoneAuthorized = false
        permissions.isAccessibilityTrusted = false
        #expect(!controller.diagnostics.isMicrophoneAuthorized)
        #expect(!controller.diagnostics.isAccessibilityTrusted)
    }

    // MARK: Paste last dictation

    @Test func nothingToPasteBeforeTheFirstDictation() {
        let controller = makeReadyController()
        #expect(!controller.canPasteLastDictation)
        controller.pasteLastDictation()
        #expect(inserter.inserted.isEmpty)
    }

    @Test func pastesTheLastDictationAgainWithTrailingSpace() async throws {
        let controller = makeReadyController()
        try await tapToStart(controller)
        await controller.finishRecording()?.value
        engine.result = .success(Transcript(text: "second", milliseconds: 1))
        try await tapToStart(controller)
        await controller.finishRecording()?.value

        #expect(controller.canPasteLastDictation)
        controller.pasteLastDictation()
        #expect(inserter.inserted == ["hello ", "second ", "second "])
    }

    @Test(arguments: [Result<Transcript, Error>.failure(FakeError()), .success(Transcript(text: "", milliseconds: 1))])
    func failedOrEmptyDictationKeepsThePreviousOne(result: Result<Transcript, Error>) async throws {
        let controller = makeReadyController()
        try await tapToStart(controller)
        await controller.finishRecording()?.value
        engine.result = result
        try await tapToStart(controller)
        await controller.finishRecording()?.value

        controller.pasteLastDictation()
        #expect(inserter.inserted == ["hello ", "hello "])
    }

    @Test func pasteLastDictationSkipsTheFocusCheck() async throws {
        let controller = makeReadyController()
        try await tapToStart(controller)
        await controller.finishRecording()?.value
        focus.hasTextInput = false

        controller.pasteLastDictation()
        #expect(inserter.inserted == ["hello ", "hello "])
        #expect(focus.checkCount == 1)
        #expect(sounds.played == [.recordingStarted, .recordingStopped])
    }

    // MARK: Refusals and failures

    /// The clip waits in the engine until the model has loaded.
    @Test func toggleWhileLoadingRecordsAndTranscribes() async throws {
        let controller = makeController()
        controller.start()
        try await tapToStart(controller)
        hotkey.send(.toggle)
        try await waitUntil { !inserter.inserted.isEmpty }
        #expect(inserter.inserted == ["hello "])
        #expect(engine.startCount == 1)  // already loading, so not started again
    }

    @Test func toggleWithoutFocusedInputPopsQuietlyAndDoesNotRecord() {
        focus.hasTextInput = false
        let controller = makeReadyController()
        var messages: [String] = []
        var seen: [AppStatus] = []
        controller.onMessage = { messages.append($0) }
        controller.onStatusChange = { seen.append($0) }
        hotkey.send(.toggle)
        #expect(recorder.calls.isEmpty)
        #expect(sounds.played == [.noFocusedInput])
        #expect(messages.isEmpty)
        #expect(seen.isEmpty)  // so the recording pill never appears
        #expect(controller.status == .ready(cleanMode: true))
    }

    @Test func toggleWithFocusedInputAgainStartsRecording() async throws {
        focus.hasTextInput = false
        let controller = makeReadyController()
        hotkey.send(.toggle)
        focus.hasTextInput = true
        try await tapToStart(controller)
        #expect(sounds.played == [.noFocusedInput, .recordingStarted])
    }

    /// Focus is checked only to start: the stopping tap must always stop, wherever focus has moved.
    @Test func stoppingTapIgnoresFocus() async throws {
        let controller = makeReadyController()
        try await tapToStart(controller)
        focus.hasTextInput = false
        hotkey.send(.toggle)
        try await waitUntil { !inserter.inserted.isEmpty }
        #expect(!recorder.isOpen)
        #expect(focus.checkCount == 1)
        #expect(sounds.played == [.recordingStarted, .recordingStopped])
    }

    @Test func toggleWhileFailedAlertsWithoutCheckingFocusAndDoesNotRecord() {
        focus.hasTextInput = false
        let controller = makeReadyController()
        engine.emit(.failed("Helper stopped (status 1)"))
        hotkey.send(.toggle)
        #expect(recorder.calls.isEmpty)
        #expect(sounds.played == [.alert])
        #expect(focus.checkCount == 0)
        #expect(controller.status == .failed("Helper stopped (status 1)"))
    }

    @Test func toggleWithoutMicPermissionAlertsWithMessage() {
        permissions.isMicrophoneAuthorized = false
        let controller = makeReadyController()
        var messages: [String] = []
        controller.onMessage = { messages.append($0) }
        hotkey.send(.toggle)
        #expect(recorder.calls.isEmpty)
        #expect(sounds.played == [.alert])
        #expect(messages.first?.hasPrefix("Microphone access is off") == true)
    }

    /// The pill showed for the start, so the failure hides it.
    @Test func recorderStartFailureAlerts() async throws {
        recorder.startError = FakeError()
        let controller = makeReadyController()
        var messages: [String] = []
        var seen: [AppStatus] = []
        controller.onMessage = { messages.append($0) }
        controller.onStatusChange = { seen.append($0) }
        hotkey.send(.toggle)
        try await waitUntil { !messages.isEmpty }
        #expect(sounds.played == [.alert])
        #expect(seen == [.starting, .ready(cleanMode: true)])
        #expect(messages == ["Mic error: fake failure"])
    }

    @Test func engineFailureAlertsAndInsertsNothing() async throws {
        engine.result = .failure(FakeError())
        let controller = makeReadyController()
        var messages: [String] = []
        controller.onMessage = { messages.append($0) }
        try await tapToStart(controller)
        await controller.finishRecording()?.value
        #expect(inserter.inserted.isEmpty)
        #expect(sounds.played == [.recordingStarted, .recordingStopped, .alert])
        #expect(messages == ["Error: fake failure"])
        #expect(controller.status == .ready(cleanMode: true))
    }

    @Test func tapShorterThanMinimumIsIgnored() async throws {
        recorder.clipToReturn = AudioClip(samples: [Float](repeating: 0, count: 1_000))  // 62 ms
        let controller = makeReadyController()
        var seen: [AppStatus] = []
        controller.onStatusChange = { seen.append($0) }
        try await tapToStart(controller)
        await controller.finishRecording()?.value
        #expect(engine.received.isEmpty)
        #expect(seen == [.starting, .listening, .ready(cleanMode: true)])  // never shows Transcribing…
        #expect(sounds.played == [.recordingStarted, .recordingStopped])  // the mic still opened and closed
        #expect(controller.status == .ready(cleanMode: true))
    }

    @Test func cancelDiscardsRecording() async throws {
        let controller = makeReadyController()
        try await tapToStart(controller)
        hotkey.send(.cancel)
        #expect(recorder.cancelCount == 1)
        #expect(engine.received.isEmpty)
        #expect(sounds.played == [.recordingStarted, .recordingStopped])
        #expect(controller.status == .ready(cleanMode: true))
    }

    @Test func cancelWithoutRecordingDoesNothing() {
        let controller = makeReadyController()
        #expect(controller.finishRecording() == nil)
        hotkey.send(.cancel)
        #expect(recorder.cancelCount == 0)
        #expect(sounds.played.isEmpty)
    }

    @Test func toggleAfterCancelStartsAFreshRecording() async throws {
        let controller = makeReadyController()
        try await tapToStart(controller)
        hotkey.send(.cancel)
        try await tapToStart(controller)
        #expect(engine.received.isEmpty)
    }

    @Test func recordingStopsAtMaximumDuration() async throws {
        var settings = DictationSettings()
        settings.maximumClipDuration = .milliseconds(20)
        let controller = makeReadyController(settings: settings)
        try await tapToStart(controller)
        try await waitUntil { engine.received.count == 1 }
        #expect(!recorder.isOpen)
        #expect(sounds.played == [.recordingStarted, .recordingStopped])  // so you know it stopped without a tap
        #expect(controller.status == .ready(cleanMode: true))
    }

    @Test func engineFailingMidRecordingReportsErrorOnStop() async throws {
        engine.result = .failure(TranscriptionError.notRunning)
        let controller = makeReadyController()
        var messages: [String] = []
        controller.onMessage = { messages.append($0) }
        try await tapToStart(controller)
        engine.emit(.failed("Helper stopped (status 1)"))
        #expect(controller.status == .listening)  // the mic stays visibly open until the next tap

        await controller.finishRecording()?.value
        #expect(messages == ["Error: Transcription helper isn't running"])
        #expect(controller.status == .failed("Helper stopped (status 1)"))
    }

    enum RecordingEnd: CaseIterable {
        case tap, tooShort, cancel, stop
    }

    /// The on-screen level meter follows the published status, so every way a recording ends must publish.
    @Test(arguments: RecordingEnd.allCases)
    func everyRecordingEndPublishesStatusOtherThanListening(end: RecordingEnd) async throws {
        if end == .tooShort { recorder.clipToReturn = AudioClip(samples: [0]) }
        let controller = makeReadyController()
        var seen: [AppStatus] = []
        controller.onStatusChange = { seen.append($0) }
        try await tapToStart(controller)
        #expect(seen == [.starting, .listening])

        switch end {
        case .tap, .tooShort: hotkey.send(.toggle)
        case .cancel: hotkey.send(.cancel)
        case .stop: controller.stop()
        }
        // Quitting also stops the engine, which reports one more state.
        #expect(seen.count == (end == .stop ? 4 : 3))
        #expect(seen.dropFirst(2).allSatisfy { $0 != .listening })
    }

    @Test func stopClosesMicAndStopsEngine() async throws {
        let controller = makeReadyController()
        try await tapToStart(controller)
        controller.stop()
        #expect(!recorder.isOpen)
        #expect(engine.stopCount == 1)
        #expect(sounds.played == [.recordingStarted, .recordingStopped])
    }

    // MARK: Reloading an unloaded model

    @Test func tapWhileUnloadedLoadsTheModelRecordsAndPastes() async throws {
        let controller = makeUnloadedController()
        engine.holdTranscription = true
        try await tapToStart(controller)
        #expect(engine.startCount == 2)
        #expect(sounds.played == [.recordingStarted])
        hotkey.send(.toggle)
        try await waitUntil { engine.received.count == 1 }
        // Sent while the model still loads: the engine holds it until then.
        #expect(controller.diagnostics.engine == .loading)
        #expect(controller.status == .transcribing)
        engine.emit(.ready(cleanMode: true, loadMilliseconds: 1))
        engine.releaseTranscription()
        try await waitUntil { !inserter.inserted.isEmpty }
        #expect(inserter.inserted == ["hello "])
    }

    /// fn key-down also starts shortcuts, so it opens only the mic; the tap loads the model.
    @Test func pressWhileUnloadedWarmsOnlyTheMicAndItsTapLoads() async throws {
        let controller = makeUnloadedController()
        hotkey.send(.pressBegan)
        hotkey.send(.pressAbandoned)
        #expect(engine.startCount == 1)
        hotkey.send(.pressBegan)
        #expect(recorder.calls == [.warmUp, .cancel, .warmUp])
        hotkey.send(.toggle)
        try await waitUntil { controller.status == .listening }
        #expect(engine.startCount == 2)
    }

    enum UnloadedRefusal: CaseIterable {
        case noFocusedInput, microphoneOff
    }

    /// A tap that can't dictate doesn't load the model, with or without a warm-up first.
    @Test(arguments: UnloadedRefusal.allCases, [false, true])
    func refusedTapWhileUnloadedDoesntLoadTheModel(refusal: UnloadedRefusal, pressFirst: Bool) {
        switch refusal {
        case .noFocusedInput: focus.hasTextInput = false
        case .microphoneOff: permissions.isMicrophoneAuthorized = false
        }
        let controller = makeUnloadedController()
        if pressFirst { hotkey.send(.pressBegan) }
        hotkey.send(.toggle)
        #expect(engine.startCount == 1)
        #expect(recorder.calls.isEmpty)
        #expect(sounds.played == [refusal == .noFocusedInput ? .noFocusedInput : .alert])
        #expect(controller.status == .unloaded)
    }

    /// e.g. the venv was removed while the app ran: nothing would transcribe the clip, so don't record it.
    @Test(arguments: [false, true])
    func reloadThatCantStartRefusesTheTap(pressFirst: Bool) async throws {
        engine.startFailure = "Couldn't start helper"
        let controller = makeUnloadedController()
        if pressFirst { hotkey.send(.pressBegan) }
        hotkey.send(.toggle)
        try await Task.sleep(for: .milliseconds(50))
        #expect(!recorder.calls.contains(.start))
        #expect(!recorder.isOpen)
        #expect(sounds.played == [.alert])
        #expect(controller.status == .failed("Couldn't start helper"))
    }

    @Test func failedReloadDiscardsTheClipAndAlerts() async throws {
        let controller = makeUnloadedController()
        var messages: [String] = []
        controller.onMessage = { messages.append($0) }
        try await tapToStart(controller)
        engine.emit(.failed("model not found"))
        engine.result = .failure(TranscriptionError.notRunning)
        await controller.finishRecording()?.value
        #expect(inserter.inserted.isEmpty)
        #expect(sounds.played == [.recordingStarted, .recordingStopped, .alert])
        #expect(messages == ["Error: Transcription helper isn't running"])
        #expect(controller.status == .failed("model not found"))
    }

    @Test func cancelDuringReloadDiscardsTheClipAndTheLoadCarriesOn() async throws {
        let controller = makeUnloadedController()
        try await tapToStart(controller)
        hotkey.send(.cancel)
        engine.emit(.ready(cleanMode: true, loadMilliseconds: 1))
        try await Task.sleep(for: .milliseconds(50))
        #expect(engine.received.isEmpty)
        #expect(engine.stopCount == 0)
        #expect(controller.status == .ready(cleanMode: true))
    }

    // MARK: Unloading the model when idle

    static let quickUnload = DictationSettings(idleUnloadDelay: .milliseconds(50))

    @Test func unloadsTheModelAfterTheDelayWithNoDictation() async throws {
        let controller = makeReadyController(settings: Self.quickUnload)
        try await waitUntil { engine.stopCount == 1 }
        #expect(controller.status == .unloaded)
    }

    enum Busy: CaseIterable {
        case warming, recording, transcribing
    }

    /// The delay counts from the end of the last dictation, and nothing in progress is ever cut short.
    @Test(arguments: Busy.allCases)
    func neverUnloadsMidDictationAndUnloadsOnceItEnds(busy: Busy) async throws {
        let controller = makeReadyController(settings: Self.quickUnload)
        switch busy {
        case .warming: hotkey.send(.pressBegan)
        case .recording: try await tapToStart(controller)
        case .transcribing:
            engine.holdTranscription = true
            try await tapToStart(controller)
            hotkey.send(.toggle)
            try await waitUntil { engine.received.count == 1 }
        }
        try await Task.sleep(for: .milliseconds(150))
        #expect(engine.stopCount == 0)

        switch busy {
        case .warming: hotkey.send(.pressAbandoned)
        case .recording: hotkey.send(.toggle)
        case .transcribing: engine.releaseTranscription()
        }
        try await waitUntil { engine.stopCount == 1 }
        if busy != .warming { #expect(inserter.inserted == ["hello "]) }
    }

    /// Only a loaded model is unloaded: there's nothing to free while it loads, and a failure needs Restart Helper.
    @Test(arguments: [EngineState.loading, .failed("Helper stopped (status 1)")])
    func neverUnloadsAnEngineThatIsntReady(state: EngineState) async throws {
        let controller = makeController(settings: Self.quickUnload)
        controller.start()
        engine.emit(state)
        try await Task.sleep(for: .milliseconds(150))
        #expect(engine.stopCount == 0)
    }

    @Test func modelReloadedForACancelledDictationUnloadsAgain() async throws {
        let controller = makeUnloadedController(settings: Self.quickUnload)
        try await tapToStart(controller)
        hotkey.send(.cancel)
        engine.emit(.ready(cleanMode: true, loadMilliseconds: 1))
        try await waitUntil { engine.stopCount == 1 }
        #expect(controller.status == .unloaded)
    }

    // MARK: Warming the mic on fn key-down

    @Test func pressWarmsTheMicSilently() {
        let controller = makeReadyController()
        var seen: [AppStatus] = []
        controller.onStatusChange = { seen.append($0) }
        hotkey.send(.pressBegan)
        #expect(recorder.calls == [.warmUp])
        #expect(sounds.played.isEmpty)
        #expect(seen.isEmpty)  // so the pill doesn't show for what may be a shortcut
        #expect(controller.status == .ready(cleanMode: true))
    }

    @Test func tapAfterPressCommits() async throws {
        let controller = makeReadyController()
        var seen: [AppStatus] = []
        controller.onStatusChange = { seen.append($0) }
        hotkey.tap()
        try await waitUntil { controller.status == .listening }
        #expect(sounds.played == [.recordingStarted])
        #expect(seen == [.starting, .listening])
        #expect(recorder.calls == [.warmUp, .start])

        await controller.finishRecording()?.value
        #expect(inserter.inserted == ["hello "])
    }

    /// fn+arrow, fn+Delete, fn+Esc: the mic closes at the other key, with nothing to see or hear.
    @Test func abandonedPressDiscardsSilently() async throws {
        let controller = makeReadyController()
        var seen: [AppStatus] = []
        controller.onStatusChange = { seen.append($0) }
        hotkey.send(.pressBegan)
        hotkey.send(.pressAbandoned)
        #expect(recorder.calls == [.warmUp, .cancel])
        #expect(!recorder.isOpen)

        try await Task.sleep(for: .milliseconds(30))
        #expect(sounds.played.isEmpty)
        #expect(seen.isEmpty)
        #expect(engine.received.isEmpty)
        #expect(controller.status == .ready(cleanMode: true))
    }

    enum PressRefusal: CaseIterable {
        case engineFailed, noFocusedInput, microphoneOff
    }

    /// A press that its tap would refuse never opens the mic, stays quiet, and leaves the refusal to the tap.
    @Test(arguments: PressRefusal.allCases)
    func refusedPressNeverOpensTheMicAndItsTapReportsIt(refusal: PressRefusal) {
        let controller: DictationController
        switch refusal {
        case .engineFailed:
            controller = makeReadyController()
            engine.emit(.failed("Helper stopped (status 1)"))
        case .noFocusedInput:
            focus.hasTextInput = false
            controller = makeReadyController()
        case .microphoneOff:
            permissions.isMicrophoneAuthorized = false
            controller = makeReadyController()
        }
        var messages: [String] = []
        var seen: [AppStatus] = []
        controller.onMessage = { messages.append($0) }
        controller.onStatusChange = { seen.append($0) }

        hotkey.send(.pressBegan)
        #expect(sounds.played.isEmpty)
        #expect(messages.isEmpty)

        hotkey.send(.toggle)
        #expect(recorder.calls.isEmpty)
        #expect(!seen.contains(.starting))  // a refusal never shows the pill
        switch refusal {
        case .engineFailed:
            #expect(sounds.played == [.alert])
            #expect(focus.checkCount == 0)
        case .noFocusedInput:
            #expect(sounds.played == [.noFocusedInput])
            #expect(messages.isEmpty)
        case .microphoneOff:
            #expect(sounds.played == [.alert])
            #expect(messages.first?.hasPrefix("Microphone access is off") == true)
        }
    }

    @Test func engineFailingBetweenPressAndTapAlerts() {
        let controller = makeReadyController()
        hotkey.send(.pressBegan)
        engine.emit(.failed("Helper stopped (status 1)"))
        hotkey.send(.toggle)
        #expect(sounds.played == [.alert])
        #expect(recorder.calls == [.warmUp, .cancel])
        #expect(controller.status == .failed("Helper stopped (status 1)"))
    }

    /// The stopping tap's key-down, or a repeated one, must not open a second mic.
    @Test func pressWhileWarmingOrRecordingIsIgnored() async throws {
        let controller = makeReadyController()
        hotkey.send(.pressBegan)
        hotkey.send(.pressBegan)
        #expect(recorder.calls == [.warmUp])

        hotkey.send(.toggle)
        try await waitUntil { controller.status == .listening }
        hotkey.send(.pressBegan)
        hotkey.send(.pressAbandoned)
        #expect(recorder.calls == [.warmUp, .start])
        #expect(controller.status == .listening)

        hotkey.send(.toggle)
        try await waitUntil { !inserter.inserted.isEmpty }
        #expect(sounds.played == [.recordingStarted, .recordingStopped])
    }

    /// fn held on its own, or a key-up a password field hid: the mic doesn't stay open, and a late tap still works.
    @Test func warmUpTimesOutSilently() async throws {
        var settings = DictationSettings()
        settings.warmUpLimit = .milliseconds(20)
        let controller = makeReadyController(settings: settings)
        hotkey.send(.pressBegan)
        try await waitUntil { recorder.calls == [.warmUp, .cancel] }
        #expect(!recorder.isOpen)
        #expect(sounds.played.isEmpty)

        hotkey.send(.toggle)
        try await waitUntil { controller.status == .listening }
        #expect(recorder.calls == [.warmUp, .cancel, .start])
        #expect(sounds.played == [.recordingStarted])
    }

    @Test func committedWarmUpOutlivesItsLimit() async throws {
        var settings = DictationSettings()
        settings.warmUpLimit = .milliseconds(20)
        let controller = makeReadyController(settings: settings)
        try await tapToStart(controller)
        try await Task.sleep(for: .milliseconds(60))
        #expect(controller.status == .listening)
        #expect(recorder.cancelCount == 0)
    }

    /// A Bluetooth input skips the warm-up, and the tap opens it as before.
    @Test func skippedWarmUpStillStartsOnTheTap() async throws {
        recorder.warmUpOpens = false
        let controller = makeReadyController()
        try await tapToStart(controller)
        #expect(recorder.calls == [.warmUp, .start])
        #expect(sounds.played == [.recordingStarted])
    }

    // MARK: While the mic is opening

    enum EndWhileOpening: CaseIterable {
        case tap, cancel, stop
    }

    /// Nothing was heard and no chime has played yet, so every way out of a start is silent, but it hides the pill,
    /// and the start's late reply doesn't revive it.
    @Test(arguments: EndWhileOpening.allCases)
    func endingWhileTheMicOpensIsSilent(end: EndWhileOpening) async throws {
        recorder.holdStart = true
        let controller = makeReadyController()
        var seen: [AppStatus] = []
        controller.onStatusChange = { seen.append($0) }
        hotkey.send(.toggle)
        try await waitUntil { recorder.calls == [.start] }

        switch end {
        case .tap: hotkey.send(.toggle)
        case .cancel: hotkey.send(.cancel)
        case .stop: controller.stop()
        }
        recorder.releaseStart()
        try await Task.sleep(for: .milliseconds(50))

        #expect(recorder.calls == [.start, .cancel])
        #expect(!recorder.isOpen)
        #expect(sounds.played.isEmpty)
        #expect(seen == [.starting, .ready(cleanMode: true)] + (end == .stop ? [.unloaded] : []))
    }

    /// Events handled back to back, e.g. after a main-thread stall: each recorder call must take its turn in that
    /// order, or the mic could open behind the discard, with nothing to close it.
    @Test(arguments: EndWhileOpening.allCases)
    func endingStraightAfterTheTapKeepsTheMicClosed(end: EndWhileOpening) async throws {
        let controller = makeReadyController()
        hotkey.send(.toggle)
        switch end {
        case .tap: hotkey.send(.toggle)
        case .cancel: hotkey.send(.cancel)
        case .stop: controller.stop()
        }
        try await Task.sleep(for: .milliseconds(50))

        #expect(recorder.calls == [.start, .cancel])
        #expect(!recorder.isOpen)
        #expect(sounds.played.isEmpty)
        #expect(controller.status == (end == .stop ? .unloaded : .ready(cleanMode: true)))
    }

    /// The stopping tap, then a shortcut straight after: the shortcut's warm-up and discard must come after the stop,
    /// or they'd close the mic first and the dictation would come back empty.
    @Test func shortcutStraightAfterTheStoppingTapKeepsTheDictation() async throws {
        let controller = makeReadyController()
        try await tapToStart(controller)
        hotkey.send(.toggle)
        hotkey.send(.pressBegan)
        hotkey.send(.pressAbandoned)
        try await waitUntil { !inserter.inserted.isEmpty }

        #expect(recorder.calls == [.warmUp, .start, .stop, .warmUp, .cancel])
        #expect(inserter.inserted == ["hello "])
        #expect(controller.status == .ready(cleanMode: true))
    }

    @Test func tapAfterADiscardedStartStartsAFreshRecording() async throws {
        recorder.holdStart = true
        let controller = makeReadyController()
        hotkey.send(.toggle)
        try await waitUntil { recorder.calls == [.start] }
        hotkey.send(.cancel)
        recorder.holdStart = false
        recorder.releaseStart()
        try await tapToStart(controller)
        #expect(sounds.played == [.recordingStarted])
    }

    /// The pill shows on the tap, with a spinner; the chime means the mic hears you, so it waits for the start,
    /// however long that takes.
    @Test func tapShowsStartingUntilTheMicIsReady() async throws {
        recorder.holdStart = true
        let controller = makeReadyController()
        var seen: [AppStatus] = []
        controller.onStatusChange = { seen.append($0) }
        hotkey.send(.toggle)
        try await waitUntil { recorder.calls == [.start] }
        try await Task.sleep(for: .milliseconds(20))
        #expect(sounds.played.isEmpty)
        #expect(seen == [.starting])

        recorder.releaseStart()
        try await waitUntil { controller.status == .listening }
        #expect(sounds.played == [.recordingStarted])
        #expect(seen == [.starting, .listening])
    }

    /// A muted mic, or AirPods another device holds, sends only silence: fail rather than chime over a dead mic.
    @Test func startThatNeverHearsAudioFailsAfterTheLimit() async throws {
        recorder.holdStart = true
        var settings = DictationSettings()
        settings.readyLimit = .milliseconds(20)
        let controller = makeReadyController(settings: settings)
        var seen: [AppStatus] = []
        var messages: [String] = []
        controller.onStatusChange = { seen.append($0) }
        controller.onMessage = { messages.append($0) }
        hotkey.send(.toggle)
        try await waitUntil { !messages.isEmpty }

        #expect(recorder.calls == [.start, .cancel])
        #expect(sounds.played == [.alert])
        #expect(seen == [.starting, .ready(cleanMode: true)])
        #expect(messages.first?.hasPrefix("Mic error: no sound from the microphone") == true)

        recorder.releaseStart()
        try await Task.sleep(for: .milliseconds(30))
        #expect(sounds.played == [.alert])
        #expect(controller.status == .ready(cleanMode: true))
    }

    /// The limit is for the start only: a dictation that started keeps going past it.
    @Test func readyLimitEndsWithTheStart() async throws {
        var settings = DictationSettings()
        settings.readyLimit = .milliseconds(20)
        let controller = makeReadyController(settings: settings)
        try await tapToStart(controller)
        try await Task.sleep(for: .milliseconds(50))
        #expect(sounds.played == [.recordingStarted])
        #expect(controller.status == .listening)
        #expect(recorder.calls == [.warmUp, .start])
    }

    /// Dictating again while the last one transcribes: the pill must still show for the new start.
    @Test func startingOutranksTranscribing() async throws {
        engine.holdTranscription = true
        let controller = makeReadyController()
        try await tapToStart(controller)
        hotkey.send(.toggle)
        try await waitUntil { controller.status == .transcribing }

        recorder.holdStart = true
        hotkey.send(.toggle)
        try await waitUntil { controller.status == .starting }
        recorder.releaseStart()
        try await waitUntil { controller.status == .listening }
        engine.releaseTranscription()
    }
}
