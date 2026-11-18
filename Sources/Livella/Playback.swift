import AudioToolbox
import CoreAudio
import Foundation

/// Output-only audio unit on one device.
///
/// Input is explicitly disabled: on AirPods any open input stream switches them
/// to headset mode.
final class Playback {
    typealias Render = (_ left: UnsafeMutablePointer<Float>, _ right: UnsafeMutablePointer<Float>, _ frames: Int) -> Void

    private var unit: AudioUnit?
    fileprivate let render: Render

    init(device: AudioObjectID, sampleRate: Double, render: @escaping Render) throws {
        self.render = render
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw CAError(what: "AudioComponentFindNext(HALOutput)", status: -1)
        }
        var instance: AudioUnit?
        try check("AudioComponentInstanceNew", AudioComponentInstanceNew(component, &instance))
        guard let instance else { throw CAError(what: "AudioComponentInstanceNew", status: -1) }
        unit = instance

        do {
            var off: UInt32 = 0, on: UInt32 = 1
            try check("EnableIO input=0", AudioUnitSetProperty(instance, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &off, 4))
            try check("EnableIO output=1", AudioUnitSetProperty(instance, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &on, 4))
            var dev = device
            try check("CurrentDevice", AudioUnitSetProperty(instance, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                                            &dev, UInt32(MemoryLayout<AudioObjectID>.size)))
            var format = AudioStreamBasicDescription(
                mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
                mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
                mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
            try check("StreamFormat", AudioUnitSetProperty(instance, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0,
                                                           &format, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)))
            var maxFrames: UInt32 = 4096
            AudioUnitSetProperty(instance, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFrames, 4)
            var callback = AURenderCallbackStruct(inputProc: playbackRenderProc,
                                                  inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
            try check("SetRenderCallback", AudioUnitSetProperty(instance, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0,
                                                                &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)))
            try check("AudioUnitInitialize", AudioUnitInitialize(instance))
        } catch {
            AudioComponentInstanceDispose(instance)
            unit = nil
            throw error
        }
    }

    func start() throws {
        guard let unit else { return }
        try check("AudioOutputUnitStart", AudioOutputUnitStart(unit))
    }

    func stop() {
        guard let unit else { return }
        AudioOutputUnitStop(unit)
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
        self.unit = nil
    }

    deinit { stop() }
}

private let playbackRenderProc: AURenderCallback = { refCon, _, _, _, frameCount, ioData in
    guard let ioData else { return noErr }
    let playback = Unmanaged<Playback>.fromOpaque(refCon).takeUnretainedValue()
    let buffers = UnsafeMutableAudioBufferListPointer(ioData)
    guard buffers.count >= 2,
          let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
          let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) else {
        for b in buffers { if let d = b.mData { memset(d, 0, Int(b.mDataByteSize)) } }
        return noErr
    }
    playback.render(left, right, Int(frameCount))
    return noErr
}
