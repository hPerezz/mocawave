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
    private let fixedHeight: CGFloat
    private let viewModel: AudioPlayerViewModel

    init(fixedHeight: CGFloat, viewModel: AudioPlayerViewModel) {
        self.fixedHeight = fixedHeight
        self.viewModel = viewModel
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
            viewModel.stopAndReset()
            AudioOpenCoordinator.shared.unregister(window: sender)
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
        Color.white.opacity(isDisabled ? 0.26 : 0.72)
    }

    private var accentColor: Color {
        Color.white.opacity(isDisabled ? 0.20 : 0.88)
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
                .fill(Color.white.opacity(isDisabled ? 0.05 : 0.08))

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
}

struct CoffeeSteamView: View {
    let expression: Double
    let isDisabled: Bool
    let cupHeight: CGFloat
    let style: CoffeeSteamStyle

    private let columnOffsets: [CGFloat] = [-0.16, 0.0, 0.16]
    private let sleepOffsets: [CGFloat] = [-0.10, 0.02, 0.16]

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

struct ProBadgeView: View {
    var body: some View {
        Text("PRO")
            .font(.system(size: 7, weight: .bold, design: .monospaced))
            .foregroundColor(Color.orange.opacity(0.92))
            .padding(.horizontal, 3)
            .padding(.vertical, 1)
            .background(Color.orange.opacity(0.12))
            .overlay(
                Rectangle()
                    .stroke(Color.orange.opacity(0.4), lineWidth: 1)
            )
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

private let lockedProParameterOpacity = 0.78

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
    let isLocked: Bool
    let action: (() -> Void)?

    @State private var isHovered = false

    private var displayLevel: Double {
        guard let normalizedLevel else { return 0 }
        return min(max(normalizedLevel, 0), 1)
    }

    var body: some View {
        Group {
            if let action {
                Button(action: action) {
                    cellBody
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    isHovered = hovering
                }
                .help(isLocked ? "Unlock Pro to access \(label)." : label)
            } else {
                cellBody
            }
        }
    }

    private var cellBody: some View {
        HStack {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.black.opacity(0.26))

                GeometryReader { proxy in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.white.opacity(isLocked ? 0.24 : 0.52))
                        .frame(width: proxy.size.width * displayLevel)
                }

                HStack(spacing: 4) {
                    Text(label)
                        .font(.system(size: 7, weight: .semibold, design: .monospaced))
                        .foregroundColor(.white.opacity(isLocked ? 0.52 : 0.72))
                        .lineLimit(1)

                    Spacer(minLength: 0)

                    Text(value)
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundColor(.white.opacity(isLocked ? 0.62 : 0.92))
                        .lineLimit(1)
                        .minimumScaleFactor(0.68)

                    if isLocked {
                        ProBadgeView()
                    }
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
        .background(
            Rectangle()
                .fill(Color.white.opacity(isHovered ? 0.05 : 0))
        )
        .opacity(isLocked ? lockedProParameterOpacity : 1)
    }
}

struct TopBarQualityCell: View {
    let value: String
    let isLocked: Bool
    let action: (() -> Void)?

    @State private var isHovered = false

    var body: some View {
        Group {
            if let action {
                Button(action: action) {
                    cellBody
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    isHovered = hovering
                }
                .help(isLocked ? "Unlock Pro to access quality analysis." : "Quality analysis")
            } else {
                cellBody
            }
        }
    }

    private var cellBody: some View {
        HStack(spacing: 5) {
            Text("REAL QUALITY")
                .font(.system(size: 8, weight: .semibold, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(1)

            Text(value)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(.white.opacity(isLocked ? 0.5 : 0.9))
                .lineLimit(1)
                .minimumScaleFactor(0.72)

            if isLocked {
                ProBadgeView()
            }
        }
        .padding(.horizontal, 8)
        .frame(minWidth: 155, maxHeight: .infinity, alignment: .leading)
        .background(
            Rectangle()
                .fill(Color.white.opacity(isHovered ? 0.05 : 0))
        )
        .opacity(isLocked ? lockedProParameterOpacity : 1)
    }
}

struct TopBarWaveformToggleCell: View {
    let isOn: Bool
    let isLocked: Bool
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
                    .foregroundColor(.white.opacity(isLocked ? 0.52 : 0.86))
                    .lineLimit(1)

                if isLocked {
                    ProBadgeView()
                }
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
        .help(isLocked ? "Unlock Pro to enable colored waveform." : "Toggle colored waveform")
    }

    private var iconColor: Color {
        if isLocked {
            return Color.white.opacity(0.42)
        }
        return isOn ? Color.accentColor : Color.white.opacity(0.72)
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
    @EnvironmentObject private var proStore: ProEntitlementStore
    @StateObject private var viewModel: AudioPlayerViewModel
    @State private var isDropTargeted = false
    @State private var isImportingAudio = false
    @State private var keyMonitor: Any?
    @State private var windowRef: NSWindow?
    @State private var showDebugWindow = false
    @State private var activeProPaywallSource: ProPaywallSource?
    private let seekStep: TimeInterval = 5
    private static let controlRowSpacing: CGFloat = 12
    private static let topBarHeight: CGFloat = 22
    private static let mainControlHeight: CGFloat = 84
    private static let coffeeScale: CGFloat = 1.72
    private static let coffeeWidth: CGFloat = VolumeFaceView.preferredWidth * coffeeScale
    private static let coffeeHeight: CGFloat = VolumeFaceView.preferredHeight * coffeeScale
    private static let coffeeSlotWidth: CGFloat = coffeeWidth - 14
    private static let windowContentHeight: CGFloat = 172
    private static let minimumWindowWidth: CGFloat = 806
    private static let supportedAudioContentTypes = ["mp3", "wav", "aac", "m4a"].compactMap { UTType(filenameExtension: $0) }

    @MainActor
    init(viewModel: AudioPlayerViewModel? = nil) {
        _viewModel = StateObject(wrappedValue: viewModel ?? AudioPlayerViewModel())
    }

    var body: some View {
        let isSleepMode = viewModel.duration > 0 && !viewModel.isPlaying

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
                                }
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
                .background(Color(NSColor.controlBackgroundColor))
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
                            expression: viewModel.faceExpression,
                            isDisabled: false,
                            cupHeight: Self.coffeeHeight,
                            style: viewModel.isPlaying ? .steam : .sleep
                        )
                        .frame(width: Self.coffeeWidth, height: Self.mainControlHeight)
                    }

                    VolumeFaceView(
                        expression: viewModel.faceExpression,
                        isDisabled: false,
                        isSleeping: isSleepMode,
                        isAngry: viewModel.duration == 0
                    )
                    .frame(width: Self.coffeeWidth, height: Self.coffeeHeight)
                }
                .frame(width: Self.coffeeSlotWidth, height: Self.mainControlHeight, alignment: .bottom)
            }

            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .foregroundColor(.red)
            }
        }
        .padding(.horizontal, 14)
        .background(
            Group {
                Button("") { requestAudioImport() }
                    .keyboardShortcut("o", modifiers: [.command])
                    .hidden()
                Button("") { showDebugWindow.toggle() }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                    .hidden()
            }
        )
        .configureWindow { window in
            windowRef = window
            applyWindowStyle(window)
            AudioOpenCoordinator.shared.register(window: window, viewModel: viewModel)
        }
        .preferredColorScheme(.dark)
        .ignoresSafeArea()
        .onDrop(of: [UTType.fileURL], isTargeted: $isDropTargeted) { providers in
            viewModel.handleDrop(providers)
        }
        .onAppear {
            installKeyMonitor()
            viewModel.handleProAccessChanged()
        }
        .onDisappear {
            removeKeyMonitor()
            if let windowRef {
                AudioOpenCoordinator.shared.unregister(window: windowRef)
            }
        }
        .onChange(of: proStore.effectiveProAccess) { hasAccess in
            viewModel.handleProAccessChanged()
            if hasAccess {
                activeProPaywallSource = nil
            }
        }
        .onChange(of: viewModel.fileName) { newName in
            windowRef?.title = newName
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
        .sheet(item: $activeProPaywallSource) { source in
            ProPaywallSheet(source: source)
                .environmentObject(proStore)
        }
    }

    private var topBar: some View {
        let isProLocked = !proStore.effectiveProAccess

        return HStack(spacing: 0) {
            TopBarMeterCell(
                label: "LUFS",
                value: lufsDisplayText(viewModel: viewModel),
                normalizedLevel: normalizedLUFSLevel(viewModel: viewModel),
                isLocked: isProLocked,
                action: isProLocked ? { presentPaywall(.lufs) } : nil
            )
            .frame(width: 112)
            TopBarDividerView()
            TopBarMeterCell(
                label: "dB",
                value: volumeDisplayText(viewModel: viewModel),
                normalizedLevel: normalizedVolumeLevel(viewModel: viewModel),
                isLocked: isProLocked,
                action: isProLocked ? { presentPaywall(.peakMeter) } : nil
            )
            .frame(width: 104)
            TopBarDividerView()
            TopBarQualityCell(
                value: qualityDisplayText(viewModel: viewModel),
                isLocked: isProLocked,
                action: isProLocked ? { presentPaywall(.quality) } : nil
            )
            TopBarDividerView()
            TopBarWaveformToggleCell(
                isOn: viewModel.showColoredWaveform,
                isLocked: viewModel.isColoredWaveformLocked,
                action: {
                    if viewModel.isColoredWaveformLocked {
                        presentPaywall(.coloredWaveform)
                    } else {
                        viewModel.toggleColoredWaveform()
                    }
                }
            )
            .frame(minWidth: 103)
            TopBarDividerView()
            TopBarValueCell(title: "BPM", value: bpmDisplayText(viewModel: viewModel))
                .frame(width: 68)
            TopBarDividerView()
            TopBarValueCell(title: "KEY (CAMELOT)", value: keyCamelotDisplayText(viewModel: viewModel))
                .frame(width: 132)
            Spacer(minLength: 0)
            TopBarDividerView()
            TopBarInstagramCell()
                .frame(width: 83)
        }
        .frame(maxWidth: .infinity)
        .frame(height: Self.topBarHeight)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.82))
        .overlay(
            Rectangle()
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
        .clipShape(Rectangle())
    }

    private func presentPaywall(_ source: ProPaywallSource) {
        activeProPaywallSource = source
    }

    private func applyWindowStyle(_ window: NSWindow) {
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        window.isMovableByWindowBackground = true
        window.isOpaque = false
        window.backgroundColor = NSColor.black.withAlphaComponent(0.9)
        window.appearance = NSAppearance(named: .darkAqua)
        window.title = viewModel.fileName

        let contentHeight = Self.windowContentHeight
        let currentContentWidth = window.contentRect(forFrameRect: window.frame).width
        let targetContentWidth = max(currentContentWidth, Self.minimumWindowWidth)
        window.setContentSize(NSSize(width: targetContentWidth, height: contentHeight))
        window.contentMinSize = NSSize(width: Self.minimumWindowWidth, height: contentHeight)
        window.contentMaxSize = NSSize(width: .greatestFiniteMagnitude, height: contentHeight)
        window.minSize = NSSize(width: Self.minimumWindowWidth, height: contentHeight)
        window.maxSize = NSSize(width: .greatestFiniteMagnitude, height: contentHeight)

        // Lock vertical resize
        let resizeDelegate = FixedHeightWindowDelegate(fixedHeight: contentHeight, viewModel: viewModel)
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
        if let bpm = viewModel.bpm {
            return "\(bpm)"
        }
        if let analyzedBPM = viewModel.analyzedBPM {
            return "\(analyzedBPM)"
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

        guard viewModel.duration > 0 else { return false }
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
