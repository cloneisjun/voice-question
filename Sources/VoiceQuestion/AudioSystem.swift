import CoreAudio
import Foundation

/// Core Audio lookups that need no permission: who is recording, and where sound comes out.
enum AudioSystem {

    struct AudioProcess {
        var pid: pid_t
        var bundleID: String
        var isRunningInput: Bool
    }

    /// Every process known to the audio system (macOS 14.2+), with whether it is capturing input.
    static func processes() -> [AudioProcess] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &objects) == noErr else { return [] }

        return objects.map { object in
            let pid: pid_t = value(object, kAudioProcessPropertyPID, default: 0)
            let running: UInt32 = value(object, kAudioProcessPropertyIsRunningInput, default: 0)
            return AudioProcess(pid: pid, bundleID: string(object, kAudioProcessPropertyBundleID) ?? "", isRunningInput: running != 0)
        }
    }

    /// Processes capturing the microphone right now, other than this one.
    static func recordingProcesses() -> [AudioProcess] {
        let me = getpid()
        return processes().filter { $0.isRunningInput && $0.pid != me }
    }

    /// True when the default output is something only the user hears (headphones), so the question
    /// can play while the microphone is already open without being dictated back.
    static func outputIsPrivate() -> Bool {
        let device: AudioObjectID = value(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, default: 0)
        guard device != 0 else { return false }
        let transport: UInt32 = value(device, kAudioDevicePropertyTransportType, default: 0)
        switch transport {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            return true
        case kAudioDeviceTransportTypeBuiltIn:
            // The headphone jack is either its own device or the built-in device's `hdpn` data source.
            let source: UInt32 = value(device, kAudioDevicePropertyDataSource, scope: kAudioDevicePropertyScopeOutput, default: 0)
            if source == fourCharCode("hdpn") { return true }
            return (outputName() ?? "").lowercased().contains("headphone")
        default:
            let name = (outputName() ?? "").lowercased()
            return ["headphone", "headset", "airpods", "earbuds", "earphone"].contains(where: name.contains)
        }
    }

    static func outputName() -> String? {
        let device: AudioObjectID = value(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, default: 0)
        return device == 0 ? nil : string(device, kAudioObjectPropertyName)
    }

    // MARK: - Property access

    private static func value<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                 scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, default fallback: T) -> T {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        var result = fallback
        let status = withUnsafeMutablePointer(to: &result) { AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0) }
        return status == noErr ? result : fallback
    }

    private static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var reference: Unmanaged<CFString>?
        let status = withUnsafeMutablePointer(to: &reference) { AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0) }
        guard status == noErr, let reference else { return nil }
        return reference.takeRetainedValue() as String
    }

    private static func fourCharCode(_ text: String) -> UInt32 {
        text.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }
}
