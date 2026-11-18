import AppKit
import SwiftUI

struct LivellaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() {
        // Started here, not from the menu's view: the menu content is only built
        // when the user opens it, and the engine has to run before that.
        Controller.shared.start()
    }

    var body: some Scene {
        MenuBarExtra {
            MenuView(controller: Controller.shared)
        } label: {
            MenuBarIcon(state: Controller.shared.icon)
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuBarIcon: View {
    @ObservedObject var state: Controller.IconState
    var body: some View {
        Image(systemName: state.engaged ? "waveform.badge.plus" : "waveform")
            .accessibilityLabel(state.engaged ? "Livella, attiva in chiamata" : "Livella")
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // `kill` and Ctrl-C must also take the volume raise back.
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                Controller.shared.shutdown()
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Controller.shared.shutdown()
    }
}

struct MenuView: View {
    @ObservedObject var controller: Controller

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if controller.permission != .granted { permissionBox }
            if let error = controller.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if controller.isEngaged { liveBox }

            Divider()

            slider(title: "Volume di video e musica in chiamata",
                   value: $controller.mediaGainDB, range: -20...6,
                   text: signedDB(controller.mediaGainDB),
                   help: "0 dB = come se la chiamata non ci fosse.")

            slider(title: "Abbassa quando si parla",
                   value: $controller.duckDepthDB, range: 0...24,
                   text: controller.duckDepthDB < 0.5 ? "Mai" : "di \(Int(controller.duckDepthDB.rounded())) dB",
                   help: "Il resto torna su da solo quando si smette di parlare.")

            Toggle(isOn: $controller.duckOnOwnVoice) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Abbassa anche quando parlo io")
                    Text(controller.micPermissionDenied
                         ? "Serve il permesso del microfono: Impostazioni di Sistema › Privacy e sicurezza › Microfono."
                         : "Misura solo il volume del microfono, non registra nulla.")
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            DisclosureGroup("Avanzate") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Compensazione automatica", isOn: $controller.autoCompensation)
                    if !controller.autoCompensation {
                        slider(title: "Compensazione manuale",
                               value: $controller.manualCompensationDB, range: 0...36,
                               text: "+\(Int(controller.manualCompensationDB.rounded())) dB",
                               help: "Quanto riportare su il volume durante la chiamata.")
                    }
                    Toggle("Avvia all'accesso", isOn: Binding(
                        get: { controller.launchAtLogin },
                        set: { controller.setLaunchAtLogin($0) }))
                    Button("Apri il registro") { NSWorkspace.shared.open(URL(fileURLWithPath: Log.path)) }
                }
                .padding(.top, 6)
            }

            Divider()

            HStack {
                Button("Ripristina volume") { controller.restoreNow() }
                    .help("Ferma Livella e rimette il volume com'era.")
                Spacer()
                Button("Esci") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
        }
        .padding(16)
        .frame(width: 340)
        .foregroundStyle(.primary)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Livella").font(.headline)
                Text(statusText)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.updatesFrequently)
            }
            Spacer()
            Toggle("Attiva", isOn: $controller.enabled)
                .toggleStyle(.switch)
                .labelsHidden()
                .accessibilityLabel("Livella attiva")
        }
    }

    private var statusText: String {
        if !controller.enabled { return "Disattivata" }
        if let call = controller.callName {
            return controller.isEngaged ? "In chiamata: \(call)" : "Chiamata rilevata: \(call)"
        }
        return "In attesa di una chiamata"
    }

    private var permissionBox: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(controller.permission == .denied
                 ? "Livella non ha il permesso di gestire l'audio delle app."
                 : "Serve il permesso «Registrazione audio di sistema» per gestire l'audio delle app.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Button(controller.permission == .denied ? "Apri Impostazioni di Sistema" : "Concedi il permesso") {
                controller.requestPermission()
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.4)))
    }

    private var liveBox: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: controller.speaker == .nobody ? "person.wave.2" : "person.wave.2.fill")
                    .accessibilityHidden(true)
                Text(speakerText)
            }
            .font(.callout.weight(.medium))
            Text(compensationText)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private var speakerText: String {
        switch controller.speaker {
        case .nobody: return "Nessuno parla: volume pieno"
        case .them: return "Parla l'altra persona: il resto è abbassato"
        case .me: return "Stai parlando: il resto è abbassato"
        case .both: return "Parlate entrambi: il resto è abbassato"
        }
    }

    private var compensationText: String {
        if controller.measurementBroken {
            return "Non riesco a misurare l'abbassamento di macOS. Usa la compensazione manuale in Avanzate."
        }
        let applied = controller.hardwareRaiseDB + controller.digitalMakeupDB
        guard controller.autoCompensation else {
            return String(format: "Compensazione manuale: +%.0f dB", applied)
        }
        guard let duck = controller.measuredDuckDB else { return "Sto misurando quanto abbassa macOS…" }
        if duck < 1.5 { return "macOS non sta abbassando il volume in questa chiamata." }
        if !controller.fullTakeover {
            return String(format: "macOS abbassa video e musica di %.0f dB, recuperati %.0f dB (la chiamata non viene toccata)", duck, applied)
        }
        return String(format: "macOS abbassa il resto di %.0f dB, compensati %.0f dB", duck, applied)
    }

    private func slider(title: String, value: Binding<Double>, range: ClosedRange<Double>, text: String, help: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.callout)
                Spacer()
                Text(text).font(.callout.monospacedDigit())
            }
            .accessibilityHidden(true)
            Slider(value: value, in: range, step: 1)
                .accessibilityLabel(title)
                .accessibilityValue(text)
                .accessibilityHint(help)
            Text(help).font(.caption)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityHidden(true)
        }
    }

    private func signedDB(_ value: Double) -> String {
        let v = Int(value.rounded())
        return v == 0 ? "0 dB" : (v > 0 ? "+\(v) dB" : "\(v) dB")
    }
}
