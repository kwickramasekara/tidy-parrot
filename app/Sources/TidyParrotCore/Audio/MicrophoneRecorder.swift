import CoreAudio
import Synchronization

/// Each call takes its turn the moment it's made, and calls run in that order, so a `stop` or `cancel` never overtakes
/// an earlier `start`, and a later `cancel` never overtakes a `stop`. Results come back on the main actor. These are
/// completion handlers rather than `async` on purpose: an `async` call made from a new `Task` would take its turn
/// only when that task ran, after anything handled in between.
@MainActor
protocol AudioRecording: AnyObject {
    /// Opens the mic in the background ahead of a likely tap, unless the input is Bluetooth or unknown. Errors are
    /// left for `start` to report.
    func warmUp()
    /// Opens the mic, or waits for an earlier call to, then waits until it hears real audio (`MicrophoneReadiness`).
    /// `opened` gets when each part of that happened. It never comes if the mic stays silent: the caller decides how
    /// long to wait, and a `cancel` drops it.
    func start(_ opened: @escaping @MainActor @Sendable (Result<MicrophoneStart, any Error>) -> Void)
    /// Stops recording. `stopped` gets the clip, already converted to `AudioClip.sampleRate`.
    func stop(_ stopped: @escaping @MainActor @Sendable (AudioClip) -> Void)
    /// Closes the mic and forgets what it heard.
    func cancel()
}

/// When each part of starting the mic happened, for the `start:` log.
struct MicrophoneStart: Sendable {
    /// Building began: at fn key-down for a warm-up, otherwise after the tap.
    var opened: ContinuousClock.Instant
    var built: ContinuousClock.Instant
    /// The start call returned.
    var running: ContinuousClock.Instant
    var firstBuffer: ContinuousClock.Instant
    /// `MicrophoneReadiness` heard real audio.
    var ready: ContinuousClock.Instant
}

/// Records from the current default input only around a dictation: from fn key-down, if the press turns out to be a
/// tap, until the next tap. A fresh input unit per recording means device changes between dictations (a Teams call
/// switching mics, AirPods connecting) never touch a long-lived unit, and the mic is closed the rest of the time.
@MainActor
final class MicrophoneRecorder: AudioRecording {
    private let session = MicrophoneSession()

    /// The next input level, from 0 to 1, for the on-screen meter. See `LevelMeter.take()`.
    func takeLevel() -> Float {
        session.meter.take()
    }

    func warmUp() {
        session.run { session in
            guard let device = AudioInputTransport.defaultInputDevice(),
                AudioInputTransport.allowsWarmUp(transportType: AudioInputTransport.transportType(of: device))
            else { return }
            // A failure here repeats when the tap calls `start`, which reports it.
            try? session.warmUp(device)
        }
    }

    func start(_ opened: @escaping @MainActor @Sendable (Result<MicrophoneStart, any Error>) -> Void) {
        session.run { session in
            do {
                try session.start(whenReady: { start in Task { @MainActor in opened(.success(start)) } })
            } catch {
                Task { @MainActor in opened(.failure(error)) }
            }
        }
    }

    func stop(_ stopped: @escaping @MainActor @Sendable (AudioClip) -> Void) {
        session.run { session in
            let clip = session.close()
            Task { @MainActor in stopped(clip) }
        }
    }

    func cancel() {
        session.run { $0.discard() }
    }
}

/// The input unit and what it hears. Opening a mic blocks for up to half a second, so all unit work runs on `queue`,
/// off the main actor, one call at a time.
private final class MicrophoneSession: @unchecked Sendable {
    // Safety: `unit` and `startup` are used only on `queue`; `buffer`, `meter`, `gate` and `InputUnit` are Sendable.
    let meter = LevelMeter()
    private let buffer = SampleBuffer()
    private let gate = ReadinessGate()
    private var unit: InputUnit?
    /// When the open unit was built and started.
    private var startup: Startup?
    private struct Startup {
        var opened, built, running: ContinuousClock.Instant
    }
    private let queue = DispatchQueue(label: "tidyparrot.microphone")

    func run(_ work: @escaping @Sendable (MicrophoneSession) -> Void) {
        queue.async { [self] in work(self) }
    }

    /// Opens `device` ahead of a likely tap, unless a mic is already open.
    func warmUp(_ device: AudioDeviceID) throws {
        guard startup == nil else { return }
        try openUnit(device)
    }

    /// Opens the default input unless a mic is already open. `whenReady` gets when each part of the start happened
    /// once the mic hears real audio: on the audio thread, or on this queue if it already has.
    func start(whenReady: @escaping @Sendable (MicrophoneStart) -> Void) throws {
        let startup = try startup ?? openUnit(nil)
        gate.whenReady { firstBuffer, ready in
            whenReady(
                MicrophoneStart(
                    opened: startup.opened, built: startup.built, running: startup.running, firstBuffer: firstBuffer,
                    ready: ready))
        }
    }

    @discardableResult
    private func openUnit(_ device: AudioDeviceID?) throws -> Startup {
        guard let device = device ?? AudioInputTransport.defaultInputDevice() else { throw RecorderError.noInput }
        let opened = ContinuousClock.now
        let unit = try InputUnit(device: device, onSamples: Self.samples(into: buffer, meter: meter, gate: gate))
        buffer.reset()
        meter.reset(sampleRate: unit.sampleRate)
        gate.reset()
        let built = ContinuousClock.now
        do {
            try unit.start()
        } catch {
            unit.dispose()
            throw error
        }
        self.unit = unit
        let startup = Startup(opened: opened, built: built, running: .now)
        self.startup = startup
        return startup
    }

    /// Closes the mic and returns what it recorded, or an empty clip if it wasn't open.
    func close() -> AudioClip {
        guard let sampleRate = closeUnit() else { return AudioClip(samples: []) }
        return AudioClip(samples: Resampler.resample(buffer.drain(), from: sampleRate))
    }

    func discard() {
        closeUnit()
        buffer.reset()
    }

    /// Returns the closed unit's sample rate, or nil if none was open.
    @discardableResult
    private func closeUnit() -> Double? {
        guard let unit else { return nil }
        unit.dispose()
        self.unit = nil
        startup = nil
        gate.reset()
        return unit.sampleRate
    }

    /// Built outside any actor: the unit calls it on the audio thread, and a closure formed in an actor-isolated
    /// method would inherit that isolation and trap when Core Audio calls it.
    private static func samples(
        into buffer: SampleBuffer, meter: LevelMeter, gate: ReadinessGate
    ) -> @Sendable (UnsafeBufferPointer<Float>) -> Void {
        { chunk in
            buffer.append(chunk)
            meter.record(chunk)
            gate.observe(chunk)
        }
    }
}

/// Samples shared between the audio thread (appending) and the recorder's queue (draining).
final class SampleBuffer: Sendable {
    private let samples = Mutex<[Float]>([])

    func append(_ chunk: UnsafeBufferPointer<Float>) {
        samples.withLock { $0.append(contentsOf: chunk) }
    }

    func reset() {
        samples.withLock { $0.removeAll(keepingCapacity: true) }
    }

    func drain() -> [Float] {
        samples.withLock { current in
            defer { current.removeAll(keepingCapacity: true) }
            return current
        }
    }
}

enum RecorderError: LocalizedError {
    case noInput
    /// A Core Audio call failed while setting up the mic. `step` says which, in words.
    case coreAudio(step: String, status: OSStatus)

    var errorDescription: String? {
        switch self {
        case .noInput: "No microphone input available"
        case .coreAudio(let step, let status): "Couldn't \(step) (Core Audio error \(status))"
        }
    }
}
