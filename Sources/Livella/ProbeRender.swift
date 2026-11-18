import AppKit
import SwiftUI

extension Probe {
    /// `Livella --render-menu <file.png>`: draws the real menu, with example
    /// status values, into a PNG. Used for the README screenshot.
    static func renderMenu(to path: String) {
        _ = NSApplication.shared
        let controller = Controller.shared
        controller.loadPreviewState()

        let view = MenuView(controller: controller)
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(12)
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: .darkAqua)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = .clear
        window.isOpaque = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        window.setContentSize(size)
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))

        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return print("render fallito") }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return print("png fallito") }
        do {
            try data.write(to: URL(fileURLWithPath: path))
            print("scritto \(path) \(rep.pixelsWide)x\(rep.pixelsHigh)")
        } catch { print("errore: \(error)") }
    }
}
