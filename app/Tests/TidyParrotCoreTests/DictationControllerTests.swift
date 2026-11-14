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
        engine.emit(.ready(cleanMode: true))
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
        permissions.accessibilityTrusted = false
        let controller = makeController()
        controller.start()
        engine.emit(.ready(cleanMode: true))
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
        engine.emit(.ready(cleanMode: false))
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

    @Test func reportsTimingMessage() async {
        let controller = makeReadyController()
        var messages: [String] = []
        controller.onMessage = { messages.append($0) }
        hotkey.send(.toggle)
        await controller.finishRecording()?.value
        #expect(messages == ["Last: 1.0s of audio in 42 ms"])
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
