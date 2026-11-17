import AppKit
import Foundation

/// Finder "Open With", double-clicks and dock drops: every file opens in a tab of the single window.
@MainActor
final class AudioOpenCoordinator {
    static let shared = AudioOpenCoordinator()

    private init() {}

    func handleExternalOpen(urls: [URL]) {
        guard !urls.isEmpty else { return }
        TabStore.shared.open(urls: urls)
        NSApp.activate(ignoringOtherApps: true)
    }
}
