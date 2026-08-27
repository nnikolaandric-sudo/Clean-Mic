import Foundation
import CoreAudio
import AVFoundation

public struct AudioDevice: Identifiable, CustomStringConvertible {
    public let id: AudioDeviceID
    public let name: String
    public let uid: String?
    public let isDefaultInput: Bool
    public let sampleRate: Double
    public let channelCount: UInt32
    public let isAlive: Bool

    public var description: String {
        let def = isDefaultInput ? " [DEFAULT]" : ""
        let alive = isAlive ? "" : " (offline)"
        return "\(name) — id:\(id) \(channelCount)ch @\(Int(sampleRate))Hz\(def)\(alive) uid:\(uid ?? "-")"
    }
}

public enum DeviceLister {
    public static func listInputDevices() -> [AudioDevice] {
        var devices: [AudioDevice] = []
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &dataSize)
        guard status == noErr else { return [] }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &dataSize, &deviceIDs)
        guard status == noErr else { return [] }

        let defaultID = defaultInputDeviceID()

        for deviceID in deviceIDs {
            guard isInputDevice(deviceID) else { continue }
            let name = deviceName(deviceID) ?? "Unknown \(deviceID)"
            let uid = deviceUID(deviceID)
            let sr = nominalSampleRate(deviceID) ?? 0
            let ch = inputChannelCount(deviceID) ?? 0
            let alive = deviceIsAlive(deviceID)
            let isDefault = deviceID == defaultID
            devices.append(AudioDevice(
                id: deviceID,
                name: name,
                uid: uid,
                isDefaultInput: isDefault,
                sampleRate: sr,
                channelCount: ch,
                isAlive: alive
            ))
        }
        // sort default first, then alive first, then name
        devices.sort { a, b in
            if a.isDefaultInput != b.isDefaultInput { return a.isDefaultInput }
            if a.isAlive != b.isAlive { return a.isAlive }
            return a.name < b.name
        }
        return devices
    }

    public static func defaultInputDeviceID() -> AudioDeviceID {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID)
        return status == noErr ? deviceID : 0
    }

    public static func deviceName(_ id: AudioDeviceID) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: Unmanaged<CFString>? = nil
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &name)
        guard status == noErr, let cf = name?.takeUnretainedValue() else { return nil }
        return cf as String
    }

    public static func deviceUID(_ id: AudioDeviceID) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: Unmanaged<CFString>? = nil
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &uid)
        guard status == noErr, let cf = uid?.takeUnretainedValue() else { return nil }
        return cf as String
    }

    public static func nominalSampleRate(_ id: AudioDeviceID) -> Double? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var rate = 0.0
        var size = UInt32(MemoryLayout<Double>.size)
        let status = AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &rate)
        return status == noErr ? rate : nil
    }

    public static func inputChannelCount(_ id: AudioDeviceID) -> UInt32? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size)
        guard status == noErr else { return nil }
        let bufferList = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: Int(size))
        defer { bufferList.deallocate() }
        status = AudioObjectGetPropertyData(id, &addr, 0, nil, &size, bufferList)
        guard status == noErr else { return nil }
        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        var count: UInt32 = 0
        for b in buffers { count += b.mNumberChannels }
        return count
    }

    public static func deviceIsAlive(_ id: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var alive: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &alive)
        return status == noErr ? alive != 0 : true
    }

    public static func isInputDevice(_ id: AudioDeviceID) -> Bool {
        guard let ch = inputChannelCount(id) else { return false }
        return ch > 0
    }

    // AVFoundation alternative for permission check
    public static func checkMicrophonePermission() -> String {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return "authorized"
        case .notDetermined: return "notDetermined"
        case .denied: return "denied"
        case .restricted: return "restricted"
        @unknown default: return "unknown"
        }
    }

    public static func requestMicrophonePermission(completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            completion(granted)
        }
    }
}
