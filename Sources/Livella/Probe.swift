import CoreAudio
import Foundation

/// Command-line diagnostics: `Livella --probe` and `Livella --probe-tap`.
enum Probe {
    static func run(_ arguments: [String]) -> Bool {
        if arguments.contains("--probe") { listState(); return true }
        if arguments.contains("--probe-tap") { tapTest(); return true }
        if arguments.contains("--probe-vad") { vadTest(); return true }
        if arguments.contains("--probe-gate") { gateTest(); return true }
        if let i = arguments.firstIndex(of: "--render-menu"), i + 1 < arguments.count {
            renderMenu(to: arguments[i + 1]); return true
        }
        return false
    }

    static func listState() {
        if let out = defaultOutputDevice() {
            print("Uscita predefinita: \(deviceName(out)) bluetooth=\(isBluetooth(out))")
            if let control = VolumeControl(device: out) {
                print("  volume: \(String(format: "%.1f", control.decibels)) dB, range \(control.range.lowerBound)…\(control.range.upperBound) dB (\(control.kind))")
            } else {
                print("  volume hardware non regolabile")
            }
        }
        if let input = defaultInputDevice() { print("Ingresso predefinito: \(deviceName(input)) bluetooth=\(isBluetooth(input))") }
        for device in [defaultInputDevice(), defaultOutputDevice()].compactMap({ $0 }) {
            let frames = readValue(device, address(kAudioDevicePropertyBufferFrameSize), default: UInt32(0))
            let rate = readValue(device, address(kAudioDevicePropertyNominalSampleRate), default: Float64(0))
            let running = readValue(device, address(kAudioDevicePropertyDeviceIsRunningSomewhere), default: UInt32(0))
            let vadIn = hasProperty(device, address(kAudioDevicePropertyVoiceActivityDetectionEnable, kAudioDevicePropertyScopeInput))
            print("  \(deviceName(device)): buffer \(frames) frame, \(Int(rate)) Hz, in uso=\(running != 0), VAD di sistema=\(vadIn)")
        }
        if let mic = builtInInputDevice() { print("Microfono del Mac: \(deviceName(mic))") }
        print("\nProcessi audio (IN = usa il microfono, OUT = riproduce):")
        for p in audioProcesses().sorted(by: { $0.name < $1.name }) {
            let flags = (p.runningInput ? "IN " : "   ") + (p.runningOutput ? "OUT" : "   ")
            let ignored = CallMonitor.isIgnored(p) ? "  [ignorato]" : ""
            print("  \(flags)  \(p.pid)\t\(p.name)\t\(p.bundleID ?? "-")\(ignored)")
        }
        print("\nChiamata rilevata ora: \(CallMonitor.voiceProcesses(in: audioProcesses()).map(\.name))")
    }

    /// Does the system's own voice activity detector report speech without this
    /// process opening the microphone?
    static func vadTest() {
        guard let mic = defaultInputDevice() else { return print("nessun microfono") }
        let enable = address(kAudioDevicePropertyVoiceActivityDetectionEnable, kAudioDevicePropertyScopeInput)
        let state = address(kAudioDevicePropertyVoiceActivityDetectionState, kAudioDevicePropertyScopeInput)
        let status = writeValue(mic, enable, UInt32(1))
        print("VAD su \(deviceName(mic)): abilitazione \(status == noErr ? "ok" : fourCC(status))")
        var changes = 0
        var addr = state
        AudioObjectAddPropertyListenerBlock(mic, &addr, DispatchQueue.global()) { _, _ in
            changes += 1
            let v = readValue(mic, state, default: UInt32(9))
            print("  \(Date().formatted(date: .omitted, time: .standard)) parla=\(v)")
        }
        for _ in 0..<10 {
            Thread.sleep(forTimeInterval: 1)
            print("stato: \(readValue(mic, state, default: UInt32(9)))")
        }
        writeValue(mic, enable, UInt32(0))
        print("cambi notificati: \(changes)")
    }

    /// Checks that a tap-only aggregate (no sub-devices) runs its IO proc.
    /// Without the audio-capture permission the samples are zeros, but the
    /// callbacks must still arrive.
    static func tapTest() {
        guard let me = processObject(forPID: getpid()) else {
            print("process object for self: none (expected before any audio IO)")
            return testWith(exclude: [])
        }
        testWith(exclude: [me])
    }

    private static func testWith(exclude: [AudioObjectID]) {
        do {
            let tap = try TapCapture(label: "probe", target: .everythingExcept(exclude), muteSource: false)
            print("tap ok, format \(tap.format.mSampleRate) Hz, \(tap.format.mChannelsPerFrame) ch, flags \(tap.format.mFormatFlags)")
            let meter = EnergyMeter()
            try tap.start { frames, n in
                var s: Double = 0
                for i in 0..<(n * 2) { s += Double(frames[i] * frames[i]) }
                meter.add(sumOfSquares: s, frameCount: n)
            }
            for _ in 0..<3 {
                Thread.sleep(forTimeInterval: 1)
                let (sum, frames) = meter.drain()
                let level = frames > 0 ? energyToDB(sum / Double(frames * 2)) : -200
                print("frames/s: \(frames)  level: \(String(format: "%.1f", level)) dBFS")
            }
            tap.invalidate()
        } catch {
            print("errore: \(error)")
        }
    }
}
