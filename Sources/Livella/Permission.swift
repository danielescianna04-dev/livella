import AppKit
import Foundation

/// "System audio recording" permission (kTCCServiceAudioCapture).
///
/// Creating a process tap never asks for it: without the grant a tap simply
/// delivers silence, which looks exactly like an app being quiet. So the state
/// is read and requested explicitly. There is no public API for this service;
/// the calls below are the same TCC entry points other tap-based tools use.
enum AudioCapturePermission {
    enum State: Int {
        case granted = 0, denied = 1, undetermined = 2, unknown = -1
    }

    private static let service = "kTCCServiceAudioCapture" as CFString
    private typealias PreflightFn = @convention(c) (CFString, CFDictionary?) -> Int32
    private typealias RequestFn = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void
    private static let handle = dlopen("/System/Library/PrivateFrameworks/TCC.framework/TCC", RTLD_NOW)

    static var state: State {
        guard let handle, let symbol = dlsym(handle, "TCCAccessPreflight") else { return .unknown }
        let preflight = unsafeBitCast(symbol, to: PreflightFn.self)
        return State(rawValue: Int(preflight(service, nil))) ?? .unknown
    }

    static func request(_ completion: @escaping (State) -> Void) {
        guard state != .granted else { return completion(.granted) }
        guard let handle, let symbol = dlsym(handle, "TCCAccessRequest") else { return completion(.unknown) }
        let request = unsafeBitCast(symbol, to: RequestFn.self)
        request(service, nil) { _ in
            DispatchQueue.main.async { completion(state) }
        }
    }

    static func openSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!
        NSWorkspace.shared.open(url)
    }
}
