import SwiftUI

// MARK: - Layout

/// The strip's column grid, so stem lanes line up in time with the main waveform above them: the left column
/// sits under the play button, the right one under the mascot, the middle one is exactly the waveform box.
struct StemLaneColumns: Equatable {
    /// Width under the play button (drawer content starts 12 pt in, the waveform box 68 pt in: 56).
    var leading: CGFloat
    /// Width under the mascot slot.
    var trailing: CGFloat
}

/// Everything the drawer can ask the player to do.
struct StemLaneActions {
    var separate: () -> Void = {}
    var cancel: () -> Void = {}
    var seek: (Double) -> Void = { _ in }
    var toggleMute: (StemKind) -> Void = { _ in }
    var toggleSolo: (StemKind, _ exclusive: Bool) -> Void = { _, _ in }
    var setVolume: (StemKind, Double) -> Void = { _, _ in }
    var resetMix: () -> Void = {}
    var startEngine: () -> Void = {}
    var muteAll: () -> Void = {}
    var clearSolo: () -> Void = {}
    /// The stem as a WAV for a DAW (exported on first use); nil if it can't be made.
    var exportFile: (StemKind) -> URL? = { _ in nil }
}

enum StemLaneMetrics {
    static let laneHeight: CGFloat = 34
    static let collapsedHeight: CGFloat = 16
    /// Track header column (name, M/S, fader + dB), DAW-style on the left.
    static let headerWidth: CGFloat = 176
    static let headerGap: CGFloat = 8
    /// Global row on top: ALL M/S + section ruler.
    static let globalRowHeight: CGFloat = 16
    static let spacing: CGFloat = 4
    /// Idle / offline / failed: one message block.
    static let messageHeight: CGFloat = 46
    static let maxVolume = 1.5
    static let unityDetent = 0.05

    static func height(of lane: StemLane) -> CGFloat { lane.isNearlySilent ? collapsedHeight : laneHeight }
}

extension StemsState {
    /// The drawer's progress bar: separation is 0–96 %, copying into the cache the rest, so it never runs back.
    var displayProgress: Double? {
        switch self {
        case .separating(let p, _, _): return min(max(p, 0), 1) * 0.96
        case .downloading(let p): return 0.96 + min(max(p, 0), 1) * 0.04
        case .loading: return 1
        default: return nil
        }
    }

    /// Short stage name for the progress row (agent stages: loading · separating · writing).
    var stageLabel: String {
        switch self {
        case .queued(let position): return position > 1 ? "Queued · \(position - 1) ahead" : "Starting"
        case .separating(_, _, let stage):
            switch stage {
            case "loading": return "Loading model"
            case "writing": return "Saving"
            default: return "Separating"
            }
        case .downloading: return "Saving"
        case .loading: return "Loading stems"
        default: return ""
        }
    }

    /// "~1:20 left", nil while the agent can't tell yet.
    var etaText: String? {
        guard case .separating(_, let eta?, _) = self, eta.isFinite, eta >= 0 else { return nil }
        let s = max(1, Int(eta.rounded()))
        return String(format: "~%d:%02d left", s / 60, s % 60)
    }

    /// Lanes are shown (skeleton or real) in these states; the rest are a single message line.
    var showsLanes: Bool { isWorking || self == .ready }
}

extension StemLane {
    /// Fader readout: "0.0", "+3.5", "−6.0", "−∞".
    static func dbText(_ volume: Double) -> String {
        guard volume > 0.0001 else { return "−∞" }
        let db = 20 * log10(volume)
        if abs(db) < 0.05 { return "0.0" }
        return (db > 0 ? "+" : "−") + String(format: "%.1f", abs(db))
    }
}

// MARK: - Drawer

/// Stems drawer: "Separate stems" → progress with skeleton lanes → one lane per stem, like a tiny DAW.
/// Lanes are time-aligned with the main waveform (same column grid), share its playhead and seek on click.
struct StemLanesView: View {
    let state: StemsState
    let lanes: [StemLane]
    let progress: Double
    let hasTrack: Bool
    let columns: StemLaneColumns
    var actions = StemLaneActions()
    var engine: EngineStartState = .idle
    /// The track's sections (from the cue flags above), tinted behind the lanes so the arrangement reads
    /// across stems.
    var sections: [WaveformSection] = []

    /// How many lanes have been revealed (they come in one by one when separation finishes).
    @State private var revealed: Int
    @State private var revealGeneration = 0

    init(state: StemsState, lanes: [StemLane], progress: Double, hasTrack: Bool, columns: StemLaneColumns,
         actions: StemLaneActions = StemLaneActions(), engine: EngineStartState = .idle,
         sections: [WaveformSection] = []) {
        self.engine = engine
        self.sections = sections
        self.state = state
        self.lanes = lanes
        self.progress = progress
        self.hasTrack = hasTrack
        self.columns = columns
        self.actions = actions
        // Opening the drawer on a ready track: lanes are simply there (the drawer has its own entrance).
        _revealed = State(initialValue: state == .ready ? lanes.count : 0)
    }

    static func contentHeight(state: StemsState, lanes: [StemLane]) -> CGFloat {
        if state == .ready, !lanes.isEmpty {
            return StemLaneMetrics.globalRowHeight + StemLaneMetrics.spacing
                + lanes.reduce(0) { $0 + StemLaneMetrics.height(of: $1) } + StemLaneMetrics.spacing * CGFloat(lanes.count - 1)
        }
        if state.isWorking {
            let n = CGFloat(StemKind.allCases.count)
            return n * StemLaneMetrics.laneHeight + (n - 1) * StemLaneMetrics.spacing
        }
        return StemLaneMetrics.messageHeight
    }

    static func panelHeight(state: StemsState, lanes: [StemLane]) -> CGFloat {
        InspectorDrawer.chromeHeight + contentHeight(state: state, lanes: lanes)
    }

    var body: some View {
        Group {
            if state.showsLanes {
                laneStack
            } else {
                message
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: RevealKey(ready: state == .ready, kinds: lanes.map(\.kind))) { key in reveal(key) }
    }

    // MARK: Lanes

    /// Slots: the real lanes once known (skeletons until revealed), six skeletons while separating.
    private var laneStack: some View {
        let ready = state == .ready && !lanes.isEmpty
        let anySolo = lanes.contains { $0.isSoloed }
        return VStack(spacing: StemLaneMetrics.spacing) {
            if ready {
                StemGlobalRow(allMuted: lanes.allSatisfy(\.isMuted), anySolo: anySolo, sections: sections,
                              columns: columns, actions: actions)
                ForEach(Array(lanes.enumerated()), id: \.element.kind) { index, lane in
                    StemLaneRow(lane: lane, index: index, anySolo: anySolo, isRevealed: index < revealed,
                                progress: progress, columns: columns, actions: actions)
                }
            } else {
                ForEach(Array(StemKind.allCases.enumerated()), id: \.element) { index, kind in
                    StemSkeletonRow(kind: kind, index: index, progress: state.displayProgress,
                                    height: StemLaneMetrics.laneHeight, columns: columns)
                }
            }
        }
        .background {
            if ready, !sections.isEmpty {
                SectionBackdrop(sections: sections, columns: columns)
                    .transition(.opacity)
            }
        }
        .overlay {
            if ready {
                PlayheadLayer(progress: progress, columns: columns, onSeek: actions.seek)
            }
        }
    }

    private struct RevealKey: Equatable {
        var ready: Bool
        var kinds: [StemKind]
    }

    /// Uses the key's values, not `self`: on macOS 12/13 onChange closures can see the previous view's
    /// properties (the cue flags never revealed because of that).
    private func reveal(_ key: RevealKey) {
        revealGeneration += 1
        let generation = revealGeneration
        guard key.ready, !key.kinds.isEmpty else {
            revealed = 0
            return
        }
        guard revealed < key.kinds.count else { return }
        if MocaMotion.reduceMotion {
            withAnimation(.easeOut(duration: 0.1)) { revealed = key.kinds.count }
            return
        }
        let start = revealed
        for i in start..<key.kinds.count {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06 + Double(i - start) * MocaMotion.staggerStep * 2) {
                guard generation == revealGeneration else { return }
                withAnimation(.easeOut(duration: 0.36)) { revealed = max(revealed, i + 1) }
            }
        }
    }

    // MARK: Messages (idle, offline, failed)

    @ViewBuilder
    private var message: some View {
        HStack(spacing: 0) {
            Spacer(minLength: columns.leading)
            Group {
                switch state {
                case .offline:
                    // Not a network problem: the local engine just isn't running. One click starts it, then
                    // the separation the user asked for carries on by itself.
                    VStack(spacing: 5) {
                        PrimaryDrawerButton(title: engine == .starting ? "Starting engine…" : "Start engine",
                                            icon: "power", isBusy: engine == .starting,
                                            isEnabled: engine != .starting,
                                            help: "Starts the local stems engine on this Mac, then separates the track",
                                            action: actions.startEngine)
                        subline(engineSubline)
                    }
                case .failed(let reason):
                    VStack(spacing: MocaSpace.xs) {
                        HStack(spacing: MocaSpace.s) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundColor(MocaTheme.Cue.drop)
                            Text("Separation failed: \(reason)")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(.white.opacity(0.86))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(reason)
                            QuietButton(title: "Retry", icon: "arrow.clockwise", action: actions.separate)
                        }
                        subline("The agent log has the details")
                    }
                default:
                    VStack(spacing: 5) {
                        SeparateButton(isEnabled: hasTrack && state != .unavailable, action: actions.separate)
                        subline(hasTrack ? "BS-Roformer · runs on this Mac · ~4 min" : "Open a track first")
                    }
                }
            }
            .frame(maxWidth: .infinity)
            Spacer(minLength: columns.trailing)
        }
        .frame(height: StemLaneMetrics.messageHeight)
        .transition(.opacity)
    }

    private var engineSubline: String {
        switch engine {
        case .starting: return "Loading on this Mac · no internet needed"
        case .notInstalled: return "One-time setup: run tools/install-mocawave-agent.sh"
        case .failed: return "It didn't start · details in dj-stack/agent/agent.log"
        case .idle: return "The stems engine isn't running · it works offline, on this Mac"
        }
    }

    private func subline(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .medium, design: .monospaced))
            .foregroundColor(.white.opacity(0.42))
            .lineLimit(1)
    }
}

// MARK: - Header accessory

/// Header row content, on the lanes' grid: progress while working, model + reset once ready.
struct StemsHeaderAccessory: View {
    let state: StemsState
    let modelName: String?
    let isMixDirty: Bool
    let trailingWidth: CGFloat
    let onCancel: () -> Void
    let onReset: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: MocaSpace.s) {
                if state.isWorking {
                    working
                } else if state == .ready {
                    ready
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // The close button (22) sits in the right column; keep the rest of that column free.
            Color.clear.frame(width: max(trailingWidth - 22, 0), height: 1)
        }
        .frame(height: 22)
        .animation(MocaMotion.state, value: state.isWorking)
    }

    @ViewBuilder
    private var working: some View {
        Text(state.stageLabel.uppercased())
            .font(.system(size: 8, weight: .semibold, design: .monospaced))
            .foregroundColor(.white.opacity(0.72))
            .lineLimit(1)
            .fixedSize()
        StemProgressBar(progress: state.displayProgress)
            .frame(height: 4)
        if let p = state.displayProgress {
            Text("\(Int((p * 100).rounded(.down)))%")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(.white.opacity(0.92))
                .monospacedDigit()
                .fixedSize()
        }
        if let eta = state.etaText {
            Text(eta)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(.white.opacity(0.5))
                .fixedSize()
        }
        QuietButton(title: "Cancel", icon: "stop.fill", action: onCancel)
            .help("Stop following the separation (the agent finishes it in the background)")
    }

    @ViewBuilder
    private var ready: some View {
        if let modelName {
            Text(modelName.uppercased())
                .font(.system(size: 7.5, weight: .bold, design: .monospaced))
                .foregroundColor(.white.opacity(0.72))
                .padding(.horizontal, 5)
                .frame(height: 13)
                .background(Capsule().fill(Color.white.opacity(0.08)))
                .help("Separated with \(modelName)")
        }
        HStack(spacing: 4) {
            Circle().fill(Color.accentColor).frame(width: 5, height: 5)
            Text("PLAYING STEMS")
                .font(.system(size: 7.5, weight: .semibold, design: .monospaced))
                .foregroundColor(.white.opacity(0.5))
        }
        .help("While this panel is open you hear the stem mix; close it to hear the file itself")
        Spacer(minLength: 0)
        if isMixDirty {
            QuietButton(title: "Reset", icon: "arrow.counterclockwise", action: onReset)
                .help("Unmute, unsolo and set every fader back to 0 dB")
                .transition(.opacity)
        }
    }
}

// MARK: - Pieces

/// The one primary action of the idle drawer.
private struct SeparateButton: View {
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        PrimaryDrawerButton(title: "Separate stems", icon: "slider.horizontal.3", isEnabled: isEnabled,
                            help: "Split the track into vocals, drums, bass, guitar, piano and other", action: action)
    }
}

/// The drawer's one primary action (Separate stems, Start engine).
struct PrimaryDrawerButton: View {
    let title: String
    let icon: String
    var isBusy = false
    var isEnabled = true
    let help: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if isBusy {
                    ProgressView().controlSize(.mini).colorScheme(.dark)
                } else {
                    Image(systemName: icon).font(.system(size: 10, weight: .semibold))
                }
                Text(title).font(.system(size: 11, weight: .semibold))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 14)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(hovered ? 1 : 0.86)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.16), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled || isBusy ? 1 : 0.4)
        .onHover { hovered = $0 }
        .animation(MocaMotion.state, value: hovered)
        .help(help)
        .accessibilityLabel(title)
    }
}

/// Small text button for secondary actions in the drawer (Cancel, Retry, Reset).
struct QuietButton: View {
    let title: String
    let icon: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 7, weight: .bold))
                Text(title).font(.system(size: 9, weight: .medium))
            }
            .foregroundColor(.white.opacity(hovered ? 0.95 : 0.66))
            .padding(.horizontal, 7)
            .frame(height: 16)
            .background(Capsule().fill(Color.white.opacity(hovered ? 0.12 : 0.06)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .fixedSize()
        .accessibilityLabel(title)
    }
}

/// Thin progress bar; indeterminate (nil) shows a sliding highlight instead.
struct StemProgressBar: View {
    let progress: Double?
    @State private var sweep = false

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.1))
                if let progress {
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: max(geo.size.height, geo.size.width * progress))
                        .animation(.linear(duration: 1), value: progress)   // the agent reports ~1×/s: glide
                } else {
                    Capsule()
                        .fill(Color.accentColor.opacity(0.7))
                        .frame(width: geo.size.width * 0.25)
                        .offset(x: sweep ? geo.size.width * 0.75 : 0)
                }
            }
            .clipShape(Capsule())
        }
        .onAppear {
            guard progress == nil, !MocaMotion.reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { sweep = true }
        }
        .accessibilityElement()
        .accessibilityLabel("Separation progress")
        .accessibilityValue(progress.map { "\(Int($0 * 100)) percent" } ?? "waiting")
    }
}

/// A lane while the stems don't exist yet: name, empty well, and the separation sweeping left to right
/// (the separator walks the track in time order, so the fill is literally where it is).
struct StemSkeletonRow: View {
    let kind: StemKind
    let index: Int
    let progress: Double?
    let height: CGFloat
    let columns: StemLaneColumns
    @State private var shimmer = false

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 3) {
                Image(systemName: kind.symbol).font(.system(size: 8, weight: .semibold))
                    .foregroundColor(kind.color.opacity(0.55))
                    .frame(width: 10)
                Text(kind.title).font(.system(size: 8, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.32))
            }
            .frame(width: columns.leading, alignment: .leading)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.035))
                    if let progress {
                        // Done part tinted, with a bright write head where the separator is.
                        ZStack(alignment: .trailing) {
                            LinearGradient(colors: [kind.color.opacity(0.03), kind.color.opacity(0.14)],
                                           startPoint: .leading, endPoint: .trailing)
                            Rectangle().fill(kind.color.opacity(0.75)).frame(width: 1.5)
                        }
                        .frame(width: max(geo.size.width * progress, 1.5))
                        .animation(.linear(duration: 1), value: progress)
                    }
                    if !MocaMotion.reduceMotion {
                        LinearGradient(colors: [.clear, Color.white.opacity(0.07), .clear],
                                       startPoint: .leading, endPoint: .trailing)
                            .frame(width: 90)
                            .offset(x: shimmer ? geo.size.width : -90)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }

            HStack(spacing: 0) {
                Spacer(minLength: 8)
                Capsule().fill(Color.white.opacity(0.08)).frame(height: 3)
            }
            .frame(width: columns.trailing)
        }
        .frame(height: height)
        .onAppear {
            guard !MocaMotion.reduceMotion else { return }
            // Diagonal sweep: each lane a beat after the one above.
            withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false).delay(Double(index) * 0.08)) {
                shimmer = true
            }
        }
        .accessibilityHidden(true)
    }
}

/// One stem, DAW-style: track header on the left (name, M/S, fader + dB), its waveform to the right
/// (played part full colour). Drag the name into Ableton/Finder to get the stem as a WAV with the tempo.
struct StemLaneRow: View {
    let lane: StemLane
    let index: Int
    let anySolo: Bool
    let isRevealed: Bool
    let progress: Double
    let columns: StemLaneColumns
    let actions: StemLaneActions

    private var isAudible: Bool { lane.gain(anySolo: anySolo) > 0 }
    private var collapsed: Bool { lane.isNearlySilent }
    private var height: CGFloat { StemLaneMetrics.height(of: lane) }

    var body: some View {
        HStack(spacing: 0) {
            header
                .padding(.horizontal, 6)
                .frame(width: columns.leading - StemLaneMetrics.headerGap, height: height, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.04)))
            Color.clear.frame(width: StemLaneMetrics.headerGap)
            waveform
        }
        .frame(height: height)
        .opacity(collapsed ? 0.72 : 1)
        .contextMenu { fileMenu }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(lane.kind.rawValue)
    }

    @ViewBuilder
    private var header: some View {
        if collapsed {
            HStack(spacing: 4) {
                dragHandle(small: true)
                Spacer(minLength: 2)
                toggles(small: true)
                fader(compact: true).frame(width: 46)
            }
        } else {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 4) {
                    dragHandle(small: false)
                    Spacer(minLength: 4)
                    toggles(small: false)
                }
                HStack(spacing: 6) {
                    fader(compact: false)
                    Text(StemLane.dbText(lane.volume) + " dB")
                        .font(.system(size: 8, weight: .semibold, design: .monospaced))
                        .foregroundColor(.white.opacity(lane.volume == 1 ? 0.42 : 0.86))
                        .lineLimit(1)
                        .frame(width: 42, alignment: .trailing)
                }
            }
        }
    }

    /// Icon + name: the grip you drag into a DAW (or Finder).
    private func dragHandle(small: Bool) -> some View {
        StemDragHandle(kind: lane.kind, small: small, isAudible: isAudible, exportFile: actions.exportFile)
    }

    private func fader(compact: Bool) -> some View {
        StemFader(volume: lane.volume, color: lane.kind.color, isAudible: isAudible, compact: compact) {
            actions.setVolume(lane.kind, $0)
        }
    }

    @ViewBuilder
    private var fileMenu: some View {
        Button("Copy \(lane.kind.rawValue.capitalized) as File (paste in Finder)") {
            guard let url = actions.exportFile(lane.kind) else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([url as NSURL])
        }
        Button("Show \(lane.kind.rawValue.capitalized) in Finder") {
            guard let url = actions.exportFile(lane.kind) else { return }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    private func toggles(small: Bool) -> some View {
        HStack(spacing: 3) {
            MixToggle(letter: "M", isOn: lane.isMuted, color: MocaTheme.Mix.mute, small: small,
                      help: "Mute \(lane.kind.rawValue) (\(index + 1))") { _ in actions.toggleMute(lane.kind) }
            MixToggle(letter: "S", isOn: lane.isSoloed, color: MocaTheme.Mix.solo, small: small,
                      help: "Solo \(lane.kind.rawValue) (⌥-click: solo only this)") { exclusive in
                actions.toggleSolo(lane.kind, exclusive)
            }
        }
    }

    private var waveform: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.03))
            ZStack {
                StemWaveformCanvas(peaks: lane.peaks, color: unplayedColor).equatable()
                StemWaveformCanvas(peaks: lane.peaks, color: playedColor).equatable()
                    .mask(alignment: .leading) {
                        GeometryReader { geo in
                            Rectangle().frame(width: geo.size.width * min(max(progress, 0), 1))
                        }
                    }
            }
            .padding(.vertical, 2)
            .mask(alignment: .leading) {
                // Reveal: a left-to-right wipe, like the lane being written.
                Rectangle().scaleEffect(x: isRevealed ? 1 : 0.001, anchor: .leading)
            }
            .opacity(isRevealed ? 1 : 0)
            if collapsed {
                // On a tag so the flat line doesn't run through it.
                Text("\(lane.kind.title) · SILENT")
                    .font(.system(size: 7, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.4))
                    .padding(.horizontal, 4)
                    .frame(height: 10)
                    .background(RoundedRectangle(cornerRadius: 2.5).fill(Color(white: 0.1)))
                    .padding(.leading, 4)
                    .allowsHitTesting(false)
                    .help("Nearly silent in this track (\(Int((lane.rmsDb ?? 0).rounded())) dB RMS); still mutable and soloable")
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .animation(MocaMotion.state, value: isAudible)
    }

    private var playedColor: Color { isAudible ? lane.kind.color : Color.white.opacity(0.26) }
    private var unplayedColor: Color { isAudible ? lane.kind.color.opacity(0.38) : Color.white.opacity(0.1) }
}

/// M / S square. ⌥-click passes `exclusive = true` (solo only this lane).
struct MixToggle: View {
    let letter: String
    let isOn: Bool
    let color: Color
    let small: Bool
    let help: String
    let action: (_ exclusive: Bool) -> Void
    @State private var hovered = false

    var body: some View {
        Button {
            action(NSEvent.modifierFlags.contains(.option))
        } label: {
            Text(letter)
                .font(.system(size: small ? 6.5 : 7.5, weight: .heavy, design: .monospaced))
                .foregroundColor(isOn ? .black.opacity(0.85) : .white.opacity(hovered ? 0.9 : 0.55))
                .frame(width: small ? 13 : 17, height: small ? 10 : 12)
                .background(RoundedRectangle(cornerRadius: 2.5)
                    .fill(isOn ? color : Color.white.opacity(hovered ? 0.14 : 0.07)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(MocaMotion.state, value: isOn)
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// Compact horizontal fader, 0…1.5 (unity at 2/3 with a detent). Drag is relative (no jump on click);
/// double-click resets to unity.
struct StemFader: View {
    let volume: Double
    let color: Color
    let isAudible: Bool
    let compact: Bool
    let onChange: (Double) -> Void

    @State private var dragStart: Double?
    @State private var hovered = false

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let thumbW: CGFloat = compact ? 5 : 6
            let x = CGFloat(volume / StemLaneMetrics.maxVolume) * (w - thumbW)
            let unityX = CGFloat(1 / StemLaneMetrics.maxVolume) * (w - thumbW) + thumbW / 2
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12)).frame(height: compact ? 2 : 3)
                Capsule().fill((isAudible ? color : Color.white).opacity(isAudible ? 0.7 : 0.25))
                    .frame(width: max(x + thumbW / 2, 0), height: compact ? 2 : 3)
                Rectangle().fill(Color.white.opacity(0.35))
                    .frame(width: 1, height: compact ? 6 : 8)
                    .offset(x: unityX - 0.5)
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.white.opacity(hovered || dragStart != nil ? 1 : 0.86))
                    .frame(width: thumbW, height: compact ? 8 : 11)
                    .shadow(color: .black.opacity(0.4), radius: 1, y: 0.5)
                    .offset(x: x)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let start = dragStart ?? volume
                        if dragStart == nil { dragStart = start }
                        var v = start + Double(value.translation.width / max(w - thumbW, 1)) * StemLaneMetrics.maxVolume
                        v = min(max(v, 0), StemLaneMetrics.maxVolume)
                        if abs(v - 1) < StemLaneMetrics.unityDetent { v = 1 }
                        onChange(v)
                    }
                    .onEnded { _ in dragStart = nil }
            )
            .simultaneousGesture(TapGesture(count: 2).onEnded { onChange(1) })
        }
        .frame(height: compact ? 10 : 12)
        .onHover { hovered = $0 }
        .help("Volume \(StemLane.dbText(volume)) dB · double-click for 0 dB")
        .accessibilityElement()
        .accessibilityLabel("Volume")
        .accessibilityValue("\(StemLane.dbText(volume)) decibels")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onChange(min(volume + 0.05, StemLaneMetrics.maxVolume))
            case .decrement: onChange(max(volume - 0.05, 0))
            @unknown default: break
            }
        }
    }
}

/// A stem's peak envelope as the main waveform draws it (2 pt bars, 1 pt gaps), so lanes and strip share bars.
/// Equatable: redrawn only when the envelope, colour or size change, not on every playhead tick.
struct StemWaveformCanvas: View, Equatable {
    let peaks: [Float]
    let color: Color

    var body: some View {
        Canvas { context, size in
            guard !peaks.isEmpty, size.width > 0 else { return }
            let barWidth: CGFloat = 2, gap: CGFloat = 1
            let count = max(1, Int((size.width + gap) / (barWidth + gap)))
            let bars = Self.resample(peaks, to: count)
            var path = Path()
            for i in 0..<count {
                let h = max(1, CGFloat(bars[i]) * size.height)
                path.addRoundedRect(in: CGRect(x: CGFloat(i) * (barWidth + gap), y: (size.height - h) / 2, width: barWidth, height: h),
                                    cornerSize: CGSize(width: 1, height: 1))
            }
            context.fill(path, with: .color(color))
        }
    }

    /// Max per bucket (down) or linear (up).
    static func resample(_ values: [Float], to count: Int) -> [Float] {
        guard !values.isEmpty, count > 0 else { return [] }
        if values.count == count { return values }
        if values.count < count {
            let scale = Double(values.count - 1) / Double(max(count - 1, 1))
            return (0..<count).map { i in
                let p = Double(i) * scale
                let lo = Int(p), hi = min(lo + 1, values.count - 1)
                return values[lo] + (values[hi] - values[lo]) * Float(p - Double(lo))
            }
        }
        let bucket = Double(values.count) / Double(count)
        return (0..<count).map { i in
            let start = Int(Double(i) * bucket)
            let end = min(max(start + 1, Int(Double(i + 1) * bucket)), values.count)
            var m: Float = 0
            for j in start..<end where values[j] > m { m = values[j] }
            return m
        }
    }
}

/// Shared playhead over every lane's waveform column, plus click / drag to seek and a hover line.
private struct PlayheadLayer: View {
    let progress: Double
    let columns: StemLaneColumns
    let onSeek: (Double) -> Void
    @State private var hoverX: CGFloat?

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: columns.leading).frame(width: columns.leading).allowsHitTesting(false)
            GeometryReader { geo in
                let w = max(geo.size.width, 1)
                ZStack(alignment: .topLeading) {
                    if let hoverX {
                        Rectangle().fill(Color.white.opacity(0.22)).frame(width: 1).offset(x: hoverX)
                    }
                    Rectangle().fill(Color.white.opacity(0.9)).frame(width: 1)
                        .shadow(color: .black.opacity(0.5), radius: 1)
                        .offset(x: w * min(max(progress, 0), 1) - 0.5)
                    MouseTrackingView(onMove: { hoverX = min(max($0, 0), w) }, onExit: { hoverX = nil })
                }
                .frame(width: w, height: geo.size.height, alignment: .topLeading)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    onSeek(min(max(value.location.x / w, 0), 1))
                })
            }
            Spacer(minLength: columns.trailing).frame(width: columns.trailing).allowsHitTesting(false)
        }
        .accessibilityHidden(true)
    }
}


/// Section markers behind the stem lanes: a faint wash of each section's colour (drop red, build amber,
/// break purple, intro/outro blue) and a thin locator line where it starts. Only in the waveform column,
/// under the lanes, so the waveforms stay the stems' own colours.
struct SectionBackdrop: View, Equatable {
    let sections: [WaveformSection]
    let columns: StemLaneColumns

    static let washOpacity = 0.10
    static let lineOpacity = 0.45

    var body: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: columns.leading)
            Canvas { context, size in
                let sorted = sections.sorted { $0.start < $1.start }
                for (i, section) in sorted.enumerated() {
                    let x0 = size.width * CGFloat(min(max(section.start, 0), 1))
                    let x1 = size.width * CGFloat(i + 1 < sorted.count ? min(max(sorted[i + 1].start, 0), 1) : 1)
                    guard x1 > x0 else { continue }
                    context.fill(Path(CGRect(x: x0, y: 0, width: x1 - x0, height: size.height)),
                                 with: .color(section.color.opacity(Self.washOpacity)))
                    context.fill(Path(CGRect(x: x0, y: 0, width: 1, height: size.height)),
                                 with: .color(section.color.opacity(Self.lineOpacity)))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 4))
            Color.clear.frame(width: columns.trailing)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}


/// The lane's name as a drag source: drop it in Ableton (or Finder) and the stem arrives as a WAV,
/// aligned with the track and carrying its tempo.
struct StemDragHandle: View {
    let kind: StemKind
    let small: Bool
    let isAudible: Bool
    let exportFile: (StemKind) -> URL?
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: hovered ? "hand.draw" : kind.symbol)
                .font(.system(size: small ? 7 : 8, weight: .semibold))
                .foregroundColor(kind.color.opacity(isAudible ? 1 : 0.4))
                .frame(width: 10)
            Text(kind.title)
                .font(.system(size: small ? 7 : 8, weight: .semibold, design: .monospaced))
                .foregroundColor(.white.opacity(isAudible ? (hovered ? 1 : 0.86) : 0.4))
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.vertical, 1)
        .contentShape(Rectangle())
        .onHover { inside in
            hovered = inside
            if inside { NSCursor.openHand.push() } else { NSCursor.pop() }
        }
        .onDrag {
            guard let url = exportFile(kind) else { return NSItemProvider() }
            let provider = NSItemProvider(object: url as NSURL)
            provider.suggestedName = url.lastPathComponent
            return provider
        }
        .help("Drag onto Ableton (or Finder): \(kind.rawValue) as a WAV aligned with the track, tempo included. Ableton doesn't paste files from the clipboard, so drag it.")
        .accessibilityLabel("\(kind.rawValue) stem, draggable as a file")
    }
}

/// Top row: ALL M (mute / unmute every lane) and S (solo clear), aligned with the lanes' M/S, and a ruler
/// with the section letters over the lanes.
struct StemGlobalRow: View {
    let allMuted: Bool
    let anySolo: Bool
    let sections: [WaveformSection]
    let columns: StemLaneColumns
    let actions: StemLaneActions

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 4) {
                Text("ALL")
                    .font(.system(size: 7.5, weight: .semibold, design: .monospaced))
                    .foregroundColor(.secondary)
                Spacer(minLength: 4)
                MixToggle(letter: "M", isOn: allMuted, color: MocaTheme.Mix.mute, small: false,
                          help: allMuted ? "Unmute all stems" : "Mute all stems") { _ in actions.muteAll() }
                MixToggle(letter: "S", isOn: anySolo, color: MocaTheme.Mix.solo, small: false,
                          help: anySolo ? "Clear solo" : "No stem soloed") { _ in actions.clearSolo() }
                    .disabled(!anySolo)
            }
            .padding(.horizontal, 6)
            .frame(width: columns.leading - StemLaneMetrics.headerGap, alignment: .leading)
            Color.clear.frame(width: StemLaneMetrics.headerGap)
            SectionRuler(sections: sections)
        }
        .frame(height: StemLaneMetrics.globalRowHeight)
    }
}

/// Section letters at their start, like locators over an arrangement.
private struct SectionRuler: View {
    let sections: [WaveformSection]

    var body: some View {
        GeometryReader { geo in
            ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                if let label = section.label {
                    Text(label)
                        .font(.system(size: 7, weight: .heavy, design: .monospaced))
                        .foregroundColor(.white.opacity(0.92))
                        .frame(width: 11, height: 11)
                        .background(RoundedRectangle(cornerRadius: 2).fill(section.color.opacity(0.85)))
                        .offset(x: geo.size.width * CGFloat(min(max(section.start, 0), 1)) + 2,
                                y: (geo.size.height - 11) / 2)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
