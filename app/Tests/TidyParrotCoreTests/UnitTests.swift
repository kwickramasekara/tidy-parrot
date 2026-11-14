import AppKit
import Foundation
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
            // A plain tap toggles on release; a repeated flags event while held does nothing.
            ([.fnDown, .fnDown, .fnUp, .fnUp], [nil, nil, .toggle, nil]),
            // Every later tap toggles again.
            ([.fnDown, .fnUp, .fnDown, .fnUp], [nil, .toggle, nil, .toggle]),
            // fn+← is a shortcut, not a tap, and it doesn't spoil the next tap.
            ([.fnDown, .key(123), .fnUp, .fnDown, .fnUp], [nil, nil, nil, nil, .toggle]),
            // Left ⌘ pressed and released while fn is held.
            (
                [
                    .fnDown, .flags(keyCode: 55, modifierFlags: fnFlag | 0x10_0008),
                    .flags(keyCode: 55, modifierFlags: fnFlag), .fnUp,
                ],
                [nil, nil, nil, nil]
            ),
            // Right ⌥, the old hotkey, does nothing.
            ([.flags(keyCode: 61, modifierFlags: 0x8_0040), .flags(keyCode: 61, modifierFlags: 0)], [nil, nil]),
            // Esc cancels; other keys don't.
            ([.key(escape), .key(0)], [.cancel, nil]),
            // fn+Esc is a shortcut, not a cancel.
            ([.fnDown, .key(escape), .fnUp], [nil, nil, nil]),
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
        (.listening, false),
        (.transcribing, false),
        (.loading, false),
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
