import SwiftUI

/// Panels that open below the player strip. Order of `allCases` = stacking order (stems sit above Camelot).
enum InspectorDrawer: String, CaseIterable, Identifiable {
    case stems
    case camelot

    var id: String { rawValue }

    var title: String {
        switch self {
        case .stems: return "STEMS"
        case .camelot: return "CAMELOT"
        }
    }

    var shortcutHint: String {
        switch self {
        case .stems: return "M"
        case .camelot: return "K"
        }
    }

    /// Height of the panel itself (without the gap above it). The stems panel follows its content (state,
    /// lane count, collapsed lanes): the caller passes `StemLanesView.panelHeight(...)`.
    func height(stems: CGFloat) -> CGFloat {
        switch self {
        case .stems: return stems
        case .camelot: return 276
        }
    }

    static let gap: CGFloat = 10
    static let bottomInset: CGFloat = 14
    /// Panel chrome around the content: top padding 6 + header 22 + spacing 6 + bottom padding 10.
    static let chromeHeight: CGFloat = 44

    /// Extra window content height needed for a set of open drawers.
    static func extraHeight(for open: [InspectorDrawer], stemsHeight: CGFloat) -> CGFloat {
        guard !open.isEmpty else { return 0 }
        return open.reduce(0) { $0 + gap + $1.height(stems: stemsHeight) } + bottomInset - gap
    }
}

/// Shared chrome for every drawer: same surface as the waveform box, a small header and a close button.
/// `accessory` sits in the header between the title and the close button; with `titleWidth` set, the title
/// gets a fixed column so the accessory lines up with content below (the stems lanes' waveform column).
struct DrawerPanel<Content: View, Accessory: View>: View {
    let drawer: InspectorDrawer
    let height: CGFloat
    var titleWidth: CGFloat? = nil
    let onClose: () -> Void
    @ViewBuilder let accessory: () -> Accessory
    @ViewBuilder let content: () -> Content

    @State private var isCloseHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: titleWidth == nil ? 6 : 0) {
                Text(drawer.title)
                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
                    .foregroundColor(.secondary)
                    .frame(width: titleWidth, alignment: .leading)
                accessory()
                Spacer(minLength: 0)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.white.opacity(isCloseHovered ? 0.95 : 0.6))
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Color.white.opacity(isCloseHovered ? 0.1 : 0)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .onHover { isCloseHovered = $0 }
                .help("Close (\(drawer.shortcutHint))")
                .accessibilityLabel("Close \(drawer.title.lowercased()) panel")
            }
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .background(MocaTheme.panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: MocaTheme.panelRadius))
        .overlay(RoundedRectangle(cornerRadius: MocaTheme.panelRadius).stroke(MocaTheme.panelStroke, lineWidth: 1))
    }
}

extension DrawerPanel where Accessory == EmptyView {
    init(drawer: InspectorDrawer, height: CGFloat, onClose: @escaping () -> Void, @ViewBuilder content: @escaping () -> Content) {
        self.init(drawer: drawer, height: height, onClose: onClose, accessory: { EmptyView() }, content: content)
    }
}

/// Top-bar KEY cell that doubles as the Camelot drawer toggle, so the wheel opens from the value it explains.
struct TopBarKeyCell: View {
    let value: String
    let isOpen: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "circle.circle")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(isOpen ? .accentColor : .white.opacity(0.72))
                Text("KEY")
                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                Text(value)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.92))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 0)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundColor(.white.opacity(isHovered || isOpen ? 0.85 : 0.45))
                    .rotationEffect(.degrees(isOpen ? 180 : 0))
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(Rectangle().fill(Color.white.opacity(isOpen ? 0.07 : (isHovered ? 0.05 : 0))))
            .contentShape(Rectangle())
            .animation(MocaMotion.state, value: isOpen)
            .animation(MocaMotion.state, value: isHovered)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("Camelot wheel (K)")
        .accessibilityLabel("Key \(value). Camelot wheel")
        .accessibilityHint(isOpen ? "Closes the Camelot wheel" : "Opens the Camelot wheel with compatible keys")
    }
}

/// Top-bar STEMS cell: opens the stems drawer and shows where separation is at a glance
/// (idle chevron · inline progress · ready check · agent offline).
struct TopBarStemsCell: View {
    let state: StemsState
    let isOpen: Bool
    let action: () -> Void

    static let width: CGFloat = 96

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(iconColor)
                    .frame(width: 11)
                if state.isWorking {
                    StemProgressBar(progress: state.displayProgress)
                        .frame(height: 3)
                    Text(state.displayProgress.map { "\(Int(($0 * 100).rounded(.down)))%" } ?? "···")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundColor(.white.opacity(0.92))
                        .monospacedDigit()
                        .lineLimit(1)
                        .fixedSize()
                } else {
                    Text("STEMS")
                        .font(.system(size: 8, weight: .semibold, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                    if state == .ready {
                        Image(systemName: "checkmark")
                            .font(.system(size: 7, weight: .heavy))
                            .foregroundColor(.accentColor)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundColor(.white.opacity(isHovered || isOpen ? 0.85 : 0.45))
                        .rotationEffect(.degrees(isOpen ? 180 : 0))
                }
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(Rectangle().fill(Color.white.opacity(isOpen ? 0.07 : (isHovered ? 0.05 : 0))))
            .contentShape(Rectangle())
            .animation(MocaMotion.state, value: isOpen)
            .animation(MocaMotion.state, value: isHovered)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(help)
        .accessibilityLabel("Stems. \(accessibilityStatus)")
        .accessibilityHint(isOpen ? "Closes the stems panel" : "Opens the stems panel")
    }

    private var icon: String {
        switch state {
        case .offline: return "bolt.slash"
        case .failed: return "exclamationmark.triangle"
        default: return "slider.horizontal.3"
        }
    }

    private var iconColor: Color {
        switch state {
        case .failed: return MocaTheme.Cue.drop
        case .offline: return .white.opacity(0.5)
        default: return isOpen || state.isWorking || state == .ready ? .accentColor : .white.opacity(0.72)
        }
    }

    private var help: String {
        switch state {
        case .offline: return "Stems agent offline (M)"
        case .failed(let m): return "Stems failed: \(m) (M)"
        case .ready: return "Stems ready (M)"
        default:
            if state.isWorking { return "\(state.stageLabel)… (M)" }
            return "Stems (M)"
        }
    }

    private var accessibilityStatus: String {
        switch state {
        case .ready: return "Ready"
        case .offline: return "Agent offline"
        case .failed(let m): return "Failed: \(m)"
        default:
            if let p = state.displayProgress { return "\(state.stageLabel), \(Int(p * 100)) percent" }
            return state.isWorking ? state.stageLabel : "Not separated"
        }
    }
}
