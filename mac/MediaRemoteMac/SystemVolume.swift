import CoreAudio
import AudioToolbox

/// Reads and writes the volume of the current default output device via CoreAudio.
/// Some devices (HDMI, certain USB DACs) expose no software volume; the getters return nil then.
enum SystemVolume {
    static let step: Float = 1.0 / 16.0 // same granularity as the volume keys

    static var volume: Float? {
        guard let device = defaultOutputDevice() else { return nil }
        var address = volumeAddress
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
        return status == noErr ? value : nil
    }

    static var isMuted: Bool? {
        guard let device = defaultOutputDevice() else { return nil }
        var address = muteAddress
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
        return status == noErr ? value != 0 : nil
    }

    @discardableResult
    static func setVolume(_ newValue: Float) -> Bool {
        guard let device = defaultOutputDevice() else { return false }
        var address = volumeAddress
        guard isSettable(device, &address) else { return false }
        var value = Float32(min(max(newValue, 0), 1))
        let status = AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
        if status == noErr, value > 0, isMuted == true {
            setMuted(false)
        }
        return status == noErr
    }

    @discardableResult
    static func setMuted(_ muted: Bool) -> Bool {
        guard let device = defaultOutputDevice() else { return false }
        var address = muteAddress
        guard isSettable(device, &address) else { return false }
        var value = UInt32(muted ? 1 : 0)
        let status = AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
        return status == noErr
    }

    private static var volumeAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )

    private static var muteAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )

    private static func isSettable(_ device: AudioDeviceID, _ address: inout AudioObjectPropertyAddress) -> Bool {
        guard AudioObjectHasProperty(device, &address) else { return false }
        var settable = DarwinBoolean(false)
        return AudioObjectIsPropertySettable(device, &address, &settable) == noErr && settable.boolValue
    }

    private static func defaultOutputDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }
}
