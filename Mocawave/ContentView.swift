import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

struct LoadingWaveformView: View {
    let title: String
    @State private var dotCount = 0
    private let timer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    init(title: String = "Loading waveform") {
        self.title = title
    }

    var body: some View {
        HStack(spacing: 0) {
            Text(title)
            Text(String(repeating: ".", count: dotCount))
        }
        .foregroundColor(.secondary)
        .onReceive(timer) { _ in
            withAnimation {
                dotCount = (dotCount + 1) % 4
            }
        }
    }
}

struct DebugWindow: View {
    @ObservedObject var viewModel: AudioPlayerViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Debug Log")
                .font(.headline)

            HStack {
                Text("isAnalyzingBPM:")
                Text(viewModel.isAnalyzingBPM ? "true" : "false")
                    .foregroundColor(viewModel.isAnalyzingBPM ? .yellow : .green)
            }
            HStack {
                Text("metadata BPM:")
                Text(viewModel.bpm.map { "\($0)" } ?? "nil")
                    .foregroundColor(viewModel.bpm != nil ? .green : .secondary)
            }
            HStack {
                Text("analyzed BPM:")
                Text(viewModel.analyzedBPM.map { "\($0)" } ?? "nil")
                    .foregroundColor(viewModel.analyzedBPM != nil ? .green : .secondary)
            }
            HStack {
                Text("isAnalyzingKey:")
                Text(viewModel.isAnalyzingKey ? "true" : "false")
                    .foregroundColor(viewModel.isAnalyzingKey ? .yellow : .green)
            }
            HStack {
                Text("key status:")
                Text(viewModel.keyAnalysisResult?.status.rawValue ?? "nil")
                    .foregroundColor(keyStatusColor(viewModel: viewModel))
            }
            HStack {
                Text("analyzed Key:")
                Text(debugKeyLabel(viewModel: viewModel))
                    .foregroundColor(keyStatusColor(viewModel: viewModel))
            }
            HStack {
                Text("camelot:")
                Text(viewModel.analyzedCamelot ?? "nil")
                    .foregroundColor(viewModel.analyzedCamelot != nil ? .green : .secondary)
            }
            HStack {
                Text("key confidence:")
                Text(viewModel.keyAnalysisResult.map { String(format: "%.2f", $0.confidence) } ?? "nil")
                    .foregroundColor(viewModel.keyAnalysisResult != nil ? .green : .secondary)
            }
            HStack {
                Text("key reason:")
                Text(viewModel.keyAnalysisResult?.uncertaintyReason?.rawValue ?? "nil")
                    .foregroundColor(viewModel.keyAnalysisResult?.uncertaintyReason != nil ? .orange : .secondary)
            }

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(viewModel.debugLog.enumerated()), id: \.offset) { index, log in
                            Text(log)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(.secondary)
                                .id(index)
                        }
                    }
                }
                .onChange(of: viewModel.debugLog.count) { _ in
                    if let last = viewModel.debugLog.indices.last {
                        proxy.scrollTo(last, anchor: .bottom)
                    }
                }
            }

            HStack {
                Button("Copy Logs") {
                    let text = viewModel.debugLogSnapshot().joined(separator: "\n")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                Button("Clear Log") {
                    viewModel.clearDebugLog()
                }
            }
        }
        .padding()
        .frame(width: 400, height: 300)
    }

    private func debugKeyLabel(viewModel: AudioPlayerViewModel) -> String {
        if let keyResult = viewModel.keyAnalysisResult {
            if keyResult.isResolved {
                return keyResult.key ?? "nil"
            }
            return "UNCERTAIN"
        }
        return "nil"
    }

    private func keyStatusColor(viewModel: AudioPlayerViewModel) -> Color {
        guard let keyResult = viewModel.keyAnalysisResult else { return .secondary }
        return keyResult.isResolved ? .green : .orange
    }
}

class FixedHeightWindowDelegate: NSObject, NSWindowDelegate {
    static var associatedKey = 0
    var fixedHeight: CGFloat
    init(fixedHeight: CGFloat) {
        self.fixedHeight = fixedHeight
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        let clampedWidth = min(max(frameSize.width, sender.minSize.width), sender.maxSize.width)
        let fixedFrameHeight = sender.frameRect(
            forContentRect: NSRect(origin: .zero, size: NSSize(width: clampedWidth, height: fixedHeight))
        ).height
        return NSSize(width: clampedWidth, height: fixedFrameHeight)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        MainActor.assumeIsolated {
            TabStore.shared.closeAll()   // the red button closes the window and every tab in it
        }
        return true
    }
}

struct VolumeFaceView: View {
    static let preferredWidth: CGFloat = 48
    static let preferredHeight: CGFloat = 36
    static let xEyesActivityThreshold: Double = 0.7

    let expression: Double
    let isDisabled: Bool
    let isSleeping: Bool
    let isAngry: Bool
    /// Drop moment: the whole mascot turns the drop red.
    var isDropping: Bool = false

    static func normalizedActivity(for expression: Double) -> Double {
        let clampedExpression = min(max(expression, -1), 1)
        return (clampedExpression + 1) / 2
    }

    static func usesXEyes(for expression: Double) -> Bool {
        normalizedActivity(for: expression) > xEyesActivityThreshold
    }

    private var clampedSmileExpression: Double {
        min(max(displayedSmileExpression, -0.4), 1)
    }

    private var displayedActivityExpression: Double {
        if isSleeping {
            return -0.6
        }
        if isAngry {
            return -0.2
        }
        return expression
    }

    private var displayedSmileExpression: Double {
        isSleeping ? 0.16 : expression
    }

    private var activity: Double {
        Self.normalizedActivity(for: displayedActivityExpression)
    }

    private var strokeColor: Color {
        if isDropping { return MocaTheme.Cue.drop }
        return Color.white.opacity(isDisabled ? 0.26 : 0.72)
    }

    private var accentColor: Color {
        if isDropping { return MocaTheme.Cue.drop }
        return Color.white.opacity(isDisabled ? 0.20 : 0.88)
    }

    var body: some View {
        GeometryReader { geometry in
            let drawingScale = min(
                geometry.size.width / Self.preferredWidth,
                geometry.size.height / Self.preferredHeight
            )
            let mugWidth = geometry.size.width * 0.44
            let mugHeight = geometry.size.height * 0.82
            let mugRect = CGRect(
                x: (geometry.size.width - mugWidth) / 2 - drawingScale,
                y: drawingScale,
                width: mugWidth,
                height: mugHeight
            )
            let rimY = mugRect.minY + mugHeight * 0.12
            let coffeeY = mugRect.minY + mugHeight * 0.24
            let mugBaseY = mugRect.maxY - mugHeight * 0.05
            let mugBaseInset = mugWidth * 0.14
            let mugWallInset = mugWidth * 0.04
            let eyeY = mugRect.midY - mugHeight * 0.06
            let eyeOffsetX = mugWidth * 0.15
            let eyeWidth = max(2.0 * drawingScale, mugWidth * 0.10)
            let eyeHeight = max(3.0 * drawingScale, mugHeight * 0.16)
            let showsXEyes = !isSleeping && Self.usesXEyes(for: expression)
            let xEyeSize = max(3.0 * drawingScale, mugWidth * 0.13)
            let xEyeLineWidth = 1.1 * drawingScale
            let leftEyeCenter = CGPoint(x: mugRect.midX - eyeOffsetX, y: eyeY)
            let rightEyeCenter = CGPoint(x: mugRect.midX + eyeOffsetX, y: eyeY)
            let sleepyEyeWidth = max(5.0 * drawingScale, mugWidth * 0.21)
            let smileY = mugRect.midY + mugHeight * 0.18
            let smileInset = mugWidth * 0.24
            let smileControlY = isAngry
                ? smileY
                : smileY + clampedSmileExpression * mugHeight * 0.22
            let shoulderY = mugRect.midY + mugHeight * 0.02
            let armDrop = geometry.size.height * 0.3
            let armLift = geometry.size.height * 0.9
            let handY = shoulderY + armDrop - activity * armLift
            let armSpread = mugWidth * (0.20 + activity * 0.20)
            let leftShoulder = CGPoint(x: mugRect.minX + mugWidth * 0.10, y: shoulderY)
            let rightShoulder = CGPoint(x: mugRect.maxX - mugWidth * 0.08, y: shoulderY)
            let leftHand = CGPoint(x: mugRect.minX - armSpread, y: handY)
            let rightHand = CGPoint(x: mugRect.maxX + armSpread, y: handY)
            let handSize = max(2.4 * drawingScale, mugWidth * 0.12)
            let armLineWidth = (1.2 + activity * 0.18) * drawingScale
            let smileLineWidth = (1.5 + activity * 0.25) * drawingScale
            let eyebrowWidth = max(6.0 * drawingScale, mugWidth * 0.20)
            let eyebrowLift = mugHeight * 0.10
            let eyebrowTilt = mugHeight * 0.05

            ZStack {
                Path { path in
                    path.move(to: CGPoint(x: mugRect.minX + mugWallInset, y: rimY))
                    path.addLine(to: CGPoint(x: mugRect.maxX - mugWallInset, y: rimY))
                    path.addLine(to: CGPoint(x: mugRect.maxX - mugBaseInset, y: mugBaseY))
                    path.addQuadCurve(
                        to: CGPoint(x: mugRect.minX + mugBaseInset, y: mugBaseY),
                        control: CGPoint(x: mugRect.midX, y: mugRect.maxY + mugHeight * 0.06)
                    )
                    path.addLine(to: CGPoint(x: mugRect.minX + mugWallInset, y: rimY))
                }
                .fill(isDropping ? MocaTheme.Cue.drop.opacity(0.35) : Color.white.opacity(isDisabled ? 0.05 : 0.08))

                Path { path in
                    path.move(to: leftShoulder)
                    path.addLine(to: leftHand)
                    path.move(to: rightShoulder)
                    path.addLine(to: rightHand)
                }
                .stroke(accentColor.opacity(0.92), style: StrokeStyle(lineWidth: armLineWidth, lineCap: .round, lineJoin: .round))

                Path { path in
                    path.move(to: CGPoint(x: mugRect.minX + mugWallInset, y: rimY))
                    path.addLine(to: CGPoint(x: mugRect.maxX - mugWallInset, y: rimY))
                    path.addLine(to: CGPoint(x: mugRect.maxX - mugBaseInset, y: mugBaseY))
                    path.addQuadCurve(
                        to: CGPoint(x: mugRect.minX + mugBaseInset, y: mugBaseY),
                        control: CGPoint(x: mugRect.midX, y: mugRect.maxY + mugHeight * 0.06)
                    )
                    path.addLine(to: CGPoint(x: mugRect.minX + mugWallInset, y: rimY))
                }
                .stroke(
                    strokeColor.opacity(0.88),
                    style: StrokeStyle(lineWidth: 1.2 * drawingScale, lineCap: .round, lineJoin: .round)
                )

                Path { path in
                    path.move(to: CGPoint(x: mugRect.minX + mugWidth * 0.14, y: coffeeY))
                    path.addQuadCurve(
                        to: CGPoint(x: mugRect.maxX - mugWidth * 0.14, y: coffeeY),
                        control: CGPoint(x: mugRect.midX, y: coffeeY - mugHeight * 0.10)
                    )
                    path.move(to: CGPoint(x: mugRect.minX + mugWidth * 0.24, y: mugBaseY - mugHeight * 0.04))
                    path.addQuadCurve(
                        to: CGPoint(x: mugRect.maxX - mugWidth * 0.24, y: mugBaseY - mugHeight * 0.04),
                        control: CGPoint(x: mugRect.midX, y: mugBaseY + mugHeight * 0.02)
                    )
                }
                .stroke(
                    strokeColor.opacity(0.60),
                    style: StrokeStyle(lineWidth: 1.0 * drawingScale, lineCap: .round)
                )

                if showsXEyes {
                    Path { path in
                        path.move(to: CGPoint(x: leftEyeCenter.x - xEyeSize / 2, y: leftEyeCenter.y - xEyeSize / 2))
                        path.addLine(to: CGPoint(x: leftEyeCenter.x + xEyeSize / 2, y: leftEyeCenter.y + xEyeSize / 2))
                        path.move(to: CGPoint(x: leftEyeCenter.x - xEyeSize / 2, y: leftEyeCenter.y + xEyeSize / 2))
                        path.addLine(to: CGPoint(x: leftEyeCenter.x + xEyeSize / 2, y: leftEyeCenter.y - xEyeSize / 2))

                        path.move(to: CGPoint(x: rightEyeCenter.x - xEyeSize / 2, y: rightEyeCenter.y - xEyeSize / 2))
                        path.addLine(to: CGPoint(x: rightEyeCenter.x + xEyeSize / 2, y: rightEyeCenter.y + xEyeSize / 2))
                        path.move(to: CGPoint(x: rightEyeCenter.x - xEyeSize / 2, y: rightEyeCenter.y + xEyeSize / 2))
                        path.addLine(to: CGPoint(x: rightEyeCenter.x + xEyeSize / 2, y: rightEyeCenter.y - xEyeSize / 2))
                    }
                    .stroke(accentColor, style: StrokeStyle(lineWidth: xEyeLineWidth, lineCap: .round))
                } else if isSleeping {
                    Path { path in
                        path.move(
                            to: CGPoint(
                                x: leftEyeCenter.x - sleepyEyeWidth / 2,
                                y: leftEyeCenter.y
                            )
                        )
                        path.addLine(
                            to: CGPoint(
                                x: leftEyeCenter.x + sleepyEyeWidth / 2,
                                y: leftEyeCenter.y
                            )
                        )

                        path.move(
                            to: CGPoint(
                                x: rightEyeCenter.x - sleepyEyeWidth / 2,
                                y: rightEyeCenter.y
                            )
                        )
                        path.addLine(
                            to: CGPoint(
                                x: rightEyeCenter.x + sleepyEyeWidth / 2,
                                y: rightEyeCenter.y
                            )
                        )
                    }
                    .stroke(
                        accentColor.opacity(0.96),
                        style: StrokeStyle(lineWidth: 1.2 * drawingScale, lineCap: .round, lineJoin: .round)
                    )
                } else {
                    Ellipse()
                        .fill(accentColor)
                        .frame(width: eyeWidth, height: eyeHeight)
                        .position(leftEyeCenter)

                    Ellipse()
                        .fill(accentColor)
                        .frame(width: eyeWidth, height: eyeHeight)
                        .position(rightEyeCenter)
                }

                if isAngry && !showsXEyes && !isSleeping {
                    Path { path in
                        path.move(
                            to: CGPoint(
                                x: leftEyeCenter.x - eyebrowWidth / 2,
                                y: leftEyeCenter.y - eyebrowLift - eyebrowTilt / 2
                            )
                        )
                        path.addLine(
                            to: CGPoint(
                                x: leftEyeCenter.x + eyebrowWidth / 2,
                                y: leftEyeCenter.y - eyebrowLift + eyebrowTilt / 2
                            )
                        )

                        path.move(
                            to: CGPoint(
                                x: rightEyeCenter.x - eyebrowWidth / 2,
                                y: rightEyeCenter.y - eyebrowLift + eyebrowTilt / 2
                            )
                        )
                        path.addLine(
                            to: CGPoint(
                                x: rightEyeCenter.x + eyebrowWidth / 2,
                                y: rightEyeCenter.y - eyebrowLift - eyebrowTilt / 2
                            )
                        )
                    }
                    .stroke(
                        accentColor.opacity(0.98),
                        style: StrokeStyle(lineWidth: 1.2 * drawingScale, lineCap: .round)
                    )
                }

                Path { path in
                    path.move(to: CGPoint(x: mugRect.minX + smileInset, y: smileY))
                    path.addQuadCurve(
                        to: CGPoint(x: mugRect.maxX - smileInset, y: smileY),
                        control: CGPoint(x: mugRect.midX, y: smileControlY)
                    )
                }
                .stroke(accentColor, style: StrokeStyle(lineWidth: smileLineWidth, lineCap: .round))

                Circle()
                    .fill(accentColor)
                    .frame(width: handSize, height: handSize)
                    .position(leftHand)

                Circle()
                    .fill(accentColor)
                    .frame(width: handSize, height: handSize)
                    .position(rightHand)
            }
        }
        .aspectRatio(Self.preferredWidth / Self.preferredHeight, contentMode: .fit)
        .opacity(isDisabled ? 0.7 : 1)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

enum CoffeeSteamStyle {
    case steam
    case sleep
    case co2   // drop moment: dense white jet
}

struct CoffeeSteamView: View {
    let expression: Double
    let isDisabled: Bool
    let cupHeight: CGFloat
    let style: CoffeeSteamStyle

    private let columnOffsets: [CGFloat] = [-0.16, 0.0, 0.16]
    private let sleepOffsets: [CGFloat] = [-0.10, 0.02, 0.16]
    private let co2Offsets: [CGFloat] = [-0.2, -0.1, 0, 0.1, 0.2]

    var body: some View {
        GeometryReader { geometry in
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { context in
                let size = geometry.size
                let rise = min(size.height * 0.42, cupHeight * 0.68) * 0.5
                let cupTop = size.height - cupHeight
                let startY = cupTop + cupHeight * 0.48 - 25
                let time = context.date.timeIntervalSinceReferenceDate

                ZStack {
                    switch style {
                    case .steam:
                        let lineWidth = max(2.2, cupHeight * 0.024)
                        let visibleColumnIndices = VolumeFaceView.usesXEyes(for: expression) ? Array(columnOffsets.indices) : [1]

                        ForEach(visibleColumnIndices, id: \.self) { index in
                            let offset = columnOffsets[index]
                            let path = steamPath(
                                in: size,
                                columnOffset: offset,
                                index: index,
                                time: time,
                                startY: startY,
                                rise: rise
                            )
                            let opacityPulse = 0.76 + 0.24 * sin(time * 1.35 + Double(index) * 0.85)
                            let softOpacity = (isDisabled ? 0.08 : 0.16) * opacityPulse
                            let coreOpacity = (isDisabled ? 0.15 : 0.30) * opacityPulse

                            path
                                .trim(from: 0.06, to: 1)
                                .stroke(
                                    Color.white.opacity(softOpacity),
                                    style: StrokeStyle(lineWidth: lineWidth * 2.4, lineCap: .round, lineJoin: .round)
                                )
                                .blur(radius: lineWidth * 0.9)

                            path
                                .trim(from: 0.06, to: 1)
                                .stroke(
                                    Color.white.opacity(coreOpacity),
                                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
                                )
                        }
                    case .co2:
                        // Five fast, nearly straight columns with dashes racing upward: a CO2 burst.
                        let lineWidth = max(3, cupHeight * 0.05)
                        ForEach(co2Offsets.indices, id: \.self) { index in
                            let x = size.width * (0.5 + co2Offsets[index])
                            let sway = CGFloat(sin(time * 9 + Double(index) * 1.7)) * size.width * 0.012
                            let top = startY - rise * (1.5 + 0.12 * CGFloat(sin(time * 7 + Double(index))))
                            let jet = Path { path in
                                path.move(to: CGPoint(x: x, y: startY))
                                path.addLine(to: CGPoint(x: x + sway, y: top))
                            }
                            jet.stroke(Color.white.opacity(0.35),
                                       style: StrokeStyle(lineWidth: lineWidth * 2.6, lineCap: .round))
                                .blur(radius: lineWidth)
                            jet.stroke(Color.white.opacity(0.9),
                                       style: StrokeStyle(lineWidth: lineWidth, lineCap: .round,
                                                          dash: [lineWidth * 2.2, lineWidth * 1.4],
                                                          dashPhase: CGFloat(time * 140)))
                        }
                    case .sleep:
                        ForEach(sleepOffsets.indices, id: \.self) { index in
                            let travelProgress = (time * 0.28 + Double(index) * 0.23).truncatingRemainder(dividingBy: 1)
                            let verticalLift = rise * CGFloat(0.14 + travelProgress * 0.98)
                            let drift = CGFloat(sin(time * 1.7 + Double(index) * 1.3)) * size.width * 0.035
                            let horizontalOffset = size.width * sleepOffsets[index] + drift
                            let fontSize = max(10, cupHeight * (0.14 + CGFloat(index) * 0.02 + CGFloat(travelProgress) * 0.015))
                            let opacity = (isDisabled ? 0.16 : 0.34) * (1.04 - travelProgress * 0.42)

                            Text("ZzZ")
                                .font(.system(size: fontSize, weight: .bold, design: .rounded))
                                .foregroundStyle(Color.white.opacity(opacity))
                                .rotationEffect(.degrees(-12 + Double(index) * 5))
                                .scaleEffect(0.88 + CGFloat(travelProgress) * 0.24)
                                .offset(x: horizontalOffset, y: -verticalLift - 22)
                                .blur(radius: CGFloat(0.2 + travelProgress * 0.6))
                        }
                    }
                }
                .frame(width: size.width, height: size.height)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func steamPath(
        in size: CGSize,
        columnOffset: CGFloat,
        index: Int,
        time: TimeInterval,
        startY: CGFloat,
        rise: CGFloat
    ) -> Path {
        let baseX = size.width * (0.5 + columnOffset)
        let phase = time * (0.9 + Double(index) * 0.12) + Double(index) * 1.6
        let firstBend = CGFloat(sin(phase * 1.25)) * size.width * 0.035
        let secondBend = CGFloat(cos(phase * 1.55 + 0.5)) * size.width * 0.06
        let thirdBend = CGFloat(sin(phase * 1.15 + 1.4)) * size.width * 0.08

        let p0 = CGPoint(x: baseX, y: startY)
        let p1 = CGPoint(x: baseX + firstBend, y: startY - rise * 0.26)
        let p2 = CGPoint(x: baseX + secondBend, y: startY - rise * 0.58)
        let p3 = CGPoint(x: baseX + thirdBend, y: startY - rise * 0.98)

        var path = Path()
        path.move(to: p0)
        path.addCurve(
            to: p1,
            control1: CGPoint(x: baseX + firstBend * 0.30, y: startY - rise * 0.10),
            control2: CGPoint(x: baseX + firstBend, y: startY - rise * 0.18)
        )
        path.addCurve(
            to: p2,
            control1: CGPoint(x: p1.x - firstBend * 0.16, y: startY - rise * 0.38),
            control2: CGPoint(x: p2.x, y: startY - rise * 0.48)
        )
        path.addCurve(
            to: p3,
            control1: CGPoint(x: p2.x, y: startY - rise * 0.74),
            control2: CGPoint(x: p3.x, y: startY - rise * 0.88)
        )
        return path
    }
}

struct CoffeeMessageArrowShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let width = rect.width
        let height = rect.height
        let bodyEndX = rect.maxX - width * 0.18
        let cornerRadius = height * 0.28

        path.move(to: CGPoint(x: rect.minX + cornerRadius, y: rect.minY))
        path.addLine(to: CGPoint(x: bodyEndX - cornerRadius * 0.45, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: bodyEndX, y: rect.minY + height * 0.18),
            control: CGPoint(x: bodyEndX + cornerRadius * 0.34, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: bodyEndX, y: rect.maxY - height * 0.18))
        path.addQuadCurve(
            to: CGPoint(x: bodyEndX - cornerRadius * 0.45, y: rect.maxY),
            control: CGPoint(x: bodyEndX + cornerRadius * 0.34, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.minX + cornerRadius, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.maxY - cornerRadius),
            control: CGPoint(x: rect.minX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + cornerRadius))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + cornerRadius, y: rect.minY),
            control: CGPoint(x: rect.minX, y: rect.minY)
        )
        path.closeSubpath()
        return path
    }
}

struct CoffeeMessageArrowView: View {
    private let arrowFill = Color(red: 0.31, green: 0.33, blue: 0.37)
    private let accentFill = Color.accentColor

    var body: some View {
        ZStack(alignment: .leading) {
            Group {
                CoffeeMessageArrowShape()
                    .fill(accentFill.opacity(0.94))
                    .frame(width: 226, height: 52)
                    .offset(x: 5, y: 5)
            }

            Group {
                CoffeeMessageArrowShape()
                    .fill(arrowFill)
                    .frame(width: 226, height: 52)
                    .overlay(
                        CoffeeMessageArrowShape()
                            .stroke(
                                Color.black.opacity(0.96),
                                style: StrokeStyle(lineWidth: 3.2, lineCap: .round, lineJoin: .round)
                            )
                    )
            }

            Capsule()
                .fill(Color.white.opacity(0.08))
                .frame(width: 108, height: 10)
                .offset(x: 20, y: -11)

            Text("FEED ME WITH MUSIC,\nYOU MONSTER!!")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(.white.opacity(0.92))
                .multilineTextAlignment(.center)
                .lineSpacing(1)
                .frame(width: 164)
                .offset(x: 16, y: -1)
        }
        .rotationEffect(.degrees(-2))
        .shadow(color: Color.black.opacity(0.18), radius: 8, y: 3)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct PlayPauseButton: View {
    static let size: CGFloat = 56

    let isPlaying: Bool
    let isDisabled: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 24))
                .frame(width: Self.size, height: Self.size)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.white.opacity(isHovered ? 0.05: 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
        .disabled(isDisabled)
    }
}

struct TopBarDividerView: View {
    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.08))
            .frame(width: 1)
            .padding(.vertical, 4)
    }
}

struct TopBarValueCell: View {
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 5) {
            Text(title)
                .font(.system(size: 8, weight: .semibold, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(1)

            Text(value)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(.white.opacity(0.92))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

struct TopBarMeterCell: View {
    let label: String
    let value: String
    let normalizedLevel: Double?

    private var displayLevel: Double {
        guard let normalizedLevel else { return 0 }
        return min(max(normalizedLevel, 0), 1)
    }

    var body: some View {
        HStack {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.black.opacity(0.26))

                GeometryReader { proxy in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.white.opacity(0.52))
                        .frame(width: proxy.size.width * displayLevel)
                }

                HStack(spacing: 4) {
                    Text(label)
                        .font(.system(size: 7, weight: .semibold, design: .monospaced))
                        .foregroundColor(.white.opacity(0.72))
                        .lineLimit(1)

                    Spacer(minLength: 0)

                    Text(value)
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundColor(.white.opacity(0.92))
                        .lineLimit(1)
                        .minimumScaleFactor(0.68)
                }
                .padding(.horizontal, 4)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(height: 14)
            .overlay(
                RoundedRectangle(cornerRadius: 2)
                    .stroke(Color.white.opacity(0.1), lineWidth: 1)
            )
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

struct TopBarQualityCell: View {
    let value: String

    var body: some View {
        HStack(spacing: 5) {
            Text("REAL QUALITY")
                .font(.system(size: 8, weight: .semibold, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(1)

            Text(value)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(.white.opacity(0.9))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .padding(.horizontal, 8)
        .frame(minWidth: 155, maxHeight: .infinity, alignment: .leading)
    }
}

struct TopBarWaveformToggleCell: View {
    let isOn: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: isOn ? "checkmark.square.fill" : "square")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(iconColor)

                Text("RGB WAVE")
                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.86))
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(
                Rectangle()
                    .fill(Color.white.opacity(isHovered ? 0.05 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
        .help("Toggle colored waveform")
    }

    private var iconColor: Color {
        isOn ? Color.accentColor : Color.white.opacity(0.72)
    }
}

struct TopBarInstagramCell: View {
    private let url = URL(string: "https://instagram.com/perezdjj")!

    var body: some View {
        Button {
            NSWorkspace.shared.open(url)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "camera")
                    .font(.system(size: 7, weight: .semibold))
                    .foregroundColor(.white.opacity(0.92))

                Text("@PEREZDJJ")
                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open instagram.com/perezdjj")
    }
}

struct ContentView: View {
    @StateObject private var viewModel: AudioPlayerViewModel
    @State private var isDropTargeted = false
    @State private var isImportingAudio = false
    @State private var keyMonitor: Any?
    @State private var windowRef: NSWindow?
    @State private var showDebugWindow = false
    @State private var openDrawers: Set<InspectorDrawer> = []
    @State private var camelotSelection: CamelotKey?
    /// Applied stems panel height: follows the content (state, collapsed lanes) a beat later, together with
    /// the window, so quick state hops (idle → loading → ready on a cached track) resize once.
    @State private var stemsPanelHeight: CGFloat = StemLanesView.panelHeight(state: StemsState.initial, lanes: [])
    @State private var stemsResizeTask: Task<Void, Never>?
    private let seekStep: TimeInterval = 5
    private static let controlRowSpacing: CGFloat = 12
    private static let topBarHeight: CGFloat = 22
    private static let mainControlHeight: CGFloat = 84
    private static let coffeeScale: CGFloat = 1.72
    private static let coffeeWidth: CGFloat = VolumeFaceView.preferredWidth * coffeeScale
    private static let coffeeHeight: CGFloat = VolumeFaceView.preferredHeight * coffeeScale
    private static let coffeeSlotWidth: CGFloat = coffeeWidth - 14
    private static let stripHorizontalPadding: CGFloat = 14
    private static let titleBarInset: CGFloat = 30            // transparent title bar over the content
    // inset 30 + bar 22 + 8 + wave 84 + bottom 18, plus the footer row (18 + 8) only when track info is on.
    private static let windowContentHeight: CGFloat = FeatureFlags.trackInfo ? 188 : 162
    // Dev builds carry the STEMS cell in the top bar.
    private static let minimumWindowWidth: CGFloat = FeatureFlags.trackInfo ? 806 + TopBarStemsCell.width + 1 : 806
    private static let drawerInnerPadding: CGFloat = 12
    /// Lanes in the stems drawer use the strip's columns: under the play button / waveform box / mascot.
    private static let stemColumns = StemLaneColumns(
        leading: PlayPauseButton.size + controlRowSpacing - drawerInnerPadding,
        trailing: coffeeSlotWidth + controlRowSpacing - drawerInnerPadding
    )
    private static let supportedAudioContentTypes = ["mp3", "wav", "aac", "m4a", "flac", "aif", "aiff"].compactMap { UTType(filenameExtension: $0) }

    /// The tab this view shows; drawers and the Camelot selection are kept on it across tab switches.
    private let tab: PlayerTab

    @MainActor
    init(tab: PlayerTab) {
        self.tab = tab
        _viewModel = StateObject(wrappedValue: tab.viewModel)
        _openDrawers = State(initialValue: tab.openDrawers)
        _camelotSelection = State(initialValue: tab.camelotSelection)
        _stemsPanelHeight = State(initialValue: StemLanesView.panelHeight(state: tab.viewModel.stemsState,
                                                                         lanes: tab.viewModel.stemLanes))
    }

    var body: some View {
        let isSleepMode = viewModel.duration > 0 && !viewModel.isPlaying

        VStack(spacing: 0) {
        VStack(alignment: .leading, spacing: 8) {
            topBar

            HStack(spacing: Self.controlRowSpacing) {
                PlayPauseButton(isPlaying: viewModel.isPlaying, isDisabled: viewModel.duration == 0) {
                    viewModel.togglePlay()
                }
                .frame(width: PlayPauseButton.size, height: Self.mainControlHeight)

                ZStack {
                    if viewModel.showSpectrogram {
                        SpectrogramView(
                            image: viewModel.spectrogramImage,
                            progress: viewModel.progress,
                            onSeek: { fraction in
                                viewModel.seekToFraction(fraction)
                            }
                        )
                        if viewModel.spectrogramImage == nil && viewModel.isAnalyzingSpectrogram {
                            LoadingWaveformView()
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    } else {
                        if viewModel.shouldRenderColoredWaveform {
                            if let coloredWaveform = viewModel.coloredWaveformData {
                                ColoredWaveformView(
                                    samples: viewModel.waveformSamples,
                                    data: coloredWaveform,
                                    progress: viewModel.progress,
                                    onSeek: { fraction in
                                        viewModel.seekToFraction(fraction)
                                    }
                                )
                            } else if viewModel.isAnalyzingColoredWaveform && !viewModel.waveformSamples.isEmpty {
                                PendingColoredWaveformView(
                                    samples: viewModel.waveformSamples,
                                    progress: viewModel.progress,
                                    onSeek: { fraction in
                                        viewModel.seekToFraction(fraction)
                                    }
                                )
                            } else {
                                WaveformView(
                                    samples: viewModel.waveformSamples,
                                    progress: viewModel.progress,
                                    onSeek: { fraction in
                                        viewModel.seekToFraction(fraction)
                                    }
                                )
                            }
                        } else {
                            WaveformView(
                                samples: viewModel.waveformSamples,
                                progress: viewModel.progress,
                                onSeek: { fraction in
                                    viewModel.seekToFraction(fraction)
                                },
                                sections: waveformSections
                            )
                        }
                        if viewModel.waveformSamples.isEmpty {
                            if viewModel.duration > 0 {
                                ZStack {
                                    PendingWaveformView(
                                        progress: viewModel.progress,
                                        onSeek: { fraction in
                                            viewModel.seekToFraction(fraction)
                                        }
                                    )

                                    LoadingWaveformView()
                                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                                        .allowsHitTesting(false)
                                }
                            } else {
                                Text("Drop an audio or click to open")
                                    .foregroundColor(.secondary)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        requestAudioImport()
                                    }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, minHeight: Self.mainControlHeight, maxHeight: Self.mainControlHeight)
                .overlay {
                    if viewModel.duration > 0, !viewModel.waveformSamples.isEmpty {
                        CueFlagsOverlay(
                            cues: viewModel.cues,
                            duration: viewModel.duration,
                            grid: viewModel.beatGrid,
                            animateIn: viewModel.cuesJustDetected,
                            selectedID: $viewModel.selectedCueID,
                            onSeek: { viewModel.seek(to: $0) },
                            onMove: { id, time, snap in viewModel.moveCue(id: id, to: time, snap: snap) }
                        )
                    }
                }
                .background(MocaTheme.panelBackground)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(
                            isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.3),
                            style: StrokeStyle(
                                lineWidth: isDropTargeted ? 2 : 1,
                                dash: isDropTargeted ? [6, 4] : []
                            )
                        )
                )
                .overlay(alignment: viewModel.progress > 0.5 ? .bottomLeading : .bottomTrailing) {
                    if let playbackTimeText = playbackTimeText(viewModel: viewModel) {
                        Text(playbackTimeText)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundColor(.white.opacity(0.86))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(Color.black.opacity(0.72))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 5)
                                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
                            )
                            .padding(viewModel.progress > 0.5 ? .leading : .trailing, 8)
                            .padding(.bottom, 8)
                            .allowsHitTesting(false)
                    }
                }
                .overlay {
                    // Errors: one quiet line over the waveform (full text on hover), never growing the window.
                    if let errorMessage = viewModel.errorMessage {
                        HStack(spacing: MocaSpace.xs) {
                            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9, weight: .semibold))
                            Text(errorMessage).font(.system(size: 10, weight: .medium)).lineLimit(1).truncationMode(.middle)
                        }
                        .foregroundColor(.white.opacity(0.92))
                        .padding(.horizontal, MocaSpace.s)
                        .frame(height: 20)
                        .background(Capsule().fill(MocaTheme.Cue.drop.opacity(0.85)))
                        .padding(.horizontal, MocaSpace.l)
                        .help(errorMessage)
                    }
                }
                .overlay(alignment: .trailing) {
                    if viewModel.duration == 0 {
                        CoffeeMessageArrowView()
                            .padding(.trailing, 10)
                            .offset(x: 20, y: -1)
                    }
                }

                ZStack(alignment: .bottom) {
                    if viewModel.duration > 0 {
                        CoffeeSteamView(
                            expression: viewModel.isDropMoment ? 1 : viewModel.faceExpression,
                            isDisabled: false,
                            cupHeight: Self.coffeeHeight,
                            // Reduce Motion: the colour change alone marks the drop.
                            style: viewModel.isDropMoment && !MocaMotion.reduceMotion ? .co2 : (viewModel.isPlaying ? .steam : .sleep)
                        )
                        .frame(width: Self.coffeeWidth, height: Self.mainControlHeight)
                    }

                    VolumeFaceView(
                        expression: viewModel.isDropMoment ? 1 : viewModel.faceExpression,
                        isDisabled: false,
                        isSleeping: isSleepMode,
                        isAngry: viewModel.duration == 0,
                        isDropping: viewModel.isDropMoment
                    )
                    // In fast (120 ms), out slower (400 ms).
                    .animation(viewModel.isDropMoment ? .easeOut(duration: 0.12) : .easeOut(duration: 0.4),
                               value: viewModel.isDropMoment)
                    .frame(width: Self.coffeeWidth, height: Self.coffeeHeight)
                }
                .frame(width: Self.coffeeSlotWidth, height: Self.mainControlHeight, alignment: .bottom)
            }

            // Track info (dev feature): under the waveform and aligned with it.
            if FeatureFlags.trackInfo, viewModel.duration > 0 {
                TrackInfoFooter(state: viewModel.trackInfo, onRetry: { viewModel.retryTrackInfo() },
                                engine: viewModel.engineStart, onStartEngine: { viewModel.startLocalEngine() })
                    // Inset to the waveform box: starts under its first flag, ends under its right edge.
                    .padding(.leading, PlayPauseButton.size + Self.controlRowSpacing + MocaSpace.xs)
                    .padding(.trailing, Self.coffeeSlotWidth + Self.controlRowSpacing + MocaSpace.s)
            }

        }
        // Anchored under the title bar with a bottom margin equal to the side margins (the content used to be
        // centred, leaving a double gap under the footer).
        .padding(.top, Self.titleBarInset)
        .frame(height: Self.windowContentHeight, alignment: .top)
        // The strip never inherits the drawer's spring: without this the waveform bars re-laid out with
        // the drawer animation every time the Camelot opened or closed.
        .transaction { $0.animation = nil }

            ForEach(orderedOpenDrawers) { drawer in
                drawerPanel(drawer)
                .padding(.top, InspectorDrawer.gap)
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .offset(y: -12)),
                    removal: .opacity.combined(with: .offset(y: -6))
                ))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.horizontal, 14)
        // Tabs live in the title bar band (the 30 pt inset above the top bar), full window width.
        .overlay(alignment: .top) { TabStrip(store: TabStore.shared) }
        .background(
            Group {
                Button("") { showDebugWindow.toggle() }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                    .hidden()
            }
        )
        .configureWindow { window in
            windowRef = window
            applyWindowStyle(window)
        }
        .preferredColorScheme(.dark)
        .ignoresSafeArea()
        .onDrop(of: [UTType.fileURL], isTargeted: $isDropTargeted) { providers in
            TabStore.shared.handleDrop(providers)   // into this tab if it's empty, else new tabs
        }
        .onAppear {
            installKeyMonitor()
        }
        .onDisappear {
            removeKeyMonitor()
        }
        .onChange(of: viewModel.fileName) { newName in
            windowRef?.title = newName
        }
        .onChange(of: openDrawers) { tab.openDrawers = $0 }
        .onChange(of: camelotSelection) { tab.camelotSelection = $0 }
        .onChange(of: viewModel.keyAnalysisResult) { result in
            camelotSelection = TrackCamelot(result).primary
        }
        .onChange(of: targetStemsPanelHeight) { height in
            scheduleStemsResize(to: height)
        }
        .fileImporter(
            isPresented: $isImportingAudio,
            allowedContentTypes: Self.supportedAudioContentTypes,
            allowsMultipleSelection: false,
            onCompletion: handleImportedAudio
        )
        .sheet(isPresented: $showDebugWindow) {
            DebugWindow(viewModel: viewModel)
        }
    }

    private var topBar: some View {
        HStack(spacing: 0) {
            TopBarMeterCell(
                label: "LUFS",
                value: lufsDisplayText(viewModel: viewModel),
                normalizedLevel: normalizedLUFSLevel(viewModel: viewModel)
            )
            .frame(width: 112)
            TopBarDividerView()
            TopBarMeterCell(
                label: "dB",
                value: volumeDisplayText(viewModel: viewModel),
                normalizedLevel: normalizedVolumeLevel(viewModel: viewModel)
            )
            .frame(width: 104)
            TopBarDividerView()
            TopBarQualityCell(value: qualityDisplayText(viewModel: viewModel))
            TopBarDividerView()
            TopBarWaveformToggleCell(
                isOn: viewModel.showColoredWaveform,
                action: { viewModel.toggleColoredWaveform() }
            )
            .frame(minWidth: 103)
            TopBarDividerView()
            TopBarValueCell(title: "BPM", value: bpmDisplayText(viewModel: viewModel))
                .frame(width: 68)
            TopBarDividerView()
            TopBarKeyCell(
                value: keyCamelotDisplayText(viewModel: viewModel),
                isOpen: openDrawers.contains(.camelot),
                action: { toggleDrawer(.camelot) }
            )
            .frame(width: 148)
            if viewModel.stemsState != .unavailable {
                TopBarDividerView()
                TopBarStemsCell(
                    state: viewModel.stemsState,
                    isOpen: openDrawers.contains(.stems),
                    action: { toggleDrawer(.stems) }
                )
                .frame(width: TopBarStemsCell.width)
            }
            Spacer(minLength: 0)
            TopBarDividerView()
            TopBarInstagramCell()
                .frame(width: 83)
        }
        .frame(maxWidth: .infinity)
        .frame(height: Self.topBarHeight)
        // Browser chrome: the selected tab and this bar are one surface, edge to edge (no box, no side
        // gutters), closed by a single hairline towards the content. Cells keep their positions — only the
        // band reaches past the strip's 14 pt margins to the window edges.
        .background(alignment: .bottom) {
            ZStack(alignment: .bottom) {
                MocaTheme.chrome
                MocaTheme.chromeHairline.frame(height: 1)
            }
            .padding(.horizontal, -Self.stripHorizontalPadding)
        }
    }

    /// Window chrome is set up once (first tab); every tab switch only fits the height to this tab's drawers.
    private func applyWindowStyle(_ window: NSWindow) {
        window.title = viewModel.loadedURL == nil ? "Mocawave" : viewModel.fileName
        if window.delegate is FixedHeightWindowDelegate {
            resizeWindowForDrawers(opening: true, animated: false)
            return
        }
        window.titleVisibility = .hidden   // the tab strip is the title
        window.tabbingMode = .disallowed
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        window.isMovableByWindowBackground = true
        window.isOpaque = false
        window.backgroundColor = .clear
        GlassBackdrop.install(in: window)   // frosted, blurs what is behind the window
        window.appearance = NSAppearance(named: .darkAqua)

        let contentHeight = currentContentHeight
        let currentContentWidth = window.contentRect(forFrameRect: window.frame).width
        let targetContentWidth = max(currentContentWidth, Self.minimumWindowWidth)
        window.setContentSize(NSSize(width: targetContentWidth, height: contentHeight))
        window.contentMinSize = NSSize(width: Self.minimumWindowWidth, height: contentHeight)
        window.contentMaxSize = NSSize(width: .greatestFiniteMagnitude, height: contentHeight)
        window.minSize = NSSize(width: Self.minimumWindowWidth, height: contentHeight)
        window.maxSize = NSSize(width: .greatestFiniteMagnitude, height: contentHeight)

        // Lock vertical resize
        let resizeDelegate = FixedHeightWindowDelegate(fixedHeight: contentHeight)
        objc_setAssociatedObject(window, &FixedHeightWindowDelegate.associatedKey, resizeDelegate, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        window.delegate = resizeDelegate

        if #available(macOS 11.0, *) {
            window.titlebarSeparatorStyle = .none
        }

        // Activate the app and make the window key
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func requestAudioImport() {
        isImportingAudio = true
    }

    /// Sections for the mono waveform: each cue (except plain "C" markers) colours the stretch it opens.
    private var waveformSections: [WaveformSection] {
        guard viewModel.duration > 0 else { return [] }
        return viewModel.cues.filter { $0.kind != .cue }.sorted { $0.time < $1.time }
            .map { WaveformSection(start: $0.time / viewModel.duration, color: $0.kind.color) }
    }

    // MARK: Drawers

    private var orderedOpenDrawers: [InspectorDrawer] {
        InspectorDrawer.allCases.filter { openDrawers.contains($0) }
    }

    private var currentContentHeight: CGFloat {
        Self.windowContentHeight + InspectorDrawer.extraHeight(for: orderedOpenDrawers, stemsHeight: stemsPanelHeight)
    }

    @ViewBuilder
    private func drawerPanel(_ drawer: InspectorDrawer) -> some View {
        switch drawer {
        case .camelot:
            DrawerPanel(drawer: drawer, height: drawer.height(stems: stemsPanelHeight), onClose: { toggleDrawer(drawer) }) {
                CamelotWheelView(track: TrackCamelot(viewModel.keyAnalysisResult), selection: $camelotSelection)
            }
        case .stems:
            DrawerPanel(drawer: drawer, height: stemsPanelHeight, titleWidth: Self.stemColumns.leading,
                        onClose: { toggleDrawer(drawer) }) {
                StemsHeaderAccessory(
                    state: viewModel.stemsState,
                    modelName: viewModel.stemsModelName,
                    isMixDirty: viewModel.isStemMixDirty,
                    trailingWidth: Self.stemColumns.trailing,
                    onCancel: { viewModel.cancelStems() },
                    onReset: { withAnimation(MocaMotion.state) { viewModel.resetStemMix() } }
                )
            } content: {
                StemLanesView(
                    state: viewModel.stemsState,
                    lanes: viewModel.stemLanes,
                    progress: viewModel.progress,
                    hasTrack: viewModel.duration > 0,
                    columns: Self.stemColumns,
                    actions: StemLaneActions(
                        separate: { viewModel.separateStems() },
                        cancel: { viewModel.cancelStems() },
                        seek: { viewModel.seekToFraction($0) },
                        toggleMute: { viewModel.toggleStemMute($0) },
                        toggleSolo: { viewModel.toggleStemSolo($0, exclusive: $1) },
                        setVolume: { viewModel.setStemVolume($0, $1) },
                        resetMix: { viewModel.resetStemMix() },
                        startEngine: { viewModel.startLocalEngine() }
                    ),
                    engine: viewModel.engineStart,
                    sections: waveformSections
                )
            }
        }
    }

    private var targetStemsPanelHeight: CGFloat {
        StemLanesView.panelHeight(state: viewModel.stemsState, lanes: viewModel.stemLanes)
    }

    /// The stems panel changed size (separation started, lanes arrived, track changed): resize once things
    /// settle, panel and window together, top edge fixed like every drawer.
    private func scheduleStemsResize(to height: CGFloat) {
        stemsResizeTask?.cancel()
        guard openDrawers.contains(.stems) else {
            stemsPanelHeight = height
            return
        }
        stemsResizeTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled, openDrawers.contains(.stems), stemsPanelHeight != height else { return }
            let growing = height > stemsPanelHeight
            withAnimation(growing ? MocaMotion.drawerIn : MocaMotion.drawerOut) { stemsPanelHeight = height }
            resizeWindowForDrawers(opening: growing)
        }
    }

    /// Opens with a spring and grows the window downward; closes faster than it opened (exit < enter).
    private func toggleDrawer(_ drawer: InspectorDrawer) {
        let opening = !openDrawers.contains(drawer)
        if opening, drawer == .camelot, camelotSelection == nil {
            camelotSelection = TrackCamelot(viewModel.keyAnalysisResult).primary
        }
        if drawer == .stems {
            stemsResizeTask?.cancel()
            if opening { stemsPanelHeight = targetStemsPanelHeight }
        }
        withAnimation(opening ? MocaMotion.drawerIn : MocaMotion.drawerOut) {
            if opening { openDrawers.insert(drawer) } else { openDrawers.remove(drawer) }
        }
        resizeWindowForDrawers(opening: opening)
        // The audio follows the mixer: open = stem mix, closed = the file itself.
        if drawer == .stems { viewModel.setStemMixActive(opening) }
    }

    /// Keeps the top edge fixed (macOS origin is bottom-left) so the strip never jumps.
    private func resizeWindowForDrawers(opening: Bool, animated: Bool = true) {
        guard let window = windowRef else { return }
        let contentHeight = currentContentHeight
        let width = window.contentRect(forFrameRect: window.frame).width
        let frameHeight = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: width, height: contentHeight)).height
        var frame = window.frame
        frame.origin.y = frame.maxY - frameHeight
        frame.size.height = frameHeight

        window.contentMinSize = NSSize(width: Self.minimumWindowWidth, height: contentHeight)
        window.contentMaxSize = NSSize(width: .greatestFiniteMagnitude, height: contentHeight)
        window.minSize = NSSize(width: Self.minimumWindowWidth, height: frameHeight)
        window.maxSize = NSSize(width: .greatestFiniteMagnitude, height: frameHeight)
        (window.delegate as? FixedHeightWindowDelegate)?.fixedHeight = contentHeight

        let duration = animated ? (opening ? MocaMotion.windowInDuration : MocaMotion.windowOutDuration) : 0
        guard duration > 0 else {
            window.setFrame(frame, display: true)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: opening ? .easeOut : .easeIn)
            context.allowsImplicitAnimation = true
            window.animator().setFrame(frame, display: true)
        }
    }

    private func rotateCamelotSelection(by steps: Int) {
        guard let current = camelotSelection ?? TrackCamelot(viewModel.keyAnalysisResult).primary else { return }
        withAnimation(MocaMotion.state) { camelotSelection = current.shifted(by: steps) }
    }

    private func setCamelotRing(major: Bool) {
        guard let current = camelotSelection ?? TrackCamelot(viewModel.keyAnalysisResult).primary,
              current.isMajor != major else { return }
        withAnimation(MocaMotion.state) { camelotSelection = current.otherRing }
    }

    private func handleImportedAudio(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            _ = viewModel.open(url: url)
        case .failure(let error):
            viewModel.addDebugLog("File import error: \(error)")
        }
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            let handled = handleKeyEventIfNeeded(event)
            return handled ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    private func shortKeyName(from fullKey: String) -> String {
        // Convert "A Minor" -> "Am", "C# Major" -> "C#"
        if fullKey.hasSuffix(" Minor") {
            return fullKey.replacingOccurrences(of: " Minor", with: "m")
        } else if fullKey.hasSuffix(" Major") {
            return fullKey.replacingOccurrences(of: " Major", with: "")
        }
        return fullKey
    }

    private func playbackTimeText(viewModel: AudioPlayerViewModel) -> String? {
        guard viewModel.duration > 0 else { return nil }
        return "\(viewModel.formattedCurrentTime) / \(viewModel.formattedDuration)"
    }

    private func bpmDisplayText(viewModel: AudioPlayerViewModel) -> String {
        if let bpm = viewModel.displayBPM {
            return "\(bpm)"
        }
        return viewModel.isAnalyzingBPM ? "..." : "--"
    }

    private func keyDisplayText(viewModel: AudioPlayerViewModel) -> String {
        if let keyResult = viewModel.keyAnalysisResult {
            if keyResult.isResolved, let analyzedKey = keyResult.key {
                return shortKeyName(from: analyzedKey)
            }
            return "UNCERTAIN"
        }
        return viewModel.isAnalyzingKey ? "..." : "--"
    }

    private func camelotDisplayText(viewModel: AudioPlayerViewModel) -> String {
        if let keyResult = viewModel.keyAnalysisResult {
            if keyResult.isResolved, let analyzedCamelot = keyResult.camelot {
                return analyzedCamelot
            }
            return "--"
        }
        return viewModel.isAnalyzingKey ? "..." : "--"
    }

    private func keyCamelotDisplayText(viewModel: AudioPlayerViewModel) -> String {
        if let keyResult = viewModel.keyAnalysisResult, !keyResult.isResolved {
            return "UNCERTAIN"
        }
        return "\(keyDisplayText(viewModel: viewModel)) (\(camelotDisplayText(viewModel: viewModel)))"
    }

    private func lufsDisplayText(viewModel: AudioPlayerViewModel) -> String {
        guard let lufs = viewModel.realtimeLUFS else { return "--" }
        return String(format: "%.1f", lufs)
    }

    private func volumeDisplayText(viewModel: AudioPlayerViewModel) -> String {
        guard let ampDB = viewModel.realtimeAmplitudeDB, ampDB.isFinite else { return "--" }
        return String(format: "%.1f", ampDB)
    }

    private func normalizedLUFSLevel(viewModel: AudioPlayerViewModel) -> Double? {
        guard let lufs = viewModel.realtimeLUFS else { return nil }
        let clamped = min(max(Double(lufs), -36), 0)
        return (clamped + 36) / 36
    }

    private func normalizedVolumeLevel(viewModel: AudioPlayerViewModel) -> Double? {
        guard let ampDB = viewModel.realtimeAmplitudeDB, ampDB.isFinite else { return nil }
        let clamped = min(max(Double(ampDB), -48), 0)
        return (clamped + 48) / 48
    }

    private func qualityDisplayText(viewModel: AudioPlayerViewModel) -> String {
        if let quality = viewModel.audioQuality {
            return formattedBitrate(quality.estimatedBitrate)
        }
        if viewModel.isAnalyzingQuality {
            return "analyzing..."
        }
        return "-- kbps"
    }

    private func formattedBitrate(_ bitrate: WaveformAnalyzer.EstimatedBitrate) -> String {
        switch bitrate {
        case .kbps128: return "128kbps"
        case .kbps192: return "192kbps"
        case .kbps256: return "256kbps"
        case .kbps320: return "320kbps"
        case .lossless: return "lossless"
        }
    }

    private func handleKeyEventIfNeeded(_ event: NSEvent) -> Bool {
        // Don't intercept events destined for panels (like file dialogs)
        if event.window is NSPanel {
            return false
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let camelotOpen = openDrawers.contains(.camelot)
        if flags.isEmpty, event.keyCode == 40 { // 'k'
            toggleDrawer(.camelot)
            return true
        }
        let stemsOpen = openDrawers.contains(.stems)
        if flags.isEmpty, event.keyCode == 46, viewModel.stemsState != .unavailable { // 'm'
            toggleDrawer(.stems)
            return true
        }
        // 1–6 mute the lanes while the mixer is open (top row digits; nothing else uses them).
        if stemsOpen, flags.isEmpty, viewModel.stemsState == .ready,
           let lane = [18, 19, 20, 21, 23, 22].firstIndex(of: Int(event.keyCode)), lane < viewModel.stemLanes.count {
            viewModel.toggleStemMute(viewModel.stemLanes[lane].kind)
            return true
        }
        if camelotOpen, flags.subtracting([.numericPad, .function]) == [.option] { // arrows carry numericPad/function
            switch event.keyCode {
            case 123: rotateCamelotSelection(by: -1); return true
            case 124: rotateCamelotSelection(by: 1); return true
            case 126: setCamelotRing(major: true); return true
            case 125: setCamelotRing(major: false); return true
            default: break
            }
        }
        if !camelotOpen, event.keyCode == 53, viewModel.selectedCueID != nil { // esc deselects a cue
            viewModel.selectedCueID = nil
            return true
        }
        if camelotOpen, event.keyCode == 53 { // esc
            let trackKey = TrackCamelot(viewModel.keyAnalysisResult).primary
            if let trackKey, camelotSelection != trackKey {
                withAnimation(MocaMotion.state) { camelotSelection = trackKey }
            } else {
                toggleDrawer(.camelot)
            }
            return true
        }
        if stemsOpen, event.keyCode == 53 { // esc closes the mixer (after a selected cue)
            toggleDrawer(.stems)
            return true
        }

        guard viewModel.duration > 0 else { return false }

        // Cues: ⇧←/⇧→ jump, ⌫ deletes, ⇧ + I B D R O C add at the playhead (snapped to the bar; ⇧⌥ = free).
        // Shift is required so stray typing while the window has focus never drops cues.
        let plainFlags = flags.subtracting([.numericPad, .function])
        if plainFlags == [.shift], event.keyCode == 123 || event.keyCode == 124 {
            viewModel.jumpToCue(forward: event.keyCode == 124)
            return true
        }
        if plainFlags.isEmpty, event.keyCode == 51 || event.keyCode == 117 { // delete / forward delete
            viewModel.deleteCue()
            return true
        }
        if plainFlags == [.shift] || plainFlags == [.shift, .option],
           let letter = event.charactersIgnoringModifiers, let kind = CueKind.forShortcut(letter) {
            viewModel.addCue(kind: kind, snap: plainFlags == [.shift])
            return true
        }

        switch event.keyCode {
        case 49: // space
            viewModel.togglePlay()
            return true
        case 123: // left arrow
            viewModel.seek(to: viewModel.currentTime - seekStep)
            return true
        case 124: // right arrow
            viewModel.seek(to: viewModel.currentTime + seekStep)
            return true
        case 1: // 's'
            viewModel.toggleSpectrogram()
            return true
        default:
            return false
        }
    }
}
