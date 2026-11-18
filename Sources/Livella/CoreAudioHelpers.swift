import AudioToolbox
import CoreAudio
import Darwin
import Foundation

// Small, dependency-free helpers around the Core Audio HAL property API.

let systemObject = AudioObjectID(kAudioObjectSystemObject)

func address(_ selector: AudioObjectPropertySelector,
             _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
             _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
}

struct CAError: Error, CustomStringConvertible {
    let what: String
    let status: OSStatus
    var description: String { "\(what) failed (\(fourCC(status)))" }
}

func check(_ what: String, _ status: OSStatus) throws {
    if status != noErr { throw CAError(what: what, status: status) }
}

func fourCC(_ status: OSStatus) -> String {
    let n = UInt32(bitPattern: status)
    let bytes = [24, 16, 8, 0].map { UInt8((n >> UInt32($0)) & 0xFF) }
    if bytes.allSatisfy({ $0 >= 32 && $0 < 127 }) {
        return "'" + String(decoding: bytes, as: UTF8.self) + "'"
    }
    return String(status)
}

func hasProperty(_ object: AudioObjectID, _ addr: AudioObjectPropertyAddress) -> Bool {
    var a = addr
    return AudioObjectHasProperty(object, &a)
}

func isSettable(_ object: AudioObjectID, _ addr: AudioObjectPropertyAddress) -> Bool {
    var a = addr
    var settable: DarwinBoolean = false
    return AudioObjectIsPropertySettable(object, &a, &settable) == noErr && settable.boolValue
}

func readValue<T>(_ object: AudioObjectID, _ addr: AudioObjectPropertyAddress, default value: T) -> T {
    var a = addr
    var result = value
    var size = UInt32(MemoryLayout<T>.size)
    let status = withUnsafeMutablePointer(to: &result) {
        AudioObjectGetPropertyData(object, &a, 0, nil, &size, $0)
    }
    return status == noErr ? result : value
}

@discardableResult
func writeValue<T>(_ object: AudioObjectID, _ addr: AudioObjectPropertyAddress, _ value: T) -> OSStatus {
    var a = addr
    var v = value
    let size = UInt32(MemoryLayout<T>.size)
    return withUnsafeMutablePointer(to: &v) {
        AudioObjectSetPropertyData(object, &a, 0, nil, size, $0)
    }
}

func readObjectList(_ object: AudioObjectID, _ addr: AudioObjectPropertyAddress) -> [AudioObjectID] {
    var a = addr
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(object, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
    var list = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(object, &a, 0, nil, &size, &list) == noErr else { return [] }
    return Array(list.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
}

func readString(_ object: AudioObjectID, _ addr: AudioObjectPropertyAddress) -> String? {
    var a = addr
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    var value: Unmanaged<CFString>?
    let status = withUnsafeMutablePointer(to: &value) {
        AudioObjectGetPropertyData(object, &a, 0, nil, &size, $0)
    }
    guard status == noErr, let value else { return nil }
    return value.takeRetainedValue() as String
}

// MARK: - Devices

func defaultOutputDevice() -> AudioObjectID? {
    let id = readValue(systemObject, address(kAudioHardwarePropertyDefaultOutputDevice), default: AudioObjectID(kAudioObjectUnknown))
    return id == kAudioObjectUnknown ? nil : id
}

func defaultInputDevice() -> AudioObjectID? {
    let id = readValue(systemObject, address(kAudioHardwarePropertyDefaultInputDevice), default: AudioObjectID(kAudioObjectUnknown))
    return id == kAudioObjectUnknown ? nil : id
}

func allDevices() -> [AudioObjectID] {
    readObjectList(systemObject, address(kAudioHardwarePropertyDevices))
}

func deviceUID(_ device: AudioObjectID) -> String? {
    readString(device, address(kAudioDevicePropertyDeviceUID))
}

func deviceName(_ device: AudioObjectID) -> String {
    readString(device, address(kAudioObjectPropertyName)) ?? "Dispositivo \(device)"
}

func transportType(_ device: AudioObjectID) -> UInt32 {
    readValue(device, address(kAudioDevicePropertyTransportType), default: UInt32(0))
}

func isBluetooth(_ device: AudioObjectID) -> Bool {
    let t = transportType(device)
    return t == kAudioDeviceTransportTypeBluetooth || t == kAudioDeviceTransportTypeBluetoothLE
}

func streamCount(_ device: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
    readObjectList(device, address(kAudioDevicePropertyStreams, scope)).count
}

/// The Mac's own microphone, if there is one.
func builtInInputDevice() -> AudioObjectID? {
    allDevices().first {
        transportType($0) == kAudioDeviceTransportTypeBuiltIn && streamCount($0, scope: kAudioObjectPropertyScopeInput) > 0
    }
}

// MARK: - Processes

struct AudioProcess: Equatable {
    let object: AudioObjectID
    let pid: pid_t
    let bundleID: String?
    let name: String
    let runningInput: Bool
    let runningOutput: Bool

    /// Groups helper processes with their app: "us.zoom.xos.callservice" and
    /// "us.zoom.xos" share "us.zoom.xos"; "com.google.Chrome.helper" joins "com.google.Chrome".
    var family: String {
        guard let bundleID, !bundleID.isEmpty else { return "pid:\(pid)" }
        return bundleID.split(separator: ".").prefix(3).joined(separator: ".")
    }

    var displayName: String {
        if let app = NSRunningApplicationName(pid: pid) { return app }
        return name
    }
}

func processName(_ pid: pid_t) -> String {
    var buffer = [CChar](repeating: 0, count: 256)
    let n = proc_name(pid, &buffer, UInt32(buffer.count))
    return n > 0 ? String(cString: buffer) : "pid \(pid)"
}

func audioProcesses() -> [AudioProcess] {
    readObjectList(systemObject, address(kAudioHardwarePropertyProcessObjectList)).map { object in
        let pid = readValue(object, address(kAudioProcessPropertyPID), default: pid_t(-1))
        return AudioProcess(
            object: object,
            pid: pid,
            bundleID: readString(object, address(kAudioProcessPropertyBundleID)),
            name: processName(pid),
            runningInput: readValue(object, address(kAudioProcessPropertyIsRunningInput), default: UInt32(0)) != 0,
            runningOutput: readValue(object, address(kAudioProcessPropertyIsRunningOutput), default: UInt32(0)) != 0
        )
    }
}

func processObject(forPID pid: pid_t) -> AudioObjectID? {
    var a = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
    var qualifier = pid
    var object = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    let status = AudioObjectGetPropertyData(systemObject, &a, UInt32(MemoryLayout<pid_t>.size), &qualifier, &size, &object)
    return status == noErr && object != kAudioObjectUnknown ? object : nil
}

func isRunningInput(_ object: AudioObjectID) -> Bool {
    readValue(object, address(kAudioProcessPropertyIsRunningInput), default: UInt32(0)) != 0
}

// MARK: - dB

@inline(__always) func dbToGain(_ db: Float) -> Float { powf(10, db / 20) }
@inline(__always) func energyToDB(_ meanSquare: Double) -> Double {
    meanSquare <= 1e-20 ? -200 : 10 * log10(meanSquare)
}
