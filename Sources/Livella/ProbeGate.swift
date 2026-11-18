import Foundation

extension Probe {
    /// `Livella --probe-gate`: feeds synthetic sounds to SpeechGate and checks
    /// each against what is expected. Levels are approximate full-band RMS.
    static func gateTest() {
        var rng = SystemRandomNumberGenerator()
        func noise() -> Float { Float.random(in: -1...1, using: &rng) * 1.732 }   // unit RMS
        var failures = 0

        /// - Parameter expect: allowed range for "% of time lowered".
        func run(_ name: String, sampleRate sr: Double = 48000, seconds: Double, seed: Float = -200,
                 background: Float = -90, expect: ClosedRange<Double>, _ sample: (Double) -> Float) {
            var gate = SpeechGate(sampleRate: sr, speechLevelDB: seed)
            let warm = Int(sr * 2), total = Int(sr * seconds)
            var buffer = [Float](repeating: 0, count: 512)
            var open = 0, blocks = 0, t = 0
            while t < warm + total {
                for i in 0..<512 {
                    let n = t + i
                    buffer[i] = noise() * dbToGain(background) + (n >= warm ? sample(Double(n - warm) / sr) : 0)
                }
                buffer.withUnsafeBufferPointer { gate.process($0.baseAddress!, count: 512) }
                if t >= warm { blocks += 1; if gate.isOpen { open += 1 } }
                t += 512
            }
            let pct = 100 * Double(open) / Double(blocks)
            let ok = expect.contains(pct)
            if !ok { failures += 1 }
            let padded = name.padding(toLength: 50, withPad: " ", startingAt: 0)
            print("\(ok ? "OK  " : "NO  ") \(padded) abbassa per il \(String(format: "%5.1f", pct))% (atteso \(Int(expect.lowerBound))–\(Int(expect.upperBound))%)")
        }

        // A voice: harmonics of a pitch that wobbles slightly, in syllables of
        // 180 ms with 90 ms gaps, plus a little breath noise.
        func voice(_ t: Double, rmsDB: Float, pitch: Double = 120) -> Float {
            let phase = t.truncatingRemainder(dividingBy: 0.27)
            guard phase < 0.18 else { return 0 }
            let shape = Float(sin(.pi * phase / 0.18))
            let angle = 2 * Double.pi * (pitch * t - (0.03 * pitch / (2 * .pi * 5)) * cos(2 * .pi * 5 * t))
            var s = 0.0
            for k in 1...20 { s += sin(Double(k) * angle) / Double(k) }
            return dbToGain(rmsDB) * shape * (Float(s) * 1.12 + 0.1 * noise())
        }
        func turns(_ t: Double, _ x: Float) -> Float { t.truncatingRemainder(dividingBy: 10) < 4 ? x : 0 }

        // A key or a clap: sharp burst of noise that dies away.
        func hit(_ t: Double, every period: Double, peakDB: Float, decay: Double) -> Float {
            let k = t.truncatingRemainder(dividingBy: period)
            return dbToGain(peakDB) * Float(exp(-k / decay)) * (noise() * 0.8 + 0.5 * Float(sin(2 * .pi * 120 * k)))
        }
        // Rubbing (head, hair, the earbud itself): loud noise in strokes of 250 ms.
        func rubbing(_ t: Double, rmsDB: Float) -> Float {
            let k = t.truncatingRemainder(dividingBy: 0.4)
            guard k < 0.25 else { return 0 }
            return dbToGain(rmsDB) * Float(sin(.pi * k / 0.25)) * noise()
        }
        // Bluetooth-microphone background wandering between about −85 and −62 dB.
        func wander(_ t: Double) -> Float {
            let level = -73 + 8 * sin(2 * .pi * 0.9 * t) + 4 * sin(2 * .pi * 3.1 * t + 1)
            return dbToGain(Float(level)) * noise()
        }

        print("— Microfono AirPods (24 kHz, voce a circa −28 dB) —")
        let air = 24000.0
        run("Solo fondo", sampleRate: air, seconds: 30, seed: -35, expect: 0...1) { wander($0) }
        run("Parli 4 s ogni 10", sampleRate: air, seconds: 60, seed: -35, expect: 38...48) { wander($0) + turns($0, voice($0, rmsDB: -28)) }
        run("Parli più piano (−36 dB)", sampleRate: air, seconds: 60, seed: -35, expect: 38...48) { wander($0) + turns($0, voice($0, rmsDB: -36)) }
        run("Voce acuta (220 Hz)", sampleRate: air, seconds: 60, seed: -35, expect: 38...48) { wander($0) + turns($0, voice($0, rmsDB: -28, pitch: 220)) }
        run("Battito di mani forte, 1 al secondo", sampleRate: air, seconds: 20, seed: -35, expect: 0...1) { wander($0) + hit($0, every: 1, peakDB: -8, decay: 0.03) }
        run("Ti gratti la testa (sfregamento forte)", sampleRate: air, seconds: 20, seed: -35, expect: 0...1) { wander($0) + rubbing($0, rmsDB: -25) }
        run("Rumore forte continuo (traffico, phon)", sampleRate: air, seconds: 20, seed: -35, expect: 0...1) { _ in noise() * dbToGain(-30) }
        run("Altra persona che parla vicino (−50 dB)", sampleRate: air, seconds: 30, seed: -30, expect: 0...1) { wander($0) + voice($0, rmsDB: -50, pitch: 180) }
        run("Altra persona parla, tu 4 s ogni 10", sampleRate: air, seconds: 60, seed: -30, expect: 38...50) {
            wander($0) + voice($0 + 0.11, rmsDB: -50, pitch: 180) + turns($0, voice($0, rmsDB: -28))
        }
        run("Ambiente rumoroso (−45 dB), tu 4 s ogni 10", sampleRate: air, seconds: 60, seed: -30, background: -45, expect: 36...50) {
            turns($0, voice($0, rmsDB: -28))
        }

        print("— Microfono del Mac (48 kHz, voce debole) —")
        run("Solo stanza", seconds: 5, expect: 0...1) { _ in 0 }
        run("Tasti veloci forti", seconds: 5, expect: 0...1) { hit($0, every: 0.12, peakDB: -35, decay: 0.008) }
        run("Raffica estrema di tasti", seconds: 5, expect: 0...1) { hit($0, every: 0.06, peakDB: -25, decay: 0.008) }
        run("Voce (−60 dB)", seconds: 5, expect: 90...100) { voice($0, rmsDB: -60) }
        run("Voce bassa (−72 dB)", seconds: 5, expect: 90...100) { voice($0, rmsDB: -72) }
        run("Voce bassa mentre scrivi", seconds: 5, expect: 90...100) { voice($0, rmsDB: -72) + hit($0, every: 0.12, peakDB: -45, decay: 0.008) }

        print(failures == 0 ? "\nTutti i casi come atteso." : "\n\(failures) casi NON come atteso.")
    }
}
