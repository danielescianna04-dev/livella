import Foundation

/// Decides "the user is speaking" from raw microphone samples.
///
/// A 10 ms slice counts as speech only if it passes three tests, all cheap
/// enough for the audio thread:
///  * **Loud enough**: clearly above the room's background, *and* not far below
///    the user's own speech level on this microphone. A headset microphone sits
///    next to the mouth, so other people's voices arrive much quieter.
///  * **Voiced**: vocal cords vibrate regularly (75–350 times a second), so the
///    sound repeats itself. A clap, a hand rubbing the head or the earbud, a
///    key click, wind: none of them do. Measured with a normalised
///    autocorrelation over the last 32 ms.
///  * **Lasting**: at least 60 ms without a break, like a vowel.
///
/// Once open, the gate stays open while speech continues and for a short hold.
struct SpeechGate {
    private(set) var isOpen = false
    private(set) var levelDB: Float = -200
    private(set) var noiseFloorDB: Float = -60
    /// The user's speech level on this microphone, learned from voiced sound.
    private(set) var speechLevelDB: Float
    /// Last voicing measure, 0…1 (for the log).
    private(set) var voicing: Float = 0

    private let sliceLength: Int
    private var sliceSum: Float = 0
    private var sliceCount = 0
    private var history: UInt32 = 0          // one bit per 10 ms slice, newest in bit 0
    private var run = 0                      // consecutive speech slices
    private var holdSlices = 0

    private var highPass: Biquad
    private var lowPass: Biquad

    // Voicing: band 250–900 Hz, decimated to about 8 kHz, last 32 ms kept.
    private var pitchLowPass: Biquad
    private let decimation: Int
    private var decimationCount = 0
    private var ring: [Float]
    private var ringPosition = 0
    private var window: [Float]
    private let windowLength: Int
    private let minLag: Int
    private let maxLag: Int

    static let syllableSlices = 6            // 60 ms without a break
    static let openWhen = 6                  // speech slices out of the last 20
    static let stayOpenWhile = 4
    static let holdTime: Float = 0.35
    static let marginDB: Float = 12          // above the background
    static let belowSpeechDB: Float = 15     // below the user's own level
    static let voicedAbove: Float = 0.5

    /// - Parameter speechLevelDB: level learned in earlier calls on this
    ///   microphone (−200 = not known yet).
    init(sampleRate: Double, speechLevelDB: Float = -200) {
        self.speechLevelDB = speechLevelDB
        let sr = Float(sampleRate)
        sliceLength = max(1, Int(sampleRate * 0.01))
        highPass = .highPass(frequency: 250, sampleRate: sr)
        lowPass = .lowPass(frequency: 3000, sampleRate: sr)
        pitchLowPass = .lowPass(frequency: 900, sampleRate: sr)
        decimation = max(1, Int((sampleRate / 8000).rounded()))
        let rate = sampleRate / Double(decimation)
        windowLength = min(512, Int(rate * 0.032))
        minLag = max(2, Int(rate / 350))
        maxLag = min(windowLength / 2, Int(rate / 75))
        ring = [Float](repeating: 0, count: windowLength)
        window = [Float](repeating: 0, count: windowLength)
    }

    mutating func process(_ samples: UnsafePointer<Float>, count: Int) {
        for i in 0..<count {
            let high = highPass.process(samples[i])
            let x = lowPass.process(high)
            sliceSum += x * x
            sliceCount += 1

            let p = pitchLowPass.process(high)
            decimationCount += 1
            if decimationCount == decimation {
                decimationCount = 0
                ring[ringPosition] = p
                ringPosition = (ringPosition + 1) % windowLength
            }
            if sliceCount == sliceLength { endSlice() }
        }
    }

    /// Highest normalised autocorrelation over the pitch range: near 1 for a
    /// vowel, low for noise and impacts.
    private mutating func measureVoicing() -> Float {
        for i in 0..<windowLength { window[i] = ring[(ringPosition + i) % windowLength] }
        let n = windowLength - maxLag
        var e0: Float = 0
        for i in 0..<n { e0 += window[i] * window[i] }
        guard e0 > 1e-18 else { return 0 }
        var best: Float = 0
        for lag in minLag...maxLag {
            var cross: Float = 0, eLag: Float = 0
            for i in 0..<n {
                let b = window[i + lag]
                cross += window[i] * b
                eLag += b * b
            }
            if cross > 0, eLag > 1e-18 {
                let r = cross / (e0 * eLag).squareRoot()
                if r > best { best = r }
            }
        }
        return best
    }

    private mutating func endSlice() {
        let db = sliceSum > 1e-20 ? 10 * log10f(sliceSum / Float(sliceCount)) : -200
        sliceSum = 0
        sliceCount = 0
        levelDB = db

        // Background: sounds near it are followed within a few seconds (so an
        // unsteady background, like a Bluetooth microphone's, is averaged and
        // not tracked at its quietest moments); clearly louder sounds, which may
        // be speech, pull it up only over ~30 s.
        let seconds: Float = 0.01
        if db < noiseFloorDB {
            noiseFloorDB += (db - noiseFloorDB) * min(1, seconds / 0.5)
        } else if db < noiseFloorDB + Self.marginDB / 2 && (history & 0xFFFFF) == 0 && !isOpen {
            noiseFloorDB += (db - noiseFloorDB) * min(1, seconds / 3)
        } else {
            noiseFloorDB += (db - noiseFloorDB) * min(1, seconds / 30)
        }
        noiseFloorDB = max(noiseFloorDB, -100)

        let threshold = max(noiseFloorDB + Self.marginDB, speechLevelDB - Self.belowSpeechDB)
        let loud = db > -90 && db > threshold
        // The autocorrelation is only worth computing for loud slices.
        voicing = loud ? measureVoicing() : 0
        let speech = loud && voicing > Self.voicedAbove

        history = (history << 1) | (speech ? 1 : 0)
        let recent = (history & 0xFFFFF).nonzeroBitCount   // last 20 slices
        run = speech ? run + 1 : 0

        // The user's level: learned only from voiced sound that lasted like a
        // vowel; rises quickly, is forgotten slowly (3 dB a minute).
        if run >= Self.syllableSlices && db > speechLevelDB {
            speechLevelDB = speechLevelDB < -150 ? db : speechLevelDB + (db - speechLevelDB) * 0.1
        } else if speechLevelDB > -150 {
            speechLevelDB -= 0.0005
        }

        if !isOpen {
            if recent >= Self.openWhen && run >= Self.syllableSlices {
                isOpen = true
                holdSlices = Int(Self.holdTime / seconds)
            }
        } else if recent >= Self.stayOpenWhile {
            holdSlices = Int(Self.holdTime / seconds)
        } else {
            holdSlices -= 1
            if holdSlices <= 0 { isOpen = false }
        }
    }
}

/// RBJ cookbook biquad, direct form I.
struct Biquad {
    var b0: Float, b1: Float, b2: Float, a1: Float, a2: Float
    var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0

    mutating func process(_ x: Float) -> Float {
        let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2 = x1; x1 = x
        y2 = y1; y1 = y
        return y
    }

    static func highPass(frequency: Float, sampleRate: Float, q: Float = 0.707) -> Biquad {
        let w = 2 * Float.pi * frequency / sampleRate
        let alpha = sinf(w) / (2 * q), c = cosf(w), a0 = 1 + alpha
        return Biquad(b0: (1 + c) / 2 / a0, b1: -(1 + c) / a0, b2: (1 + c) / 2 / a0,
                      a1: -2 * c / a0, a2: (1 - alpha) / a0)
    }

    static func lowPass(frequency: Float, sampleRate: Float, q: Float = 0.707) -> Biquad {
        let w = 2 * Float.pi * frequency / sampleRate
        let alpha = sinf(w) / (2 * q), c = cosf(w), a0 = 1 + alpha
        return Biquad(b0: (1 - c) / 2 / a0, b1: (1 - c) / a0, b2: (1 - c) / 2 / a0,
                      a1: -2 * c / a0, a2: (1 - alpha) / a0)
    }
}
