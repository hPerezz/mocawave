import AVFoundation
import Combine
import CoreGraphics
import Foundation
import UniformTypeIdentifiers

@MainActor
final class AudioPlayerViewModel: ObservableObject {
    private static let coloredWaveformPreferenceKey = "showColoredWaveform"

    private struct PlaybackTelemetry: Equatable {
        var currentTime: TimeInterval = 0
        var realtimeLUFS: Float? = nil
        var realtimeAmplitudeDB: Float? = nil
        var faceExpression: Double = 0
    }

    @Published var isPlaying: Bool = false
    @Published var duration: TimeInterval = 0
    @Published var waveformSamples: [Float] = [] { didSet { scheduleCueDetectionIfReady() } }
    @Published var coloredWaveformData: WaveformAnalyzer.ColoredWaveformData? = nil
    @Published var fileName: String = "No file loaded"
    @Published var errorMessage: String?
    @Published var bpm: Int? { didSet { scheduleCueDetectionIfReady() } }
    @Published var analyzedBPM: Int? { didSet { scheduleCueDetectionIfReady() } }
    @Published var isAnalyzingBPM: Bool = false
    @Published var keyAnalysisResult: KeyAnalyzer.KeyAnalysisResult?
    /// Grid + cues for the open file (nil until detected or loaded from CueStore).
    @Published private(set) var cueAnalysis: CueAnalysis?
    /// True when the cues were just detected (flags animate in); false when they came from the store.
    @Published private(set) var cuesJustDetected = false
    @Published var selectedCueID: UUID?
    @Published var isAnalyzingKey: Bool = false
    @Published var spectrogramImage: CGImage? = nil
    @Published var isAnalyzingSpectrogram: Bool = false
    @Published var showSpectrogram: Bool = false
    @Published var isAnalyzingColoredWaveform: Bool = false
    @Published var showColoredWaveform: Bool
    @Published var audioQuality: WaveformAnalyzer.AudioQualityResult? = nil
    @Published var isAnalyzingQuality: Bool = false
    @Published var debugLog: [String] = []
    @Published private var playbackTelemetry = PlaybackTelemetry()

    private let supportedExtensions: Set<String> = ["mp3", "wav", "aac", "m4a", "flac", "aif", "aiff"]
    private let faceAttackAlpha: Double = 0.30
    private let faceReleaseAlpha: Double = 0.12
    private let playbackLoopIntervalNanoseconds: UInt64 = 50_000_000
    private let debugLogFlushDelayNanoseconds: UInt64 = 250_000_000
    private var audioEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var audioFile: AVAudioFile?
    private var startingFramePosition: AVAudioFramePosition = 0
    private var lufsMeter: LUFSMeter?
    private var analysisTask: Task<Void, Never>?
    private var bpmAnalysisTask: Task<Void, Never>?
    private var keyAnalysisTask: Task<Void, Never>?
    private var spectrogramTask: Task<Void, Never>?
    private var coloredWaveformTask: Task<Void, Never>?
    private var qualityAnalysisTask: Task<Void, Never>?
    private var cueTask: Task<Void, Never>?
    private var cueRequestedURL: URL?
    private var playbackTask: Task<Void, Never>?
    private var isScrubbing: Bool = false
    private var currentURL: URL?
    // Keep App Sandbox access alive for the currently loaded file.
    private var securityScopedURL: URL?
    private var isAccessingSecurityScopedURL = false
    private var pendingDebugLogEntries: [String] = []
    private var debugLogFlushTask: Task<Void, Never>?
    private let preferences: UserDefaults
    private let waveformAnalysisCoordinator: any WaveformAnalysisScheduling
    /// Incremented on every play() call; completion handlers compare against this
    /// to detect stale callbacks from previous scheduleSegment calls.
    private var playGeneration: UInt64 = 0

    init(
        userDefaults: UserDefaults = .standard,
        waveformAnalysisCoordinator: (any WaveformAnalysisScheduling)? = nil
    ) {
        self.preferences = userDefaults
        self.waveformAnalysisCoordinator = waveformAnalysisCoordinator ?? WaveformAnalysisCoordinator.shared

        let savedPreference = userDefaults.bool(forKey: Self.coloredWaveformPreferenceKey)
        _showColoredWaveform = Published(initialValue: savedPreference)
    }

    var prefersColoredWaveform: Bool {
        showColoredWaveform
    }

    var shouldRenderColoredWaveform: Bool {
        prefersColoredWaveform && !showSpectrogram
    }

    var analyzedKey: String? {
        keyAnalysisResult?.key
    }

    var analyzedCamelot: String? {
        keyAnalysisResult?.camelot
    }

    var currentTime: TimeInterval {
        playbackTelemetry.currentTime
    }

    var realtimeLUFS: Float? {
        playbackTelemetry.realtimeLUFS
    }

    var realtimeAmplitudeDB: Float? {
        playbackTelemetry.realtimeAmplitudeDB
    }

    var faceExpression: Double {
        playbackTelemetry.faceExpression
    }

    var progress: Double {
        guard duration > 0 else { return 0 }
        return min(max(currentTime / duration, 0), 1)
    }

    private func updatePlaybackTelemetry(_ mutation: (inout PlaybackTelemetry) -> Void) {
        var nextTelemetry = playbackTelemetry
        mutation(&nextTelemetry)
        guard nextTelemetry != playbackTelemetry else { return }
        playbackTelemetry = nextTelemetry
    }

    private func resetPlaybackTelemetry() {
        updatePlaybackTelemetry { telemetry in
            telemetry = PlaybackTelemetry()
        }
    }

    private func clearRealtimePlaybackMetrics(resetFace: Bool = false) {
        updatePlaybackTelemetry { telemetry in
            telemetry.realtimeLUFS = nil
            telemetry.realtimeAmplitudeDB = nil
            if resetFace {
                telemetry.faceExpression = 0
            }
        }
    }

    private func updateFaceExpression(for telemetry: inout PlaybackTelemetry) {
        guard waveformSamples.count > 1, duration > 0 else { return }

        let progress = min(max(telemetry.currentTime / duration, 0), 1)
        let scaledIndex = progress * Double(waveformSamples.count - 1)
        let lowerIndex = min(max(Int(scaledIndex.rounded(.down)), 0), waveformSamples.count - 1)
        let upperIndex = min(lowerIndex + 1, waveformSamples.count - 1)
        let fraction = Float(scaledIndex - Double(lowerIndex))
        let lowerValue = waveformSamples[lowerIndex]
        let upperValue = waveformSamples[upperIndex]
        let interpolatedValue = lowerValue + (upperValue - lowerValue) * fraction
        let targetExpression = Double(min(max(interpolatedValue, 0), 1)) * 2 - 1
        let alpha = targetExpression > telemetry.faceExpression ? faceAttackAlpha : faceReleaseAlpha
        telemetry.faceExpression += (targetExpression - telemetry.faceExpression) * alpha
    }

    var formattedCurrentTime: String {
        Self.formatTime(currentTime)
    }

    var formattedDuration: String {
        Self.formatTime(duration)
    }

    @discardableResult
    func open(url: URL) -> Bool {
        errorMessage = nil
        guard isSupported(url: url) else {
            errorMessage = "Unsupported file type."
            return false
        }

        let previousURL = currentURL
        let startedAccessingSecurityScopedResource = url.startAccessingSecurityScopedResource()
        stopPlayback()
        stopEngine()
        analysisTask?.cancel()
        bpmAnalysisTask?.cancel()
        keyAnalysisTask?.cancel()
        spectrogramTask?.cancel()
        coloredWaveformTask?.cancel()
        qualityAnalysisTask?.cancel()
        if previousURL != url {
            cancelWaveformFamily(for: previousURL)
        }
        resetCues()
        waveformSamples = []
        coloredWaveformData = nil
        spectrogramImage = nil
        isAnalyzingSpectrogram = false
        isAnalyzingColoredWaveform = false
        bpm = nil
        analyzedBPM = nil
        isAnalyzingBPM = false
        keyAnalysisResult = nil
        isAnalyzingKey = false
        audioQuality = nil
        isAnalyzingQuality = false
        resetPlaybackTelemetry()
        fileName = url.lastPathComponent
        currentURL = url

        extractBPM(from: url)

        do {
            let file = try AVAudioFile(forReading: url)
            audioFile = file
            duration = Double(file.length) / file.processingFormat.sampleRate
            startingFramePosition = 0

            let engine = AVAudioEngine()
            let node = AVAudioPlayerNode()
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: file.processingFormat)

            try engine.start()
            audioEngine = engine
            playerNode = node
            replaceSecurityScopedResource(with: url, startedAccessing: startedAccessingSecurityScopedResource)
            configureRealtimeMetersIfNeeded()
        } catch {
            if startedAccessingSecurityScopedResource {
                url.stopAccessingSecurityScopedResource()
            }
            releaseSecurityScopedResource()
            let diagnostic = diagnosticDescription(for: error)
            addDebugLog("File open error: \(diagnostic)")
            errorMessage = "Failed to open audio file: \(diagnostic)"
            audioFile = nil
            audioEngine = nil
            playerNode = nil
            lufsMeter = nil
            duration = 0
            currentURL = nil
            resetPlaybackTelemetry()
            return false
        }

        // Analysis first: if the output device isn't running, AVAudioPlayerNode.play() raises an ObjC
        // exception ("player did not see an IO cycle") that skips the rest of open().
        loadOrAnalyze(url: url)
        play()
        if showSpectrogram {
            analyzeAndRenderSpectrogram(for: url)
        }
        return true
    }

    func togglePlay() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    func play() {
        guard let playerNode, let audioFile, let audioEngine else { return }
        if !audioEngine.isRunning {
            do { try audioEngine.start() } catch { return }
        }

        playGeneration &+= 1
        let expectedGeneration = playGeneration
        let startFrame = startingFramePosition
        let totalFrames = AVAudioFrameCount(audioFile.length - startFrame)
        guard totalFrames > 0 else { return }

        let handlePlaybackCompletion: @MainActor @Sendable () -> Void = { [weak self] in
            self?.handlePlaybackCompletion(generation: expectedGeneration)
        }
        playerNode.scheduleSegment(audioFile, startingFrame: startFrame, frameCount: totalFrames, at: nil) {
            Task { @MainActor in
                handlePlaybackCompletion()
            }
        }
        playerNode.play()
        isPlaying = true
        startPlaybackLoop()
    }

    func pause() {
        guard let playerNode else { return }
        playGeneration &+= 1  // invalidate any pending completion
        startingFramePosition = currentFramePosition()
        playerNode.stop()
        isPlaying = false
        stopPlaybackLoop()
        clearRealtimePlaybackMetrics()
    }

    func seek(to seconds: TimeInterval) {
        guard audioFile != nil else { return }
        let clamped = min(max(seconds, 0), duration)
        let sampleRate = audioFile!.processingFormat.sampleRate
        let targetFrame = AVAudioFramePosition(clamped * sampleRate)
        let wasPlaying = isPlaying

        if wasPlaying {
            playGeneration &+= 1  // invalidate any pending completion
            playerNode?.stop()
            stopPlaybackLoop()
        }

        startingFramePosition = targetFrame
        lufsMeter?.reset()
        updatePlaybackTelemetry { telemetry in
            telemetry.currentTime = clamped
            telemetry.realtimeLUFS = nil
            telemetry.realtimeAmplitudeDB = nil
            updateFaceExpression(for: &telemetry)
        }

        if wasPlaying {
            play()
        }
    }

    func seekToFraction(_ fraction: Double) {
        let clamped = min(max(fraction, 0), 1)
        seek(to: clamped * duration)
    }

    func setScrubbing(_ scrubbing: Bool) {
        isScrubbing = scrubbing
    }

    func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) else {
            return false
        }

        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { [weak self] item, _ in
            guard let self else { return }
            let url: URL?
            if let data = item as? Data {
                url = URL(dataRepresentation: data, relativeTo: nil)
            } else if let itemURL = item as? URL {
                url = itemURL
            } else {
                url = nil
            }

            if let url {
                Task { @MainActor in
                    self.open(url: url)
                }
            }
        }

        return true
    }

    deinit {
        if let currentURL {
            let waveformAnalysisCoordinator = waveformAnalysisCoordinator
            Task {
                await waveformAnalysisCoordinator.cancelAll(for: currentURL)
            }
        }
        analysisTask?.cancel()
        bpmAnalysisTask?.cancel()
        keyAnalysisTask?.cancel()
        spectrogramTask?.cancel()
        coloredWaveformTask?.cancel()
        qualityAnalysisTask?.cancel()
        playbackTask?.cancel()
        debugLogFlushTask?.cancel()
    }

    private func handlePlaybackCompletion(generation: UInt64) {
        guard generation == playGeneration else { return }
        isPlaying = false
        stopPlaybackLoop()
        startingFramePosition = 0
        updatePlaybackTelemetry { telemetry in
            telemetry.currentTime = duration
            telemetry.realtimeLUFS = nil
            telemetry.realtimeAmplitudeDB = nil
        }
    }

    private func currentFramePosition() -> AVAudioFramePosition {
        guard let playerNode, let nodeTime = playerNode.lastRenderTime,
              let playerTime = playerNode.playerTime(forNodeTime: nodeTime) else {
            return startingFramePosition
        }
        return startingFramePosition + playerTime.sampleTime
    }

    private func extractBPM(from url: URL) {
        let asset = AVURLAsset(url: url)
        let capturedURL = url
        Task {
            let metadata = try? await asset.load(.metadata)
            guard let metadata else { return }

            for item in metadata {
                if let key = item.commonKey?.rawValue, key == "tempo" {
                    if let value = try? await item.load(.value) as? NSNumber {
                        guard self.currentURL == capturedURL else { return }
                        self.bpm = value.intValue
                        return
                    }
                }
                if let identifier = item.identifier {
                    if identifier == .id3MetadataBeatsPerMinute ||
                       identifier == .iTunesMetadataBeatsPerMin {
                        if let value = try? await item.load(.value) {
                            if let number = value as? NSNumber {
                                guard self.currentURL == capturedURL else { return }
                                self.bpm = number.intValue
                                return
                            } else if let string = value as? String, let parsed = Int(string) {
                                guard self.currentURL == capturedURL else { return }
                                self.bpm = parsed
                                return
                            }
                        }
                    }
                }
            }
        }
    }

    func addDebugLog(_ message: String) {
        let timestamp = Date().formatted(date: .omitted, time: .standard)
        pendingDebugLogEntries.append("[\(timestamp)] \(message)")
        scheduleDebugLogFlushIfNeeded()
    }

    func debugLogSnapshot() -> [String] {
        debugLog + pendingDebugLogEntries
    }

    func clearDebugLog() {
        debugLogFlushTask?.cancel()
        debugLogFlushTask = nil
        pendingDebugLogEntries.removeAll()
        debugLog.removeAll()
    }

    private func diagnosticDescription(for error: Error) -> String {
        if let localizedError = error as? LocalizedError,
           let description = localizedError.errorDescription,
           !description.isEmpty {
            return description
        }

        let nsError = error as NSError
        var components = ["[\(nsError.domain) \(nsError.code)] \(nsError.localizedDescription)"]

        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            components.append("underlying=[\(underlying.domain) \(underlying.code)] \(underlying.localizedDescription)")
        }
        if let failureReason = nsError.userInfo[NSLocalizedFailureReasonErrorKey] as? String,
           !failureReason.isEmpty {
            components.append("reason=\(failureReason)")
        }
        if let filePath = nsError.userInfo[NSFilePathErrorKey] as? String,
           !filePath.isEmpty {
            components.append("path=\(filePath)")
        }

        return components.joined(separator: " | ")
    }

    private func cancelWaveformFamily(for url: URL?) {
        guard let url else { return }
        let waveformAnalysisCoordinator = waveformAnalysisCoordinator
        Task {
            await waveformAnalysisCoordinator.cancelAll(for: url)
        }
    }

    private func cancelColoredWaveformAnalysis(for url: URL?) {
        guard let url else { return }
        let waveformAnalysisCoordinator = waveformAnalysisCoordinator
        Task {
            await waveformAnalysisCoordinator.cancelColoredWaveform(for: url)
        }
    }

    private func cancelSpectrogramAnalysis(for url: URL?) {
        guard let url else { return }
        let waveformAnalysisCoordinator = waveformAnalysisCoordinator
        Task {
            await waveformAnalysisCoordinator.cancelSpectrogram(for: url)
        }
    }

    private func cancelQualityAnalysis(for url: URL?) {
        guard let url else { return }
        let waveformAnalysisCoordinator = waveformAnalysisCoordinator
        Task {
            await waveformAnalysisCoordinator.cancelQuality(for: url)
        }
    }

    private func scheduleDebugLogFlushIfNeeded() {
        guard debugLogFlushTask == nil else { return }
        debugLogFlushTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: self.debugLogFlushDelayNanoseconds)
            guard !Task.isCancelled else { return }
            self.flushPendingDebugLogs()
        }
    }

    private func flushPendingDebugLogs() {
        debugLogFlushTask = nil
        guard !pendingDebugLogEntries.isEmpty else { return }
        debugLog.append(contentsOf: pendingDebugLogEntries)
        if debugLog.count > 50 {
            debugLog.removeFirst(debugLog.count - 50)
        }
        pendingDebugLogEntries.removeAll()
    }

    private func cachedKeyLogLine(for result: KeyAnalyzer.KeyAnalysisResult) -> String {
        if result.isResolved {
            return "Loaded cached key: \(result.key ?? "--") (\(result.camelot ?? "--")) conf=\(String(format: "%.2f", result.confidence))"
        }
        return "Loaded cached key: UNCERTAIN reason=\(result.uncertaintyReason?.rawValue ?? "unknown") conf=\(String(format: "%.2f", result.confidence))"
    }

    private func keyCompletionLogLine(for result: KeyAnalyzer.KeyAnalysisResult) -> String {
        if result.isResolved {
            let runnerUp = result.runnerUpKey ?? "--"
            return "Key analysis complete: \(result.key ?? "--") (\(result.camelot ?? "--")) conf=\(String(format: "%.2f", result.confidence)) runnerUp=\(runnerUp)"
        }
        let runnerUp = result.runnerUpKey ?? "--"
        let reason = result.uncertaintyReason?.rawValue ?? "unknown"
        return "Key analysis complete: UNCERTAIN reason=\(reason) conf=\(String(format: "%.2f", result.confidence)) runnerUp=\(runnerUp)"
    }

    private func persistColoredWaveformPreference(_ enabled: Bool) {
        preferences.set(enabled, forKey: Self.coloredWaveformPreferenceKey)
    }

    private func savedColoredWaveformPreference() -> Bool {
        preferences.bool(forKey: Self.coloredWaveformPreferenceKey)
    }

    func toggleColoredWaveform() {
        setColoredWaveformEnabled(!showColoredWaveform)
    }

    func setColoredWaveformEnabled(_ enabled: Bool) {
        if showColoredWaveform == enabled {
            persistColoredWaveformPreference(enabled)
            if enabled, let url = currentURL {
                prepareColoredWaveformIfNeeded(for: url)
            }
            return
        }

        showColoredWaveform = enabled
        persistColoredWaveformPreference(enabled)

        if enabled {
            if let url = currentURL {
                prepareColoredWaveformIfNeeded(for: url)
            }
        } else {
            isAnalyzingColoredWaveform = false
            coloredWaveformTask?.cancel()
            cancelColoredWaveformAnalysis(for: currentURL)
        }
    }

    func toggleSpectrogram() {
        showSpectrogram.toggle()
        if showSpectrogram, spectrogramImage == nil, !isAnalyzingSpectrogram, let url = currentURL {
            analyzeAndRenderSpectrogram(for: url)
        } else if !showSpectrogram {
            spectrogramTask?.cancel()
            isAnalyzingSpectrogram = false
            cancelSpectrogramAnalysis(for: currentURL)
        }
    }

    private func analyzeAndRenderSpectrogram(for url: URL) {
        let capturedURL = url
        spectrogramTask?.cancel()
        isAnalyzingSpectrogram = true
        addDebugLog("Spectrogram analysis started for: \(url.lastPathComponent)")
        spectrogramTask = Task { [weak self] in
            defer {
                self?.isAnalyzingSpectrogram = false
                self?.spectrogramTask = nil
            }
            guard let self else { return }
            do {
                let data = try await self.waveformAnalysisCoordinator.spectrogram(
                    url: url,
                    targetColumns: 2000,
                    freqBins: 128
                )
                guard !Task.isCancelled, self.currentURL == capturedURL, self.showSpectrogram else { return }

                let image = await Task.detached(priority: .utility) {
                    Self.renderSpectrogramImage(data: data)
                }.value
                guard !Task.isCancelled, self.currentURL == capturedURL, self.showSpectrogram else { return }

                self.spectrogramImage = image
                self.addDebugLog("Spectrogram rendered for: \(url.lastPathComponent)")
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, self.currentURL == capturedURL else { return }
                self.addDebugLog("Spectrogram error: \(self.diagnosticDescription(for: error))")
            }
        }
    }

    private func configureRealtimeMetersIfNeeded() {
        guard lufsMeter == nil else { return }
        guard let engine = audioEngine, let audioFile else { return }

        let meter = LUFSMeter(
            sampleRate: audioFile.processingFormat.sampleRate,
            channelCount: Int(audioFile.processingFormat.channelCount),
            computeLUFS: true
        )
        lufsMeter = meter

        let tapFormat = engine.mainMixerNode.outputFormat(forBus: 0)
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: tapFormat) { buffer, _ in
            meter.process(buffer: buffer)
        }
    }

    private func disableRealtimeMeters() {
        if let engine = audioEngine {
            engine.mainMixerNode.removeTap(onBus: 0)
        }
        lufsMeter = nil
        clearRealtimePlaybackMetrics()
    }

    private func prepareColoredWaveformIfNeeded(for url: URL) {
        guard prefersColoredWaveform, coloredWaveformData == nil, !isAnalyzingColoredWaveform else { return }

        let capturedURL = url
        Task { [weak self] in
            guard let self else { return }
            if let cached = await AudioCache.shared.getCached(for: url),
               let cachedColoredWaveform = cached.coloredWaveformData,
               self.currentURL == capturedURL,
               self.prefersColoredWaveform {
                self.coloredWaveformData = cachedColoredWaveform
                self.addDebugLog("Loaded cached RGB waveform for: \(url.lastPathComponent)")
                return
            }

            guard self.currentURL == capturedURL, self.prefersColoredWaveform else { return }
            self.analyzeColoredWaveform(for: url, shouldCache: true)
        }
    }

    private func analyzeColoredWaveform(for url: URL, shouldCache: Bool = false) {
        guard prefersColoredWaveform else {
            isAnalyzingColoredWaveform = false
            return
        }

        coloredWaveformTask?.cancel()

        let capturedURL = url
        isAnalyzingColoredWaveform = true
        addDebugLog("RGB waveform analysis started for: \(url.lastPathComponent)")
        coloredWaveformTask = Task { [weak self] in
            defer {
                self?.isAnalyzingColoredWaveform = false
                self?.coloredWaveformTask = nil
            }
            guard let self else { return }
            do {
                let data = try await self.waveformAnalysisCoordinator.coloredWaveform(
                    url: url,
                    targetColumns: 2000
                )
                guard !Task.isCancelled, self.currentURL == capturedURL, self.prefersColoredWaveform else { return }

                self.coloredWaveformData = data
                self.addDebugLog("RGB waveform analysis complete: \(url.lastPathComponent)")

                if shouldCache {
                    await AudioCache.shared.upsertColoredWaveform(
                        data,
                        waveformSamples: self.waveformSamples,
                        analyzedBPM: self.analyzedBPM,
                        keyAnalysisResult: self.keyAnalysisResult,
                        analyzedQuality: self.audioQuality,
                        for: url
                    )
                    self.addDebugLog("RGB waveform cached for: \(url.lastPathComponent)")
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, self.currentURL == capturedURL, self.prefersColoredWaveform else { return }
                self.addDebugLog("RGB waveform error: \(self.diagnosticDescription(for: error))")
            }
        }
    }

    nonisolated static func renderSpectrogramImage(data: [[Float]]) -> CGImage? {
        let width = data.count
        guard width > 0 else { return nil }
        let height = data[0].count

        // Color stops: 0.0 → dark navy, 0.3 → deep blue, 0.65 → red-orange, 1.0 → yellow
        func colorForValue(_ v: Float) -> (UInt8, UInt8, UInt8) {
            let t = min(max(v, 0), 1)
            let r: Float, g: Float, b: Float
            if t < 0.3 {
                let f = t / 0.3
                r = Float(5) + f * Float(0 - 5)
                g = Float(5) + f * Float(20 - 5)
                b = Float(20) + f * Float(80 - 20)
            } else if t < 0.65 {
                let f = (t - 0.3) / 0.35
                r = Float(0) + f * Float(220 - 0)
                g = Float(20) + f * Float(80 - 20)
                b = Float(80) + f * Float(20 - 80)
            } else {
                let f = (t - 0.65) / 0.35
                r = Float(220) + f * Float(255 - 220)
                g = Float(80) + f * Float(240 - 80)
                b = Float(20) + f * Float(30 - 20)
            }
            return (UInt8(min(max(r, 0), 255)), UInt8(min(max(g, 0), 255)), UInt8(min(max(b, 0), 255)))
        }

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for x in 0..<width {
            for y in 0..<height {
                // Flip y so low freq at bottom
                let bin = height - 1 - y
                let value = data[x][bin]
                let (r, g, b) = colorForValue(value)
                let offset = (y * width + x) * 4
                pixels[offset] = r
                pixels[offset + 1] = g
                pixels[offset + 2] = b
                pixels[offset + 3] = 255
            }
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        return context.makeImage()
    }

    private func loadOrAnalyze(url: URL) {
        Task { [weak self] in
            guard let self else { return }
            let cached = await AudioCache.shared.getCached(for: url)
            guard self.currentURL == url else { return }

            if let cached {
                self.addDebugLog("Cache hit for: \(url.lastPathComponent)")
                let isWaveformMissing = cached.waveformSamples.isEmpty
                if isWaveformMissing {
                    self.analyzeWaveform(for: url, shouldCache: true)
                } else {
                    self.waveformSamples = cached.waveformSamples
                }
                self.coloredWaveformData = cached.coloredWaveformData
                if let cachedBPM = cached.analyzedBPM {
                    self.analyzedBPM = cachedBPM
                    self.addDebugLog("Loaded cached BPM: \(cachedBPM)")
                } else {
                    self.analyzeBPM(for: url, shouldCache: true)
                }
                if let cachedKeyResult = cached.keyAnalysisResult {
                    self.keyAnalysisResult = cachedKeyResult
                    self.addDebugLog(self.cachedKeyLogLine(for: cachedKeyResult))
                } else {
                    self.analyzeKey(for: url, shouldCache: true)
                }
                if let cachedQuality = cached.analyzedQuality {
                    self.audioQuality = cachedQuality
                    self.addDebugLog("Loaded cached quality: \(cachedQuality.estimatedBitrate.rawValue)")
                } else {
                    self.analyzeQuality(for: url, shouldCache: true)
                }
                if self.prefersColoredWaveform {
                    if cached.coloredWaveformData != nil {
                        self.addDebugLog("Loaded cached RGB waveform for: \(url.lastPathComponent)")
                    } else if !isWaveformMissing {
                        self.analyzeColoredWaveform(for: url, shouldCache: true)
                    }
                }
            } else {
                self.addDebugLog("Cache miss - analyzing: \(url.lastPathComponent)")
                self.analyzeWaveform(for: url, shouldCache: true, triggerFollowUpAnalysis: true)
            }
        }
    }

    private func analyzeBPM(for url: URL, shouldCache: Bool = false) {
        let capturedURL = url
        isAnalyzingBPM = true
        addDebugLog("BPM analysis started for: \(url.lastPathComponent)")
        bpmAnalysisTask = Task { [weak self] in
            defer {
                self?.isAnalyzingBPM = false
                self?.bpmAnalysisTask = nil
                self?.addDebugLog("BPM analysis ended. isAnalyzingBPM = false")
            }
            guard let self else {
                self?.addDebugLog("BPM analysis: self was nil")
                return
            }
            do {
                self.addDebugLog("BPM analysis: starting detached background task (Ellis DP analyzer)...")
                let detectedBPM = try await Task.detached(priority: .utility) {
                    try BPMAnalyzer4.analyze(url: url)
                }.value
                self.addDebugLog("BPM analysis: detached task returned \(detectedBPM)")
                guard !Task.isCancelled else {
                    self.addDebugLog("BPM analysis: task was cancelled")
                    return
                }
                guard self.currentURL == capturedURL else {
                    self.addDebugLog("BPM analysis: URL changed, discarding result")
                    return
                }
                self.analyzedBPM = detectedBPM
                self.addDebugLog("BPM analysis complete: \(detectedBPM) BPM")

                if shouldCache {
                    await AudioCache.shared.updateBPM(detectedBPM, for: url)
                    self.addDebugLog("BPM cached for: \(url.lastPathComponent)")
                }
            } catch is CancellationError {
                self.addDebugLog("BPM analysis: CancellationError")
                return
            } catch {
                self.addDebugLog("BPM analysis error: \(error)")
                guard !Task.isCancelled, self.currentURL == capturedURL else { return }
                self.analyzedBPM = nil
            }
        }
    }

    private func analyzeKey(for url: URL, shouldCache: Bool = false) {
        let capturedURL = url
        isAnalyzingKey = true
        addDebugLog("Key analysis started for: \(url.lastPathComponent)")
        keyAnalysisTask = Task { [weak self] in
            defer {
                self?.isAnalyzingKey = false
                self?.keyAnalysisTask = nil
                self?.addDebugLog("Key analysis ended. isAnalyzingKey = false")
            }
            guard let self else {
                self?.addDebugLog("Key analysis: self was nil")
                return
            }
            do {
                self.addDebugLog("Key analysis: starting detached background task...")
                let result = try await Task.detached(priority: .utility) {
                    try KeyAnalyzer.analyze(url: url)
                }.value
                self.addDebugLog("Key analysis: detached task returned status=\(result.status.rawValue)")
                guard !Task.isCancelled else {
                    self.addDebugLog("Key analysis: task was cancelled")
                    return
                }
                guard self.currentURL == capturedURL else {
                    self.addDebugLog("Key analysis: URL changed, discarding result")
                    return
                }
                self.keyAnalysisResult = result
                self.addDebugLog(self.keyCompletionLogLine(for: result))

                if shouldCache {
                    await AudioCache.shared.updateKey(result, for: url)
                    self.addDebugLog("Key cached for: \(url.lastPathComponent)")
                }
            } catch is CancellationError {
                self.addDebugLog("Key analysis: CancellationError")
                return
            } catch {
                self.addDebugLog("Key analysis error: \(error)")
                guard !Task.isCancelled, self.currentURL == capturedURL else { return }
                self.keyAnalysisResult = nil
            }
        }
    }

    private func analyzeQuality(for url: URL, shouldCache: Bool = false) {
        let capturedURL = url
        isAnalyzingQuality = true
        addDebugLog("Quality analysis started for: \(url.lastPathComponent)")
        qualityAnalysisTask = Task { [weak self] in
            defer {
                self?.isAnalyzingQuality = false
                self?.qualityAnalysisTask = nil
            }
            guard let self else { return }
            do {
                let (result, debug) = try await self.waveformAnalysisCoordinator.quality(url: url)
                guard !Task.isCancelled, self.currentURL == capturedURL else { return }
                self.audioQuality = result
                self.addDebugLog("Quality: \(result.estimatedBitrate.rawValue) | frames=\(debug.totalFrames)")
                self.addDebugLog("  rel16k=\(String(format: "%.1f", debug.medianRel16k)) rel17k=\(String(format: "%.1f", debug.medianRel17k)) rel18k=\(String(format: "%.1f", debug.medianRel18k))")
                self.addDebugLog("  rel19k=\(String(format: "%.1f", debug.medianRel19k)) rel20k=\(String(format: "%.1f", debug.medianRel20k))")

                if shouldCache {
                    await AudioCache.shared.updateQuality(result, for: url)
                    self.addDebugLog("Quality cached for: \(url.lastPathComponent)")
                }
            } catch is CancellationError {
                return
            } catch {
                self.addDebugLog("Quality analysis error: \(self.diagnosticDescription(for: error))")
                guard !Task.isCancelled, self.currentURL == capturedURL else { return }
                self.audioQuality = nil
            }
        }
    }

    private func analyzeWaveform(
        for url: URL,
        shouldCache: Bool = false,
        triggerFollowUpAnalysis: Bool = false
    ) {
        let capturedURL = url
        let targetSamples = 2000
        analysisTask?.cancel()
        addDebugLog("Waveform analysis started for: \(url.lastPathComponent)")
        analysisTask = Task { [weak self] in
            defer {
                self?.analysisTask = nil
            }
            guard let self else { return }

            do {
                let samples = try await self.waveformAnalysisCoordinator.waveform(
                    url: url,
                    targetSamples: targetSamples
                )
                guard !Task.isCancelled, self.currentURL == capturedURL else { return }
                self.waveformSamples = samples
                if shouldCache {
                    await AudioCache.shared.store(waveformSamples: samples, analyzedBPM: nil, for: url)
                    self.addDebugLog("Waveform cached for: \(url.lastPathComponent)")
                }
                if self.prefersColoredWaveform {
                    self.analyzeColoredWaveform(for: url, shouldCache: true)
                }
                if self.showSpectrogram, self.spectrogramImage == nil, !self.isAnalyzingSpectrogram {
                    self.analyzeAndRenderSpectrogram(for: url)
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, self.currentURL == capturedURL else { return }
                let diagnostic = self.diagnosticDescription(for: error)
                self.waveformSamples = []
                self.addDebugLog("Waveform analysis error: \(diagnostic)")
                self.errorMessage = "Failed to analyze waveform: \(diagnostic)"
            }

            guard !Task.isCancelled, self.currentURL == capturedURL else { return }

            if triggerFollowUpAnalysis {
                self.analyzeBPM(for: url, shouldCache: true)
                self.analyzeKey(for: url, shouldCache: true)
                self.analyzeQuality(for: url, shouldCache: true)
            }
        }
    }

    private func startPlaybackLoop() {
        guard playbackTask == nil else { return }
        playbackTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, self.isPlaying {
                var nextTelemetry = self.playbackTelemetry
                if !self.isScrubbing {
                    let framePos = self.currentFramePosition()
                    let sampleRate = self.audioFile?.processingFormat.sampleRate ?? 44100
                    nextTelemetry.currentTime = Double(framePos) / sampleRate
                }
                if let meter = self.lufsMeter {
                    nextTelemetry.realtimeLUFS = meter.shortTermLUFS
                    nextTelemetry.realtimeAmplitudeDB = meter.peakAmplitudeDB
                } else {
                    nextTelemetry.realtimeLUFS = nil
                    nextTelemetry.realtimeAmplitudeDB = nil
                }
                self.updateFaceExpression(for: &nextTelemetry)
                if nextTelemetry != self.playbackTelemetry {
                    self.playbackTelemetry = nextTelemetry
                }
                try? await Task.sleep(nanoseconds: self.playbackLoopIntervalNanoseconds)
            }
            if !Task.isCancelled {
                self.isPlaying = false
            }
            self.playbackTask = nil
        }
    }

    private func stopPlaybackLoop() {
        playbackTask?.cancel()
        playbackTask = nil
    }

    // MARK: - Cues

    var cues: [Cue] { cueAnalysis?.cues ?? [] }

    /// BPM to show: the file's tag, else the cue grid (fitted over the whole track), else BPMAnalyzer4
    /// (first 60 s, integer, occasionally an octave off).
    var displayBPM: Int? {
        if let bpm, bpm > 0 { return bpm }   // some files carry TBPM = 0
        if let grid = beatGrid { return Int(grid.bpm.rounded()) }
        return analyzedBPM
    }
    var beatGrid: BeatGrid? { cueAnalysis?.grid }

    private func resetCues() {
        cueTask?.cancel()
        cueTask = nil
        cueRequestedURL = nil
        cueAnalysis = nil
        cuesJustDetected = false
        selectedCueID = nil
    }

    /// Runs once per file, after the waveform is on screen and a BPM is known (or BPM analysis gave up).
    private func scheduleCueDetectionIfReady() {
        guard let url = currentURL, cueRequestedURL != url, !waveformSamples.isEmpty else { return }
        cueRequestedURL = url
        cueTask = Task { [weak self] in
            let lookup = await CueStore.shared.analysis(for: url)
            let stored = lookup?.analysis
            // Current detector and a grid: use as is. Older detector, or only manual cues so far: detect again,
            // keeping the manual cues.
            if let lookup, lookup.isCurrent, let stored, stored.grid != nil {
                guard let self, !Task.isCancelled, self.currentURL == url else { return }
                self.cuesJustDetected = false
                self.cueAnalysis = stored
                self.addDebugLog("Loaded \(stored.cues.count) cached cues")
                return
            }
            // The BPM hint only picks the tempo octave the user sees; wait briefly for it (it is usually
            // set in the same pass as the waveform, or a few hundred ms later by BPMAnalyzer4).
            var waited = 0
            while let me = self, me.currentURL == url, me.displayBPM == nil,
                  me.isAnalyzingBPM || waited < 5, waited < 100, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                waited += 1
            }
            let hint = self?.displayBPM   // tag (> 0), else BPMAnalyzer4
            let started = Date()
            let detected = try? await Task.detached(priority: .utility) {
                try CueDetector.analyze(url: url, bpmHint: hint.map(Double.init))
            }.value
            guard let self, !Task.isCancelled, self.currentURL == url, let detected else { return }
            // Keep cues the user placed while detection ran (or before it ever ran).
            let manual = (self.cueAnalysis?.cues ?? []) + (stored?.cues ?? [])
            let result = detected.merging(manual: manual)
            let edited = result.cues.contains(where: \.isManual)
            self.cuesJustDetected = true
            self.cueAnalysis = result
            self.addDebugLog(String(format: "Cues: %d in %.2fs (grid %.2f BPM)", result.cues.count,
                                    Date().timeIntervalSince(started), result.grid?.bpm ?? 0))
            await CueStore.shared.store(result, edited: edited, for: url)
        }
    }

    private func commitCueEdit(_ cues: [Cue]) {
        guard let url = currentURL else { return }
        let analysis = CueAnalysis(grid: cueAnalysis?.grid, cues: cues.sorted { $0.time < $1.time })
        cuesJustDetected = false
        cueAnalysis = analysis
        Task { await CueStore.shared.store(analysis, edited: true, for: url) }
    }

    /// Snaps to the nearest downbeat when a grid exists (hold ⌥ to place freely).
    func snappedCueTime(_ time: Double, snap: Bool = true) -> Double {
        let clamped = min(max(0, time), duration)
        guard snap, let grid = beatGrid else { return clamped }
        return min(max(0, grid.nearestBarTime(to: clamped)), duration)
    }

    /// Adds a cue at the playhead. A cue already within half a bar is retyped instead of duplicated.
    func addCue(kind: CueKind, snap: Bool = true) {
        guard duration > 0 else { return }
        let time = snappedCueTime(currentTime, snap: snap)
        var list = cues
        let tolerance = (beatGrid?.barPeriod ?? 2) / 2
        if let i = list.firstIndex(where: { abs($0.time - time) < tolerance }) {
            list[i].kind = kind
            list[i].isManual = true
            list[i].confidence = 1
            selectedCueID = list[i].id
        } else {
            let cue = Cue(kind: kind, time: time, confidence: 1, isManual: true)
            list.append(cue)
            selectedCueID = cue.id
        }
        commitCueEdit(list)
    }

    func moveCue(id: UUID, to time: Double, snap: Bool) {
        var list = cues
        guard let i = list.firstIndex(where: { $0.id == id }) else { return }
        list[i].time = snappedCueTime(time, snap: snap)
        list[i].isManual = true
        list[i].confidence = 1
        commitCueEdit(list)
    }

    /// Deletes the selected cue, or the one nearest the playhead (within a bar) when nothing is selected.
    func deleteCue() {
        let tolerance = beatGrid?.barPeriod ?? 2
        let target = selectedCueID.flatMap { id in cues.first { $0.id == id } }
            ?? cues.min { abs($0.time - currentTime) < abs($1.time - currentTime) }.flatMap { abs($0.time - currentTime) <= tolerance ? $0 : nil }
        guard let target else { return }
        selectedCueID = nil
        commitCueEdit(cues.filter { $0.id != target.id })
    }

    func jumpToCue(forward: Bool) {
        let now = currentTime
        let target = forward
            ? cues.first { $0.time > now + 0.05 }
            : cues.last { $0.time < now - 0.6 }   // small window so a double tap walks back past the cue just reached
        guard let target else { return }
        selectedCueID = target.id
        seek(to: target.time)
    }

    func stopAndReset() {
        let previousURL = currentURL
        stopPlayback()
        stopEngine()
        analysisTask?.cancel()
        bpmAnalysisTask?.cancel()
        keyAnalysisTask?.cancel()
        spectrogramTask?.cancel()
        coloredWaveformTask?.cancel()
        qualityAnalysisTask?.cancel()
        cancelWaveformFamily(for: previousURL)
        resetCues()
        duration = 0
        waveformSamples = []
        coloredWaveformData = nil
        spectrogramImage = nil
        isAnalyzingSpectrogram = false
        showSpectrogram = false
        isAnalyzingColoredWaveform = false
        fileName = "No file loaded"
        bpm = nil
        analyzedBPM = nil
        keyAnalysisResult = nil
        audioQuality = nil
        isAnalyzingQuality = false
        resetPlaybackTelemetry()
        currentURL = nil
        releaseSecurityScopedResource()
    }

    private func stopPlayback() {
        playGeneration &+= 1  // invalidate any pending completion
        playerNode?.stop()
        isPlaying = false
        stopPlaybackLoop()
        clearRealtimePlaybackMetrics()
    }

    private func stopEngine() {
        disableRealtimeMeters()
        audioEngine?.stop()
        audioEngine = nil
        playerNode = nil
        audioFile = nil
        startingFramePosition = 0
    }

    private func replaceSecurityScopedResource(with url: URL, startedAccessing: Bool) {
        releaseSecurityScopedResource()
        guard startedAccessing else { return }
        securityScopedURL = url
        isAccessingSecurityScopedURL = true
    }

    private func releaseSecurityScopedResource() {
        guard isAccessingSecurityScopedURL, let securityScopedURL else {
            self.securityScopedURL = nil
            isAccessingSecurityScopedURL = false
            return
        }

        securityScopedURL.stopAccessingSecurityScopedResource()
        self.securityScopedURL = nil
        isAccessingSecurityScopedURL = false
    }

    private func isSupported(url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }

    private static func formatTime(_ time: TimeInterval) -> String {
        guard time.isFinite && !time.isNaN else { return "00:00" }
        let totalSeconds = max(Int(time.rounded()), 0)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
