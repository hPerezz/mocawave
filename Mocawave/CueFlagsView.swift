import AppKit
import SwiftUI

/// Cue flags drawn over the waveform: a thin line through the wave plus a lettered tag at the top.
/// Freshly detected cues drop in one by one, left to right; a line flashes where each one lands.
struct CueFlagsOverlay: View {
    let cues: [Cue]
    let duration: Double
    let grid: BeatGrid?
    /// Animate the reveal (true right after detection; cached cues just appear).
    let animateIn: Bool
    @Binding var selectedID: UUID?
    let onSeek: (Double) -> Void
    let onMove: (_ id: UUID, _ time: Double, _ snap: Bool) -> Void

    @State private var visible: Set<UUID> = []
    @State private var flashing: Set<UUID> = []
    @State private var hoveredID: UUID?
    @State private var drag: (id: UUID, dx: CGFloat)?
    @State private var revealGeneration = 0

    init(cues: [Cue], duration: Double, grid: BeatGrid?, animateIn: Bool, selectedID: Binding<UUID?>,
         onSeek: @escaping (Double) -> Void, onMove: @escaping (_ id: UUID, _ time: Double, _ snap: Bool) -> Void,
         revealed: Bool = false) {
        self.cues = cues
        self.duration = duration
        self.grid = grid
        self.animateIn = animateIn
        _selectedID = selectedID
        self.onSeek = onSeek
        self.onMove = onMove
        _visible = State(initialValue: revealed ? Set(cues.map(\.id)) : [])
    }

    static let tagSize: CGFloat = 14
    private let tagTop: CGFloat = 4

    var body: some View {
        GeometryReader { geo in
            let rows = tagRows(width: geo.size.width)
            ZStack(alignment: .topLeading) {
                ForEach(cues) { cue in
                    flag(for: cue, size: geo.size, row: rows[cue.id] ?? 0)
                }
                // Hover label on its own top layer so neighbouring tags never cover it.
                if let id = hoveredID ?? drag?.id, let cue = cues.first(where: { $0.id == id }), visible.contains(id) {
                    infoLabel(for: cue, size: geo.size, row: rows[id] ?? 0)
                        .zIndex(10)
                }
            }
        }
        .onAppear { reveal(cues, animated: animateIn) }
        // Use the values onChange hands over: on macOS 12/13 the closure sees the *previous* view's
        // properties (cues were still empty there, so nothing was ever revealed).
        .onChange(of: RevealKey(cues: cues, animated: animateIn)) { key in reveal(key.cues, animated: key.animated) }
    }

    // MARK: Flag

    private func xPosition(for cue: Cue, width: CGFloat) -> CGFloat {
        guard duration > 0 else { return 0 }
        let base = CGFloat(cue.time / duration) * width
        guard let drag, drag.id == cue.id else { return base }
        let raw = Double((base + drag.dx) / width) * duration
        let snapped = (NSEvent.modifierFlags.contains(.option) || grid == nil) ? raw : grid!.nearestBarTime(to: raw)
        return CGFloat(min(max(0, snapped), duration) / duration) * width
    }

    /// Tags closer than a tag width share no row: the later one drops to the next row (up to 3 rows).
    private func tagRows(width: CGFloat) -> [UUID: Int] {
        var rows: [UUID: Int] = [:]
        var lastX = [CGFloat](repeating: -.infinity, count: 3)
        for cue in cues.sorted(by: { $0.time < $1.time }) {
            let x = xPosition(for: cue, width: width)
            let row = lastX.firstIndex { x - $0 > Self.tagSize + 2 } ?? 0
            rows[cue.id] = row
            lastX[row] = x
        }
        return rows
    }

    @ViewBuilder
    private func flag(for cue: Cue, size: CGSize, row: Int) -> some View {
        let x = xPosition(for: cue, width: size.width)
        let isVisible = visible.contains(cue.id)
        let isFlashing = flashing.contains(cue.id)
        let isSelected = selectedID == cue.id
        let isHovered = hoveredID == cue.id || drag?.id == cue.id
        // Tags sit right of their line; near the right edge they flip to the left so they stay inside.
        let flip = x > size.width - Self.tagSize - 4
        let tagX = flip ? x - Self.tagSize / 2 - 1 : x + Self.tagSize / 2 + 1

        Rectangle()
            .fill(cue.kind.color.opacity(isFlashing ? 0.95 : (isSelected || isHovered ? 0.8 : 0.42)))
            .frame(width: isFlashing || isSelected ? 2 : 1, height: size.height)
            .position(x: x, y: size.height / 2)
            .opacity(isVisible ? 1 : 0)
            .allowsHitTesting(false)

        // Every interaction modifier goes on the 14 pt tag *before* .position(): applied after it, .help /
        // .onHover / the gesture cover the whole overlay and swallow clicks meant for the waveform (seek).
        CueTagView(cue: cue, isSelected: isSelected, isHovered: isHovered)
            .gesture(tagGesture(for: cue, width: size.width))
            .onHover { inside in
                if inside { hoveredID = cue.id } else if hoveredID == cue.id { hoveredID = nil }
            }
            .help("\(cue.kind.title) · click to jump · drag to move (⌥ = off grid) · ⌫ deletes · ⇧D/⇧B/⇧R adds")
            .accessibilityElement()
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("\(cue.kind.title) cue at \(Self.clock(cue.time))\(cue.isSuggestion ? ", suggestion" : "")")
            .allowsHitTesting(isVisible)
            .scaleEffect(isVisible ? 1 : 0.6, anchor: .top)
            .offset(y: isVisible ? 0 : -10)
            .opacity(isVisible ? 1 : 0)
            .position(x: tagX, y: tagTop + Self.tagSize / 2 + CGFloat(row) * (Self.tagSize + 3))

    }

    /// Anchored by its leading (or trailing, when flipped) edge next to the tag.
    private func infoLabel(for cue: Cue, size: CGSize, row: Int) -> some View {
        let x = xPosition(for: cue, width: size.width)
        let flip = x > size.width - 170
        return CueInfoLabel(cue: cue, time: Double(x / max(size.width, 1)) * duration, grid: grid)
            .fixedSize()
            .padding(flip ? .trailing : .leading, flip ? size.width - x + 4 : x + Self.tagSize + 4)
            .padding(.top, tagTop - 1 + CGFloat(row) * (Self.tagSize + 3))
            .frame(width: size.width, height: size.height, alignment: flip ? .topTrailing : .topLeading)
            .allowsHitTesting(false)
            .transition(.opacity)
    }

    private func tagGesture(for cue: Cue, width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if abs(value.translation.width) > 3 || drag?.id == cue.id {
                    drag = (cue.id, value.translation.width)
                    selectedID = cue.id
                }
            }
            .onEnded { value in
                defer { drag = nil }
                guard duration > 0, width > 0 else { return }
                if abs(value.translation.width) > 3 {
                    let base = CGFloat(cue.time / duration) * width
                    let time = Double((base + value.translation.width) / width) * duration
                    onMove(cue.id, time, !NSEvent.modifierFlags.contains(.option))
                } else {
                    selectedID = cue.id
                    onSeek(cue.time)
                }
            }
    }

    // MARK: Reveal

    /// New cues pop in one at a time (90 ms apart, left to right) with a brief line flash; cues that were
    /// already visible stay put. Reduce Motion, or cues loaded from cache, show everything at once.
    private struct RevealKey: Equatable {
        var cues: [Cue]
        var animated: Bool
    }

    private func reveal(_ cues: [Cue], animated: Bool) {
        revealGeneration += 1
        let generation = revealGeneration
        let ids = Set(cues.map(\.id))
        visible.formIntersection(ids)
        let pending = cues.filter { !visible.contains($0.id) }.sorted { $0.time < $1.time }
        guard !pending.isEmpty else { return }

        if MocaMotion.reduceMotion || (!animated && visible.isEmpty) {
            visible.formUnion(pending.map(\.id))
            return
        }
        if !animated {   // a cue the user just added: single pop
            withAnimation(MocaMotion.pop) { visible.formUnion(pending.map(\.id)) }
            return
        }
        for (index, cue) in pending.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15 + Double(index) * MocaMotion.cueStaggerStep) {
                guard generation == revealGeneration else { return }
                withAnimation(.spring(response: 0.34, dampingFraction: 0.68)) {
                    _ = visible.insert(cue.id)
                    _ = flashing.insert(cue.id)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                    withAnimation(.easeOut(duration: 0.3)) { _ = flashing.remove(cue.id) }
                }
            }
        }
    }

    static func clock(_ t: Double) -> String {
        let s = max(0, Int(t.rounded()))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// The lettered square at the top of each cue line. Suggestions (low confidence) are drawn hollow.
struct CueTagView: View {
    let cue: Cue
    let isSelected: Bool
    let isHovered: Bool

    var body: some View {
        let hollow = cue.isSuggestion
        Text(cue.kind.letter)
            .font(.system(size: 8, weight: .heavy, design: .rounded))
            .foregroundColor(hollow ? cue.kind.color : Color.black.opacity(0.85))
            .frame(width: CueFlagsOverlay.tagSize, height: CueFlagsOverlay.tagSize)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(hollow ? Color.black.opacity(0.55) : cue.kind.color)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(hollow ? cue.kind.color : Color.white.opacity(isSelected ? 0.95 : 0),
                                  style: StrokeStyle(lineWidth: isSelected ? 1.5 : 1, dash: hollow ? [2, 1.5] : []))
            )
            .scaleEffect(isHovered ? 1.15 : 1)
            .animation(MocaMotion.state, value: isHovered)
            .animation(MocaMotion.state, value: isSelected)
            .contentShape(Rectangle().inset(by: -4))   // easier to grab than 14 pt
    }
}

/// "DROP · bar 65 · 1:58" next to a hovered or dragged tag.
struct CueInfoLabel: View {
    let cue: Cue
    let time: Double
    let grid: BeatGrid?

    var body: some View {
        HStack(spacing: 4) {
            Text(cue.kind.title.uppercased())
                .foregroundColor(cue.kind.color)
            if let grid {
                Text("· bar \(grid.displayBar(at: time))")
            }
            Text("· \(CueFlagsOverlay.clock(time))")
            if cue.isSuggestion {
                Text("· suggestion").foregroundColor(.secondary)
            }
        }
        .font(.system(size: 9, weight: .bold, design: .monospaced))
        .foregroundColor(.white.opacity(0.9))
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color.black.opacity(0.78)))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.white.opacity(0.1), lineWidth: 1))
    }
}
