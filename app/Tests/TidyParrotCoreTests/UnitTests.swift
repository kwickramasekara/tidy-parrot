import AppKit
import CoreAudio
import Foundation
import Synchronization
import Testing

@testable import TidyParrotCore

struct FocusedInputTests {
    @Test(arguments: ["AXTextField", "AXTextArea", "AXComboBox"])
    func textRolesMayTakeText(role: String) {
        #expect(AccessibilityFocusedInput.mayTakeText(role: role))
    }

    /// Electron, web pages and Alacritty report these while you're editing, so they mustn't refuse.
    @Test(arguments: ["AXWindow", "AXGroup", "AXWebArea", "AXScrollArea", "AXTable", "AXUnknown", "SomeCustomRole"])
    func containersAndUnknownRolesMayTakeText(role: String) {
        #expect(AccessibilityFocusedInput.mayTakeText(role: role))
    }

    @Test func noAnswerMayTakeText() {
        #expect(AccessibilityFocusedInput.mayTakeText(role: nil))
    }

    @Test(arguments: AccessibilityFocusedInput.nonTextRoles.sorted())
    func controlsCannotTakeText(role: String) {
        #expect(!AccessibilityFocusedInput.mayTakeText(role: role))
    }
}

struct HelperProtocolTests {
    @Test func frameIsLittleEndianLengthThenFloat32Samples() {
        let data = HelperProtocol.frame(AudioClip(samples: [1.0, -0.5]))
        #expect(data.count == 4 + 8)
        #expect(Array(data.prefix(4)) == [8, 0, 0, 0])
        let samples = data.dropFirst(4).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        #expect(samples == [1.0, -0.5])
    }

    @Test func emptyClipFramesAsZeroLength() {
        #expect(Array(HelperProtocol.frame(AudioClip(samples: []))) == [0, 0, 0, 0])
    }

    @Test(arguments: [
        (
            #"{"ready": true, "load_ms": 512, "clean_mode": true}"#,
            HelperProtocol.Message.ready(loadMilliseconds: 512, cleanMode: true, vocabulary: nil)
        ),
        (
            #"{"text": "Hi there.", "ms": 61}"#,
            .transcript(Transcript(text: "Hi there.", milliseconds: 61), vocabulary: nil)
        ),
        (#"{"error": "model not found"}"#, .error("model not found")),
        (#"{"text": ""}"#, .transcript(Transcript(text: "", milliseconds: 0), vocabulary: nil)),
        (
            #"{"ready": true, "load_ms": 5, "clean_mode": true, "vocabulary": {"terms": 0, "loaded_at": null, "error": null}}"#,
            .ready(
                loadMilliseconds: 5, cleanMode: true,
                vocabulary: VocabularyStatus(terms: 0, loadedAt: nil, problem: nil))
        ),
        (
            #"{"text": "Hi.", "ms": 9, "vocabulary": {"terms": 154, "loaded_at": 1000.5, "error": "line 3 has no letters or digits"}}"#,
            .transcript(
                Transcript(text: "Hi.", milliseconds: 9),
                vocabulary: VocabularyStatus(
                    terms: 154, loadedAt: Date(timeIntervalSince1970: 1000.5),
                    problem: "line 3 has no letters or digits"))
        ),
    ])
    func decodesMessages(line: String, expected: HelperProtocol.Message) {
        #expect(HelperProtocol.decode(line) == expected)
    }

    @Test func errorWinsOverOtherFields() {
        #expect(HelperProtocol.decode(#"{"text": "x", "error": "bad"}"#) == .error("bad"))
    }

    @Test func malformedVocabularyRejectsTheLine() {
        // A missing "terms" is a protocol bug; better an unreadable reply than a made-up count.
        #expect(HelperProtocol.decode(#"{"text": "x", "vocabulary": {"loaded_at": 1}}"#) == nil)
    }

    @Test(arguments: ["", "not json", "[1, 2]", "{}", #"{"ms": 5}"#])
    func rejectsGarbage(line: String) {
        #expect(HelperProtocol.decode(line) == nil)
    }
}

struct TapToToggleDetectorTests {
    enum Input: Sendable {
        case fnDown, fnUp
        case flags(keyCode: UInt16, modifierFlags: UInt)
        case key(UInt16)
    }

    static let fnFlag: UInt = 0x80_0000
    static let escape: UInt16 = 53

    /// Each row feeds a key sequence to a fresh detector and lists the event expected after each input.
    @Test(
        arguments: [
            // A press begins on key-down and a plain tap toggles on release; a repeated flags event does nothing.
            ([.fnDown, .fnDown, .fnUp, .fnUp], [.pressBegan, nil, .toggle, nil]),
            // Every later tap begins and toggles again.
            ([.fnDown, .fnUp, .fnDown, .fnUp], [.pressBegan, .toggle, .pressBegan, .toggle]),
            // fn+← is a shortcut, not a tap: abandoned at the arrow, and it doesn't spoil the next tap.
            ([.fnDown, .key(123), .fnUp, .fnDown, .fnUp], [.pressBegan, .pressAbandoned, nil, .pressBegan, .toggle]),
            // A held arrow repeats, but the press is abandoned only once.
            (
                [.fnDown, .key(123), .key(123), .key(123), .key(123), .key(123), .fnUp],
                [.pressBegan, .pressAbandoned, nil, nil, nil, nil, nil]
            ),
            // Left ⌘ pressed and released while fn is held.
            (
                [
                    .fnDown, .flags(keyCode: 55, modifierFlags: fnFlag | 0x10_0008),
                    .flags(keyCode: 55, modifierFlags: fnFlag), .fnUp,
                ],
                [.pressBegan, .pressAbandoned, nil, nil]
            ),
            // Right ⌥, the old hotkey, does nothing.
            ([.flags(keyCode: 61, modifierFlags: 0x8_0040), .flags(keyCode: 61, modifierFlags: 0)], [nil, nil]),
            // Esc cancels; other keys don't.
            ([.key(escape), .key(0)], [.cancel, nil]),
            // fn+Esc is a shortcut, not a cancel: it abandons the press.
            ([.fnDown, .key(escape), .fnUp], [.pressBegan, .pressAbandoned, nil]),
        ] as [([Input], [HotkeyEvent?])])
    func detects(inputs: [Input], expected: [HotkeyEvent?]) {
        var detector = TapToToggleDetector(key: .function)
        let events = inputs.map { input in
            switch input {
            case .fnDown: detector.flagsChanged(keyCode: 63, modifierFlags: Self.fnFlag)
            case .fnUp: detector.flagsChanged(keyCode: 63, modifierFlags: 0)
            case .flags(let keyCode, let flags): detector.flagsChanged(keyCode: keyCode, modifierFlags: flags)
            case .key(let keyCode): detector.keyDown(keyCode: keyCode)
            }
        }
        #expect(events == expected)
    }
}

struct AudioInputTransportTests {
    @Test(arguments: [
        (kAudioDeviceTransportTypeBuiltIn, true),
        (kAudioDeviceTransportTypeUSB, true),
        (kAudioDeviceTransportTypeDisplayPort, true),
        (kAudioDeviceTransportTypeBluetooth, false),
        (kAudioDeviceTransportTypeBluetoothLE, false),
    ])
    func warmsUpOnlyNonBluetoothInputs(transportType: UInt32, allowed: Bool) {
        #expect(AudioInputTransport.allowsWarmUp(transportType: transportType) == allowed)
    }

    @Test func unknownInputIsNotWarmedUp() {
        #expect(!AudioInputTransport.allowsWarmUp(transportType: nil))
    }
}

struct ResamplerTests {
    @Test func sameRateIsUnchanged() {
        let input: [Float] = [0.1, 0.2, 0.3]
        #expect(Resampler.resample(input, from: 16_000) == input)
    }

    @Test func emptyStaysEmpty() {
        #expect(Resampler.resample([], from: 48_000).isEmpty)
    }

    @Test func downsamples48kToAboutAThird() {
        let input = (0..<48_000).map { Float(sin(Double($0) * 2 * .pi * 440 / 48_000)) }
        let output = Resampler.resample(input, from: 48_000)
        #expect(abs(output.count - 16_000) <= 16)
    }
}

struct HelperConfigurationTests {
    @Test func readsHelperKeys() {
        let info: [String: Any] = [
            "TPHelperPython": "/py", "TPHelperScript": "/helper.py", "TPHelperArguments": ["--verbatim"],
        ]
        #expect(
            HelperProcessEngine.Configuration(infoDictionary: info)
                == .init(python: "/py", script: "/helper.py", arguments: ["--verbatim"]))
    }

    @Test func argumentsAreOptional() {
        let info: [String: Any] = ["TPHelperPython": "/py", "TPHelperScript": "/helper.py"]
        #expect(HelperProcessEngine.Configuration(infoDictionary: info)?.arguments == [])
    }

    @Test func missingPathsGiveNil() {
        #expect(HelperProcessEngine.Configuration(infoDictionary: ["TPHelperPython": "/py"]) == nil)
    }
}

struct AppStatusTests {
    @Test func readyMentionsHotkeyAndCleanMode() {
        #expect(
            AppStatus.ready(cleanMode: true).presentation(hotkey: .function).text
                == "Ready: tap fn to dictate (clean mode)")
        #expect(!AppStatus.ready(cleanMode: false).presentation(hotkey: .function).text.contains("clean"))
    }

    @Test func listeningExplainsHowToStopAndCancel() {
        let text = AppStatus.listening.presentation(hotkey: .function).text
        #expect(text == "Listening… tap fn to insert, Esc to cancel")
    }

    @Test(arguments: [
        (AppStatus.needsAccessibility, true),
        (.failed("Helper stopped"), true),
        (.starting, false),
        (.listening, false),
        (.transcribing, false),
        (.loading, false),
        (.unloaded, false),
        (.ready(cleanMode: true), false),
        (.ready(cleanMode: false), false),
        (.vocabularyProblem("line 3 has no letters or digits"), true),
    ])
    func onlyProblemsNeedAttention(status: AppStatus, needsAttention: Bool) {
        #expect(status.presentation(hotkey: .function).needsAttention == needsAttention)
    }

    @Test func vocabularyProblemSaysTheFileWasntApplied() {
        #expect(
            AppStatus.vocabularyProblem("line 3 has no letters or digits").presentation(hotkey: .function).text
                == "Vocabulary file not applied: line 3 has no letters or digits")
    }

    @Test func failureShowsReason() {
        #expect(AppStatus.failed("Helper stopped").presentation(hotkey: .function).text == "Helper stopped")
    }
}

struct DiagnosticsTests {
    @Test func readyShowsLoadTimeLastDictationAndPermissions() {
        let diagnostics = Diagnostics(
            engine: .ready(cleanMode: true, loadMilliseconds: 2140),
            lastTiming: .init(audioDuration: 1.26, milliseconds: 76),
            isMicrophoneAuthorized: true, isAccessibilityTrusted: true)
        #expect(
            diagnostics.lines == [
                "Helper: ready",
                "Model load: 2140 ms",
                "Last dictation: 1.3s of audio in 76 ms",
                "Microphone: allowed",
                "Accessibility: allowed",
            ])
    }

    @Test(arguments: [
        (VocabularyStatus(terms: 0, loadedAt: nil, problem: nil), ["Vocabulary: loading…"]),
        (VocabularyStatus(terms: 0, loadedAt: Date(), problem: nil), ["Vocabulary: off (file empty or missing)"]),
        (
            VocabularyStatus(terms: 2, loadedAt: nil, problem: "line 3 has no letters or digits"),
            ["Vocabulary: loading…", "Vocabulary file not applied: line 3 has no letters or digits"]
        ),
    ])
    func vocabularyLinesSitBeforePermissions(vocabulary: VocabularyStatus, expected: [String]) {
        let diagnostics = Diagnostics(
            engine: .ready(cleanMode: true, loadMilliseconds: 1), lastTiming: nil, vocabulary: vocabulary,
            isMicrophoneAuthorized: true, isAccessibilityTrusted: true)
        #expect(Array(diagnostics.lines.dropFirst(3).dropLast(2)) == expected)
    }

    @Test func loadedVocabularyShowsCountAndTime() {
        let loadedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let diagnostics = Diagnostics(
            engine: .ready(cleanMode: true, loadMilliseconds: 1), lastTiming: nil,
            vocabulary: VocabularyStatus(terms: 154, loadedAt: loadedAt, problem: nil),
            isMicrophoneAuthorized: true, isAccessibilityTrusted: true)
        #expect(
            diagnostics.lines.contains(
                "Vocabulary: 154 terms, loaded \(loadedAt.formatted(date: .omitted, time: .standard))"))
    }

    /// Load time comes from the helper's ready message, so there's nothing to show before or without one.
    @Test(arguments: [
        (EngineState.loading, "Helper: loading model…"),
        (.unloaded, "Helper: unloaded (loads when you dictate)"),
        (.failed("Helper stopped (status 1)"), "Helper: failed (Helper stopped (status 1))"),
    ])
    func notReadyShowsOnlyTheHelperState(engine: EngineState, helperLine: String) {
        let diagnostics = Diagnostics(
            engine: engine, lastTiming: nil, isMicrophoneAuthorized: false, isAccessibilityTrusted: false)
        #expect(
            diagnostics.lines == [
                helperLine,
                "Last dictation: none yet",
                "Microphone: not allowed",
                "Accessibility: not allowed",
            ])
    }
}

@MainActor
struct UnavailableEngineTests {
    @Test func reportsFailureOnStart() async {
        let engine = UnavailableEngine(reason: "no config")
        var states: [EngineState] = []
        engine.onStateChange = { states.append($0) }
        engine.start()
        #expect(states == [.failed("no config")])
        await #expect(throws: TranscriptionError.notRunning) {
            try await engine.transcribe(AudioClip(samples: []))
        }
    }
}

struct AudioLevelTests {
    func rms(atDecibels decibels: Float) -> Float { pow(10, decibels / 20) }

    @Test(arguments: [Float(0), -1, .nan])
    func silenceOrBrokenInputIsZero(rms: Float) {
        #expect(AudioLevel.normalized(rms: rms) == 0)
    }

    @Test func belowFloorIsZeroAndAboveCeilingIsOne() {
        #expect(AudioLevel.normalized(rms: rms(atDecibels: -70)) == 0)
        #expect(AudioLevel.normalized(rms: 1) == 1)
    }

    @Test func scalesLinearlyInDecibelsBetweenFloorAndCeiling() {
        let floor = AudioLevel.floorDecibels
        let ceiling = AudioLevel.ceilingDecibels
        #expect(abs(AudioLevel.normalized(rms: rms(atDecibels: floor + 0.01))) < 0.01)
        #expect(abs(AudioLevel.normalized(rms: rms(atDecibels: (floor + ceiling) / 2)) - 0.5) < 0.01)
        #expect(abs(AudioLevel.normalized(rms: rms(atDecibels: ceiling - 0.01)) - 1) < 0.01)
    }
}

struct MicrophoneReadinessTests {
    static let loud: Float = 0.01
    static let silent: Float = 0

    /// Which buffer, counting from 1, made the mic ready, or nil if none did.
    func readyAt(_ peaks: [Float]) -> Int? {
        var readiness = MicrophoneReadiness()
        let transitions = peaks.indices.filter { readiness.observe(peak: peaks[$0]) }
        #expect(transitions.count <= 1)
        return transitions.first.map { $0 + 1 }
    }

    @Test(arguments: [
        ([loud, loud, loud], 3),
        ([silent, silent, loud, loud, loud, loud], 5),
        // A Bluetooth headset sends stray samples before its link is up: a gap starts the count again.
        ([loud, silent, loud, loud, silent, loud, loud, loud], 8),
        ([loud, loud, loud, loud, loud], 3),
    ])
    func readyAfterThreeLoudBuffersInARow(peaks: [Float], buffer: Int) {
        #expect(readyAt(peaks) == buffer)
    }

    @Test(arguments: [
        [loud, loud],
        [loud, silent, loud, silent, loud],
        // Below the threshold: digital silence with rounding noise, not a mic.
        [Float](repeating: 0.000_001, count: 10),
        [Float](repeating: .nan, count: 10),
        [Float](repeating: silent, count: 300),
    ])
    func neverReadyWithoutRealAudio(peaks: [Float]) {
        #expect(readyAt(peaks) == nil)
    }
}

@MainActor
struct StartLogTests {
    /// Milliseconds after an arbitrary origin, so each row reads as a timeline.
    nonisolated static let origin = ContinuousClock.now
    nonisolated static func at(_ milliseconds: Int) -> ContinuousClock.Instant { origin + .milliseconds(milliseconds) }

    nonisolated static func start(opened: Int, built: Int, running: Int, firstBuffer: Int, ready: Int)
        -> MicrophoneStart
    {
        MicrophoneStart(
            opened: at(opened), built: at(built), running: at(running), firstBuffer: at(firstBuffer), ready: at(ready))
    }

    @Test(arguments: [
        // Warmed on fn key-down: the mic opened before the tap's key-up.
        (
            start(opened: 5, built: 15, running: 45, firstBuffer: 95, ready: 125), Optional(0), 100, 130,
            "start: key-down → chime 130 ms, key-up → chime 30 ms"
                + " (warm; build 10 ms, start 30 ms, first buffer +50 ms, ready +30 ms)"
        ),
        // Bluetooth skips the warm-up: key-down is known, but the mic opened after the tap.
        (
            start(opened: 102, built: 110, running: 140, firstBuffer: 160, ready: 1_260), 0, 100, 1_265,
            "start: key-down → chime 1265 ms, key-up → chime 1165 ms"
                + " (cold; build 8 ms, start 30 ms, first buffer +20 ms, ready +1100 ms)"
        ),
        // No key-down seen: nothing to measure from but the tap.
        (
            start(opened: 102, built: 110, running: 140, firstBuffer: 160, ready: 200), nil, 100, 205,
            "start: key-up → chime 105 ms (cold; build 8 ms, start 30 ms, first buffer +20 ms, ready +40 ms)"
        ),
    ])
    func saysWhereTheTimeWent(
        start: MicrophoneStart, pressed: Int?, released: Int, chime: Int, expected: String
    ) {
        let log = DictationController.startLog(
            start, pressedAt: pressed.map(Self.at), releasedAt: Self.at(released), chimeAt: Self.at(chime))
        #expect(log == expected)
    }
}

struct ReadinessGateTests {
    /// Counts the waiter's calls, which may come from any thread.
    final class Calls: Sendable {
        private let times = Mutex<[(ContinuousClock.Instant, ContinuousClock.Instant)]>([])
        var count: Int { times.withLock { $0.count } }
        var first: (ContinuousClock.Instant, ContinuousClock.Instant)? { times.withLock { $0.first } }
        func record(_ firstBuffer: ContinuousClock.Instant, _ ready: ContinuousClock.Instant) {
            times.withLock { $0.append((firstBuffer, ready)) }
        }
    }

    func send(_ peak: Float, to gate: ReadinessGate, buffers: Int = 1) {
        let samples = [Float](repeating: peak, count: 160)
        for _ in 0..<buffers { samples.withUnsafeBufferPointer { gate.observe($0) } }
    }

    /// A mic warmed up on fn key-down is usually ready before the tap asks.
    @Test func waiterAfterReadyIsAnsweredAtOnce() {
        let gate = ReadinessGate()
        let calls = Calls()
        send(0, to: gate)
        send(0.01, to: gate, buffers: 3)
        gate.whenReady { calls.record($0, $1) }
        #expect(calls.count == 1)
        if let (firstBuffer, ready) = calls.first { #expect(firstBuffer < ready) }
    }

    @Test func waiterBeforeReadyIsAnsweredOnceWhenReady() {
        let gate = ReadinessGate()
        let calls = Calls()
        gate.whenReady { calls.record($0, $1) }
        send(0, to: gate, buffers: 5)
        send(0.01, to: gate, buffers: 2)
        #expect(calls.count == 0)
        send(0.01, to: gate, buffers: 5)
        #expect(calls.count == 1)
    }

    /// Closing the mic drops the waiter, so a later unit's audio can't answer a discarded start.
    @Test func resetForgetsTheWaiterAndTheReadiness() {
        let gate = ReadinessGate()
        let calls = Calls()
        send(0.01, to: gate, buffers: 3)
        gate.reset()
        gate.whenReady { calls.record($0, $1) }
        #expect(calls.count == 0)
        gate.reset()
        send(0.01, to: gate, buffers: 3)
        #expect(calls.count == 0)
    }
}

struct LevelMeterTests {
    /// At 1 kHz a 50 ms window is 50 samples, which keeps the arithmetic readable.
    let window = 50
    /// Constant amplitudes whose levels are 100% and 50%.
    let loud: Float = 1
    let medium = Float(pow(10, -32.5 / 20))

    func makeMeter() -> LevelMeter {
        let meter = LevelMeter()
        meter.reset(sampleRate: 1_000)
        return meter
    }

    /// One buffer made of one full window per amplitude.
    func windows(_ amplitudes: [Float]) -> [Float] {
        amplitudes.flatMap { [Float](repeating: $0, count: window) }
    }

    func record(_ meter: LevelMeter, _ samples: [Float]) {
        samples.withUnsafeBufferPointer { meter.record($0) }
    }

    /// Rounded to whole percent, so levels compare exactly.
    func percent(_ level: Float) -> Float { (level * 100).rounded() }

    /// The bug this guards against: the mic delivers ~100 ms buffers, the bars read every 50 ms, and every other
    /// read used to find nothing new and show silence.
    @Test func bufferSpanningTwoWindowsGivesTwoLevelsAndThenHoldsTheLast() {
        let meter = makeMeter()
        record(meter, windows([loud, medium]))
        #expect(percent(meter.take()) == 100)
        #expect(percent(meter.take()) == 50)
        #expect(percent(meter.take()) == 50)  // no new audio yet isn't silence
    }

    @Test func windowFilledAcrossSmallBuffersAveragesAllItsSamples() {
        let meter = makeMeter()
        record(meter, [Float](repeating: medium, count: 25))
        record(meter, [Float](repeating: 0, count: 20))
        #expect(meter.take() == 0)  // 45 of 50 samples: nothing complete yet
        record(meter, [Float](repeating: 0, count: 5))
        // Half the window at medium, half silent: 3 dB below medium (43%), not medium itself (50%).
        #expect(percent(meter.take()) == 43)
    }

    @Test func readerKeepingPaceLosesNothing() {
        let meter = makeMeter()
        var taken: [Float] = []
        for amplitudes: [Float] in [[0, medium], [loud, 0], [medium, loud]] {
            record(meter, windows(amplitudes))
            taken += [meter.take(), meter.take()]
        }
        #expect(taken.map(percent) == [0, 50, 100, 0, 50, 100])
    }

    @Test func largestDocumentedBufferKeepsEveryLevel() {
        let meter = makeMeter()
        let amplitudes: [Float] = [0, medium, loud, 0, medium, loud, 0, medium]  // 400 ms
        record(meter, windows(amplitudes))
        let taken = amplitudes.map { _ in meter.take() }
        #expect(taken.map(percent) == [0, 50, 100, 0, 50, 100, 0, 50])
    }

    /// After a main-thread stall the reader skips to the latest buffer instead of trailing the mic for the rest of
    /// the recording.
    @Test func readerThatFellBehindSkipsToTheLatestBuffer() {
        let meter = makeMeter()
        record(meter, windows([0, 0]))
        record(meter, windows([medium, medium]))
        record(meter, windows([loud, medium]))
        #expect(percent(meter.take()) == 100)
        #expect(percent(meter.take()) == 50)
    }

    /// Skipping ahead happens only when a buffer completes a window, so a small buffer can't discard a level the
    /// reader hasn't taken yet.
    @Test func bufferCompletingNoWindowKeepsWaitingLevels() {
        let meter = makeMeter()
        record(meter, windows([loud]))
        record(meter, [Float](repeating: 0, count: 20))
        #expect(percent(meter.take()) == 100)
    }

    @Test func resetClearsWaitingLevelsAndPartialWindow() {
        let meter = makeMeter()
        record(meter, [Float](repeating: loud, count: window + 30))
        meter.reset(sampleRate: 1_000)
        #expect(meter.take() == 0)
        record(meter, windows([0]))
        #expect(meter.take() == 0)  // the 30 loud samples didn't carry over into this window
    }
}

struct LevelBarsTests {
    let step = LevelBars.stepDuration

    @Test func startsAsAFlatRowOfDots() {
        let bars = LevelBars(count: 3)
        #expect(bars.levels == [0, 0, 0])
        #expect(bars.heights == [0, 0, 0])
        #expect(bars.scroll == 0)
    }

    @Test func newLevelEntersOnTheRightAsADotAndTheRestShiftLeft() {
        var bars = LevelBars(count: 3)
        for _ in 0..<60 { bars.advance(by: 1.0 / 60) { 0.5 } }
        let heights = bars.heights
        bars.push(0.75)
        #expect(bars.levels == [0.5, 0.5, 0.75])
        #expect(bars.heights == Array(heights.dropFirst()) + [0])
    }

    @Test func partOfAStepSlidesWithoutSampling() {
        var bars = LevelBars(count: 3)
        var samples = 0
        bars.advance(by: step * 0.4) {
            samples += 1
            return 1
        }
        #expect(samples == 0)
        #expect(abs(bars.scroll - 0.4) < 1e-9)
        #expect(bars.levels == [0, 0, 0])
    }

    @Test func eachCompletedStepSamplesOnceAndKeepsTheRemainder() {
        var bars = LevelBars(count: 3)
        var samples = 0
        bars.advance(by: step * 0.6) {
            samples += 1
            return 1
        }
        bars.advance(by: step * 0.6) {
            samples += 1
            return 1
        }
        #expect(samples == 1)
        #expect(abs(bars.scroll - 0.2) < 1e-9)
        #expect(bars.levels == [0, 0, 1])
    }

    @Test func heightGrowsSteadilyTowardItsLevelWithoutOvershooting() {
        var bars = LevelBars(count: 1)
        bars.push(0.8)
        var previous: Float = 0
        for _ in 0..<9 {  // nine tenths of a step, so no new bar replaces this one
            bars.advance(by: step / 10) { 0 }
            #expect(bars.heights[0] > previous)
            #expect(bars.heights[0] < 0.8)
            previous = bars.heights[0]
        }
    }

    @Test func barsSettleNearTheirLevelBeforeScrollingOut() {
        var bars = LevelBars(count: 16)
        for _ in 0..<120 { bars.advance(by: 1.0 / 60) { 0.5 } }
        // The oldest bar has had about 0.75 s to settle; the newest has only just started growing.
        #expect(abs(bars.heights[0] - 0.5) < 0.01)
        #expect(bars.heights[15] < bars.heights[14])
    }

    @Test func longStallIsCappedSoBarsDontLurch() {
        var bars = LevelBars(count: 4)
        var samples = 0
        bars.advance(by: 10) {
            samples += 1
            return 1
        }
        #expect(samples == Int(LevelBars.maximumFrameTime / step))
    }

    @Test func negativeFrameTimeChangesNothing() {
        var bars = LevelBars(count: 2)
        bars.push(1)
        let before = bars
        bars.advance(by: -1) { 1 }
        #expect(bars == before)
    }
}

@MainActor
struct RecordingIndicatorTests {
    @Test(arguments: [
        NSRect(x: 0, y: 0, width: 1512, height: 944),
        // A second display left of and above the main one has negative x and a non-zero y.
        NSRect(x: -1920, y: 200, width: 1920, height: 1055),
    ])
    func sitsAtTopCentreOfVisibleFrame(visibleFrame: NSRect) {
        let frame = RecordingIndicator.frame(in: visibleFrame)
        #expect(frame.size == RecordingIndicator.size)
        #expect(abs(frame.midX - visibleFrame.midX) <= 0.5)
        #expect(frame.maxY == visibleFrame.maxY - RecordingIndicator.topMargin)
        #expect(visibleFrame.contains(frame))
    }

    @Test(arguments: [
        (Duration.zero, "0:00"),
        (.milliseconds(9_900), "0:09"),  // rounds down, like a stopwatch
        (.seconds(65), "1:05"),
        (.seconds(180), "3:00"),
        (.seconds(-1), "0:00"),
    ])
    func elapsedTextIsMinutesAndPaddedSeconds(elapsed: Duration, expected: String) {
        #expect(RecordingIndicator.elapsedText(elapsed) == expected)
    }

    @Test(arguments: [
        (AppStatus.starting, RecordingIndicator.Mode.starting),
        (.listening, .listening),
        (.needsAccessibility, .hidden),
        (.transcribing, .hidden),
        (.loading, .hidden),
        (.unloaded, .hidden),
        (.ready(cleanMode: true), .hidden),
        (.vocabularyProblem("line 3"), .hidden),
        (.failed("Helper stopped"), .hidden),
    ])
    func pillShowsOnlyWhileTheMicIsInUse(status: AppStatus, mode: RecordingIndicator.Mode) {
        #expect(RecordingIndicator.Mode(status: status) == mode)
    }
}

/// Uses a view in no window, so nothing appears on screen and the display link never fires on its own.
@MainActor
struct LevelBarsViewTests {
    let view = LevelBarsView(barCount: 4)

    @Test func framesAdvanceTheBarsWhileRunning() {
        view.start { 1 }
        view.frame(at: 10)  // the first frame only sets the clock
        #expect(view.bars == LevelBars(count: 4))
        view.frame(at: 10 + LevelBars.stepDuration)
        #expect(view.bars.levels.last == 1)
    }

    @Test func stopEndsTheAnimationAndFlattensTheBars() {
        #expect(!view.isRunning)
        view.start { 1 }
        #expect(view.isRunning)
        view.frame(at: 0)
        view.frame(at: 0.05)
        view.stop()
        #expect(!view.isRunning)
        #expect(view.bars == LevelBars(count: 4))

        view.frame(at: 1)
        view.frame(at: 1.05)
        #expect(view.bars == LevelBars(count: 4))  // stopped: frames do nothing
    }

    @Test func restartDoesNotCountTheTimeSpentStopped() {
        view.start { 1 }
        view.frame(at: 0)
        view.stop()
        view.start { 1 }
        view.frame(at: 60)  // a minute later: must not be treated as one long frame
        #expect(view.bars == LevelBars(count: 4))
    }
}

struct VocabularyFileTests {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    var url: URL { folder.appendingPathComponent("vocabulary.txt") }

    @Test func createsAnEmptyFileWhenTheUserDeletedIt() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(VocabularyFile.prepareForEditing(at: url) == url)
        #expect(try Data(contentsOf: url).isEmpty)
    }

    @Test func leavesAnExistingFileAlone() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("React\n".utf8).write(to: url)
        #expect(VocabularyFile.prepareForEditing(at: url) == url)
        #expect(try String(contentsOf: url, encoding: .utf8) == "React\n")
    }

    /// Before the helper's first launch: creating the folder would stop it seeding the default list.
    @Test func createsNothingBeforeTheHelperHasSeeded() {
        #expect(VocabularyFile.prepareForEditing(at: url) == nil)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }
}
