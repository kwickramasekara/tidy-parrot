import Testing

@testable import TidyParrotCore

@MainActor
struct DictationControllerTests {
    let hotkey = FakeHotkey()
    let recorder = FakeRecorder()
    let engine = FakeEngine()
    let inserter = FakeInserter()
    let permissions = FakePermissions()
    let alerts = AlertCounter()

    final class AlertCounter {
        var count = 0
    }

    func makeController(settings: DictationSettings = DictationSettings()) -> DictationController {
        DictationController(
            dependencies: .init(
                hotkey: hotkey, recorder: recorder, engine: engine, inserter: inserter, permissions: permissions,
                alert: { alerts.count += 1 }),
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

    @Test func pressRecordsAndReleaseInsertsTextWithTrailingSpace() async {
        let controller = makeReadyController()
        hotkey.send(.press)
        #expect(controller.status == .listening)

        let task = controller.finishRecording()
        #expect(controller.status == .transcribing)
        await task?.value

        #expect(engine.received.count == 1)
        #expect(inserter.inserted == ["hello "])
        #expect(controller.status == .ready(cleanMode: true))
    }

    @Test func emptyTranscriptInsertsNothing() async {
        engine.result = .success(Transcript(text: "", milliseconds: 1))
        let controller = makeReadyController()
        hotkey.send(.press)
        await controller.finishRecording()?.value
        #expect(inserter.inserted.isEmpty)
    }

    @Test func reportsTimingMessage() async {
        let controller = makeReadyController()
        var messages: [String] = []
        controller.onMessage = { messages.append($0) }
        hotkey.send(.press)
        await controller.finishRecording()?.value
        #expect(messages == ["Last: 1.0s of audio in 42 ms"])
    }

    // MARK: Refusals and failures

    @Test func pressBeforeEngineReadyAlertsAndDoesNotRecord() {
        let controller = makeController()
        controller.start()
        hotkey.send(.press)
        #expect(!recorder.isRecording)
        #expect(alerts.count == 1)
    }

    @Test func pressWithoutMicPermissionAlertsWithMessage() {
        permissions.isMicrophoneAuthorized = false
        let controller = makeReadyController()
        var messages: [String] = []
        controller.onMessage = { messages.append($0) }
        hotkey.send(.press)
        #expect(!recorder.isRecording)
        #expect(alerts.count == 1)
        #expect(messages.first?.hasPrefix("Microphone access is off") == true)
    }

    @Test func recorderStartFailureAlerts() {
        recorder.startError = FakeError()
        let controller = makeReadyController()
        var messages: [String] = []
        controller.onMessage = { messages.append($0) }
        hotkey.send(.press)
        #expect(alerts.count == 1)
        #expect(messages == ["Mic error: fake failure"])
    }

    @Test func engineFailureAlertsAndInsertsNothing() async {
        engine.result = .failure(FakeError())
        let controller = makeReadyController()
        var messages: [String] = []
        controller.onMessage = { messages.append($0) }
        hotkey.send(.press)
        await controller.finishRecording()?.value
        #expect(inserter.inserted.isEmpty)
        #expect(alerts.count == 1)
        #expect(messages == ["Error: fake failure"])
        #expect(controller.status == .ready(cleanMode: true))
    }

    @Test func tapShorterThanMinimumIsIgnored() {
        recorder.clipToReturn = AudioClip(samples: [Float](repeating: 0, count: 1_000))  // 62 ms
        let controller = makeReadyController()
        hotkey.send(.press)
        #expect(controller.finishRecording() == nil)
        #expect(engine.received.isEmpty)
        #expect(controller.status == .ready(cleanMode: true))
    }

    @Test func cancelDiscardsRecording() {
        let controller = makeReadyController()
        hotkey.send(.press)
        hotkey.send(.cancel)
        #expect(recorder.cancelCount == 1)
        #expect(engine.received.isEmpty)
        #expect(controller.status == .ready(cleanMode: true))
    }

    @Test func releaseWithoutPressDoesNothing() {
        let controller = makeReadyController()
        #expect(controller.finishRecording() == nil)
        hotkey.send(.cancel)
        #expect(recorder.cancelCount == 0)
    }

    @Test func secondPressWhileRecordingIsIgnored() {
        let controller = makeReadyController()
        hotkey.send(.press)
        hotkey.send(.press)
        #expect(alerts.count == 0)
        #expect(controller.status == .listening)
    }

    @Test func recordingStopsAtMaximumDuration() async throws {
        var settings = DictationSettings()
        settings.maximumClipDuration = .milliseconds(20)
        let controller = makeReadyController(settings: settings)
        hotkey.send(.press)
        try await waitUntil { engine.received.count == 1 }
        #expect(!recorder.isRecording)
        #expect(controller.status == .ready(cleanMode: true))
    }

    @Test func engineFailingMidRecordingReportsErrorOnRelease() async {
        engine.result = .failure(TranscriptionError.notRunning)
        let controller = makeReadyController()
        var messages: [String] = []
        controller.onMessage = { messages.append($0) }
        hotkey.send(.press)
        engine.emit(.failed("Helper stopped (status 1)"))
        #expect(controller.status == .listening)  // the mic stays visibly open until release

        await controller.finishRecording()?.value
        #expect(messages == ["Error: Transcription helper isn't running"])
        #expect(controller.status == .failed("Helper stopped (status 1)"))
    }

    @Test func stopClosesMicAndStopsEngine() {
        let controller = makeReadyController()
        hotkey.send(.press)
        controller.stop()
        #expect(!recorder.isRecording)
        #expect(engine.stopCount == 1)
    }
}
