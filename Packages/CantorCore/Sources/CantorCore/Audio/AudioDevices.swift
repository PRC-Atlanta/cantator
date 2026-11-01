import CoreAudio
import Foundation

public struct AudioOutputDevice: Identifiable, Equatable, Sendable {
    public var id: String { uid }
    public var deviceID: AudioDeviceID
    public var uid: String
    public var name: String
    public var outputChannels: Int
    public var sampleRate: Double
}

public enum AudioDevices {
    public static func outputDevices() -> [AudioOutputDevice] {
        allDeviceIDs().compactMap { device(for: $0) }.filter { $0.outputChannels > 0 }
    }

    public static func device(uid: String) -> AudioOutputDevice? {
        outputDevices().first { $0.uid == uid }
    }

    /// Asks Core Audio directly instead of walking every device, so it is cheap to poll.
    public static func deviceID(uid: String) -> AudioDeviceID? {
        var address = propertyAddress(kAudioHardwarePropertyTranslateUIDToDevice)
        var cfUID = uid as CFString
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafePointer(to: &cfUID) {
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<CFString>.size), $0, &size, &id
            )
        }
        return status == noErr && id != kAudioObjectUnknown ? id : nil
    }

    public static func isAlive(uid: String) -> Bool {
        guard let id = deviceID(uid: uid) else { return false }
        var alive: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = propertyAddress(kAudioDevicePropertyDeviceIsAlive)
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &alive)
        return status == noErr && alive != 0
    }

    public static func defaultDeviceUID(system: Bool) -> String? {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = propertyAddress(system ? kAudioHardwarePropertyDefaultSystemOutputDevice : kAudioHardwarePropertyDefaultOutputDevice)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        guard status == noErr else { return nil }
        return stringProperty(id, kAudioDevicePropertyDeviceUID)
    }

    @discardableResult
    public static func setDefaultDevice(uid: String, system: Bool) -> Bool {
        guard var id = deviceID(uid: uid) else { return false }
        var address = propertyAddress(system ? kAudioHardwarePropertyDefaultSystemOutputDevice : kAudioHardwarePropertyDefaultOutputDevice)
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, size, &id) == noErr
    }

    /// Calls `handler` on the main queue when devices come or go or macOS changes its default
    /// outputs. Returns a cancel closure.
    public static func observeDeviceChanges(_ handler: @escaping @Sendable () -> Void) -> () -> Void {
        let selectors = [
            kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice,
            kAudioHardwarePropertyDefaultSystemOutputDevice,
        ]
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        for selector in selectors {
            var address = propertyAddress(selector)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
        }
        return {
            for selector in selectors {
                var address = propertyAddress(selector)
                AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
            }
        }
    }

    private static func propertyAddress(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var address = propertyAddress(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func device(for id: AudioDeviceID) -> AudioOutputDevice? {
        guard let uid = stringProperty(id, kAudioDevicePropertyDeviceUID) else { return nil }
        let name = stringProperty(id, kAudioObjectPropertyName) ?? uid
        return AudioOutputDevice(deviceID: id, uid: uid, name: name, outputChannels: outputChannelCount(id), sampleRate: nominalRate(id))
    }

    private static func stringProperty(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = propertyAddress(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private static func outputChannelCount(_ id: AudioDeviceID) -> Int {
        var address = propertyAddress(kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeOutput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func nominalRate(_ id: AudioDeviceID) -> Double {
        var address = propertyAddress(kAudioDevicePropertyNominalSampleRate)
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        AudioObjectGetPropertyData(id, &address, 0, nil, &size, &rate)
        return rate
    }
}
