import AppKit
import SwiftUI

struct WindowConfigurator: NSViewRepresentable {
    let configure: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                configure(window)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Don't reconfigure on every view update - only configure once in makeNSView
    }
}

extension View {
    func configureWindow(_ configure: @escaping (NSWindow) -> Void) -> some View {
        #if MOCA_SNAPSHOT
        self   // headless snapshot builds have no window to configure
        #else
        background(WindowConfigurator(configure: configure))
        #endif
    }
}
