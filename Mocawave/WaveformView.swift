import AppKit
import SwiftUI

// MARK: - Mouse tracking helper for macOS 12+

struct MouseTrackingView: NSViewRepresentable {
    let onMove: (CGFloat) -> Void
    let onExit: () -> Void

    func makeNSView(context: Context) -> TrackingNSView {
        let view = TrackingNSView()
        view.onMove = onMove
        view.onExit = onExit
        return view
    }

    func updateNSView(_ nsView: TrackingNSView, context: Context) {
        nsView.onMove = onMove
        nsView.onExit = onExit
    }

    class TrackingNSView: NSView {
        var onMove: ((CGFloat) -> Void)?
        var onExit: (() -> Void)?
        private var trackingArea: NSTrackingArea?

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let existing = trackingArea {
                removeTrackingArea(existing)
            }
            let area = NSTrackingArea(
                rect: bounds,
                options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(area)
            trackingArea = area
        }

        override func mouseMoved(with event: NSEvent) {
            let location = convert(event.locationInWindow, from: nil)
            onMove?(location.x)
        }

        override func mouseExited(with event: NSEvent) {
            onExit?()
        }
    }
}

private enum WaveformResampler {
    static func resample(_ samples: [Float], to targetCount: Int) -> [Float] {
        guard !samples.isEmpty, targetCount > 0 else { return [] }
        if samples.count == targetCount { return samples }

        if samples.count < targetCount {
            let denominator = Double(max(targetCount - 1, 1))
            let scale = Double(samples.count - 1) / denominator
            return (0..<targetCount).map { index in
                let position = Double(index) * scale
                let lower = Int(position)
                let upper = min(lower + 1, samples.count - 1)
                let fraction = Float(position - Double(lower))
                return samples[lower] + (samples[upper] - samples[lower]) * fraction
            }
        }

        let bucketSize = Double(samples.count) / Double(targetCount)
        return (0..<targetCount).map { index in
            let start = Int(Double(index) * bucketSize)
            let end = Int(Double(index + 1) * bucketSize)
            let safeEnd = max(start + 1, end)
            var maxValue: Float = 0
            if start < samples.count {
                for sampleIndex in start..<min(safeEnd, samples.count) {
                    maxValue = max(maxValue, samples[sampleIndex])
                }
            }
            return maxValue
        }
    }

    static func resample(
        _ columns: [WaveformAnalyzer.ColoredWaveformData.Column],
        to targetCount: Int
    ) -> [WaveformAnalyzer.ColoredWaveformData.Column] {
        guard !columns.isEmpty, targetCount > 0 else { return [] }
        if columns.count == targetCount { return columns }

        if columns.count < targetCount {
            let denominator = Double(max(targetCount - 1, 1))
            let scale = Double(columns.count - 1) / denominator
            return (0..<targetCount).map { index in
                let position = Double(index) * scale
                let lower = Int(position)
                let upper = min(lower + 1, columns.count - 1)
                let fraction = Float(position - Double(lower))
                let lowerColumn = columns[lower]
                let upperColumn = columns[upper]
                return WaveformAnalyzer.ColoredWaveformData.Column(
                    height: interpolatedValue(lowerColumn.height, upperColumn.height, fraction: fraction),
                    red: interpolatedValue(lowerColumn.red, upperColumn.red, fraction: fraction),
                    green: interpolatedValue(lowerColumn.green, upperColumn.green, fraction: fraction),
                    blue: interpolatedValue(lowerColumn.blue, upperColumn.blue, fraction: fraction)
                )
            }
        }

        let bucketSize = Double(columns.count) / Double(targetCount)
        return (0..<targetCount).map { index in
            let start = Int(Double(index) * bucketSize)
            let end = Int(Double(index + 1) * bucketSize)
            let safeEnd = max(start + 1, end)

            var maxHeight: Float = 0
            var weightedRed: Float = 0
            var weightedGreen: Float = 0
            var weightedBlue: Float = 0
            var totalWeight: Float = 0

            if start < columns.count {
                for columnIndex in start..<min(safeEnd, columns.count) {
                    let column = columns[columnIndex]
                    let weight = max(column.height, 0.01)
                    maxHeight = max(maxHeight, column.height)
                    weightedRed += column.red * weight
                    weightedGreen += column.green * weight
                    weightedBlue += column.blue * weight
                    totalWeight += weight
                }
            }

            let divisor = max(totalWeight, 0.01)
            return WaveformAnalyzer.ColoredWaveformData.Column(
                height: maxHeight,
                red: weightedRed / divisor,
                green: weightedGreen / divisor,
                blue: weightedBlue / divisor
            )
        }
    }

    private static func interpolatedValue(_ lower: Float, _ upper: Float, fraction: Float) -> Float {
        lower + (upper - lower) * fraction
    }

    static func placeholderSamples(count: Int) -> [Float] {
        guard count > 0 else { return [] }

        return (0..<count).map { index in
            let position = Double(index) / Double(max(count - 1, 1))
            let broadWave = 0.34 + 0.18 * sin(position * .pi * 2.2)
            let mediumWave = 0.14 * sin(position * .pi * 7.4 + 0.6)
            let fineWave = 0.08 * sin(position * .pi * 19.0 + 1.1)
            let pulse = 0.12 * pow(sin(position * .pi * 4.0), 2)
            return Float(min(max(broadWave + mediumWave + fineWave + pulse, 0.08), 0.92))
        }
    }
}

// MARK: - WaveformView

/// A stretch of the track coloured by the cue that opens it (fractions of the duration).
struct WaveformSection: Equatable {
    var start: Double
    var color: Color
}

struct WaveformView: View {
    let samples: [Float]
    let progress: Double
    let onSeek: (Double) -> Void
    /// Section colours (mono mode with cues): played bars in the section colour, the rest softer.
    var sections: [WaveformSection] = []

    @State private var hoverX: CGFloat? = nil

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size

            ZStack {
                Canvas { context, size in
                    guard !samples.isEmpty else { return }

                    let barWidth: CGFloat = 2
                    let barSpacing: CGFloat = 1
                    let barCount = max(1, Int((size.width + barSpacing) / (barWidth + barSpacing)))
                    let renderSamples = WaveformResampler.resample(samples, to: barCount)
                    let clampedProgress = min(max(progress, 0), 1)
                    let progressIndex = min(Int(Double(barCount) * clampedProgress), barCount - 1)

                    var sectionIndex = -1
                    for index in 0..<barCount {
                        let sample = CGFloat(renderSamples[index])
                        let barHeight = max(1, sample * size.height)
                        let x = CGFloat(index) * (barWidth + barSpacing)
                        let y = (size.height - barHeight) / 2
                        let rect = CGRect(x: x, y: y, width: barWidth, height: barHeight)
                        let fraction = (Double(index) + 0.5) / Double(barCount)
                        while sectionIndex + 1 < sections.count, sections[sectionIndex + 1].start <= fraction { sectionIndex += 1 }
                        let played = index <= progressIndex
                        let color: Color
                        if sectionIndex >= 0 {
                            color = sections[sectionIndex].color.opacity(played ? 1 : 0.38)
                        } else {
                            color = played ? Color.accentColor : Color.secondary.opacity(0.45)
                        }
                        context.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2), with: .color(color))
                    }

                    if let hx = hoverX, hx >= 0 {
                        let hoverIndex = min(Int(hx / (barWidth + barSpacing)), barCount - 1)

                        if hoverIndex > progressIndex {
                            for index in (progressIndex + 1)...hoverIndex {
                                let x = CGFloat(index) * (barWidth + barSpacing)
                                guard x + barWidth <= hx else { break }
                                let sample = CGFloat(renderSamples[index])
                                let barHeight = max(1, sample * size.height)
                                let y = (size.height - barHeight) / 2
                                let rect = CGRect(x: x, y: y, width: barWidth, height: barHeight)
                                context.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2), with: .color(Color.white.opacity(0.15)))
                            }
                        } else if hoverIndex < progressIndex {
                            for index in hoverIndex...progressIndex {
                                let x = CGFloat(index) * (barWidth + barSpacing)
                                let sample = CGFloat(renderSamples[index])
                                let barHeight = max(1, sample * size.height)
                                let y = (size.height - barHeight) / 2
                                let rect = CGRect(x: x, y: y, width: barWidth, height: barHeight)
                                context.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2), with: .color(Color.black.opacity(0.3)))
                            }
                        }

                        let hoverSample = CGFloat(renderSamples[max(0, hoverIndex)])
                        let lineHeight = max(1, hoverSample * size.height)
                        let lineY = (size.height - lineHeight) / 2
                        let lineRect = CGRect(x: hx - 0.5, y: lineY, width: 1, height: lineHeight)
                        context.fill(Path(lineRect), with: .color(Color.white.opacity(0.25)))
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

struct ColoredWaveformView: View {
    let samples: [Float]
    let data: WaveformAnalyzer.ColoredWaveformData
    let progress: Double
    let onSeek: (Double) -> Void

    @State private var hoverX: CGFloat? = nil

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size

            ZStack {
                Canvas { context, size in
                    guard !samples.isEmpty, !data.columns.isEmpty else { return }

                    let barWidth: CGFloat = 2
                    let barSpacing: CGFloat = 1
                    let barCount = max(1, Int((size.width + barSpacing) / (barWidth + barSpacing)))
                    let renderSamples = WaveformResampler.resample(samples, to: barCount)
                    let renderColumns = WaveformResampler.resample(data.columns, to: barCount)
                    let clampedProgress = min(max(progress, 0), 1)
                    let progressIndex = min(Int(Double(barCount) * clampedProgress), barCount - 1)

                    for index in 0..<barCount {
                        let sample = CGFloat(renderSamples[index])
                        let barHeight = max(1, sample * size.height)
                        let x = CGFloat(index) * (barWidth + barSpacing)
                        let y = (size.height - barHeight) / 2
                        let rect = CGRect(x: x, y: y, width: barWidth, height: barHeight)
                        let column = renderColumns[index]
                        let baseColor = Color(
                            .sRGB,
                            red: Double(min(max(column.red, 0), 1)),
                            green: Double(min(max(column.green, 0), 1)),
                            blue: Double(min(max(column.blue, 0), 1)),
                            opacity: index <= progressIndex ? 0.95 : 0.42
                        )
                        context.fill(
                            Path(roundedRect: rect, cornerRadius: barWidth / 2),
                            with: .color(baseColor)
                        )
                    }

                    if let hx = hoverX, hx >= 0 {
                        let hoverIndex = min(Int(hx / (barWidth + barSpacing)), barCount - 1)

                        if hoverIndex > progressIndex {
                            for index in (progressIndex + 1)...hoverIndex {
                                let x = CGFloat(index) * (barWidth + barSpacing)
                                guard x + barWidth <= hx else { break }
                                let sample = CGFloat(renderSamples[index])
                                let barHeight = max(1, sample * size.height)
                                let y = (size.height - barHeight) / 2
                                let rect = CGRect(x: x, y: y, width: barWidth, height: barHeight)
                                context.fill(
                                    Path(roundedRect: rect, cornerRadius: barWidth / 2),
                                    with: .color(Color.white.opacity(0.15))
                                )
                            }
                        } else if hoverIndex < progressIndex {
                            for index in hoverIndex...progressIndex {
                                let x = CGFloat(index) * (barWidth + barSpacing)
                                let sample = CGFloat(renderSamples[index])
                                let barHeight = max(1, sample * size.height)
                                let y = (size.height - barHeight) / 2
                                let rect = CGRect(x: x, y: y, width: barWidth, height: barHeight)
                                context.fill(
                                    Path(roundedRect: rect, cornerRadius: barWidth / 2),
                                    with: .color(Color.black.opacity(0.3))
                                )
                            }
                        }

                        let hoverSample = CGFloat(renderSamples[max(0, hoverIndex)])
                        let lineHeight = max(1, hoverSample * size.height)
                        let lineY = (size.height - lineHeight) / 2
                        let lineRect = CGRect(x: hx - 0.5, y: lineY, width: 1, height: lineHeight)
                        context.fill(Path(lineRect), with: .color(Color.white.opacity(0.25)))
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

struct PendingWaveformView: View {
    let progress: Double
    let onSeek: (Double) -> Void

    @State private var hoverX: CGFloat? = nil

    private let placeholderSamples = WaveformResampler.placeholderSamples(count: 320)

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { timeline in
            GeometryReader { proxy in
                let size = proxy.size
                let time = timeline.date.timeIntervalSinceReferenceDate

                ZStack {
                    Canvas { context, size in
                        guard !placeholderSamples.isEmpty else { return }

                        let barWidth: CGFloat = 2
                        let barSpacing: CGFloat = 1
                        let barCount = max(1, Int((size.width + barSpacing) / (barWidth + barSpacing)))
                        let renderSamples = WaveformResampler.resample(placeholderSamples, to: barCount)
                        let clampedProgress = min(max(progress, 0), 1)
                        let progressIndex = min(Int(Double(barCount) * clampedProgress), barCount - 1)

                        for index in 0..<barCount {
                            let sample = animatedPlaceholderSample(
                                baseSample: CGFloat(renderSamples[index]),
                                index: index,
                                time: time
                            )
                            let barHeight = max(1, sample * size.height)
                            let x = CGFloat(index) * (barWidth + barSpacing)
                            let y = (size.height - barHeight) / 2
                            let rect = CGRect(x: x, y: y, width: barWidth, height: barHeight)
                            let shimmer = 0.08 + 0.08 * (0.5 + 0.5 * sin(time * 2.1 + Double(index) * 0.19))
                            let color = index <= progressIndex
                                ? Color.accentColor.opacity(0.84 + shimmer)
                                : Color.secondary.opacity(0.34 + shimmer * 0.35)
                            context.fill(
                                Path(roundedRect: rect, cornerRadius: barWidth / 2),
                                with: .color(color)
                            )
                        }

                        if let hx = hoverX, hx >= 0 {
                            let hoverIndex = min(Int(hx / (barWidth + barSpacing)), barCount - 1)

                            if hoverIndex > progressIndex {
                                for index in (progressIndex + 1)...hoverIndex {
                                    let x = CGFloat(index) * (barWidth + barSpacing)
                                    guard x + barWidth <= hx else { break }
                                    let sample = animatedPlaceholderSample(
                                        baseSample: CGFloat(renderSamples[index]),
                                        index: index,
                                        time: time
                                    )
                                    let barHeight = max(1, sample * size.height)
                                    let y = (size.height - barHeight) / 2
                                    let rect = CGRect(x: x, y: y, width: barWidth, height: barHeight)
                                    context.fill(
                                        Path(roundedRect: rect, cornerRadius: barWidth / 2),
                                        with: .color(Color.white.opacity(0.15))
                                    )
                                }
                            } else if hoverIndex < progressIndex {
                                for index in hoverIndex...progressIndex {
                                    let x = CGFloat(index) * (barWidth + barSpacing)
                                    let sample = animatedPlaceholderSample(
                                        baseSample: CGFloat(renderSamples[index]),
                                        index: index,
                                        time: time
                                    )
                                    let barHeight = max(1, sample * size.height)
                                    let y = (size.height - barHeight) / 2
                                    let rect = CGRect(x: x, y: y, width: barWidth, height: barHeight)
                                    context.fill(
                                        Path(roundedRect: rect, cornerRadius: barWidth / 2),
                                        with: .color(Color.black.opacity(0.3))
                                    )
                                }
                            }

                            let hoverSample = animatedPlaceholderSample(
                                baseSample: CGFloat(renderSamples[max(0, hoverIndex)]),
                                index: hoverIndex,
                                time: time
                            )
                            let lineHeight = max(1, hoverSample * size.height)
                            let lineY = (size.height - lineHeight) / 2
                            let lineRect = CGRect(x: hx - 0.5, y: lineY, width: 1, height: lineHeight)
                            context.fill(Path(lineRect), with: .color(Color.white.opacity(0.25)))
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

    private func animatedPlaceholderSample(baseSample: CGFloat, index: Int, time: TimeInterval) -> CGFloat {
        let normalizedIndex = Double(index) / 42.0
        let breathe = 0.72 + 0.28 * (0.5 + 0.5 * sin(time * 1.1))
        let travelingSwell = 0.78 + 0.34 * (0.5 + 0.5 * sin((time * 1.7) - normalizedIndex))
        let ripple = 0.90 + 0.14 * sin((time * 0.9) + normalizedIndex * 2.4)
        let animated = baseSample * breathe * travelingSwell * ripple
        return min(max(animated, 0.08), 0.98)
    }
}

struct PendingColoredWaveformView: View {
    let samples: [Float]
    let progress: Double
    let onSeek: (Double) -> Void

    @State private var hoverX: CGFloat? = nil

    var body: some View {
        TimelineView(.animation) { timeline in
            GeometryReader { proxy in
                let size = proxy.size
                let time = timeline.date.timeIntervalSinceReferenceDate

                ZStack {
                    Canvas { context, size in
                        guard !samples.isEmpty else { return }

                        let barWidth: CGFloat = 2
                        let barSpacing: CGFloat = 1
                        let barCount = max(1, Int((size.width + barSpacing) / (barWidth + barSpacing)))
                        let renderSamples = WaveformResampler.resample(samples, to: barCount)
                        let clampedProgress = min(max(progress, 0), 1)
                        let progressIndex = min(Int(Double(barCount) * clampedProgress), barCount - 1)

                        for index in 0..<barCount {
                            let sample = CGFloat(renderSamples[index])
                            let barHeight = max(1, sample * size.height)
                            let x = CGFloat(index) * (barWidth + barSpacing)
                            let y = (size.height - barHeight) / 2
                            let rect = CGRect(x: x, y: y, width: barWidth, height: barHeight)
                            let isPlayed = index <= progressIndex
                            let color = isPlayed
                                ? placeholderColor(
                                    for: index,
                                    barCount: barCount,
                                    time: time
                                )
                                : Color.secondary.opacity(0.45)
                            context.fill(
                                Path(roundedRect: rect, cornerRadius: barWidth / 2),
                                with: .color(color)
                            )
                        }

                        if let hx = hoverX, hx >= 0 {
                            let hoverIndex = min(Int(hx / (barWidth + barSpacing)), barCount - 1)

                            if hoverIndex > progressIndex {
                                for index in (progressIndex + 1)...hoverIndex {
                                    let x = CGFloat(index) * (barWidth + barSpacing)
                                    guard x + barWidth <= hx else { break }
                                    let sample = CGFloat(renderSamples[index])
                                    let barHeight = max(1, sample * size.height)
                                    let y = (size.height - barHeight) / 2
                                    let rect = CGRect(x: x, y: y, width: barWidth, height: barHeight)
                                    context.fill(
                                        Path(roundedRect: rect, cornerRadius: barWidth / 2),
                                        with: .color(Color.white.opacity(0.15))
                                    )
                                }
                            } else if hoverIndex < progressIndex {
                                for index in hoverIndex...progressIndex {
                                    let x = CGFloat(index) * (barWidth + barSpacing)
                                    let sample = CGFloat(renderSamples[index])
                                    let barHeight = max(1, sample * size.height)
                                    let y = (size.height - barHeight) / 2
                                    let rect = CGRect(x: x, y: y, width: barWidth, height: barHeight)
                                    context.fill(
                                        Path(roundedRect: rect, cornerRadius: barWidth / 2),
                                        with: .color(Color.black.opacity(0.3))
                                    )
                                }
                            }

                            let hoverSample = CGFloat(renderSamples[max(0, hoverIndex)])
                            let lineHeight = max(1, hoverSample * size.height)
                            let lineY = (size.height - lineHeight) / 2
                            let lineRect = CGRect(x: hx - 0.5, y: lineY, width: 1, height: lineHeight)
                            context.fill(Path(lineRect), with: .color(Color.white.opacity(0.25)))
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

    private func placeholderColor(
        for index: Int,
        barCount: Int,
        time: TimeInterval
    ) -> Color {
        let normalizedIndex = Double(index) / Double(max(barCount - 1, 1))
        let phase = time * 2.4 + normalizedIndex * 8.0
        let red = 0.5 + 0.5 * sin(phase)
        let green = 0.5 + 0.5 * sin(phase + (2 * .pi / 3))
        let blue = 0.5 + 0.5 * sin(phase + (4 * .pi / 3))

        return Color(
            .sRGB,
            red: 0.26 + red * 0.74,
            green: 0.26 + green * 0.74,
            blue: 0.26 + blue * 0.74,
            opacity: 0.96
        )
    }
}
