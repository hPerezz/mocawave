import AppKit
import SwiftUI

/// Mocawave has exactly one window (tracks are tabs inside it), owned here rather than by a SwiftUI
/// WindowGroup: a WindowGroup spawns a new window for every file opened from Finder, and keeping it from
/// doing so also kept it from creating the first window when the app was launched by opening a file.
class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Our own tabs: no system window tabs ("Show Tab Bar", merge windows).
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { showMainWindow() }
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    /// Dock click with no window on screen: bring the window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { MainActor.assumeIsolated { showMainWindow() } }
        return true
    }

    /// Finder double-click / Open With / Dock drop — before or after launch: every file becomes a tab.
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            showMainWindow()
            AudioOpenCoordinator.shared.handleExternalOpen(urls: urls)
        }
    }

    @MainActor
    private func showMainWindow() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let hosting = NSHostingView(rootView: MocawaveRootView(store: TabStore.shared))
        if #available(macOS 13.0, *) {
            hosting.sizingOptions = []   // the window's size is ours (fixed height per drawers), not SwiftUI's
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 903, height: 188),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true   // the tab strip lives in the title bar
        window.titleVisibility = .hidden
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.title = "Mocawave"
        window.contentView = hosting
        if !window.setFrameUsingName("MocawaveMain") { window.center() }
        window.setFrameAutosaveName("MocawaveMain")
        self.window = window
        window.makeKeyAndOrderFront(nil)
    }
}

@main
struct MocawaveApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        // No SwiftUI-managed windows (see AppDelegate); this scene only carries the menu commands.
        Settings { EmptyView() }
            .commands { TabCommands(store: TabStore.shared) }
    }
}
