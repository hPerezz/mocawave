import AppKit
import SwiftUI

/// Single source for colours and motion so every feature (drawers, Camelot, cues, stems) shares one rhythm.
enum MocaTheme {
    // MARK: Compatibility tiers (Camelot)
    static func color(for tier: CamelotTier) -> Color {
        switch tier {
        case .perfect: return Color(red: 0.13, green: 0.77, blue: 0.37)   // #22C55E
        case .good: return Color(red: 0.08, green: 0.72, blue: 0.65)      // #14B8A6
        case .energy: return Color(red: 0.96, green: 0.62, blue: 0.04)    // #F59E0B
        case .avoid: return Color.white.opacity(0.06)
        }
    }

    // MARK: Stems (M4) and cues (M2) — defined now so every view reuses the same palette
    enum Stem {
        static let drums = Color(red: 0.98, green: 0.45, blue: 0.09)
        static let bass = Color(red: 0.55, green: 0.36, blue: 0.96)
        static let vocals = Color(red: 0.93, green: 0.28, blue: 0.60)
        static let guitar = Color(red: 0.23, green: 0.51, blue: 0.96)
        static let piano = Color(red: 0.92, green: 0.70, blue: 0.03)
        static let other = Color(red: 0.58, green: 0.64, blue: 0.72)
    }

    /// Section palette, shared by flags, the sectioned waveform and the mascot: drop red (energy peak),
    /// build amber (tension), break blue (calm), intro/outro neutral slate (mixing zones). No green, so the
    /// hardest pair for colour-blind users (red/green) never appears; every flag also carries a letter.
    enum Cue {
        static let introOutro = Color(red: 0.58, green: 0.64, blue: 0.72)
        static let build = Color(red: 0.96, green: 0.70, blue: 0.10)
        static let drop = Color(red: 0.94, green: 0.27, blue: 0.27)
        static let breakdown = Color(red: 0.23, green: 0.51, blue: 0.96)
    }

    // MARK: Surfaces (glass)
    /// Wells (waveform box, drawers) sit on the blurred window as slightly darker translucent panes.
    static let panelBackground = Color.black.opacity(0.28)
    static let panelStroke = Color.white.opacity(0.14)
    static let panelRadius: CGFloat = 12
    static let barBackground = Color.white.opacity(0.06)
}

/// Motion tokens. Springs to arrive, faster ease-in to leave, short stagger; everything collapses to a
/// short fade when the user enables Reduce Motion.
enum MocaMotion {
    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    static var drawerIn: Animation {
        reduceMotion ? .easeOut(duration: 0.1) : .spring(response: 0.38, dampingFraction: 0.86)
    }
    static var drawerOut: Animation {
        reduceMotion ? .easeOut(duration: 0.1) : .easeIn(duration: 0.24)
    }
    /// Window frame animation matching drawerIn / drawerOut.
    static var windowInDuration: TimeInterval { reduceMotion ? 0 : 0.32 }
    static var windowOutDuration: TimeInterval { reduceMotion ? 0 : 0.22 }

    static var state: Animation { .easeOut(duration: 0.15) }
    static var pop: Animation {
        reduceMotion ? .easeOut(duration: 0.1) : .spring(response: 0.32, dampingFraction: 0.8)
    }

    /// Delay between items revealed in sequence (lanes, wheel slices).
    static let staggerStep: TimeInterval = 0.04
    /// Delay between cue flags appearing one by one (M2).
    static let cueStaggerStep: TimeInterval = 0.09
}

/// Frosted window background: blurs whatever is behind the window — the closest native material before
/// macOS 26's Liquid Glass (which needs the macOS 26 SDK; add a `glassEffect` branch when building with it).
///
/// Installed at window level, below SwiftUI's hosting view. Inside a SwiftUI background the effect view
/// lives in a layer-backed subtree and the window server never applies the behind-window blur: the window
/// just turned transparent.
final class GlassBackdrop: NSVisualEffectView {
    static func install(in window: NSWindow, material: NSVisualEffectView.Material = .hudWindow) {
        guard let content = window.contentView, let frame = content.superview,
              !frame.subviews.contains(where: { $0 is GlassBackdrop }) else { return }
        let backdrop = GlassBackdrop(frame: frame.bounds)
        backdrop.material = material
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active            // stay frosted when the window is not key
        backdrop.autoresizingMask = [.width, .height]
        frame.addSubview(backdrop, positioned: .below, relativeTo: content)
    }
}
