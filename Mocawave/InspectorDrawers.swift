import SwiftUI

/// Panels that open below the player strip. Order of `allCases` = stacking order (stems will sit above Camelot).
enum InspectorDrawer: String, CaseIterable, Identifiable {
    case camelot

    var id: String { rawValue }

    var title: String {
        switch self {
        case .camelot: return "CAMELOT"
        }
    }

    var shortcutHint: String {
        switch self {
        case .camelot: return "K"
        }
    }

    /// Height of the panel itself (without the gap above it).
    var height: CGFloat {
        switch self {
        case .camelot: return 276
        }
    }

    static let gap: CGFloat = 10
    static let bottomInset: CGFloat = 14

    /// Extra window content height needed for a set of open drawers.
    static func extraHeight(for open: [InspectorDrawer]) -> CGFloat {
        guard !open.isEmpty else { return 0 }
        return open.reduce(0) { $0 + gap + $1.height } + bottomInset - gap
    }
}

/// Shared chrome for every drawer: same surface as the waveform box, a small header and a close button.
struct DrawerPanel<Content: View>: View {
    let drawer: InspectorDrawer
    let onClose: () -> Void
    @ViewBuilder let content: () -> Content

    @State private var isCloseHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(drawer.title)
                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
                    .foregroundColor(.secondary)
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
        .frame(height: drawer.height)
        .background(MocaTheme.panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: MocaTheme.panelRadius))
        .overlay(RoundedRectangle(cornerRadius: MocaTheme.panelRadius).stroke(MocaTheme.panelStroke, lineWidth: 1))
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
