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

struct HoldToTalkDetectorTests {
    let key = ModifierKey.rightOption

    @Test func pressThenRelease() {
        var detector = HoldToTalkDetector(key: key)
        #expect(detector.flagsChanged(keyCode: 61, modifierFlags: 0x80040) == .press)
        #expect(detector.flagsChanged(keyCode: 61, modifierFlags: 0x80040) == nil)  // repeat while held
        #expect(detector.flagsChanged(keyCode: 61, modifierFlags: 0) == .release)
        #expect(detector.flagsChanged(keyCode: 61, modifierFlags: 0) == nil)
    }

    @Test func leftOptionIsIgnored() {
        var detector = HoldToTalkDetector(key: key)
        // Left ⌥ has key code 58 and device mask 0x20.
        #expect(detector.flagsChanged(keyCode: 58, modifierFlags: 0x80020) == nil)
        // Right ⌥ released while left ⌥ is still down: the right-side bit is clear, so it's a release.
        #expect(detector.flagsChanged(keyCode: 61, modifierFlags: 0x80060) == .press)
        #expect(detector.flagsChanged(keyCode: 61, modifierFlags: 0x80020) == .release)
    }

    @Test func otherKeyDuringHoldCancelsOnce() {
        var detector = HoldToTalkDetector(key: key)
        _ = detector.flagsChanged(keyCode: 61, modifierFlags: 0x80040)
        #expect(detector.keyDown() == .cancel)
        #expect(detector.keyDown() == nil)
        // The eventual key-up of ⌥ isn't a release, since the hold was cancelled.
        #expect(detector.flagsChanged(keyCode: 61, modifierFlags: 0) == nil)
    }

    @Test func keyDownWithoutHoldIsIgnored() {
        var detector = HoldToTalkDetector(key: key)
        #expect(detector.keyDown() == nil)
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
        let (symbol, text) = AppStatus.ready(cleanMode: true).presentation(hotkey: .rightOption)
        #expect(symbol == "bird")
        #expect(text == "Ready: hold Right ⌥ to dictate (clean mode)")
        #expect(!AppStatus.ready(cleanMode: false).presentation(hotkey: .rightOption).text.contains("clean"))
    }

    @Test func failureShowsReason() {
        #expect(AppStatus.failed("Helper stopped").presentation(hotkey: .rightOption).text == "Helper stopped")
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
