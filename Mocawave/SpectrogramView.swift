import AppKit
import SwiftUI

struct SpectrogramView: View {
    let image: CGImage?
    let progress: Double
    let onSeek: (Double) -> Void

    @State private var hoverX: CGFloat? = nil

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size

            ZStack {
                Canvas { context, size in
                    // Draw spectrogram image
                    if let image {
                        context.draw(
                            Image(decorative: image, scale: 1.0),
                            in: CGRect(origin: .zero, size: size)
                        )
                    }

                    let clampedProgress = min(max(progress, 0), 1)
                    let progressX = clampedProgress * size.width

                    // Dim played region
                    if progressX > 0 {
                        let playedRect = CGRect(x: 0, y: 0, width: progressX, height: size.height)
                        context.fill(Path(playedRect), with: .color(Color.black.opacity(0.35)))
                    }

                    // Playhead line
                    if progress > 0 {
                        let lineRect = CGRect(x: progressX - 0.5, y: 0, width: 1, height: size.height)
                        context.fill(Path(lineRect), with: .color(Color.white))
                    }

                    // Hover line
                    if let hx = hoverX, hx >= 0 {
                        let hoverRect = CGRect(x: hx - 0.5, y: 0, width: 1, height: size.height)
                        context.fill(Path(hoverRect), with: .color(Color.white.opacity(0.3)))
                    }
                }

                MouseTrackingView(
                    onMove: { x in
                        hoverX = min(max(x, 0), size.width)
                    },
                    onExit: {
                        hoverX = nil
                    }
                )
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let width = max(size.width, 1)
                        let fraction = min(max(value.location.x / width, 0), 1)
                        onSeek(fraction)
                    }
            )
        }
    }
}
