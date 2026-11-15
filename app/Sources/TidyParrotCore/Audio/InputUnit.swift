import AudioToolbox
import CoreAudio

/// An input-only AUHAL unit on one device. `AVAudioEngine`'s input node builds an aggregate of the default input and
/// output and starts both, which cost about 435 ms on the built-in mic with display speakers as the output, and it asks
/// a Bluetooth headset to change format, then waits up to 3 s when the headset ignores it. This starts only the mic.
final class InputUnit: @unchecked Sendable {
    // Safety: every stored property is set in `init` and never reassigned. `buffers` is written only in `render`,
    // which Core Audio calls on its I/O thread one cycle at a time, and freed in `dispose` once the I/O has stopped.
    // The owner calls `start` and `dispose` from one serial queue.
    let sampleRate: Double
    private let unit: AudioUnit
    private let buffers: UnsafeMutableAudioBufferListPointer
    private let onSamples: @Sendable (UnsafeBufferPointer<Float>) -> Void

    /// Builds and initializes the unit without starting it. `onSamples` gets the first channel of each buffer on the
    /// I/O thread, from `start` until `dispose`.
    init(device: AudioDeviceID, onSamples: @escaping @Sendable (UnsafeBufferPointer<Float>) -> Void) throws {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &description) else { throw RecorderError.noInput }
        var created: AudioUnit?
        try Self.check(AudioComponentInstanceNew(component, &created), "create the input unit")
        guard let unit = created else { throw RecorderError.noInput }

        let format: AudioStreamBasicDescription
        do {
            format = try Self.configure(unit, device: device)
        } catch {
            AudioComponentInstanceDispose(unit)
            throw error
        }
        self.unit = unit
        sampleRate = format.mSampleRate
        buffers = AudioBufferList.allocate(maximumBuffers: Int(format.mChannelsPerFrame))
        self.onSamples = onSamples

        do {
            // A C function can't capture anything, so the callback finds this unit through the context pointer.
            // `dispose` stops the I/O before its owner lets go of the unit.
            let callback = AURenderCallbackStruct(
                inputProc: { context, flags, timestamp, _, frames, _ in
                    Unmanaged<InputUnit>.fromOpaque(context).takeUnretainedValue()
                        .render(flags: flags, timestamp: timestamp, frames: frames)
                    return noErr
                }, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
            try Self.set(
                unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, callback,
                "set the input callback")
            try Self.check(AudioUnitInitialize(unit), "initialize the input unit")
        } catch {
            dispose()
            throw error
        }
    }

    func start() throws {
        try Self.check(AudioOutputUnitStart(unit), "start the microphone")
    }

    /// Stops the I/O and frees the unit. Call it once, whether or not `start` succeeded.
    func dispose() {
        AudioOutputUnitStop(unit)
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
        free(buffers.unsafeMutablePointer)
    }

    /// Input on element 1 only, from `device`, delivered as Float32 at the device's own rate: AUHAL converts the sample
    /// format but not the rate (TN2091), so `Resampler` still converts to 16 kHz. Returns the client format.
    private static func configure(_ unit: AudioUnit, device: AudioDeviceID) throws -> AudioStreamBasicDescription {
        try set(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, UInt32(1), "enable input")
        try set(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, UInt32(0), "disable output")
        try set(
            unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, device, "select the microphone")

        var deviceFormat = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(
            AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &deviceFormat, &size),
            "read the microphone format")
        guard deviceFormat.mSampleRate > 0, deviceFormat.mChannelsPerFrame > 0 else { throw RecorderError.noInput }

        let bytes = UInt32(MemoryLayout<Float>.size)
        let client = AudioStreamBasicDescription(
            mSampleRate: deviceFormat.mSampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: bytes, mFramesPerPacket: 1, mBytesPerFrame: bytes,
            mChannelsPerFrame: deviceFormat.mChannelsPerFrame, mBitsPerChannel: 32, mReserved: 0)
        try set(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, client, "set the recording format")
        return client
    }

    private func render(
        flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>, timestamp: UnsafePointer<AudioTimeStamp>,
        frames: UInt32
    ) {
        // Null data pointers ask the unit to lend its own buffers for this cycle, one per channel.
        for index in buffers.indices {
            buffers[index] = AudioBuffer(
                mNumberChannels: 1, mDataByteSize: frames * UInt32(MemoryLayout<Float>.size), mData: nil)
        }
        // A failed render (the device went away, or changed format mid-recording) loses this buffer only.
        guard AudioUnitRender(unit, flags, timestamp, 1, frames, buffers.unsafeMutablePointer) == noErr,
            let first = buffers.first, let data = first.mData
        else { return }
        // First channel only: speech is mono, and multi-channel interfaces put the mic on channel 1. The count comes
        // from what the unit filled, not from what was asked for.
        onSamples(
            UnsafeBufferPointer(
                start: data.assumingMemoryBound(to: Float.self),
                count: Int(first.mDataByteSize) / MemoryLayout<Float>.size))
    }

    private static func set<Value: BitwiseCopyable>(
        _ unit: AudioUnit, _ property: AudioUnitPropertyID, _ scope: AudioUnitScope, _ element: AudioUnitElement,
        _ value: Value, _ step: String
    ) throws {
        var value = value
        try check(
            AudioUnitSetProperty(unit, property, scope, element, &value, UInt32(MemoryLayout<Value>.size)), step)
    }

    private static func check(_ status: OSStatus, _ step: String) throws {
        guard status == noErr else { throw RecorderError.coreAudio(step: step, status: status) }
    }
}
