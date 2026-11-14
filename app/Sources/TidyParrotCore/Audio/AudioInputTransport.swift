import CoreAudio

/// How the default input is connected, to keep warm-up away from Bluetooth headsets: opening their mic switches them
/// to the call profile, which degrades whatever they're playing, and an fn shortcut would do that for nothing.
enum AudioInputTransport {
    /// Unknown counts as Bluetooth, so a device Core Audio can't describe starts on the tap, as it always has.
    static func allowsWarmUp(transportType: UInt32?) -> Bool {
        guard let transportType else { return false }
        return transportType != kAudioDeviceTransportTypeBluetooth
            && transportType != kAudioDeviceTransportTypeBluetoothLE
    }

    /// The default input's transport type, or nil if Core Audio can't say. This is the device `AVAudioEngine`'s input
    /// node opens. `AudioHardwareSystem` would be simpler but needs macOS 26.
    static func defaultInputTransportType() -> UInt32? {
        guard
            let device = property(
                of: AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice),
            device != kAudioObjectUnknown
        else { return nil }
        return property(of: device, kAudioDevicePropertyTransportType)
    }

    /// Both properties read here are a `UInt32` (`AudioDeviceID` is one).
    private static func property(of object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }
}
