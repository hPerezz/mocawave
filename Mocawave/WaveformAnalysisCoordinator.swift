import Foundation

protocol WaveformAnalysisScheduling: Sendable {
    func waveform(url: URL, targetSamples: Int) async throws -> [Float]
    func coloredWaveform(url: URL, targetColumns: Int) async throws -> WaveformAnalyzer.ColoredWaveformData
    func spectrogram(url: URL, targetColumns: Int, freqBins: Int) async throws -> [[Float]]
    func quality(url: URL) async throws -> (WaveformAnalyzer.AudioQualityResult, WaveformAnalyzer.QualityDebugInfo)
    func cancelAll(for url: URL) async
    func cancelColoredWaveform(for url: URL) async
    func cancelSpectrogram(for url: URL) async
    func cancelQuality(for url: URL) async
}

actor WaveformAnalysisCoordinator: WaveformAnalysisScheduling {
    typealias WaveformOperation = @Sendable (URL, Int) throws -> [Float]
    typealias ColoredWaveformOperation = @Sendable (URL, Int) throws -> WaveformAnalyzer.ColoredWaveformData
    typealias SpectrogramOperation = @Sendable (URL, Int, Int) throws -> [[Float]]
    typealias QualityOperation = @Sendable (URL) throws -> (WaveformAnalyzer.AudioQualityResult, WaveformAnalyzer.QualityDebugInfo)

    static let shared = WaveformAnalysisCoordinator()

    private protocol URLScopedRequestKey: Hashable, Sendable {
        var url: URL { get }
    }

    private struct QueueTail: Sendable {
        let generation: UInt64
        let task: Task<Void, Never>
    }

    private struct WaveformRequestKey: URLScopedRequestKey {
        let url: URL
        let targetSamples: Int
    }

    private struct ColoredWaveformRequestKey: URLScopedRequestKey {
        let url: URL
        let targetColumns: Int
    }

    private struct SpectrogramRequestKey: URLScopedRequestKey {
        let url: URL
        let targetColumns: Int
        let freqBins: Int
    }

    private struct QualityRequestKey: URLScopedRequestKey {
        let url: URL
    }

    private let waveformOperation: WaveformOperation
    private let coloredWaveformOperation: ColoredWaveformOperation
    private let spectrogramOperation: SpectrogramOperation
    private let qualityOperation: QualityOperation

    private var queueGeneration: UInt64 = 0
    private var queueTails: [URL: QueueTail] = [:]
    private var waveformTasks: [WaveformRequestKey: Task<[Float], Error>] = [:]
    private var coloredWaveformTasks: [ColoredWaveformRequestKey: Task<WaveformAnalyzer.ColoredWaveformData, Error>] = [:]
    private var spectrogramTasks: [SpectrogramRequestKey: Task<[[Float]], Error>] = [:]
    private var qualityTasks: [QualityRequestKey: Task<(WaveformAnalyzer.AudioQualityResult, WaveformAnalyzer.QualityDebugInfo), Error>] = [:]

    init(
        waveformOperation: @escaping WaveformOperation = { url, targetSamples in
            try WaveformAnalyzer.analyze(url: url, targetSamples: targetSamples)
        },
        coloredWaveformOperation: @escaping ColoredWaveformOperation = { url, targetColumns in
            try WaveformAnalyzer.analyzeColoredWaveform(url: url, targetColumns: targetColumns)
        },
        spectrogramOperation: @escaping SpectrogramOperation = { url, targetColumns, freqBins in
            try WaveformAnalyzer.analyzeSpectrogram(url: url, targetColumns: targetColumns, freqBins: freqBins)
        },
        qualityOperation: @escaping QualityOperation = { url in
            try WaveformAnalyzer.analyzeQuality(url: url)
        }
    ) {
        self.waveformOperation = waveformOperation
        self.coloredWaveformOperation = coloredWaveformOperation
        self.spectrogramOperation = spectrogramOperation
        self.qualityOperation = qualityOperation
    }

    func waveform(url: URL, targetSamples: Int) async throws -> [Float] {
        let normalizedURL = normalize(url)
        let key = WaveformRequestKey(url: normalizedURL, targetSamples: targetSamples)

        if let existingTask = waveformTasks[key] {
            return try await existingTask.value
        }

        let task = enqueue(url: normalizedURL) { [waveformOperation, url] in
            try Self.withSecurityScopedAccess(to: url) {
                try waveformOperation(url, targetSamples)
            }
        }
        waveformTasks[key] = task
        scheduleWaveformCleanup(task, key: key)
        return try await task.value
    }

    func coloredWaveform(url: URL, targetColumns: Int) async throws -> WaveformAnalyzer.ColoredWaveformData {
        let normalizedURL = normalize(url)
        let key = ColoredWaveformRequestKey(url: normalizedURL, targetColumns: targetColumns)

        if let existingTask = coloredWaveformTasks[key] {
            return try await existingTask.value
        }

        let task = enqueue(url: normalizedURL) { [coloredWaveformOperation, url] in
            try Self.withSecurityScopedAccess(to: url) {
                try coloredWaveformOperation(url, targetColumns)
            }
        }
        coloredWaveformTasks[key] = task
        scheduleColoredWaveformCleanup(task, key: key)
        return try await task.value
    }

    func spectrogram(url: URL, targetColumns: Int, freqBins: Int) async throws -> [[Float]] {
        let normalizedURL = normalize(url)
        let key = SpectrogramRequestKey(url: normalizedURL, targetColumns: targetColumns, freqBins: freqBins)

        if let existingTask = spectrogramTasks[key] {
            return try await existingTask.value
        }

        let task = enqueue(url: normalizedURL) { [spectrogramOperation, url] in
            try Self.withSecurityScopedAccess(to: url) {
                try spectrogramOperation(url, targetColumns, freqBins)
            }
        }
        spectrogramTasks[key] = task
        scheduleSpectrogramCleanup(task, key: key)
        return try await task.value
    }

    func quality(url: URL) async throws -> (WaveformAnalyzer.AudioQualityResult, WaveformAnalyzer.QualityDebugInfo) {
        let normalizedURL = normalize(url)
        let key = QualityRequestKey(url: normalizedURL)

        if let existingTask = qualityTasks[key] {
            return try await existingTask.value
        }

        let task = enqueue(url: normalizedURL) { [qualityOperation, url] in
            try Self.withSecurityScopedAccess(to: url) {
                try qualityOperation(url)
            }
        }
        qualityTasks[key] = task
        scheduleQualityCleanup(task, key: key)
        return try await task.value
    }

    func cancelAll(for url: URL) async {
        let normalizedURL = normalize(url)
        cancelTasks(for: normalizedURL, in: &waveformTasks)
        cancelTasks(for: normalizedURL, in: &coloredWaveformTasks)
        cancelTasks(for: normalizedURL, in: &spectrogramTasks)
        cancelTasks(for: normalizedURL, in: &qualityTasks)
        queueTails[normalizedURL]?.task.cancel()
        queueTails[normalizedURL] = nil
    }

    func cancelColoredWaveform(for url: URL) async {
        cancelTasks(for: normalize(url), in: &coloredWaveformTasks)
    }

    func cancelSpectrogram(for url: URL) async {
        cancelTasks(for: normalize(url), in: &spectrogramTasks)
    }

    func cancelQuality(for url: URL) async {
        cancelTasks(for: normalize(url), in: &qualityTasks)
    }

    private func enqueue<Result: Sendable>(
        url: URL,
        operation: @escaping @Sendable () throws -> Result
    ) -> Task<Result, Error> {
        let predecessor = queueTails[url]?.task
        let task = Task.detached(priority: .utility) {
            await predecessor?.value
            try Task.checkCancellation()
            return try operation()
        }

        queueGeneration &+= 1
        let generation = queueGeneration
        let tailTask = Task.detached(priority: .utility) {
            _ = try? await task.value
        }
        queueTails[url] = QueueTail(generation: generation, task: tailTask)

        Task { [generation, url] in
            await tailTask.value
            self.removeTail(for: url, generation: generation)
        }

        return task
    }

    private func normalize(_ url: URL) -> URL {
        url.standardizedFileURL
    }

    nonisolated private static func withSecurityScopedAccess<Result>(
        to url: URL,
        _ operation: () throws -> Result
    ) rethrows -> Result {
        let startedAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if startedAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }
        return try operation()
    }

    private func cancelTasks<Key, Result>(
        for url: URL,
        in tasks: inout [Key: Task<Result, Error>]
    ) where Key: URLScopedRequestKey {
        let matchingKeys = tasks.keys.filter { $0.url == url }
        for key in matchingKeys {
            tasks[key]?.cancel()
            tasks.removeValue(forKey: key)
        }
    }

    private func removeTail(for url: URL, generation: UInt64) {
        guard queueTails[url]?.generation == generation else { return }
        queueTails[url] = nil
    }

    private func removeWaveformTask(for key: WaveformRequestKey) {
        waveformTasks.removeValue(forKey: key)
    }

    private func removeColoredWaveformTask(for key: ColoredWaveformRequestKey) {
        coloredWaveformTasks.removeValue(forKey: key)
    }

    private func removeSpectrogramTask(for key: SpectrogramRequestKey) {
        spectrogramTasks.removeValue(forKey: key)
    }

    private func removeQualityTask(for key: QualityRequestKey) {
        qualityTasks.removeValue(forKey: key)
    }

    private func scheduleWaveformCleanup(_ task: Task<[Float], Error>, key: WaveformRequestKey) {
        Task { [key] in
            _ = try? await task.value
            self.removeWaveformTask(for: key)
        }
    }

    private func scheduleColoredWaveformCleanup(
        _ task: Task<WaveformAnalyzer.ColoredWaveformData, Error>,
        key: ColoredWaveformRequestKey
    ) {
        Task { [key] in
            _ = try? await task.value
            self.removeColoredWaveformTask(for: key)
        }
    }

    private func scheduleSpectrogramCleanup(
        _ task: Task<[[Float]], Error>,
        key: SpectrogramRequestKey
    ) {
        Task { [key] in
            _ = try? await task.value
            self.removeSpectrogramTask(for: key)
        }
    }

    private func scheduleQualityCleanup(
        _ task: Task<(WaveformAnalyzer.AudioQualityResult, WaveformAnalyzer.QualityDebugInfo), Error>,
        key: QualityRequestKey
    ) {
        Task { [key] in
            _ = try? await task.value
            self.removeQualityTask(for: key)
        }
    }
}
