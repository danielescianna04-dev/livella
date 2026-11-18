import AudioToolbox
import CoreAudio
import Foundation

/// A Core Audio process tap plus the private, tap-only aggregate device needed
/// to read it.
///
/// The aggregate deliberately has **no sub-devices**. Including the output
/// device (as most examples do) would hand us its input streams too, and on
/// AirPods starting those opens the AirPods microphone, which drops them into
/// low-quality headset mode: the exact thing Livella exists to prevent.
final class TapCapture {
    enum Target {
        case processes([AudioObjectID])
        case everythingExcept([AudioObjectID])
    }

    let label: String
    private(set) var tapID = AudioObjectID(kAudioObjectUnknown)
    private(set) var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private(set) var format = AudioStreamBasicDescription()
    private var ioProcID: AudioDeviceIOProcID?
    private let queue: DispatchQueue
    private let scratch: UnsafeMutablePointer<Float>
    private let scratchFrames = 16384

    /// - Parameter muteSource: true mutes the tapped processes while Livella is
    ///   reading them ("muted when tapped"): if Livella stops or crashes, they are
    ///   audible again on their own.
    init(label: String, target: Target, muteSource: Bool) throws {
        self.label = label
        queue = DispatchQueue(label: "livella.tap.\(label)", qos: .userInteractive)
        scratch = .allocate(capacity: scratchFrames * 2)

        let description: CATapDescription
        switch target {
        case .processes(let ids): description = CATapDescription(stereoMixdownOfProcesses: ids)
        case .everythingExcept(let ids): description = CATapDescription(stereoGlobalTapButExcludeProcesses: ids)
        }
        description.name = "Livella \(label)"
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = muteSource ? .mutedWhenTapped : .unmuted

        do {
            try check("AudioHardwareCreateProcessTap(\(label))", AudioHardwareCreateProcessTap(description, &tapID))
            var addr = address(kAudioTapPropertyFormat)
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try check("kAudioTapPropertyFormat", AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &format))

            let aggregate: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Livella \(label)",
                kAudioAggregateDeviceUIDKey: "local.livella.\(label).\(UUID().uuidString)",
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceSubDeviceListKey: [[String: Any]](),
                kAudioAggregateDeviceTapListKey: [[
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: true,
                ]],
            ]
            try check("AudioHardwareCreateAggregateDevice(\(label))",
                      AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID))
        } catch {
            invalidate()
            throw error
        }
    }

    var sampleRate: Double { format.mSampleRate }

    /// `onFrames` runs on a realtime thread with interleaved stereo frames.
    func start(_ onFrames: @escaping (UnsafePointer<Float>, Int) -> Void) throws {
        let scratch = self.scratch
        let maxFrames = scratchFrames
        var procID: AudioDeviceIOProcID?
        try check("AudioDeviceCreateIOProcIDWithBlock(\(label))",
                  AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { _, input, _, _, _ in
                      let frames = interleaveStereo(input, into: scratch, maxFrames: maxFrames)
                      if frames > 0 { onFrames(scratch, frames) }
                  })
        ioProcID = procID
        try check("AudioDeviceStart(\(label))", AudioDeviceStart(aggregateID, procID))
    }

    func invalidate() {
        if let ioProcID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        ioProcID = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        // Destroying the tap is what un-mutes the tapped processes.
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    deinit {
        invalidate()
        scratch.deallocate()
    }
}
