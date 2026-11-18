import CoreAudio
import Foundation

/// Finds the call by itself: a call is any process that is using the
/// microphone, apart from system services that keep it open all the time
/// (Siri, dictation, sound recognition). The call's voice is that process plus
/// the helper processes of the same app.
///
/// FaceTime is the example of why it works this way: the FaceTime app never
/// opens the microphone, the `avconferenced` daemon does, and it is also the
/// process that plays the other person's voice.
final class CallMonitor: @unchecked Sendable {
    /// Main queue. Empty array = no call.
    var onChange: (([AudioProcess]) -> Void)?
    /// Runs on the monitor's own queue the instant the call ends, before any
    /// main-thread work: the volume raise has to come off immediately.
    var onCallEndedImmediate: (() -> Void)?

    private let queue = DispatchQueue(label: "livella.callmonitor", qos: .userInteractive)
    private var voice: [AudioProcess] = []
    private var listened: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
    private var listListener: AudioObjectPropertyListenerBlock?
    private var fastTimer: DispatchSourceTimer?
    private var slowTimer: DispatchSourceTimer?

    // MARK: Classification

    private static let ignoredBundlePrefixes = [
        "com.apple.corespeech", "com.apple.siri", "com.apple.assistant", "com.apple.Siri",
        "com.apple.SpeechRecognitionCore", "com.apple.speech", "com.apple.localspeechrecognition",
        "com.apple.accessibility", "com.apple.SoundAnalysis", "com.apple.soundanalysis",
        "com.apple.controlcenter", "com.apple.audio.", "com.apple.coreaudio",
    ]
    private static let ignoredNames: Set<String> = [
        "corespeechd", "assistantd", "Siri", "heard", "localspeechrecognition",
        "SpeechRecognitionCore", "soundanalysisd", "coreaudiod", "AccessibilityUIServer",
    ]

    static func isIgnored(_ p: AudioProcess) -> Bool {
        if p.pid == getpid() { return true }
        if ignoredNames.contains(p.name) { return true }
        if let id = p.bundleID, ignoredBundlePrefixes.contains(where: { id.hasPrefix($0) }) { return true }
        return false
    }

    static func callers(in processes: [AudioProcess]) -> [AudioProcess] {
        processes.filter { $0.runningInput && !isIgnored($0) }
    }

    static func voiceProcesses(in processes: [AudioProcess]) -> [AudioProcess] {
        let families = Set(callers(in: processes).map(\.family))
        guard !families.isEmpty else { return [] }
        return processes.filter { families.contains($0.family) && $0.pid != getpid() }
    }

    // MARK: Lifecycle

    func start() {
        queue.async { [self] in
            var addr = address(kAudioHardwarePropertyProcessObjectList)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.rescan() }
            if AudioObjectAddPropertyListenerBlock(systemObject, &addr, queue, block) == noErr { listListener = block }

            // Full rescan once a second catches anything a notification missed.
            let slow = DispatchSource.makeTimerSource(queue: queue)
            slow.schedule(deadline: .now() + 1, repeating: 1)
            slow.setEventHandler { [weak self] in self?.rescan() }
            slow.resume()
            slowTimer = slow

            // During a call, re-check the callers 20 times a second. This is a
            // safety timer: every moment the raise outlives the call is too loud.
            let fast = DispatchSource.makeTimerSource(queue: queue)
            fast.schedule(deadline: .now() + 0.05, repeating: 0.05)
            fast.setEventHandler { [weak self] in self?.fastCheck() }
            fast.resume()
            fastTimer = fast

            rescan()
        }
    }

    func stop() {
        queue.sync {
            slowTimer?.cancel(); slowTimer = nil
            fastTimer?.cancel(); fastTimer = nil
            if let listListener {
                var addr = address(kAudioHardwarePropertyProcessObjectList)
                AudioObjectRemovePropertyListenerBlock(systemObject, &addr, queue, listListener)
            }
            listListener = nil
            removeInputListeners(keeping: [])
        }
    }

    // MARK: Work (monitor queue)

    private func fastCheck() {
        guard !voice.isEmpty else { return }
        let callerObjects = voice.filter(\.runningInput).map(\.object)
        if !callerObjects.isEmpty && !callerObjects.contains(where: isRunningInput) {
            rescan()
        }
    }

    private func rescan() {
        let processes = audioProcesses()
        let newVoice = Self.voiceProcesses(in: processes)
        watchInputs(of: processes)

        let oldKey = voice.map(\.object).sorted()
        let newKey = newVoice.map(\.object).sorted()
        let wasInCall = !voice.isEmpty
        voice = newVoice
        guard oldKey != newKey else { return }

        if wasInCall && newVoice.isEmpty {
            onCallEndedImmediate?()
        }
        let snapshot = newVoice
        DispatchQueue.main.async { [weak self] in self?.onChange?(snapshot) }
    }

    /// Listens for "started / stopped using the microphone" on every process, so a
    /// call is noticed the moment it starts or ends rather than at the next poll.
    private func watchInputs(of processes: [AudioProcess]) {
        let objects = Set(processes.map(\.object))
        removeInputListeners(keeping: objects)
        for object in objects where listened[object] == nil {
            var addr = address(kAudioProcessPropertyIsRunningInput)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.rescan() }
            if AudioObjectAddPropertyListenerBlock(object, &addr, queue, block) == noErr {
                listened[object] = block
            }
        }
    }

    private func removeInputListeners(keeping: Set<AudioObjectID>) {
        for (object, block) in listened where !keeping.contains(object) {
            var addr = address(kAudioProcessPropertyIsRunningInput)
            AudioObjectRemovePropertyListenerBlock(object, &addr, queue, block)
            listened[object] = nil
        }
    }
}
