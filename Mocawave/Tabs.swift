import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Model

/// One open track. Keeps its own player (waveform, cues, stems, labels) and the drawers it had open, so
/// switching tabs never re-analyses anything.
@MainActor
final class PlayerTab: ObservableObject, Identifiable {
    let id = UUID()
    let viewModel: AudioPlayerViewModel
    var openDrawers: Set<InspectorDrawer> = []
    var camelotSelection: CamelotKey?

    init(viewModel: AudioPlayerViewModel? = nil) {
        self.viewModel = viewModel ?? AudioPlayerViewModel()
    }

    var isEmpty: Bool { viewModel.loadedURL == nil }
}

/// The single Mocawave window's tabs. Opening a file (Finder, ⌘O, drop) lands in a tab: the empty one if
/// there is one, the tab already showing that file, or a new tab next to the current one.
/// Only one tab plays at a time: starting one pauses the others.
@MainActor
final class TabStore: ObservableObject {
    static let shared = TabStore()

    @Published private(set) var tabs: [PlayerTab]
    @Published var selectedID: UUID
    private var watchers: [UUID: AnyCancellable] = [:]

    static let supportedContentTypes = ["mp3", "wav", "aac", "m4a", "flac", "aif", "aiff"]
        .compactMap { UTType(filenameExtension: $0) }

    init() {
        let first = PlayerTab()
        tabs = [first]
        selectedID = first.id
        watch(first)
    }

    var selected: PlayerTab { tabs.first { $0.id == selectedID } ?? tabs[0] }
    var selectedIndex: Int { tabs.firstIndex { $0.id == selectedID } ?? 0 }

    // MARK: Opening

    /// Opens every file in its own tab; the last one is selected (and plays).
    func open(urls: [URL]) {
        for (i, url) in urls.enumerated() { open(url, select: i == urls.count - 1) }
    }

    func open(_ url: URL, select: Bool = true) {
        if let existing = tabs.first(where: { $0.viewModel.loadedURL?.standardizedFileURL == url.standardizedFileURL }) {
            if select { selectedID = existing.id }
            return
        }
        let target: PlayerTab
        if selected.isEmpty {
            target = selected
        } else if let empty = tabs.first(where: \.isEmpty) {
            target = empty
        } else {
            target = PlayerTab()
            tabs.insert(target, at: min(selectedIndex + 1, tabs.count))
            watch(target)
        }
        if select { selectedID = target.id }
        target.viewModel.open(url: url)
        if !select { target.viewModel.pause() }
    }

    /// File > Open… (⌘O): several files at once → several tabs.
    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = Self.supportedContentTypes
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        let handle: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK else { return }
            self?.open(urls: panel.urls)
        }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            panel.beginSheetModal(for: window, completionHandler: handle)
        } else {
            handle(panel.runModal())
        }
    }

    // MARK: Tabs

    func newTab() {
        if let empty = tabs.first(where: \.isEmpty) {
            selectedID = empty.id
            return
        }
        let tab = PlayerTab()
        tabs.insert(tab, at: min(selectedIndex + 1, tabs.count))
        watch(tab)
        selectedID = tab.id
    }

    func close(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs[index]
        tab.viewModel.stopAndReset()
        watchers[id] = nil
        tabs.remove(at: index)
        if tabs.isEmpty {
            let fresh = PlayerTab()
            tabs = [fresh]
            watch(fresh)
            selectedID = fresh.id
        } else if selectedID == id {
            selectedID = tabs[min(index, tabs.count - 1)].id   // the right neighbour, else the left one
        }
    }

    /// ⌘W: closes the tab; on the last, empty tab it closes the window (like a browser).
    func closeSelectedOrWindow() {
        if tabs.count == 1, selected.isEmpty {
            (NSApp.keyWindow ?? NSApp.mainWindow)?.performClose(nil)
        } else {
            close(selectedID)
        }
    }

    func closeAll() {
        tabs.forEach { $0.viewModel.stopAndReset() }
    }

    func select(index: Int) {
        guard !tabs.isEmpty else { return }
        selectedID = tabs[min(max(index, 0), tabs.count - 1)].id
    }

    func selectNext(_ step: Int) {
        guard !tabs.isEmpty else { return }
        selectedID = tabs[(selectedIndex + step + tabs.count) % tabs.count].id
    }

    func move(_ id: UUID, to destination: Int) {
        guard let from = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs.remove(at: from)
        tabs.insert(tab, at: min(max(destination, 0), tabs.count))
    }

    private func watch(_ tab: PlayerTab) {
        let id = tab.id
        watchers[id] = tab.viewModel.$isPlaying
            .removeDuplicates()
            .filter { $0 }
            .sink { [weak self] _ in self?.pauseAll(except: id) }
    }

    private func pauseAll(except id: UUID) {
        for tab in tabs where tab.id != id && tab.viewModel.isPlaying {
            tab.viewModel.pause()
        }
    }
}

// MARK: - Window root

/// The window: browser-style tab strip in the title bar, the selected tab's player below.
struct MocawaveRootView: View {
    @ObservedObject var store: TabStore

    var body: some View {
        ContentView(tab: store.selected)
            .id(store.selectedID)
        .configureWindow { window in
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.tabbingMode = .disallowed
        }
        .onChange(of: store.selectedID) { _ in
            let name = store.selected.viewModel.fileName
            (NSApp.keyWindow ?? NSApp.mainWindow)?.title = store.selected.isEmpty ? "Mocawave" : name
        }
    }
}

// MARK: - Tab strip

enum TabStripMetrics {
    /// Room for the traffic lights.
    static let leadingInset: CGFloat = 80
    static let height: CGFloat = 30
    static let tabHeight: CGFloat = 26
    static let minTabWidth: CGFloat = 96
    static let maxTabWidth: CGFloat = 230
    static let addButtonWidth: CGFloat = 28
    static let radius: CGFloat = 8
}

/// Tabs in the title bar, next to the traffic lights. Empty space still drags the window; double-click
/// zooms it (title bar behaviour). The selected tab is a raised card that flows into the top bar below.
struct TabStrip: View {
    @ObservedObject var store: TabStore
    @State private var dragging: UUID?
    @State private var dragOffset: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let available = geo.size.width - TabStripMetrics.leadingInset - TabStripMetrics.addButtonWidth - 16
            let width = min(TabStripMetrics.maxTabWidth,
                            max(TabStripMetrics.minTabWidth, available / CGFloat(max(store.tabs.count, 1))))
            HStack(alignment: .bottom, spacing: 0) {
                ForEach(Array(store.tabs.enumerated()), id: \.element.id) { index, tab in
                    TabItem(viewModel: tab.viewModel,
                            isSelected: tab.id == store.selectedID,
                            showsDivider: !isSelectedOrBeforeSelected(index),
                            onSelect: { store.selectedID = tab.id },
                            onClose: { withAnimation(MocaMotion.state) { store.close(tab.id) } })
                        .frame(width: width)
                        .offset(x: dragging == tab.id ? dragOffset : 0)
                        .zIndex(dragging == tab.id ? 1 : 0)
                        .gesture(reorderGesture(for: tab, index: index, width: width))
                        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottom)))
                }
                AddTabButton { withAnimation(MocaMotion.state) { store.newTab() } }
                    .frame(width: TabStripMetrics.addButtonWidth, height: TabStripMetrics.tabHeight)
                    .padding(.leading, 4)
                Spacer(minLength: 0)
            }
            .padding(.leading, TabStripMetrics.leadingInset)
            .frame(height: TabStripMetrics.height, alignment: .bottom)
            .background(windowDragArea)
        }
        .frame(height: TabStripMetrics.height)
        .animation(MocaMotion.state, value: store.tabs.map(\.id))
    }

    @ViewBuilder
    private var windowDragArea: some View {
        #if MOCA_SNAPSHOT
        Color.clear
        #else
        WindowDragArea()
        #endif
    }

    /// Dividers sit between unselected tabs only (none touching the raised card), like browser tabs.
    private func isSelectedOrBeforeSelected(_ index: Int) -> Bool {
        let selected = store.selectedIndex
        return index == selected || index + 1 == selected || index == store.tabs.count - 1
    }

    /// Drag a tab sideways to reorder it.
    private func reorderGesture(for tab: PlayerTab, index: Int, width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                dragging = tab.id
                dragOffset = value.translation.width
            }
            .onEnded { value in
                let steps = Int((value.translation.width / width).rounded())
                withAnimation(MocaMotion.state) {
                    if steps != 0 { store.move(tab.id, to: index + steps) }
                    dragging = nil
                    dragOffset = 0
                }
                store.selectedID = tab.id
            }
    }
}

private struct TabItem: View {
    @ObservedObject var viewModel: AudioPlayerViewModel
    let isSelected: Bool
    let showsDivider: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 6) {
            statusIcon
                .frame(width: 12)
            // Name truncates in the middle; the extension always shows (mp3 vs flac vs m4a matters here).
            HStack(spacing: 0) {
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(0)
                if let ext = fileExtension {
                    Text("." + ext)
                        .lineLimit(1)
                        .fixedSize()
                        .opacity(0.55)
                        .layoutPriority(1)
                }
            }
            .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
            .foregroundColor(.white.opacity(isSelected ? 0.95 : (hovered ? 0.8 : 0.58)))
            .frame(maxWidth: .infinity, alignment: .leading)
            CloseTabButton(action: onClose)
                .opacity(isSelected || hovered ? 1 : 0)
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .frame(height: TabStripMetrics.tabHeight)
        .background(background)
        .overlay(alignment: .trailing) {
            if showsDivider && !hovered {
                Rectangle().fill(Color.white.opacity(0.14)).frame(width: 1, height: 14)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { hovered = $0 }
        .animation(MocaMotion.state, value: hovered)
        .help(viewModel.loadedURL?.lastPathComponent ?? "New tab")
        .accessibilityElement(children: .combine)
        .accessibilityLabel(viewModel.loadedURL?.lastPathComponent ?? title)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    private var title: String {
        guard let url = viewModel.loadedURL else { return "New Tab" }
        return url.deletingPathExtension().lastPathComponent
    }

    private var fileExtension: String? {
        guard let ext = viewModel.loadedURL?.pathExtension, !ext.isEmpty else { return nil }
        return ext.lowercased()
    }

    /// What the tab is doing, so you can tell at a glance without switching: playing, separating stems,
    /// analysing, idle.
    @ViewBuilder
    private var statusIcon: some View {
        if viewModel.isPlaying {
            Image(systemName: "speaker.wave.2.fill")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(.accentColor)
        } else if let p = viewModel.stemsState.displayProgress, viewModel.stemsState.isWorking {
            ProgressRing(progress: p)
        } else if viewModel.loadedURL == nil {
            Image(systemName: "plus.circle")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(.white.opacity(0.45))
        } else {
            Image(systemName: "waveform")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(.white.opacity(isSelected ? 0.75 : 0.45))
        }
    }

    @ViewBuilder
    private var background: some View {
        if isSelected {
            // No outline: the card is the same surface as the bar below, they read as one piece.
            BrowserTabShape(radius: TabStripMetrics.radius)
                .fill(MocaTheme.tabSelected)
                .padding(.horizontal, -TabStripMetrics.radius)   // the flares reach under the neighbours
        } else if hovered {
            RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.07)).padding(.vertical, 2)
        }
    }
}

/// Browser tab outline: rounded top corners and concave flares at the bottom, so the tab flows into the bar.
/// `open: true` draws the outline without the bottom edge (for the stroke).
struct BrowserTabShape: Shape {
    var radius: CGFloat
    var open = false

    func path(in rect: CGRect) -> Path {
        let r = radius
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.addArc(center: CGPoint(x: rect.minX, y: rect.maxY - r), radius: r,
                 startAngle: .degrees(90), endAngle: .degrees(0), clockwise: true)
        p.addLine(to: CGPoint(x: rect.minX + r, y: rect.minY + r))
        p.addArc(center: CGPoint(x: rect.minX + 2 * r, y: rect.minY + r), radius: r,
                 startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        p.addLine(to: CGPoint(x: rect.maxX - 2 * r, y: rect.minY))
        p.addArc(center: CGPoint(x: rect.maxX - 2 * r, y: rect.minY + r), radius: r,
                 startAngle: .degrees(270), endAngle: .degrees(0), clockwise: false)
        p.addLine(to: CGPoint(x: rect.maxX - r, y: rect.maxY - r))
        p.addArc(center: CGPoint(x: rect.maxX, y: rect.maxY - r), radius: r,
                 startAngle: .degrees(180), endAngle: .degrees(90), clockwise: true)
        if !open { p.closeSubpath() }
        return p
    }
}

private struct ProgressRing: View {
    let progress: Double

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.18), lineWidth: 1.5)
            Circle().trim(from: 0, to: progress)
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 10, height: 10)
        .help("Separating stems · \(Int(progress * 100))%")
    }
}

private struct CloseTabButton: View {
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 7.5, weight: .bold))
                .foregroundColor(.white.opacity(hovered ? 0.95 : 0.6))
                .frame(width: 16, height: 16)
                .background(Circle().fill(Color.white.opacity(hovered ? 0.14 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help("Close tab (⌘W)")
        .accessibilityLabel("Close tab")
    }
}

private struct AddTabButton: View {
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.white.opacity(hovered ? 0.95 : 0.6))
                .frame(width: 22, height: 22)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(hovered ? 0.1 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help("New tab (⌘T)")
        .accessibilityLabel("New tab")
    }
}

/// Empty title-bar space behaves like a title bar: drag moves the window, double-click zooms.
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        #if MOCA_SNAPSHOT
        NSView()
        #else
        DragView()
        #endif
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                window?.performZoom(nil)
            } else {
                window?.performDrag(with: event)
            }
        }
    }
}

// MARK: - Menu commands

struct TabCommands: Commands {
    let store: TabStore

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Tab") { store.newTab() }
                .keyboardShortcut("t")
            Button("Open…") { store.presentOpenPanel() }
                .keyboardShortcut("o")
            Divider()
            // Listed before the system "Close" so ⌘W closes the tab, not the window.
            Button("Close Tab") { store.closeSelectedOrWindow() }
                .keyboardShortcut("w")
        }
        CommandMenu("Tab") {
            Button("Show Next Tab") { store.selectNext(1) }
                .keyboardShortcut(.tab, modifiers: .control)
            Button("Show Previous Tab") { store.selectNext(-1) }
                .keyboardShortcut(.tab, modifiers: [.control, .shift])
            Button("Next Tab") { store.selectNext(1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
            Button("Previous Tab") { store.selectNext(-1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
            Divider()
            ForEach(1..<9) { n in
                Button("Tab \(n)") { store.select(index: n - 1) }
                    .keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: .command)
            }
            Button("Last Tab") { store.select(index: store.tabs.count - 1) }
                .keyboardShortcut("9", modifiers: .command)
        }
    }
}

// MARK: - Drops

extension TabStore {
    /// Files dropped on the window: each one in a tab (the current tab if it's empty).
    func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !fileProviders.isEmpty else { return false }
        let group = DispatchGroup()
        var urls = [URL?](repeating: nil, count: fileProviders.count)
        let lock = NSLock()
        for (i, provider) in fileProviders.enumerated() {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                let url = (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) } ?? (item as? URL)
                lock.lock(); urls[i] = url; lock.unlock()
                group.leave()
            }
        }
        group.notify(queue: .main) { [weak self] in
            // Our own stem exports dragged back over the window (a lane drag that ended here) aren't tracks
            // to open: without this, letting go of a stem over Mocawave opened it as a new tab.
            let exports = StemExport.root.standardizedFileURL.path
            let found = urls.compactMap { $0 }.filter { !$0.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(exports) }
            let supported = Set(["mp3", "wav", "aac", "m4a", "flac", "aif", "aiff"])
            MainActor.assumeIsolated {
                self?.open(urls: found.filter { supported.contains($0.pathExtension.lowercased()) })
            }
        }
        return true
    }
}
