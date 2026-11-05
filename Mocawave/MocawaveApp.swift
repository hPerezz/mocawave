import AppKit
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // SwiftPM launches from Xcode don't have a main app bundle, which makes
        // AppKit's automatic window tab indexing emit a startup warning.
        if Bundle.main.bundleIdentifier?.isEmpty != false {
            NSWindow.allowsAutomaticWindowTabbing = false
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in
            AudioOpenCoordinator.shared.handleExternalOpen(urls: urls)
        }
    }
}

@main
struct MocawaveApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        // Finder document opens are handled by AppDelegate.application(_:open:).
        // Letting the WindowGroup also claim every external event causes a second
        // window to be spawned for the same file-open request on macOS.
        WindowGroup {
            ContentView()
        }
    }
}
