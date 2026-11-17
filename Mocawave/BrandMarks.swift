import AppKit
import SwiftUI

// Brand marks for the track-info source icons. Generated from official assets:
// - Beatport: icon mark served by Beatport's own site (greenroom.beatport.com header logo, "BP logo.svg"),
//   converted 1:1 from its SVG path (viewBox 27×34).
// - Deezer: the heart from the official press kit (newsroom-deezer.com/press-kit → DEEZER-LOGO.zip,
//   Vertical-cb-black-rgb.png), cropped to the heart and scaled to 96 px.
// Trademarks of their owners; used only to identify the source of the information shown.

/// Beatport's icon mark as a vector shape (fills the rect, aspect-fit).
struct BeatportMark: Shape {
    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width / 27, rect.height / 34)
        let dx = rect.midX - 27 * scale / 2, dy = rect.midY - 34 * scale / 2
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: dx + x * scale, y: dy + y * scale) }
        var path = Path()
        path.move(to: pt(26.7563, 23.5179))
        path.addCurve(to: pt(17.0827, 33.15), control1: pt(26.7563, 28.8473), control2: pt(22.4875, 33.15))
        path.addCurve(to: pt(7.45809, 23.5179), control1: pt(11.6778, 33.15), control2: pt(7.45809, 28.9529))
        path.addCurve(to: pt(9.97179, 17.0034), control1: pt(7.45809, 20.9627), control2: pt(8.43186, 18.6981))
        path.addLine(to: pt(3.43086, 23.5179))
        path.addLine(to: pt(0, 20.1021))
        path.addLine(to: pt(7.37882, 12.8365))
        path.addCurve(to: pt(8.89234, 9.12259), control1: pt(8.37902, 11.8401), control2: pt(8.89234, 10.5493))
        path.addLine(to: pt(8.89234, 0))
        path.addLine(to: pt(13.731, 0))
        path.addLine(to: pt(13.731, 9.12259))
        path.addCurve(to: pt(10.7871, 16.2259), control1: pt(13.731, 11.9231), control2: pt(12.7308, 14.2897))
        path.addLine(to: pt(10.5719, 16.441))
        path.addCurve(to: pt(17.0864, 13.9386), control1: pt(12.2741, 14.8822), control2: pt(14.5953, 13.9386))
        path.addCurve(to: pt(26.76, 23.5179), control1: pt(22.5705, 13.9386), control2: pt(26.76, 18.2716))
        path.addLine(to: pt(26.7563, 23.5179))
        path.closeSubpath()
        path.move(to: pt(22.378, 23.5179))
        path.addCurve(to: pt(17.0827, 18.3508), control1: pt(22.378, 20.6645), control2: pt(20.0002, 18.3508))
        path.addCurve(to: pt(11.8363, 23.5179), control1: pt(14.1651, 18.3508), control2: pt(11.8363, 20.774))
        path.addCurve(to: pt(17.0827, 28.7378), control1: pt(11.8363, 26.2618), control2: pt(14.1613, 28.7378))
        path.addCurve(to: pt(22.378, 23.5179), control1: pt(20.004, 28.7378), control2: pt(22.378, 26.2883))
        path.closeSubpath()
        return path
    }
}

enum DeezerMark {
    /// Official Deezer heart, 96 px PNG (transparent).
    static let image: NSImage? = {
        let base64 = [
        "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"
        ].joined()
        return Data(base64Encoded: base64).flatMap(NSImage.init(data:))
    }()
}

