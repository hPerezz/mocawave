import CryptoKit
import Foundation

/// Manages persistent caching of audio analysis results (waveform and BPM)
/// in the Application Support directory.
actor AudioCache {
    static let shared = AudioCache()

    /// Bump this version when the waveform analysis algorithm changes
    /// to invalidate all cached waveform data.
    private static let cacheVersion = 8 // v8: BPM folded to the DJ range 70–180 (was 40–240)

    private struct VersionedCache: Codable {
        let version: Int
        let entries: [String: CacheEntry]
    }

    private struct CacheEntry: Codable {
        let waveformSamples: [Float]
        let analyzedBPM: Int?
        let keyAnalysisResult: KeyAnalyzer.KeyAnalysisResult?
        let analyzedQuality: WaveformAnalyzer.AudioQualityResult?
        let coloredWaveformData: WaveformAnalyzer.ColoredWaveformData?
        let fileSize: UInt64
        let modificationDate: Date
    }

    private var cache: [String: CacheEntry] = [:]
    private let cacheURL: URL
    private var isDirty = false

    init(baseDirectoryURL: URL? = nil) {
        let appFolder: URL
        if let baseDirectoryURL {
            appFolder = baseDirectoryURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            appFolder = appSupport.appendingPathComponent("mocawave", isDirectory: true)
        }

        try? FileManager.default.createDirectory(at: appFolder, withIntermediateDirectories: true)

        cacheURL = appFolder.appendingPathComponent("audio_cache.json")
        // Load cache synchronously in init - discard if version mismatch
        cache = Self.loadCacheSync(from: cacheURL)
    }

    private nonisolated static func loadCacheSync(from url: URL) -> [String: CacheEntry] {
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else {
            return [:]
        }
        // Try loading versioned format first
        if let versioned = try? JSONDecoder().decode(VersionedCache.self, from: data),
           versioned.version == cacheVersion {
            return versioned.entries
        }
        // Version mismatch or old format — discard cache
        return [:]
    }

    struct CachedData {
        let waveformSamples: [Float]
        let analyzedBPM: Int?
        let keyAnalysisResult: KeyAnalyzer.KeyAnalysisResult?
        let analyzedQuality: WaveformAnalyzer.AudioQualityResult?
        let coloredWaveformData: WaveformAnalyzer.ColoredWaveformData?
    }

    func getCached(for url: URL) -> CachedData? {
        guard let key = cacheKey(for: url),
              let entry = cache[key],
              isValid(entry: entry, for: url) else {
            return nil
        }
        return CachedData(
            waveformSamples: entry.waveformSamples,
            analyzedBPM: entry.analyzedBPM,
            keyAnalysisResult: entry.keyAnalysisResult,
            analyzedQuality: entry.analyzedQuality,
            coloredWaveformData: entry.coloredWaveformData
        )
    }

    func store(
        waveformSamples: [Float],
        analyzedBPM: Int?,
        keyAnalysisResult: KeyAnalyzer.KeyAnalysisResult? = nil,
        analyzedQuality: WaveformAnalyzer.AudioQualityResult? = nil,
        coloredWaveformData: WaveformAnalyzer.ColoredWaveformData? = nil,
        for url: URL
    ) {
        guard let key = cacheKey(for: url),
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let fileSize = attrs[.size] as? UInt64,
              let modDate = attrs[.modificationDate] as? Date else {
            return
        }

        let existingEntry = cache[key]

        cache[key] = CacheEntry(
            waveformSamples: waveformSamples,
            analyzedBPM: analyzedBPM,
            keyAnalysisResult: keyAnalysisResult ?? existingEntry?.keyAnalysisResult,
            analyzedQuality: analyzedQuality ?? existingEntry?.analyzedQuality,
            coloredWaveformData: coloredWaveformData ?? existingEntry?.coloredWaveformData,
            fileSize: fileSize,
            modificationDate: modDate
        )
        isDirty = true
        saveCache()
    }

    func updateBPM(_ bpm: Int?, for url: URL) {
        guard let key = cacheKey(for: url),
              var entry = cache[key] else {
            return
        }

        entry = CacheEntry(
            waveformSamples: entry.waveformSamples,
            analyzedBPM: bpm,
            keyAnalysisResult: entry.keyAnalysisResult,
            analyzedQuality: entry.analyzedQuality,
            coloredWaveformData: entry.coloredWaveformData,
            fileSize: entry.fileSize,
            modificationDate: entry.modificationDate
        )
        cache[key] = entry
        isDirty = true
        saveCache()
    }

    func updateKey(_ keyAnalysisResult: KeyAnalyzer.KeyAnalysisResult?, for url: URL) {
        guard let key = cacheKey(for: url),
              var entry = cache[key] else {
            return
        }

        entry = CacheEntry(
            waveformSamples: entry.waveformSamples,
            analyzedBPM: entry.analyzedBPM,
            keyAnalysisResult: keyAnalysisResult,
            analyzedQuality: entry.analyzedQuality,
            coloredWaveformData: entry.coloredWaveformData,
            fileSize: entry.fileSize,
            modificationDate: entry.modificationDate
        )
        cache[key] = entry
        isDirty = true
        saveCache()
    }

    func updateQuality(_ quality: WaveformAnalyzer.AudioQualityResult?, for url: URL) {
        guard let key = cacheKey(for: url),
              var entry = cache[key] else {
            return
        }

        entry = CacheEntry(
            waveformSamples: entry.waveformSamples,
            analyzedBPM: entry.analyzedBPM,
            keyAnalysisResult: entry.keyAnalysisResult,
            analyzedQuality: quality,
            coloredWaveformData: entry.coloredWaveformData,
            fileSize: entry.fileSize,
            modificationDate: entry.modificationDate
        )
        cache[key] = entry
        isDirty = true
        saveCache()
    }

    func upsertColoredWaveform(
        _ coloredWaveformData: WaveformAnalyzer.ColoredWaveformData,
        waveformSamples: [Float],
        analyzedBPM: Int?,
        keyAnalysisResult: KeyAnalyzer.KeyAnalysisResult?,
        analyzedQuality: WaveformAnalyzer.AudioQualityResult?,
        for url: URL
    ) {
        guard let key = cacheKey(for: url),
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let fileSize = attrs[.size] as? UInt64,
              let modDate = attrs[.modificationDate] as? Date else {
            return
        }

        let existingEntry = cache[key]
        let resolvedWaveformSamples = existingEntry?.waveformSamples.isEmpty == false
            ? existingEntry?.waveformSamples ?? waveformSamples
            : waveformSamples

        cache[key] = CacheEntry(
            waveformSamples: resolvedWaveformSamples,
            analyzedBPM: existingEntry?.analyzedBPM ?? analyzedBPM,
            keyAnalysisResult: existingEntry?.keyAnalysisResult ?? keyAnalysisResult,
            analyzedQuality: existingEntry?.analyzedQuality ?? analyzedQuality,
            coloredWaveformData: coloredWaveformData,
            fileSize: fileSize,
            modificationDate: modDate
        )
        isDirty = true
        saveCache()
    }

    func updateWaveform(_ samples: [Float], for url: URL) {
        guard let key = cacheKey(for: url),
              var entry = cache[key] else {
            // No existing entry - can't update, need full store
            return
        }

        entry = CacheEntry(
            waveformSamples: samples,
            analyzedBPM: entry.analyzedBPM,
            keyAnalysisResult: entry.keyAnalysisResult,
            analyzedQuality: entry.analyzedQuality,
            coloredWaveformData: entry.coloredWaveformData,
            fileSize: entry.fileSize,
            modificationDate: entry.modificationDate
        )
        cache[key] = entry
        isDirty = true
        saveCache()
    }

    private func cacheKey(for url: URL) -> String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let fileSize = attrs[.size] as? UInt64 else {
            return nil
        }

        // Use file path + size for quick identification
        // For more robust detection, we sample first 8KB of file content
        let pathHash = url.path.data(using: .utf8)!
        var hasher = SHA256()
        hasher.update(data: pathHash)

        // Add file size
        var size = fileSize
        withUnsafeBytes(of: &size) { hasher.update(bufferPointer: $0) }

        // Sample first 8KB of file for content-based hashing
        if let handle = try? FileHandle(forReadingFrom: url) {
            let sample = handle.readData(ofLength: 8192)
            hasher.update(data: sample)
            try? handle.close()
        }

        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func isValid(entry: CacheEntry, for url: URL) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let fileSize = attrs[.size] as? UInt64,
              let modDate = attrs[.modificationDate] as? Date else {
            return false
        }

        // Cache is valid if file size and modification date match
        return entry.fileSize == fileSize &&
               abs(entry.modificationDate.timeIntervalSince(modDate)) < 1.0
    }

    private func loadCache() {
        cache = Self.loadCacheSync(from: cacheURL)
    }

    private func saveCache() {
        guard isDirty else { return }
        isDirty = false

        let versioned = VersionedCache(version: Self.cacheVersion, entries: cache)
        Task.detached(priority: .utility) { [versioned, cacheURL] in
            guard let data = try? JSONEncoder().encode(versioned) else { return }
            try? data.write(to: cacheURL, options: .atomic)
        }
    }
}
