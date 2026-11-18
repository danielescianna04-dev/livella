import CoreAudio
import Foundation

/// During a call, takes over all audio and plays it back itself:
///
///   call voice ──tap (muted)──┐
///                             ├─► mix ─► make-up gain ─► limiter ─► output
///   everything else ─tap ─────┘   ▲
///        (muted)                  └ lowered while the voice tap carries speech
///
/// A third, *unmuted* tap listens to Livella's own output. macOS lowers that
/// output just like every other non-call sound, so comparing what Livella
/// played with what the tap hears gives the exact amount macOS is taking away,
/// whatever the call app is.
final class MixEngine: @unchecked Sendable {
    // UI / controller → render thread
    let mediaGainDB = SharedFloat(0)
    let duckDepthDB = SharedFloat(10)
    let makeupDB = SharedFloat(0)
    private let outputTarget = SharedFloat(0)

    // render thread → controller
    let outputMeter = EnergyMeter()
    let selfMeter = EnergyMeter()
    let voiceLevelDB = SharedFloat(-200)
    let mediaLevelDB = SharedFloat(-200)
    let duckingDB = SharedFloat(0)

    private var playback: Playback?
    private var mediaTap: TapCapture?
    private var voiceTap: TapCapture?
    private var selfTap: TapCapture?
    private let mediaRing = StereoRing()
    private let voiceRing = StereoRing()

    private let maxFrames = 4096
    private let media: UnsafeMutablePointer<Float>
    private let voice: UnsafeMutablePointer<Float>

    // Render-thread state
    private var sampleRate: Double = 48000
    private var sideGain: Float = 1
    private var holdLeft = 0
    private var ownHoldLeft = 0
    private var limiter: Float = 1
    private var outGain: Float = 0

    // Sidechain tuning: speech in a call arrives around −30…−15 dBFS; the call
    // app's own noise suppression keeps the pauses near silence.
    private let speechThresholdDB: Float = -45
    private let holdSeconds = 0.4
    private let attackSeconds: Float = 0.03
    private let releaseSeconds: Float = 0.12   // time constant: back to full in ~0.4 s

    private(set) var isRunning = false
    private(set) var voiceObjects: [AudioObjectID] = []
    /// false = "gentle" mode: the call app is never muted or re-played; its
    /// tap only measures when the other person speaks. Its echo canceller keeps
    /// seeing exactly what it expects.
    private(set) var takeOverCall = false
    private let mixVoice = SharedFloat(0)

    /// 1 while the user is speaking into the mic (set by `MicListener`).
    private let ownSpeech: SharedFloat
    /// 1 = also lower video/music while the user speaks.
    let duckOnOwnVoice = SharedFloat(1)
    /// For the UI: 1 while the other person is speaking.
    let remoteSpeaking = SharedFloat(0)
    /// How far video/music go down while *you* speak. Set by the controller to
    /// at least everything Livella added back, so while you talk the call app's
    /// echo canceller hears the same quiet background as without Livella, and
    /// does not mistake your voice for echo.
    let ownDuckDB = SharedFloat(30)

    init(ownSpeech: SharedFloat) {
        self.ownSpeech = ownSpeech
        media = .allocate(capacity: maxFrames * 2)
        voice = .allocate(capacity: maxFrames * 2)
        media.initialize(repeating: 0, count: maxFrames * 2)
        voice.initialize(repeating: 0, count: maxFrames * 2)
    }

    deinit {
        stop()
        media.deallocate()
        voice.deallocate()
    }

    // MARK: Control (main thread)

    func start(outputDevice: AudioObjectID, voiceProcesses: [AudioObjectID], takeOverCall: Bool) throws {
        guard !isRunning else { return }
        self.takeOverCall = takeOverCall
        mixVoice.value = takeOverCall ? 1 : 0
        guard let me = processObject(forPID: getpid()) else {
            // Without our own process object the global tap would include our
            // own output and feed it back into itself.
            throw CAError(what: "process object for Livella", status: -1)
        }
        do {
            try buildTaps(me: me, voiceProcesses: voiceProcesses)
            sampleRate = mediaTap?.sampleRate ?? 48000
            sideGain = 1; holdLeft = 0; limiter = 1; outGain = 0
            outputTarget.value = 0

            let playback = try Playback(device: outputDevice, sampleRate: sampleRate) { [unowned self] l, r, n in
                self.render(left: l, right: r, frames: n)
            }
            try playback.start()
            self.playback = playback

            let selfTap = try TapCapture(label: "self", target: .processes([me]), muteSource: false)
            try selfTap.start { [meter = selfMeter] frames, n in
                meter.add(sumOfSquares: sumOfSquares(frames, n * 2), frameCount: n)
            }
            self.selfTap = selfTap

            try startTaps()
            isRunning = true
            outputTarget.value = 1
            Log.write("engine started at \(Int(sampleRate)) Hz on \(deviceName(outputDevice)), voice processes \(voiceProcesses), mode \(takeOverCall ? "full" : "gentle")")
        } catch {
            stop()
            throw error
        }
    }

    /// The set of call processes changed mid-call (a helper started, say).
    func updateVoice(_ voiceProcesses: [AudioObjectID]) throws {
        guard isRunning, Set(voiceProcesses) != Set(voiceObjects), let me = processObject(forPID: getpid()) else { return }
        mediaTap?.invalidate(); mediaTap = nil
        voiceTap?.invalidate(); voiceTap = nil
        try buildTaps(me: me, voiceProcesses: voiceProcesses)
        try startTaps()
        Log.write("voice processes now \(voiceProcesses)")
    }

    /// Silences Livella's output immediately. Safe from any thread; used first
    /// when a call ends, while the volume raise is being taken back.
    func silenceNow() {
        outputTarget.value = -1
    }

    func stop() {
        outputTarget.value = -1
        // Tearing down the taps is what lets every app be heard directly again.
        mediaTap?.invalidate(); mediaTap = nil
        voiceTap?.invalidate(); voiceTap = nil
        selfTap?.invalidate(); selfTap = nil
        playback?.stop(); playback = nil
        mediaRing.reset(); voiceRing.reset()
        _ = outputMeter.drain(); _ = selfMeter.drain()
        voiceObjects = []
        if isRunning { Log.write("engine stopped") }
        isRunning = false
    }

    private func buildTaps(me: AudioObjectID, voiceProcesses: [AudioObjectID]) throws {
        voiceObjects = voiceProcesses
        mediaTap = try TapCapture(label: "media", target: .everythingExcept([me] + voiceProcesses), muteSource: true)
        if !voiceProcesses.isEmpty {
            voiceTap = try TapCapture(label: "voice", target: .processes(voiceProcesses), muteSource: takeOverCall)
            if let v = voiceTap, abs(v.sampleRate - (mediaTap?.sampleRate ?? v.sampleRate)) > 1 {
                Log.write("warning: voice tap \(v.sampleRate) Hz vs media \(mediaTap?.sampleRate ?? 0) Hz")
            }
        }
    }

    private func startTaps() throws {
        try mediaTap?.start { [ring = mediaRing] frames, n in ring.push(frames, count: n) }
        try voiceTap?.start { [ring = voiceRing] frames, n in ring.push(frames, count: n) }
    }

    // MARK: Render (realtime thread: no locks, no allocation)

    private func render(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames total: Int) {
        var offset = 0
        while offset < total {
            let n = min(maxFrames, total - offset)
            renderChunk(left: left + offset, right: right + offset, frames: n)
            offset += n
        }
    }

    private func renderChunk(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames n: Int) {
        let target = Int(sampleRate * 0.025), maxLatency = Int(sampleRate * 0.09)
        mediaRing.pop(into: media, count: n, targetLatency: target, maxLatency: maxLatency)
        voiceRing.pop(into: voice, count: n, targetLatency: target, maxLatency: maxLatency)

        let voiceMS = sumOfSquares(voice, n * 2) / Double(n * 2)
        let mediaMS = sumOfSquares(media, n * 2) / Double(n * 2)
        let voiceDB = Float(energyToDB(voiceMS))
        voiceLevelDB.value = voiceDB
        mediaLevelDB.value = Float(energyToDB(mediaMS))

        if voiceDB > speechThresholdDB {
            holdLeft = Int(sampleRate * holdSeconds)
        } else {
            holdLeft = max(0, holdLeft - n)
        }
        remoteSpeaking.value = holdLeft > 0 ? 1 : 0
        // Keep video/music down for the whole turn, not word by word: every time
        // they come back up between two sentences, the start of the next one is
        // spoken over loud audio and gets cut on the other side.
        if duckOnOwnVoice.value > 0 && ownSpeech.value > 0 {
            // No extra wait: the speech detector already holds for 0.35 s after
            // the last word. (A 2 s hold was tried against choppy voice; the
            // cause turned out to be the microphone, so it only added delay.)
            ownHoldLeft = 1
        } else {
            ownHoldLeft = max(0, ownHoldLeft - n)
        }
        let userSpeaking = ownHoldLeft > 0
        var duckTarget: Float = 1
        if holdLeft > 0 { duckTarget = dbToGain(-duckDepthDB.value) }
        if userSpeaking { duckTarget = min(duckTarget, dbToGain(-ownDuckDB.value)) }
        let sr = Float(sampleRate)
        // Faster when you start speaking: your first words are the ones at risk.
        let attack = 1 - expf(-1 / ((userSpeaking ? 0.008 : attackSeconds) * sr))
        let release = 1 - expf(-1 / (releaseSeconds * sr))
        let mediaGain = dbToGain(mediaGainDB.value)
        let makeup = dbToGain(makeupDB.value)

        let wanted = outputTarget.value
        let enabled: Float = wanted > 0 ? 1 : 0
        if wanted < 0 { outGain = 0 }                 // hard cut
        let fade = 1 - expf(-1 / (0.01 * sr))         // 10 ms fade-in

        let v = mixVoice.value
        var peak: Float = 0
        for i in 0..<n {
            sideGain += (duckTarget - sideGain) * (duckTarget < sideGain ? attack : release)
            let m = mediaGain * sideGain
            let l = (voice[i * 2] * v + media[i * 2] * m) * makeup
            let r = (voice[i * 2 + 1] * v + media[i * 2 + 1] * m) * makeup
            left[i] = l
            right[i] = r
            peak = max(peak, abs(l), abs(r))
        }
        duckingDB.value = 20 * log10f(max(sideGain, 1e-4))

        // Block limiter: instant attack, slow release.
        let ceiling: Float = 0.97
        let needed: Float = peak > ceiling ? ceiling / peak : 1
        // Release over ~0.5 s so heavy make-up gain does not pump audibly.
        let releasePerBlock = min(1, Float(n) / (sr * 0.5))
        if needed < limiter { limiter = needed } else { limiter += (needed - limiter) * releasePerBlock }

        var outSum: Double = 0
        for i in 0..<n {
            outGain += (enabled - outGain) * fade
            let g = limiter * outGain
            let l = left[i] * g, r = right[i] * g
            left[i] = l
            right[i] = r
            outSum += Double(l * l) + Double(r * r)
        }
        outputMeter.add(sumOfSquares: outSum, frameCount: n)
    }
}

@inline(__always)
func sumOfSquares(_ p: UnsafePointer<Float>, _ count: Int) -> Double {
    var s: Float = 0
    for i in 0..<count { s += p[i] * p[i] }
    return Double(s)
}
