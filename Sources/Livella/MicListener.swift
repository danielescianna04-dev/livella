import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation

/// Tells whether *you* are speaking, from the level of the system microphone.
///
/// Only measures loudness: nothing is recorded, stored or sent. It runs only
/// during a call, when the call app already has the microphone open, so it never
/// changes the microphone's state itself (on AirPods, opening the mic outside a
/// call would switch them to headset mode).
///
/// The threshold follows the room: a slow noise-floor tracker learns the
/// background level, and speech has to rise clearly above it.
final class MicListener: @unchecked Sendable {
    /// 1 while you are speaking (with a short hold), else 0. Read by the render thread.
    let speaking = SharedFloat(0)
    let levelDB = SharedFloat(-200)
    let noiseFloor = SharedFloat(-60)
    let speechLevel = SharedFloat(-200)

    private var unit: AudioUnit?
    private var buffer: UnsafeMutablePointer<Float>
    private let maxFrames = 8192
    private var sampleRate: Double = 48000
    fileprivate var bufferList = AudioBufferList()

    // Input-thread state
    private var gate = SpeechGate(sampleRate: 48000)
    private var seedKey: String?

    init() {
        buffer = .allocate(capacity: maxFrames)
        buffer.initialize(repeating: 0, count: maxFrames)
    }

    deinit {
        stop()
        buffer.deallocate()
    }

    static var permission: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .audio) }

    static func requestPermission(_ done: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { ok in DispatchQueue.main.async { done(ok) } }
    }

    func start(device: AudioObjectID) throws {
        stop()
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw CAError(what: "AudioComponentFindNext(mic)", status: -1)
        }
        var instance: AudioUnit?
        try check("AudioComponentInstanceNew(mic)", AudioComponentInstanceNew(component, &instance))
        guard let instance else { throw CAError(what: "mic unit", status: -1) }
        unit = instance

        do {
            var on: UInt32 = 1, off: UInt32 = 0
            try check("mic EnableIO input", AudioUnitSetProperty(instance, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &on, 4))
            try check("mic EnableIO output", AudioUnitSetProperty(instance, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &off, 4))
            var dev = device
            try check("mic CurrentDevice", AudioUnitSetProperty(instance, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                                                &dev, UInt32(MemoryLayout<AudioObjectID>.size)))
            // Device format on the hardware side tells us the sample rate.
            var hw = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            AudioUnitGetProperty(instance, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &hw, &size)
            sampleRate = hw.mSampleRate > 0 ? hw.mSampleRate : 48000
            // Start from the speech level learned on this microphone in earlier
            // calls. A Bluetooth headset mic sits near the mouth, so until one is
            // learned assume about −35 dB: its unsteady background is far below.
            let key = "speechLevel." + (deviceUID(device) ?? "unknown")
            let stored = UserDefaults.standard.object(forKey: key) as? Double
            let seed: Float = stored.map { Float($0) } ?? (isBluetooth(device) ? -35 : -200)
            seedKey = key
            gate = SpeechGate(sampleRate: sampleRate, speechLevelDB: seed)

            var mono = AudioStreamBasicDescription(
                mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
                mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
                mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
            try check("mic StreamFormat", AudioUnitSetProperty(instance, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1,
                                                               &mono, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)))
            var callback = AURenderCallbackStruct(inputProc: micInputProc, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
            try check("mic InputCallback", AudioUnitSetProperty(instance, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0,
                                                                &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)))
            try check("mic Initialize", AudioUnitInitialize(instance))
            try check("mic Start", AudioOutputUnitStart(instance))
            Log.write("mic listener on \(deviceName(device)) at \(Int(sampleRate)) Hz")
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        speaking.value = 0
        levelDB.value = -200
        guard let unit else { return }
        AudioOutputUnitStop(unit)
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
        self.unit = nil
        if let seedKey, gate.speechLevelDB > -150 {
            UserDefaults.standard.set(Double(gate.speechLevelDB), forKey: seedKey)
        }
    }

    // MARK: Input thread

    fileprivate func pull(_ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                          _ timestamp: UnsafePointer<AudioTimeStamp>, _ frames: UInt32) -> OSStatus {
        guard let unit else { return noErr }
        let n = min(Int(frames), maxFrames)
        bufferList.mNumberBuffers = 1
        bufferList.mBuffers = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(n * 4), mData: buffer)
        let status = AudioUnitRender(unit, flags, timestamp, 1, UInt32(n), &bufferList)
        guard status == noErr else { return status }
        analyse(frames: n)
        return noErr
    }

    private func analyse(frames n: Int) {
        gate.process(buffer, count: n)
        levelDB.value = gate.levelDB
        noiseFloor.value = gate.noiseFloorDB
        speechLevel.value = gate.speechLevelDB
        speaking.value = gate.isOpen ? 1 : 0
    }
}

private let micInputProc: AURenderCallback = { refCon, flags, timestamp, _, frames, _ in
    Unmanaged<MicListener>.fromOpaque(refCon).takeUnretainedValue().pull(flags, timestamp, frames)
}
