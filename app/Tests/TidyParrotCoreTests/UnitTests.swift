import Foundation
import Testing

@testable import TidyParrotCore

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
            HelperProtocol.Message.ready(loadMilliseconds: 512, cleanMode: true)
        ),
        (#"{"text": "Hi there.", "ms": 61}"#, .transcript(Transcript(text: "Hi there.", milliseconds: 61))),
        (#"{"error": "model not found"}"#, .error("model not found")),
        (#"{"text": ""}"#, .transcript(Transcript(text: "", milliseconds: 0))),
    ])
    func decodesMessages(line: String, expected: HelperProtocol.Message) {
        #expect(HelperProtocol.decode(line) == expected)
    }

    @Test func errorWinsOverOtherFields() {
        #expect(HelperProtocol.decode(#"{"text": "x", "error": "bad"}"#) == .error("bad"))
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
        let (symbol, text) = AppStatus.ready(cleanMode: true).presentation(hotkey: .function)
        #expect(symbol == "bird")
        #expect(text == "Ready: tap fn to dictate (clean mode)")
        #expect(!AppStatus.ready(cleanMode: false).presentation(hotkey: .function).text.contains("clean"))
    }

    @Test func listeningExplainsHowToStopAndCancel() {
        let text = AppStatus.listening.presentation(hotkey: .function).text
        #expect(text == "Listening… tap fn to insert, Esc to cancel")
    }

    @Test func failureShowsReason() {
        #expect(AppStatus.failed("Helper stopped").presentation(hotkey: .function).text == "Helper stopped")
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
