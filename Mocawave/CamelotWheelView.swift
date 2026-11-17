import SwiftUI

/// What the analyzer said about the playing track, in Camelot terms.
struct TrackCamelot: Equatable {
    /// Resolved key, or the analyzer's best guess when uncertain.
    var primary: CamelotKey?
    /// Second candidate (only shown when the key is uncertain).
    var runnerUp: CamelotKey?
    var isUncertain: Bool
    var uncertaintyNote: String?

    static let empty = TrackCamelot(primary: nil, runnerUp: nil, isUncertain: false, uncertaintyNote: nil)

    init(primary: CamelotKey?, runnerUp: CamelotKey?, isUncertain: Bool, uncertaintyNote: String?) {
        self.primary = primary
        self.runnerUp = runnerUp
        self.isUncertain = isUncertain
        self.uncertaintyNote = uncertaintyNote
    }

    init(_ result: KeyAnalyzer.KeyAnalysisResult?) {
        guard let result else { self = .empty; return }
        if result.isResolved {
            self.init(primary: result.camelot.flatMap { CamelotKey($0) }, runnerUp: nil, isUncertain: false, uncertaintyNote: nil)
            return
        }
        let note: String
        switch result.uncertaintyReason {
        case .relativeMajorMinorTie: note = "relative major/minor tie"
        case .smallRunnerUpMargin: note = "runner-up almost as strong"
        case .lowAbsoluteScore: note = "weak tonal match"
        case .insufficientTonalFrames: note = "too few tonal frames"
        case .none: note = "low confidence"
        }
        self.init(primary: result.candidateKey.flatMap { CamelotKey(keyName: $0) },
                  runnerUp: result.runnerUpKey.flatMap { CamelotKey(keyName: $0) },
                  isUncertain: true, uncertaintyNote: note)
    }
}

/// Two-ring Camelot wheel. Clicking a slice repaints every other slice by how well it mixes from it.
struct CamelotWheelView: View {
    let track: TrackCamelot
    @Binding var selection: CamelotKey?

    @State private var appeared = false
    @State private var litKeys: Set<CamelotKey> = []
    @State private var litAll = false
    @State private var revealGeneration = 0
    @State private var hovered: CamelotKey?

    private let wheelSize: CGFloat = 236
    private let sidePanelWidth: CGFloat = 400

    /// `revealed: true` starts in the final state (no entry animation): for previews and snapshot tests.
    init(track: TrackCamelot, selection: Binding<CamelotKey?>, revealed: Bool = false) {
        self.track = track
        _selection = selection
        _appeared = State(initialValue: revealed)
        _litAll = State(initialValue: revealed)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 22) {
            wheel
                .frame(width: wheelSize, height: wheelSize)
                .scaleEffect(appeared ? 1 : 0.92)
                .opacity(appeared ? 1 : 0)
            sidePanel
                .frame(width: sidePanelWidth, height: wheelSize, alignment: .topLeading)
                .opacity(appeared ? 1 : 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            withAnimation(MocaMotion.pop) { appeared = true }
            revealSequentially(from: selection ?? track.primary)
        }
        // onChange's closure sees the previous view's `track` on macOS 12/13: use the new value it passes.
        .onChange(of: track) { newTrack in revealSequentially(from: newTrack.primary) }
    }

    // MARK: Wheel

    private var wheel: some View {
        ZStack {
            ForEach(CamelotKey.all, id: \.self) { key in
                slice(for: key)
            }
            centerLabel
            // One tracker for the whole wheel: SwiftUI's onHover uses each slice's full (shared) frame,
            // not its shape, so per-slice hover never resolves to the slice under the pointer.
            PointerTrackingView { point, size in
                let key = point.flatMap { SliceGeometry.key(at: $0, in: size) }
                if key != hovered { hovered = key }
            }
            .allowsHitTesting(false)   // tracking areas still fire; taps go to the slices
        }
    }

    private func relation(of key: CamelotKey) -> CamelotRelation? {
        selection.map { CamelotRelation(from: $0, to: key) }
    }

    private func isLit(_ key: CamelotKey) -> Bool { litAll || litKeys.contains(key) }

    private func slice(for key: CamelotKey) -> some View {
        let geometry = SliceGeometry(key: key)
        let tier = relation(of: key)?.tier ?? .avoid
        let lit = isLit(key) && tier != .avoid
        let isTrackKey = key == track.primary
        let isCandidate = track.isUncertain && (key == track.primary || key == track.runnerUp)
        let isSelected = key == selection
        let isHovered = key == hovered

        return ZStack {
            SliceShape(geometry: geometry)
                .fill(lit ? MocaTheme.color(for: tier) : MocaTheme.color(for: .avoid))
            SliceShape(geometry: geometry)
                .fill(Color.white.opacity(isHovered ? 0.12 : 0))
            SliceShape(geometry: geometry)
                .stroke(Color.black.opacity(0.45), lineWidth: 1)
            if isCandidate {
                SliceShape(geometry: geometry)
                    .inset(by: 1.5)
                    .stroke(Color.white.opacity(0.9), style: StrokeStyle(lineWidth: 1.5, dash: [3, 2.5]))
            } else if isTrackKey {
                SliceShape(geometry: geometry)
                    .inset(by: 1.5)
                    .stroke(Color.white, lineWidth: 2.5)
            }
            if isSelected && !isTrackKey {
                SliceShape(geometry: geometry)
                    .inset(by: 1.5)
                    .stroke(Color.white.opacity(0.75), lineWidth: 1.5)
            }
            sliceLabel(key: key, geometry: geometry, lit: lit, tier: tier, emphasized: isTrackKey || isSelected, hovered: isHovered)
        }
        .contentShape(SliceShape(geometry: geometry))
        .onTapGesture { select(key) }
        .animation(MocaMotion.state, value: lit)
        .animation(MocaMotion.state, value: tier)
        .animation(MocaMotion.state, value: isHovered)
        .accessibilityElement()
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("\(key.code), \(key.musicalName)")
        .accessibilityValue(accessibilityValue(for: key))
    }

    /// Code by default; on hover the musical name (Cm, F#) takes the main line and the code shrinks under it.
    private func sliceLabel(key: CamelotKey, geometry: SliceGeometry, lit: Bool, tier: CamelotTier,
                            emphasized: Bool, hovered: Bool) -> some View {
        GeometryReader { proxy in
            let point = geometry.labelPoint(in: proxy.size)
            ZStack {
                VStack(spacing: 0) {
                    if lit, !tier.glyph.isEmpty {
                        Text(tier.glyph)
                            .font(.system(size: 6, weight: .bold))
                    }
                    Text(key.code)
                        .font(.system(size: key.isMajor ? 10 : 9, weight: emphasized ? .heavy : .semibold, design: .monospaced))
                }
                .opacity(hovered ? 0 : 1)
                VStack(spacing: 0) {
                    Text(key.shortName)
                        .font(.system(size: key.isMajor ? 12 : 11, weight: .heavy))
                    Text(key.code)
                        .font(.system(size: 7, weight: .semibold, design: .monospaced))
                        .opacity(0.75)
                }
                .opacity(hovered ? 1 : 0)
                .scaleEffect(hovered ? 1 : 0.85)
            }
            .foregroundColor(lit ? Color.black.opacity(0.82) : Color.white.opacity(emphasized || hovered ? 0.95 : 0.55))
            .position(point)
        }
        .allowsHitTesting(false)
    }

    private var centerLabel: some View {
        VStack(spacing: 1) {
            Text(selection?.code ?? "--")
                .font(.system(size: 18, weight: .heavy, design: .monospaced))
                .foregroundColor(.white.opacity(0.95))
            Text(centerCaption)
                .font(.system(size: 7, weight: .semibold, design: .monospaced))
                .foregroundColor(.secondary)
        }
        .allowsHitTesting(false)
    }

    private var centerCaption: String {
        guard let selection else { return "PICK A KEY" }
        if selection == track.primary { return track.isUncertain ? "BEST GUESS" : "TRACK" }
        return "SELECTED"
    }

    // MARK: Side panel

    private var sidePanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            focusInfo
            VStack(alignment: .leading, spacing: 5) {
                ForEach(CamelotTier.allCases, id: \.self) { tier in
                    legendRow(tier)
                }
            }
            if track.isUncertain {
                uncertaintyRow
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    /// Hovered slice wins over the selection so the user can read relations before clicking.
    private var focusInfo: some View {
        let focus = hovered ?? selection
        return VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(focus?.code ?? "--")
                    .font(.system(size: 22, weight: .heavy, design: .monospaced))
                    .foregroundColor(.white.opacity(0.95))
                Text(focus.map { "\($0.shortName) · \($0.musicalName)" } ?? "no key detected")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.8))
            }
            Text(focusRelationText(focus))
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
        .animation(MocaMotion.state, value: focus)
    }

    private func focusRelationText(_ focus: CamelotKey?) -> String {
        guard let focus else { return "Open a track or click any slice" }
        if let selection, focus != selection {
            return "from \(selection.code): \(CamelotRelation(from: selection, to: focus).label)"
        }
        let count = focus.compatibleKeys.count - 1
        return "\(count) keys mix from here"
    }

    private func legendRow(_ tier: CamelotTier) -> some View {
        HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 3)
                    .fill(tier == .avoid ? Color.white.opacity(0.1) : MocaTheme.color(for: tier))
                Text(tier.glyph)
                    .font(.system(size: 7, weight: .bold))
                    .foregroundColor(.black.opacity(0.8))
            }
            .frame(width: 16, height: 12)
            Text(tier.title.uppercased())
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(.white.opacity(0.88))
                .frame(width: 58, alignment: .leading)
            Text(tier.detail)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var uncertaintyRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "questionmark.diamond")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(MocaTheme.color(for: .energy))
            Text(uncertaintyText)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(.white.opacity(0.8))
                .lineLimit(2)
        }
        .accessibilityElement(children: .combine)
    }

    private var uncertaintyText: String {
        let candidates = [track.primary, track.runnerUp].compactMap { $0?.code }.joined(separator: " or ")
        let note = track.uncertaintyNote ?? "low confidence"
        return candidates.isEmpty ? "Key uncertain · \(note)" : "Key uncertain: \(candidates) · \(note)"
    }

    private func accessibilityValue(for key: CamelotKey) -> String {
        var parts: [String] = []
        if key == track.primary { parts.append(track.isUncertain ? "best guess for this track" : "this track's key") }
        if let relation = relation(of: key), key != selection { parts.append(relation.tier.title + ", " + relation.label) }
        return parts.joined(separator: ". ")
    }

    // MARK: Behaviour

    private func select(_ key: CamelotKey) {
        revealGeneration += 1           // cancels a reveal still in flight (interruptible)
        withAnimation(MocaMotion.state) {
            litAll = true
            selection = key
        }
    }

    /// Light compatible slices one by one, strongest relation first, so the order teaches the hierarchy.
    private func revealSequentially(from origin: CamelotKey?) {
        revealGeneration += 1
        let generation = revealGeneration
        litAll = false
        litKeys = []
        guard let origin else { return }
        if MocaMotion.reduceMotion {
            litAll = true
            return
        }
        let order = origin.compatibleKeys.map(\.key)
        for (index, key) in order.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.14 + Double(index) * MocaMotion.staggerStep) {
                guard generation == revealGeneration else { return }
                withAnimation(MocaMotion.state) { _ = litKeys.insert(key) }
                if index == order.count - 1 { litAll = true }
            }
        }
    }
}

// MARK: - Geometry

/// Angles and radii of one slice. 12 sits at the top, numbers run clockwise; B (major) is the outer ring.
struct SliceGeometry {
    let key: CamelotKey

    static let outerRing: ClosedRange<CGFloat> = 0.64...1.0
    static let innerRing: ClosedRange<CGFloat> = 0.33...0.62

    var radii: ClosedRange<CGFloat> { key.isMajor ? Self.outerRing : Self.innerRing }
    var centerAngle: Angle { .degrees(-90 + Double(key.number % 12) * 30) }
    var startAngle: Angle { centerAngle - .degrees(15) }
    var endAngle: Angle { centerAngle + .degrees(15) }

    /// Which slice is under `point` (top-left origin, y down), or nil for the centre hole / outside the wheel.
    static func key(at point: CGPoint, in size: CGSize) -> CamelotKey? {
        let radius = min(size.width, size.height) / 2
        guard radius > 0 else { return nil }
        let dx = point.x - size.width / 2
        let dy = point.y - size.height / 2
        let r = (dx * dx + dy * dy).squareRoot() / radius
        let isMajor: Bool
        if outerRing.contains(r) { isMajor = true } else if innerRing.contains(r) { isMajor = false } else { return nil }
        let degrees = Double(atan2(dy, dx)) * 180 / .pi + 90          // 0° = top, clockwise
        let index = Int((degrees / 30).rounded()) % 12
        return CamelotKey(number: index <= 0 ? index + 12 : index, isMajor: isMajor)
    }

    func labelPoint(in size: CGSize) -> CGPoint {
        let radius = min(size.width, size.height) / 2
        let mid = radius * (radii.lowerBound + radii.upperBound) / 2
        let a = CGFloat(centerAngle.radians)
        return CGPoint(x: size.width / 2 + mid * CoreGraphics.cos(a), y: size.height / 2 + mid * CoreGraphics.sin(a))
    }
}

struct SliceShape: InsettableShape {
    let geometry: SliceGeometry
    var insetAmount: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let radius = min(rect.width, rect.height) / 2
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outer = radius * geometry.radii.upperBound - insetAmount
        let inner = radius * geometry.radii.lowerBound + insetAmount
        // Shrink the angular span so the inset stays even along the radial edges.
        let angularInset = Angle.radians(Double(insetAmount / max(inner, 1)))
        let start = geometry.startAngle + angularInset
        let end = geometry.endAngle - angularInset
        var path = Path()
        path.addArc(center: center, radius: outer, startAngle: start, endAngle: end, clockwise: false)
        path.addArc(center: center, radius: inner, startAngle: end, endAngle: start, clockwise: true)
        path.closeSubpath()
        return path
    }

    func inset(by amount: CGFloat) -> SliceShape {
        var copy = self
        copy.insetAmount += amount
        return copy
    }
}

// MARK: - Pointer tracking

/// Reports the pointer position (top-left origin) while it is over the view, nil when it leaves.
/// Hit-testing passes through, so taps still reach the slices underneath.
#if MOCA_SNAPSHOT
/// Headless snapshot builds: pointer tracking is a no-op.
struct PointerTrackingView: View {
    let onChange: (CGPoint?, CGSize) -> Void
    var body: some View { Color.clear }
}
#else
struct PointerTrackingView: NSViewRepresentable {
    let onChange: (CGPoint?, CGSize) -> Void

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ nsView: TrackingView, context: Context) {
        nsView.onChange = onChange
    }

    final class TrackingView: NSView {
        var onChange: ((CGPoint?, CGSize) -> Void)?
        override var isFlipped: Bool { true }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: .zero,
                                           options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                           owner: self))
        }

        override func mouseMoved(with event: NSEvent) { report(event) }
        override func mouseEntered(with event: NSEvent) { report(event) }
        override func mouseExited(with event: NSEvent) { onChange?(nil, bounds.size) }

        private func report(_ event: NSEvent) {
            onChange?(convert(event.locationInWindow, from: nil), bounds.size)
        }
    }
}
#endif
