import CoreAudio
import Foundation

/// Hardware output volume of one device, in dB.
/// Uses the main element if it has a volume control, otherwise the channels.
struct VolumeControl {
    enum Kind: String { case decibels, scalar }

    let device: AudioObjectID
    let elements: [AudioObjectPropertyElement]
    let kind: Kind

    init?(device: AudioObjectID) {
        self.device = device
        let scope = kAudioDevicePropertyScopeOutput
        for (kind, selector) in [(Kind.decibels, kAudioDevicePropertyVolumeDecibels), (Kind.scalar, kAudioDevicePropertyVolumeScalar)] {
            if kind == .scalar {
                // Scalar is only usable if the device can convert to and from dB.
                guard hasProperty(device, address(kAudioDevicePropertyVolumeScalarToDecibels, scope, kAudioObjectPropertyElementMain))
                        || hasProperty(device, address(kAudioDevicePropertyVolumeScalarToDecibels, scope, 1)) else { continue }
            }
            let main = address(selector, scope, kAudioObjectPropertyElementMain)
            if hasProperty(device, main) && isSettable(device, main) {
                self.elements = [kAudioObjectPropertyElementMain]
                self.kind = kind
                return
            }
            let channels: [AudioObjectPropertyElement] = [1, 2].filter {
                let a = address(selector, scope, $0)
                return hasProperty(device, a) && isSettable(device, a)
            }
            if !channels.isEmpty {
                self.elements = channels
                self.kind = kind
                return
            }
        }
        return nil
    }

    private var conversionElement: AudioObjectPropertyElement { elements[0] }

    var range: ClosedRange<Float> {
        var value = AudioValueRange(mMinimum: -96, mMaximum: 0)
        value = readValue(device, address(kAudioDevicePropertyVolumeRangeDecibels, kAudioDevicePropertyScopeOutput, conversionElement), default: value)
        let low = Float(value.mMinimum), high = Float(value.mMaximum)
        return low < high ? low...high : -96...0
    }

    var decibels: Float {
        let values = elements.map { element -> Float in
            switch kind {
            case .decibels:
                return readValue(device, address(kAudioDevicePropertyVolumeDecibels, kAudioDevicePropertyScopeOutput, element), default: Float32(0))
            case .scalar:
                let scalar = readValue(device, address(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeOutput, element), default: Float32(0))
                return convert(scalar, kAudioDevicePropertyVolumeScalarToDecibels)
            }
        }
        return values.reduce(0, +) / Float(values.count)
    }

    func set(decibels db: Float) {
        let clamped = min(max(db, range.lowerBound), range.upperBound)
        for element in elements {
            switch kind {
            case .decibels:
                writeValue(device, address(kAudioDevicePropertyVolumeDecibels, kAudioDevicePropertyScopeOutput, element), Float32(clamped))
            case .scalar:
                let scalar = convert(clamped, kAudioDevicePropertyVolumeDecibelsToScalar)
                writeValue(device, address(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeOutput, element), Float32(scalar))
            }
        }
    }

    private func convert(_ value: Float, _ selector: AudioObjectPropertySelector) -> Float {
        var a = address(selector, kAudioDevicePropertyScopeOutput, conversionElement)
        var v = Float32(value)
        var size = UInt32(MemoryLayout<Float32>.size)
        AudioObjectGetPropertyData(device, &a, 0, nil, &size, &v)
        return v
    }
}

/// Owns every hardware volume change Livella makes.
///
/// While a call is up macOS lowers everything except the call by a fixed amount.
/// Livella raises the device volume by that amount and **must** take it back the
/// moment the call ends, or the next sound plays far too loud. So:
///  * the raise is recorded on disk *before* it is applied, and a launch after a
///    crash takes it back;
///  * the restore subtracts what was added from the *current* volume, so volume
///    keys pressed during the call are kept;
///  * it is thread-safe, because the call-ended path runs off the main thread.
final class VolumeGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var control: VolumeControl?
    private var deviceUIDValue: String?
    private(set) var appliedDB: Float = 0

    private static var stateFile: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Livella", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("volume-raise.json")
    }

    private struct Saved: Codable { let deviceUID: String; let appliedDB: Float }

    /// How far the hardware volume can still go up on the attached device.
    var headroomDB: Float {
        lock.lock(); defer { lock.unlock() }
        guard let control else { return 0 }
        return max(0, control.range.upperBound - control.decibels)
    }

    var canControl: Bool {
        lock.lock(); defer { lock.unlock() }
        return control != nil
    }

    /// After a restore no raise is allowed until the next `attach`, so a late
    /// timer tick cannot push the volume back up once the call has ended.
    private var frozen = true

    func attach(device: AudioObjectID) {
        lock.lock(); defer { lock.unlock() }
        if appliedDB > 0, let control { control.set(decibels: control.decibels - appliedDB) }
        appliedDB = 0
        control = VolumeControl(device: device)
        deviceUIDValue = deviceUID(device)
        frozen = false
    }

    /// Sets the total raise to `wantedDB` (≥ 0). Returns the raise actually applied.
    @discardableResult
    func setRaise(_ wantedDB: Float) -> Float {
        lock.lock(); defer { lock.unlock() }
        guard !frozen, let control, let uid = deviceUIDValue else { return 0 }
        let current = control.decibels
        let base = current - appliedDB
        let target = min(base + max(0, wantedDB), control.range.upperBound)
        let newRaise = max(0, target - base)
        guard abs(newRaise - appliedDB) >= 0.5 else { return appliedDB }

        if newRaise > appliedDB { Self.save(Saved(deviceUID: uid, appliedDB: newRaise)) }
        control.set(decibels: base + newRaise)
        appliedDB = max(0, control.decibels - base)
        if appliedDB < 0.5 {
            appliedDB = 0
            Self.clearSaved()
        } else {
            Self.save(Saved(deviceUID: uid, appliedDB: appliedDB))
        }
        return appliedDB
    }

    /// Takes back whatever was added. Safe to call any number of times.
    func restore() {
        lock.lock(); defer { lock.unlock() }
        frozen = true
        if appliedDB > 0, let control {
            control.set(decibels: control.decibels - appliedDB)
            Log.write(String(format: "volume restored (-%.1f dB)", appliedDB))
        }
        appliedDB = 0
        Self.clearSaved()
    }

    func detach() {
        restore()
        lock.lock(); defer { lock.unlock() }
        control = nil
        deviceUIDValue = nil
    }

    /// Called at launch: undo a raise left behind by a crash.
    static func recoverAfterCrash() {
        guard let data = try? Data(contentsOf: stateFile),
              let saved = try? JSONDecoder().decode(Saved.self, from: data) else { return }
        defer { clearSaved() }
        guard let device = allDevices().first(where: { deviceUID($0) == saved.deviceUID }),
              let control = VolumeControl(device: device) else { return }
        control.set(decibels: control.decibels - saved.appliedDB)
        Log.write(String(format: "crash recovery: volume lowered by %.1f dB on %@", saved.appliedDB, deviceName(device)))
    }

    private static func save(_ saved: Saved) {
        if let data = try? JSONEncoder().encode(saved) { try? data.write(to: stateFile, options: .atomic) }
    }

    private static func clearSaved() {
        try? FileManager.default.removeItem(at: stateFile)
    }
}
