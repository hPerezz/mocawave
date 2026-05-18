import AppKit
import Foundation

@MainActor
final class AudioOpenCoordinator {
    static let shared = AudioOpenCoordinator()

    private final class Entry {
        weak var window: NSWindow?
        weak var viewModel: AudioPlayerViewModel?

        init(window: NSWindow, viewModel: AudioPlayerViewModel) {
            self.window = window
            self.viewModel = viewModel
        }
    }

    private var entries: [Entry] = []
    private var pendingURL: URL?

    private init() {}

    func register(window: NSWindow, viewModel: AudioPlayerViewModel) {
        entries.removeAll { $0.window == nil || $0.viewModel == nil || $0.window === window }
        entries.append(Entry(window: window, viewModel: viewModel))

        if let pendingURL {
            self.pendingURL = nil
            _ = viewModel.open(url: pendingURL)
        }
    }

    func unregister(window: NSWindow) {
        entries.removeAll { $0.window == nil || $0.viewModel == nil || $0.window === window }
    }

    func handleExternalOpen(urls: [URL]) {
        guard let url = urls.reversed().first else { return }
        pruneReleasedEntries()

        if let targetViewModel = activeViewModel() {
            _ = targetViewModel.open(url: url)
            return
        }

        pendingURL = url
    }

    private func activeViewModel() -> AudioPlayerViewModel? {
        let candidateWindows = [NSApp.keyWindow, NSApp.mainWindow].compactMap { $0 }

        for candidateWindow in candidateWindows {
            if let entry = entries.first(where: { $0.window === candidateWindow }),
               let viewModel = entry.viewModel {
                return viewModel
            }
        }

        return entries.compactMap(\.viewModel).first
    }

    private func pruneReleasedEntries() {
        entries.removeAll { $0.window == nil || $0.viewModel == nil }
    }
}
