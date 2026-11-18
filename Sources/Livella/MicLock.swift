import CoreAudio
import Foundation

/// Keeps the system microphone on the Mac's own mic whenever macOS (or an app)
/// switches it to Bluetooth headphones. With their mic closed, AirPods stay in
/// high-quality stereo instead of dropping to the 16 kHz headset profile.
///
/// Apps that pick a specific microphone in their own settings are not affected
/// by the system default; for those the mic has to be chosen in the app.
final class MicLock {
    var enabled = false { didSet { if enabled { enforce() } } }
    var onSwitch: ((String) -> Void)?

    private var listener: AudioObjectPropertyListenerBlock?
    private let selectors = [kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDevices]

    func start() {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            // Small delay: right after a connection the device list is still settling.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self?.enforce() }
        }
        for selector in selectors {
            var addr = address(selector)
            AudioObjectAddPropertyListenerBlock(systemObject, &addr, .main, block)
        }
        listener = block
        enforce()
    }

    func stop() {
        guard let listener else { return }
        for selector in selectors {
            var addr = address(selector)
            AudioObjectRemovePropertyListenerBlock(systemObject, &addr, .main, listener)
        }
        self.listener = nil
    }

    private func enforce() {
        guard enabled, let input = defaultInputDevice(), isBluetooth(input),
              let mac = builtInInputDevice(), mac != input else { return }
        let from = deviceName(input)
        if writeValue(systemObject, address(kAudioHardwarePropertyDefaultInputDevice), mac) == noErr {
            Log.write("microphone: \(from) -> \(deviceName(mac))")
            onSwitch?(deviceName(mac))
        }
    }
}
