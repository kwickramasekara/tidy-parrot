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
        hotkey.send(.toggle)
        #expect(controller.status == .listening)

        hotkey.send(.toggle)
        #expect(controller.status == .transcribing)
        try await waitUntil { controller.status == .ready(cleanMode: true) }

        #expect(engine.received.count == 1)
        #expect(inserter.inserted == ["hello "])
        #expect(sounds.played == [.recordingStarted, .recordingStopped])
    }

    @Test func emptyTranscriptInsertsNothing() async {
        engine.result = .success(Transcript(text: "", milliseconds: 1))
        let controller = makeReadyController()
        hotkey.send(.toggle)
        await controller.finishRecording()?.value
        #expect(inserter.inserted.isEmpty)
    }

    /// Timings go to the log only; a success just clears the previous dictation's error from the menu.
    @Test func successClearsPreviousErrorMessage() async {
        engine.result = .failure(FakeError())
        let controller = makeReadyController()
        var messages: [String] = []
        controller.onMessage = { messages.append($0) }
        hotkey.send(.toggle)
        await controller.finishRecording()?.value
        engine.result = .success(Transcript(text: "hello", milliseconds: 42))
        hotkey.send(.toggle)
        await controller.finishRecording()?.value
        #expect(messages == ["Error: fake failure", ""])
    }

    // MARK: Diagnostics

    @Test func diagnosticsRecordTheLastSuccessfulDictation() async {
        let controller = makeReadyController()
        #expect(controller.diagnostics.lastTiming == nil)
        hotkey.send(.toggle)
        await controller.finishRecording()?.value
        #expect(controller.diagnostics.lastTiming == .init(audioDuration: 1.0, milliseconds: 42))
    }

    @Test func failedDictationKeepsThePreviousTiming() async {
        let controller = makeReadyController()
        hotkey.send(.toggle)
        await controller.finishRecording()?.value
        engine.result = .failure(FakeError())
        hotkey.send(.toggle)
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

    @Test func vocabularyProblemDoesntHideBiggerOnes() {
        let controller = makeReadyController()
        engine.emit(VocabularyStatus(terms: 1, loadedAt: Date(), problem: "bad line"))
        engine.emit(.failed("Helper stopped (status 1)"))
        #expect(controller.status == .failed("Helper stopped (status 1)"))

        engine.emit(.ready(cleanMode: true, loadMilliseconds: 1))
        hotkey.send(.toggle)
        #expect(controller.status == .listening)
    }

    @Test func vocabularyProblemStillAllowsDictation() async {
        let controller = makeReadyController()
        engine.emit(VocabularyStatus(terms: 1, loadedAt: Date(), problem: "bad line"))
        hotkey.send(.toggle)
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

    @Test func pastesTheLastDictationAgainWithTrailingSpace() async {
        let controller = makeReadyController()
        hotkey.send(.toggle)
        await controller.finishRecording()?.value
        engine.result = .success(Transcript(text: "second", milliseconds: 1))
        hotkey.send(.toggle)
        await controller.finishRecording()?.value

        #expect(controller.canPasteLastDictation)
        controller.pasteLastDictation()
        #expect(inserter.inserted == ["hello ", "second ", "second "])
    }

    @Test(arguments: [Result<Transcript, Error>.failure(FakeError()), .success(Transcript(text: "", milliseconds: 1))])
    func failedOrEmptyDictationKeepsThePreviousOne(result: Result<Transcript, Error>) async {
        let controller = makeReadyController()
        hotkey.send(.toggle)
        await controller.finishRecording()?.value
        engine.result = result
        hotkey.send(.toggle)
        await controller.finishRecording()?.value

        controller.pasteLastDictation()
        #expect(inserter.inserted == ["hello ", "hello "])
    }

    @Test func pasteLastDictationSkipsTheFocusCheck() async {
        let controller = makeReadyController()
        hotkey.send(.toggle)
        await controller.finishRecording()?.value
        focus.hasTextInput = false

        controller.pasteLastDictation()
        #expect(inserter.inserted == ["hello ", "hello "])
        #expect(focus.checkCount == 1)
        #expect(sounds.played == [.recordingStarted, .recordingStopped])
    }

    // MARK: Refusals and failures

    @Test func toggleBeforeEngineReadyAlertsAndDoesNotRecord() {
        let controller = makeController()
        controller.start()
        hotkey.send(.toggle)
        #expect(!recorder.isRecording)
        #expect(sounds.played == [.alert])
    }

    @Test func toggleWithoutFocusedInputPopsQuietlyAndDoesNotRecord() {
        focus.hasTextInput = false
        let controller = makeReadyController()
        var messages: [String] = []
        var seen: [AppStatus] = []
        controller.onMessage = { messages.append($0) }
        controller.onStatusChange = { seen.append($0) }
        hotkey.send(.toggle)
        #expect(!recorder.isRecording)
        #expect(sounds.played == [.noFocusedInput])
        #expect(messages.isEmpty)
        #expect(seen.isEmpty)  // so the recording pill never appears
        #expect(controller.status == .ready(cleanMode: true))
    }

    @Test func toggleWithFocusedInputAgainStartsRecording() {
        focus.hasTextInput = false
        let controller = makeReadyController()
        hotkey.send(.toggle)
        focus.hasTextInput = true
        hotkey.send(.toggle)
        #expect(controller.status == .listening)
        #expect(sounds.played == [.noFocusedInput, .recordingStarted])
    }

    /// Focus is checked only to start: the stopping tap must always stop, wherever focus has moved.
    @Test func stoppingTapIgnoresFocus() async throws {
        let controller = makeReadyController()
        hotkey.send(.toggle)
        focus.hasTextInput = false
        hotkey.send(.toggle)
        #expect(!recorder.isRecording)
        #expect(focus.checkCount == 1)
        try await waitUntil { controller.status == .ready(cleanMode: true) }
        #expect(sounds.played == [.recordingStarted, .recordingStopped])
    }

    @Test func toggleBeforeEngineReadyAlertsWithoutCheckingFocus() {
        focus.hasTextInput = false
        let controller = makeController()
        controller.start()
        hotkey.send(.toggle)
        #expect(sounds.played == [.alert])
        #expect(focus.checkCount == 0)
    }

    @Test func toggleWithoutMicPermissionAlertsWithMessage() {
        permissions.isMicrophoneAuthorized = false
        let controller = makeReadyController()
        var messages: [String] = []
        controller.onMessage = { messages.append($0) }
        hotkey.send(.toggle)
        #expect(!recorder.isRecording)
        #expect(sounds.played == [.alert])
        #expect(messages.first?.hasPrefix("Microphone access is off") == true)
    }

    @Test func recorderStartFailureAlerts() {
        recorder.startError = FakeError()
        let controller = makeReadyController()
        var messages: [String] = []
        controller.onMessage = { messages.append($0) }
        hotkey.send(.toggle)
        #expect(sounds.played == [.alert])
        #expect(messages == ["Mic error: fake failure"])
    }

    @Test func engineFailureAlertsAndInsertsNothing() async {
        engine.result = .failure(FakeError())
        let controller = makeReadyController()
        var messages: [String] = []
        controller.onMessage = { messages.append($0) }
        hotkey.send(.toggle)
        await controller.finishRecording()?.value
        #expect(inserter.inserted.isEmpty)
        #expect(sounds.played == [.recordingStarted, .recordingStopped, .alert])
        #expect(messages == ["Error: fake failure"])
        #expect(controller.status == .ready(cleanMode: true))
    }

    @Test func tapShorterThanMinimumIsIgnored() {
        recorder.clipToReturn = AudioClip(samples: [Float](repeating: 0, count: 1_000))  // 62 ms
        let controller = makeReadyController()
        hotkey.send(.toggle)
        #expect(controller.finishRecording() == nil)
        #expect(engine.received.isEmpty)
        #expect(sounds.played == [.recordingStarted, .recordingStopped])  // the mic still opened and closed
        #expect(controller.status == .ready(cleanMode: true))
    }

    @Test func cancelDiscardsRecording() {
        let controller = makeReadyController()
        hotkey.send(.toggle)
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

    @Test func toggleAfterCancelStartsAFreshRecording() {
        let controller = makeReadyController()
        hotkey.send(.toggle)
        hotkey.send(.cancel)
        hotkey.send(.toggle)
        #expect(controller.status == .listening)
        #expect(engine.received.isEmpty)
    }

    @Test func recordingStopsAtMaximumDuration() async throws {
        var settings = DictationSettings()
        settings.maximumClipDuration = .milliseconds(20)
        let controller = makeReadyController(settings: settings)
        hotkey.send(.toggle)
        try await waitUntil { engine.received.count == 1 }
        #expect(!recorder.isRecording)
        #expect(sounds.played == [.recordingStarted, .recordingStopped])  // so you know it stopped without a tap
        #expect(controller.status == .ready(cleanMode: true))
    }

    @Test func engineFailingMidRecordingReportsErrorOnStop() async {
        engine.result = .failure(TranscriptionError.notRunning)
        let controller = makeReadyController()
        var messages: [String] = []
        controller.onMessage = { messages.append($0) }
        hotkey.send(.toggle)
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
    func everyRecordingEndPublishesStatusOtherThanListening(end: RecordingEnd) {
        if end == .tooShort { recorder.clipToReturn = AudioClip(samples: [0]) }
        let controller = makeReadyController()
        var seen: [AppStatus] = []
        controller.onStatusChange = { seen.append($0) }
        hotkey.send(.toggle)
        #expect(seen == [.listening])

        switch end {
        case .tap, .tooShort: hotkey.send(.toggle)
        case .cancel: hotkey.send(.cancel)
        case .stop: controller.stop()
        }
        #expect(seen.count == 2)
        #expect(seen.last != .listening)
    }

    @Test func stopClosesMicAndStopsEngine() {
        let controller = makeReadyController()
        hotkey.send(.toggle)
        controller.stop()
        #expect(!recorder.isRecording)
        #expect(engine.stopCount == 1)
    }
}
