import CoreAudio

/// Lists the Mac's audio output devices and switches the default output (like Sound settings).
enum AudioOutputs {
    static func all() -> [AudioOutput] {
        deviceIDs().compactMap { device in
            guard hasOutputStreams(device), !isHidden(device),
                  let uid = string(device, kAudioDevicePropertyDeviceUID),
                  let name = string(device, kAudioObjectPropertyName)
            else { return nil }
            return AudioOutput(id: uid, name: name, kind: kind(device))
        }
    }

    static func currentID() -> String? {
        defaultOutputDevice().flatMap { string($0, kAudioDevicePropertyDeviceUID) }
    }

    @discardableResult
    static func select(id: String) -> Bool {
        guard var device = deviceIDs().first(where: { string($0, kAudioDevicePropertyDeviceUID) == id }) else { return false }
        var address = globalAddress(kAudioHardwarePropertyDefaultOutputDevice)
        let status = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                                UInt32(MemoryLayout<AudioDeviceID>.size), &device)
        return status == noErr
    }

    // MARK: - CoreAudio helpers

    private static func deviceIDs() -> [AudioDeviceID] {
        var address = globalAddress(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func defaultOutputDevice() -> AudioDeviceID? {
        var address = globalAddress(kAudioHardwarePropertyDefaultOutputDevice)
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }

    private static func hasOutputStreams(_ device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                 mScope: kAudioDevicePropertyScopeOutput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func isHidden(_ device: AudioDeviceID) -> Bool {
        uint32(device, kAudioDevicePropertyIsHidden) == 1
    }

    private static func kind(_ device: AudioDeviceID) -> AudioOutput.Kind {
        switch uint32(device, kAudioDevicePropertyTransportType) {
        case kAudioDeviceTransportTypeBuiltIn: .builtIn
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: .bluetooth
        case kAudioDeviceTransportTypeAirPlay: .airPlay
        case kAudioDeviceTransportTypeUSB: .usb
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: .display
        default: .other
        }
    }

    private static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = globalAddress(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private static func uint32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = globalAddress(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private static func globalAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }
}
