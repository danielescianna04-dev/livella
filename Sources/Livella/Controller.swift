import AppKit
import CoreAudio
import Foundation
import ServiceManagement

/// Glue between call detection, the audio engine, the volume raise and the UI.
final class Controller: ObservableObject {
    static let shared = Controller()

    // MARK: Settings (persisted)

    private let defaults = UserDefaults.standard

    @Published var enabled: Bool { didSet { defaults.set(enabled, forKey: "enabled"); reconcile() } }
    @Published var mediaGainDB: Double { didSet { defaults.set(mediaGainDB, forKey: "mediaGainDB"); engine.mediaGainDB.value = Float(mediaGainDB) } }
    @Published var duckDepthDB: Double { didSet { defaults.set(duckDepthDB, forKey: "duckDepthDB"); engine.duckDepthDB.value = Float(duckDepthDB) } }
    @Published var micLockEnabled: Bool { didSet { defaults.set(micLockEnabled, forKey: "micLock"); micLock.enabled = micLockEnabled } }
    @Published var autoCompensation: Bool { didSet { defaults.set(autoCompensation, forKey: "autoCompensation") } }
    @Published var manualCompensationDB: Double { didSet { defaults.set(manualCompensationDB, forKey: "manualCompensationDB") } }
    @Published var duckOnOwnVoice: Bool {
        didSet {
            defaults.set(duckOnOwnVoice, forKey: "duckOnOwnVoice")
            engine.duckOnOwnVoice.value = duckOnOwnVoice ? 1 : 0
            if duckOnOwnVoice { requestMicPermissionIfNeeded() }
            restartMicListener()
        }
    }
    /// false (default) = gentle mode: the call's own audio is never touched.
    @Published var fullTakeover: Bool {
        didSet {
            defaults.set(fullTakeover, forKey: "fullTakeover")
            if engine.isRunning { disengage(); reconcile() }
        }
    }
    @Published var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled

    /// Only what the menu bar icon needs, so the icon is not redrawn on every
    /// level change (that alone cost a third of a CPU core).
    final class IconState: ObservableObject { @Published var engaged = false }
    let icon = IconState()
    private var lastDiagnostics = Date.distantPast

    // MARK: Status

    @Published private(set) var callName: String?
    @Published private(set) var measuredDuckDB: Double?
    @Published private(set) var measurementBroken = false
    @Published private(set) var hardwareRaiseDB: Double = 0
    @Published private(set) var digitalMakeupDB: Double = 0
    enum Speaker { case nobody, them, me, both }
    @Published private(set) var speaker: Speaker = .nobody
    @Published private(set) var micPermissionDenied = false
    @Published private(set) var permission: AudioCapturePermission.State = AudioCapturePermission.state
    @Published private(set) var lastError: String?
    @Published private(set) var lastMicSwitch: String?

    var isEngaged: Bool { engine.isRunning || previewEngaged }
    private var previewEngaged = false

    /// Example status for `--render-menu` (the README screenshot). The running
    /// app never calls this.
    func loadPreviewState() {
        previewEngaged = true
        permission = .granted
        callName = "WhatsApp"
        measuredDuckDB = 30
        digitalMakeupDB = 18
        speaker = .them
    }

    // MARK: Parts

    private let mic: MicListener
    private let engine: MixEngine
    private let monitor = CallMonitor()
    private let volume = VolumeGuard()
    private let micLock = MicLock()
    /// Mic start/stop off the main thread: opening an input device can block.
    private let micQueue = DispatchQueue(label: "livella.mic")
    private var voice: [AudioProcess] = []
    private var meterTimer: Timer?
    private var permissionTimer: Timer?
    private var outputListener: AudioObjectPropertyListenerBlock?
    private var inputListener: AudioObjectPropertyListenerBlock?
    private var engagedOutput: AudioObjectID?
    /// Every hardware volume change is a Bluetooth command to the headphones;
    /// sending them often disturbs the link (and the call), so they are rare.
    private var lastHardwareChange = Date.distantPast
    private var smoothedDuck: Double?

    // Measurement state
    private var windows: [(out: Double, outFrames: Int, own: Double, ownFrames: Int)] = []
    private var validWindows = 0
    private var dropStreak = 0

    private init() {
        defaults.register(defaults: [
            "enabled": true, "mediaGainDB": 0.0, "duckDepthDB": 10.0, "micLock": true,
            "autoCompensation": true, "manualCompensationDB": 20.0, "duckOnOwnVoice": true,
            "fullTakeover": false,
        ])
        // Option removed from the menu at the user's request: always gentle mode.
        fullTakeover = false
        let listener = MicListener()
        mic = listener
        engine = MixEngine(ownSpeech: listener.speaking)
        duckOnOwnVoice = defaults.bool(forKey: "duckOnOwnVoice")
        enabled = defaults.bool(forKey: "enabled")
        mediaGainDB = defaults.double(forKey: "mediaGainDB")
        duckDepthDB = defaults.double(forKey: "duckDepthDB")
        // Never move the microphone: on this setup the Mac's own mic made the
        // user's voice break up for the other person (tested 2026-11-18).
        micLockEnabled = false
        autoCompensation = defaults.bool(forKey: "autoCompensation")
        manualCompensationDB = defaults.double(forKey: "manualCompensationDB")
    }

    func start() {
        VolumeGuard.recoverAfterCrash()
        engine.mediaGainDB.value = Float(mediaGainDB)
        engine.duckDepthDB.value = Float(duckDepthDB)
        engine.duckOnOwnVoice.value = duckOnOwnVoice ? 1 : 0
        if duckOnOwnVoice { requestMicPermissionIfNeeded() }

        micLock.onSwitch = { [weak self] name in self?.lastMicSwitch = name }
        micLock.enabled = micLockEnabled
        micLock.start()

        // Safety first: when the call ends, silence our output and take the volume
        // raise back on the monitor's queue, before anything waits for the main thread.
        monitor.onCallEndedImmediate = { [engine, volume] in
            engine.silenceNow()
            volume.restore()
        }
        monitor.onChange = { [weak self] processes in
            self?.voice = processes
            self?.reconcile()
        }
        monitor.start()

        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.outputDeviceChanged() }
        AudioObjectAddPropertyListenerBlock(systemObject, &addr, .main, block)
        outputListener = block

        // The microphone moved (e.g. AirPods -> Mac): follow it.
        var inAddr = address(kAudioHardwarePropertyDefaultInputDevice)
        let inBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.restartMicListener() }
        AudioObjectAddPropertyListenerBlock(systemObject, &inAddr, .main, inBlock)
        inputListener = inBlock

        refreshPermission(askIfNeeded: true)
        Log.write("Livella started")
    }

    func shutdown() {
        disengage()
        monitor.stop()
        micLock.stop()
        Log.write("Livella quit")
    }

    // MARK: Permission

    func requestPermission() {
        if permission == .denied {
            AudioCapturePermission.openSettings()
        } else {
            refreshPermission(askIfNeeded: true)
        }
    }

    private func refreshPermission(askIfNeeded: Bool) {
        permission = AudioCapturePermission.state
        if permission == .undetermined && askIfNeeded {
            AudioCapturePermission.request { [weak self] state in
                self?.permission = state
                self?.reconcile()
            }
        }
        // Keep checking until granted: the user may flip it in System Settings.
        if permission != .granted && permissionTimer == nil {
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
                guard let self else { return timer.invalidate() }
                self.permission = AudioCapturePermission.state
                if self.permission == .granted {
                    timer.invalidate()
                    self.permissionTimer = nil
                    self.reconcile()
                }
            }
        }
        reconcile()
    }

    // MARK: Engage / disengage

    private func reconcile() {
        let shouldRun = enabled && permission == .granted && !voice.isEmpty
        if !shouldRun {
            disengage()
            callName = voice.isEmpty ? nil : Self.describe(voice)
            return
        }
        callName = Self.describe(voice)
        if engine.isRunning {
            do { try engine.updateVoice(voice.map(\.object)) } catch { fail(error) }
        } else {
            engage()
        }
    }

    private func engage() {
        guard let output = defaultOutputDevice() else { return }
        volume.attach(device: output)
        windows = []; validWindows = 0; dropStreak = 0
        measuredDuckDB = nil; measurementBroken = false; smoothedDuck = nil
        lastHardwareChange = .distantPast
        do {
            try engine.start(outputDevice: output, voiceProcesses: voice.map(\.object), takeOverCall: fullTakeover)
            engagedOutput = output
            icon.engaged = true
            lastError = nil
            meterTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
            if !autoCompensation { applyCompensation(manualCompensationDB) }
            restartMicListener()
        } catch {
            fail(error)
        }
    }

    private func disengage() {
        meterTimer?.invalidate()
        meterTimer = nil
        engine.silenceNow()
        volume.restore()
        engine.stop()
        volume.detach()
        engagedOutput = nil
        if icon.engaged { icon.engaged = false }
        micQueue.async { [mic] in mic.stop() }
        engine.makeupDB.value = 0
        if hardwareRaiseDB != 0 { hardwareRaiseDB = 0 }
        if digitalMakeupDB != 0 { digitalMakeupDB = 0 }
        if speaker != .nobody { speaker = .nobody }
    }

    // MARK: Your voice

    private func requestMicPermissionIfNeeded() {
        switch MicListener.permission {
        case .notDetermined:
            MicListener.requestPermission { [weak self] ok in
                self?.micPermissionDenied = !ok
                self?.restartMicListener()
            }
        case .denied, .restricted:
            micPermissionDenied = true
        default:
            micPermissionDenied = false
        }
    }

    /// Listens to the microphone only during a call (when the call app has it
    /// open anyway) and only if "also when I speak" is on.
    private func restartMicListener() {
        let wanted = engine.isRunning && duckOnOwnVoice && MicListener.permission == .authorized
        let device = defaultInputDevice()
        micQueue.async { [mic] in
            mic.stop()
            guard wanted, let device else { return }
            do { try mic.start(device: device) } catch { Log.write("mic listener: \(error)") }
        }
    }

    private func fail(_ error: Error) {
        Log.write("error: \(error)")
        lastError = "\(error)"
        disengage()
    }

    private func outputDeviceChanged() {
        // macOS also sends this when the same headphones only change mode
        // (AirPods headset -> stereo). Restart only for a real device change.
        guard engine.isRunning, defaultOutputDevice() != engagedOutput else { return }
        Log.write("output device changed, restarting")
        disengage()
        reconcile()
    }

    /// Panic button.
    func restoreNow() {
        disengage()
        enabled = false
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            lastError = "Avvio all'accesso: \(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: Measuring how much macOS lowers us

    private func tick() {
        guard engine.isRunning else { return }
        let them = engine.remoteSpeaking.value > 0
        let me = duckOnOwnVoice && mic.speaking.value > 0
        let now: Speaker = them && me ? .both : them ? .them : me ? .me : .nobody
        if now != speaker { speaker = now }

        // While you speak, take video/music back down by everything Livella
        // added (plus a margin), i.e. to where macOS itself would keep them.
        let added = mediaGainDB + digitalMakeupDB + hardwareRaiseDB
        // Same depth as for the other person, as the slider says. (A deeper cut
        // was tried against choppy voice; the cause was the microphone.)
        _ = added
        engine.ownDuckDB.value = Float(duckDepthDB)

        if Date().timeIntervalSince(lastDiagnostics) >= 2 {
            lastDiagnostics = Date()
            Log.write(String(format: "levels  mic %.0f dB (background %.0f, your voice %.0f) you-speaking=%@  call voice %.0f dB  media %.0f dB  lowering %.0f dB",
                             mic.levelDB.value, mic.noiseFloor.value, mic.speechLevel.value, me ? "yes" : "no",
                             engine.voiceLevelDB.value, engine.mediaLevelDB.value, engine.duckingDB.value))
        }

        let out = engine.outputMeter.drain()
        let own = engine.selfMeter.drain()
        windows.append((out.sum, out.frames, own.sum, own.frames))
        if windows.count > 10 { windows.removeFirst() }

        if !autoCompensation {
            applyCompensation(manualCompensationDB)
            return
        }

        // One 100 ms window: used only to react fast when the lowering stops.
        if let instant = Self.estimate(out.sum, out.frames, own.sum, own.frames) {
            let applied = hardwareRaiseDB + digitalMakeupDB
            dropStreak = instant < applied - 8 ? dropStreak + 1 : 0
            if dropStreak >= 3 {
                Log.write(String(format: "lowering stopped (now %.1f dB), cutting raise", instant))
                smoothedDuck = max(0, instant)
                applyCompensation(max(0, instant), urgent: true)
                validWindows = 0
                return
            }
        }

        // One-second view: used to set the raise.
        let total = windows.reduce((0.0, 0, 0.0, 0)) { ($0.0 + $1.out, $0.1 + $1.outFrames, $0.2 + $1.own, $0.3 + $1.ownFrames) }
        let outDB = total.1 > 0 ? energyToDB(total.0 / Double(total.1 * 2)) : -200
        let ownDB = total.3 > 0 ? energyToDB(total.2 / Double(total.3 * 2)) : -200
        guard outDB > -60 else { return }        // too quiet to measure: keep what we have
        if ownDB < -110 {
            // We are playing but the tap on our own output hears nothing:
            // the measurement does not work here, so never raise on it.
            if !measurementBroken { measurementBroken = true }
            applyCompensation(0, urgent: true)
            return
        }
        if measurementBroken { measurementBroken = false }
        let raw = min(40, max(0, outDB - ownDB))
        let duck = smoothedDuck.map { $0 + (raw - $0) * 0.2 } ?? raw
        smoothedDuck = duck
        let shown = duck.rounded()
        if measuredDuckDB != shown { measuredDuckDB = shown }
        validWindows += 1
        if validWindows >= 3 { applyCompensation(duck) }
    }

    private static func estimate(_ out: Double, _ outFrames: Int, _ own: Double, _ ownFrames: Int) -> Double? {
        guard outFrames > 0, ownFrames > 0 else { return nil }
        let outDB = energyToDB(out / Double(outFrames * 2))
        let ownDB = energyToDB(own / Double(ownFrames * 2))
        guard outDB > -55, ownDB > -110 else { return nil }
        return min(40, max(0, outDB - ownDB))
    }

    /// Hardware volume first (clean gain applied after the system lowers us),
    /// digital make-up only for what the hardware cannot reach.
    ///
    /// The hardware volume moves rarely (each move is a Bluetooth command to the
    /// headphones): only for a gap of 3 dB or more, at most every 3 seconds.
    /// Lowering it is never delayed. Small differences are made up digitally,
    /// which costs nothing.
    private func applyCompensation(_ wanted: Double, urgent: Bool = false) {
        let target = max(0, wanted)
        guard fullTakeover else {
            // Gentle mode: the call plays directly, so raising the headphone
            // volume would raise the call too. Only video and music go up, digitally.
            if hardwareRaiseDB != 0 { volume.setRaise(0); hardwareRaiseDB = 0 }
            let digital = min(18, target)
            engine.makeupDB.value = Float(digital)
            if (digitalMakeupDB * 2).rounded() != (digital * 2).rounded() { digitalMakeupDB = digital }
            return
        }
        var hw = hardwareRaiseDB
        let gap = target - hw
        let lowering = gap <= -3
        let rested = Date().timeIntervalSince(lastHardwareChange) >= 3
        if urgent || lowering || (abs(gap) >= 3 && rested) {
            let applied = Double(volume.setRaise(Float(target)))
            if abs(applied - hw) >= 0.5 {
                lastHardwareChange = Date()
                Log.write(String(format: "headphone volume raise %.1f -> %.1f dB (wanted %.1f)", hw, applied, target))
            }
            hw = applied
        }
        let digital = min(18, max(-6, target - hw))
        engine.makeupDB.value = Float(digital)
        let shownHW = (hw * 2).rounded() / 2, shownDigital = (digital * 2).rounded() / 2
        if hardwareRaiseDB != shownHW { hardwareRaiseDB = hw }
        if (digitalMakeupDB * 2).rounded() / 2 != shownDigital { digitalMakeupDB = digital }
    }

    private static func describe(_ processes: [AudioProcess]) -> String {
        let callers = CallMonitor.callers(in: processes)
        let names = (callers.isEmpty ? processes : callers).map { p -> String in
            if p.name == "avconferenced" { return "FaceTime" }
            return p.displayName
        }
        return Array(Set(names)).sorted().joined(separator: ", ")
    }
}
