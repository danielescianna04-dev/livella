import AppKit
import AudioToolbox
import CoreAudio
import Synchronization

func NSRunningApplicationName(pid: pid_t) -> String? {
    NSRunningApplication(processIdentifier: pid)?.localizedName
}

/// Single-producer / single-consumer ring of interleaved stereo Float32 frames.
/// The producer is a tap's IO thread, the consumer is the playback render thread.
/// No locks, no allocation after init.
final class StereoRing: @unchecked Sendable {
    private let capacity: Int          // frames, power of two
    private let mask: Int
    private let storage: UnsafeMutablePointer<Float>
    private let writeIndex = Atomic<Int>(0)
    private let readIndex = Atomic<Int>(0)
    private var primed = false   // consumer-only state

    init(capacityFrames: Int = 1 << 15) {
        var c = 1
        while c < capacityFrames { c <<= 1 }
        capacity = c
        mask = c - 1
        storage = .allocate(capacity: c * 2)
        storage.initialize(repeating: 0, count: c * 2)
    }

    deinit { storage.deallocate() }

    /// Producer side.
    func push(_ frames: UnsafePointer<Float>, count: Int) {
        let w = writeIndex.load(ordering: .relaxed)
        let r = readIndex.load(ordering: .acquiring)
        let free = capacity - (w - r)
        let n = min(count, free)
        guard n > 0 else { return }
        for i in 0..<n {
            let slot = ((w + i) & mask) * 2
            storage[slot] = frames[i * 2]
            storage[slot + 1] = frames[i * 2 + 1]
        }
        writeIndex.store(w + n, ordering: .releasing)
    }

    /// Consumer side. Fills `count` frames of `out`, padding with silence on underrun.
    /// If the buffer has drifted above `maxLatency` frames it skips ahead to
    /// `targetLatency`, which keeps added latency bounded when two clocks drift.
    func pop(into out: UnsafeMutablePointer<Float>, count: Int, targetLatency: Int, maxLatency: Int) {
        let w = writeIndex.load(ordering: .acquiring)
        var r = readIndex.load(ordering: .relaxed)
        if w - r > maxLatency + count { r = w - targetLatency - count }
        let available = w - r
        // After an underrun, wait until a little audio has built up again, so the
        // output does not alternate between one buffer of sound and one of silence.
        if !primed {
            if available < targetLatency + count {
                out.update(repeating: 0, count: count * 2)
                return
            }
            primed = true
        }
        if available < count { primed = false }
        let n = max(0, min(count, available))
        for i in 0..<n {
            let slot = ((r + i) & mask) * 2
            out[i * 2] = storage[slot]
            out[i * 2 + 1] = storage[slot + 1]
        }
        if n < count {
            (out + n * 2).update(repeating: 0, count: (count - n) * 2)
        }
        readIndex.store(r + n, ordering: .releasing)
    }

    func reset() {
        readIndex.store(writeIndex.load(ordering: .acquiring), ordering: .releasing)
    }
}

/// Energy accumulator a realtime thread can feed without locks.
/// Doubles are stored as bit patterns and added with a CAS loop.
final class EnergyMeter: @unchecked Sendable {
    private let sum = Atomic<UInt64>(0)
    private let frames = Atomic<Int>(0)

    func add(sumOfSquares: Double, frameCount: Int) {
        var old = sum.load(ordering: .relaxed)
        while true {
            let new = (Double(bitPattern: old) + sumOfSquares).bitPattern
            let (exchanged, current) = sum.compareExchange(expected: old, desired: new, ordering: .relaxed)
            if exchanged { break }
            old = current
        }
        frames.add(frameCount, ordering: .relaxed)
    }

    /// Returns (sum of squares, frames) since the last drain.
    func drain() -> (sum: Double, frames: Int) {
        let s = Double(bitPattern: sum.exchange(0, ordering: .relaxed))
        let f = frames.exchange(0, ordering: .relaxed)
        return (s, f)
    }
}

/// A Float the UI writes and the render thread reads.
final class SharedFloat: @unchecked Sendable {
    private let bits: Atomic<UInt32>
    init(_ value: Float) { bits = Atomic(value.bitPattern) }
    var value: Float {
        get { Float(bitPattern: bits.load(ordering: .relaxed)) }
        set { bits.store(newValue.bitPattern, ordering: .relaxed) }
    }
}

/// Copies whatever layout a tap delivers (interleaved stereo, mono, or
/// non-interleaved) into interleaved stereo. Returns the frame count.
/// Taps deliver Float32.
func interleaveStereo(_ list: UnsafePointer<AudioBufferList>, into out: UnsafeMutablePointer<Float>, maxFrames: Int) -> Int {
    let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
    guard let first = buffers.first, let firstData = first.mData else { return 0 }
    let firstChannels = max(1, Int(first.mNumberChannels))
    let frames = min(maxFrames, Int(first.mDataByteSize) / MemoryLayout<Float>.size / firstChannels)
    let a = firstData.assumingMemoryBound(to: Float.self)

    if firstChannels >= 2 {
        for i in 0..<frames {
            out[i * 2] = a[i * firstChannels]
            out[i * 2 + 1] = a[i * firstChannels + 1]
        }
    } else if buffers.count >= 2, let secondData = buffers[1].mData {
        let b = secondData.assumingMemoryBound(to: Float.self)
        for i in 0..<frames {
            out[i * 2] = a[i]
            out[i * 2 + 1] = b[i]
        }
    } else {
        for i in 0..<frames {
            out[i * 2] = a[i]
            out[i * 2 + 1] = a[i]
        }
    }
    return frames
}
