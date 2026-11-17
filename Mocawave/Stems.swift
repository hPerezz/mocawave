import Accelerate
import AVFoundation
import SwiftUI

/// The six stems every separator we use returns, in lane order (top → bottom). Shared contract with the
/// dj-stack agent: `docs/stems-contract.md`.
enum StemKind: String, CaseIterable, Codable, Sendable, Identifiable {
    case vocals, drums, bass, guitar, piano, other

    var id: String { rawValue }

    var title: String { rawValue.uppercased() }

    var color: Color {
        switch self {
        case .vocals: return MocaTheme.Stem.vocals
        case .drums: return MocaTheme.Stem.drums
        case .bass: return MocaTheme.Stem.bass
        case .guitar: return MocaTheme.Stem.guitar
        case .piano: return MocaTheme.Stem.piano
        case .other: return MocaTheme.Stem.other
        }
    }

    var symbol: String {
        switch self {
        case .vocals: return "mic.fill"
        case .drums: return "circle.grid.2x2.fill"
        case .bass: return "waveform.path"
        case .guitar: return "guitars.fill"
        case .piano: return "pianokeys"
        case .other: return "sparkles"
        }
    }
}

/// `manifest.json`, written by whoever separated the track (agent today, Core ML later).
struct StemManifest: Codable, Equatable, Sendable {
    var version: Int
    var model: String
    var source: Source
    var sampleRate: Double?
    var created: String?
    var stems: [Entry]

    struct Source: Codable, Equatable, Sendable {
        var path: String?
        var size: Int?
        var duration: Double?
    }

    struct Entry: Codable, Equatable, Sendable {
        var name: String
        var file: String
        var bytes: Int?
        var rmsDb: Double?
    }

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    /// Short, human name of the model for the drawer header ("BS-Roformer", "Demucs 6s").
    var modelName: String {
        let lower = model.lowercased()
        if lower.contains("roformer") { return "BS-Roformer" }
        if lower.contains("htdemucs_6s") { return "Demucs 6s" }
        if lower.contains("demucs") { return "Demucs" }
        return (model as NSString).deletingPathExtension
    }
}

/// One separated track on disk, ready to play.
struct StemSet: Equatable, Sendable {
    var directory: URL
    var manifest: StemManifest
    /// Stems present on disk, in lane order.
    var files: [(kind: StemKind, url: URL, rmsDb: Double?)]

    static func == (a: StemSet, b: StemSet) -> Bool { a.directory == b.directory && a.manifest == b.manifest }
}

/// A lane in the mixer: what to draw and how it's mixed.
struct StemLane: Identifiable, Equatable, Sendable {
    var kind: StemKind
    /// Peak envelope, 0…1 on a scale shared by all lanes of the track (a quiet stem looks quiet).
    var peaks: [Float]
    var rmsDb: Double?
    var volume: Double = 1          // 0…1.5 (fader; 1 = unity)
    var isMuted = false
    var isSoloed = false

    var id: StemKind { kind }

    /// Practically silent across the whole track (piano on a techno tune): drawn collapsed, still playable.
    var isNearlySilent: Bool { (rmsDb ?? 0) < StemLane.silentThresholdDB }
    static let silentThresholdDB = -45.0

    /// Gain actually applied, given every lane's solo state.
    func gain(anySolo: Bool) -> Float {
        if isMuted { return 0 }
        if anySolo && !isSoloed { return 0 }
        return Float(volume)
    }
}

enum StemsState: Equatable, Sendable {
    /// Nothing cached and no way to separate (release build without the agent).
    case unavailable
    /// Not separated yet: offer the button.
    case idle
    /// The agent isn't running.
    case offline
    case queued(position: Int)
    case separating(progress: Double, eta: Double?, stage: String)
    /// Copying the separated files into the app cache.
    case downloading(progress: Double)
    /// Reading the cached stems (peaks, players).
    case loading
    case ready
    case failed(String)

    var isWorking: Bool {
        switch self {
        case .queued, .separating, .downloading, .loading: return true
        default: return false
        }
    }

    /// 0…1 for the progress bar, nil when indeterminate.
    var progress: Double? {
        switch self {
        case .separating(let p, _, _): return p
        case .downloading(let p): return p
        default: return nil
        }
    }
}

/// Stems cache inside the app container: `Application Support/mocawave/stems/<trackKey>/`.
/// Reopening a track that was separated once is instant and needs nothing else running (offline).
actor StemStore {
    static let shared = StemStore()

    let root: URL
    /// Evict least-recently-used tracks above this size.
    let byteLimit: Int64

    init(root: URL? = nil, byteLimit: Int64 = 10 * 1_024 * 1_024 * 1_024) {
        if let root {
            self.root = root
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.root = appSupport.appendingPathComponent("mocawave/stems", isDirectory: true)
        }
        self.byteLimit = byteLimit
        try? FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
    }

    func directory(for url: URL) -> URL? {
        AudioCache.trackKey(for: url).map { root.appendingPathComponent($0, isDirectory: true) }
    }

    /// The cached stems of `url`, if complete. Touches the entry (LRU).
    func cached(for url: URL) -> StemSet? {
        guard let dir = directory(for: url) else { return nil }
        guard let set = Self.load(dir) else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: dir.path)
        return set
    }

    static func load(_ dir: URL) -> StemSet? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("manifest.json")),
              let manifest = try? StemManifest.decoder.decode(StemManifest.self, from: data) else { return nil }
        var files: [(StemKind, URL, Double?)] = []
        for kind in StemKind.allCases {
            guard let entry = manifest.stems.first(where: { $0.name == kind.rawValue }) else { continue }
            let file = dir.appendingPathComponent(entry.file)
            guard FileManager.default.fileExists(atPath: file.path) else { return nil }   // incomplete
            files.append((kind, file, entry.rmsDb))
        }
        guard !files.isEmpty else { return nil }
        return StemSet(directory: dir, manifest: manifest, files: files)
    }

    /// Moves a fully downloaded set (files already in `staging`, manifest included) into place atomically,
    /// so a half-written entry is never picked up.
    func install(staging: URL, for url: URL) throws -> StemSet {
        guard let dir = directory(for: url) else { throw CocoaError(.fileReadNoSuchFile) }
        let fm = FileManager.default
        if fm.fileExists(atPath: dir.path) { try fm.removeItem(at: dir) }
        try fm.moveItem(at: staging, to: dir)
        guard let set = Self.load(dir) else { throw CocoaError(.fileReadCorruptFile) }
        evictIfNeeded(keeping: dir)
        return set
    }

    /// A fresh staging folder next to the cache (same volume, so `install` is a rename).
    func makeStaging() throws -> URL {
        let dir = root.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func totalBytes() -> Int64 {
        entries().reduce(0) { $0 + $1.bytes }
    }

    func clear() {
        for entry in entries() { try? FileManager.default.removeItem(at: entry.url) }
    }

    private func entries() -> [(url: URL, bytes: Int64, used: Date)] {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey],
                                                     options: [.skipsHiddenFiles]) else { return [] }
        return dirs.map { dir in
            let used = (try? dir.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
            let bytes = files.reduce(Int64(0)) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
            return (dir, bytes, used)
        }
    }

    private func evictIfNeeded(keeping: URL) {
        var all = entries().sorted { $0.used < $1.used }   // oldest first
        var total = all.reduce(Int64(0)) { $0 + $1.bytes }
        while total > byteLimit, let oldest = all.first {
            all.removeFirst()
            if oldest.url.standardizedFileURL == keeping.standardizedFileURL { continue }
            try? FileManager.default.removeItem(at: oldest.url)
            total -= oldest.bytes
        }
    }

    // MARK: Peaks

    static let peakBins = 1_200

    /// Peak envelopes for every stem, on one shared scale. Cached as `peaks.json` next to the stems.
    func peaks(for set: StemSet) async -> [StemKind: [Float]] {
        let cacheFile = set.directory.appendingPathComponent("peaks.json")
        if let data = try? Data(contentsOf: cacheFile),
           let raw = try? JSONDecoder().decode([String: [Float]].self, from: data) {
            let decoded = Dictionary(uniqueKeysWithValues: raw.compactMap { k, v in StemKind(rawValue: k).map { ($0, v) } })
            if decoded.count == set.files.count { return decoded }
        }
        let bins = Self.peakBins
        let raw: [StemKind: [Float]] = await withTaskGroup(of: (StemKind, [Float]).self) { group in
            for file in set.files {
                group.addTask { (file.kind, Self.peakEnvelope(of: file.url, bins: bins)) }
            }
            var out: [StemKind: [Float]] = [:]
            for await (kind, env) in group { out[kind] = env }
            return out
        }
        let scaled = Self.sharedScale(raw)
        if let data = try? JSONEncoder().encode(Dictionary(uniqueKeysWithValues: scaled.map { ($0.key.rawValue, $0.value) })) {
            try? data.write(to: cacheFile, options: .atomic)
        }
        return scaled
    }

    /// Max |sample| per bin over both channels.
    nonisolated static func peakEnvelope(of url: URL, bins: Int) -> [Float] {
        guard let file = try? AVAudioFile(forReading: url), file.length > 0 else { return [] }
        let format = file.processingFormat
        let total = file.length
        var out = [Float](repeating: 0, count: bins)
        let chunk: AVAudioFrameCount = 65_536
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { return [] }
        var position: AVAudioFramePosition = 0
        while position < total {
            do { try file.read(into: buffer, frameCount: chunk) } catch { break }
            let n = Int(buffer.frameLength)
            if n == 0 { break }
            guard let channels = buffer.floatChannelData else { break }
            for c in 0..<Int(format.channelCount) {
                let data = channels[c]
                var i = 0
                while i < n {
                    let bin = min(bins - 1, Int((position + AVAudioFramePosition(i)) * AVAudioFramePosition(bins) / total))
                    // Walk to the end of this bin within the buffer, keeping the max.
                    let binEnd = min(n, Int(AVAudioFramePosition(bin + 1) * total / AVAudioFramePosition(bins) - position))
                    var m = out[bin]
                    let end = max(binEnd, i + 1)
                    while i < end {
                        let v = abs(data[i])
                        if v > m { m = v }
                        i += 1
                    }
                    out[bin] = m
                }
            }
            position += AVAudioFramePosition(n)
        }
        return out
    }

    // MARK: Alignment

    /// Frames by which the stems lag the source *as Core Audio decodes it* (positive = stems late). Separators
    /// decode with their own decoder, which may keep the MP3 decoder delay (529 frames, measured on real
    /// stems) or AAC priming (2112) that Core Audio trims. Measured once by cross-correlating the summed stems
    /// with the source, cached in `align.json`; 0 when unsure (low correlation, different sample rates).
    func alignment(for set: StemSet, source: URL) -> Int {
        let cacheFile = set.directory.appendingPathComponent("align.json")
        if let data = try? Data(contentsOf: cacheFile),
           let cached = try? JSONDecoder().decode([String: Double].self, from: data), let frames = cached["frames"] {
            return Int(frames)
        }
        let measured = Self.measureOffset(stems: set.files.map(\.url), source: source)
        let frames = measured.map { $0.score >= Self.alignMinScore ? $0.lag : 0 } ?? 0
        let record: [String: Double] = ["frames": Double(frames), "lag": Double(measured?.lag ?? 0), "score": measured?.score ?? 0]
        if let data = try? JSONEncoder().encode(record) { try? data.write(to: cacheFile, options: .atomic) }
        return frames
    }

    static let alignMinScore = 0.6

    /// Best lag (frames, stems relative to source) over three windows of the track, with its normalised
    /// correlation. nil if the files can't be read or the sample rates differ.
    nonisolated static func measureOffset(stems: [URL], source: URL, window: Int = 16_384, maxLag: Int = 4_096) -> (lag: Int, score: Double)? {
        guard let src = try? AVAudioFile(forReading: source), src.length > Int64(window + 2 * maxLag) else { return nil }
        let rate = src.processingFormat.sampleRate
        let files = stems.compactMap { try? AVAudioFile(forReading: $0) }
        guard files.count == stems.count, files.allSatisfy({ $0.processingFormat.sampleRate == rate }) else { return nil }
        var best: (lag: Int, score: Double)?
        for fraction in [0.3, 0.5, 0.7] {
            let start = AVAudioFramePosition(Double(src.length) * fraction)
            guard let a = monoWindow(src, from: start, count: window) else { continue }
            var mix = [Float](repeating: 0, count: window + 2 * maxLag)
            for f in files {
                guard let s = monoWindow(f, from: start - AVAudioFramePosition(maxLag), count: mix.count) else { continue }
                vDSP_vadd(mix, 1, s, 1, &mix, 1, vDSP_Length(mix.count))
            }
            var corr = [Float](repeating: 0, count: 2 * maxLag + 1)
            vDSP_conv(mix, 1, a, 1, &corr, 1, vDSP_Length(corr.count), vDSP_Length(window))   // correlation
            var peak: Float = 0
            var index: vDSP_Length = 0
            vDSP_maxvi(corr, 1, &peak, &index, vDSP_Length(corr.count))
            var ea: Float = 0, em: Float = 0
            vDSP_svesq(a, 1, &ea, vDSP_Length(window))
            mix.withUnsafeBufferPointer { p in vDSP_svesq(p.baseAddress! + Int(index), 1, &em, vDSP_Length(window)) }
            guard ea > 1e-6, em > 1e-6 else { continue }
            let score = Double(peak) / sqrt(Double(ea) * Double(em))
            if score > (best?.score ?? -1) { best = (Int(index) - maxLag, score) }
        }
        return best
    }

    /// `count` frames from `start` (zeros outside the file), channels averaged.
    nonisolated private static func monoWindow(_ file: AVAudioFile, from start: AVAudioFramePosition, count: Int) -> [Float]? {
        var out = [Float](repeating: 0, count: count)
        let skip = max(0, -Int(start))
        let first = max(start, 0)
        guard first < file.length, count > skip,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(count - skip)) else { return out }
        file.framePosition = first
        do { try file.read(into: buffer, frameCount: AVAudioFrameCount(count - skip)) } catch { return nil }
        let channels = Int(file.processingFormat.channelCount)
        guard let data = buffer.floatChannelData, channels > 0 else { return nil }
        for c in 0..<channels {
            for i in 0..<Int(buffer.frameLength) { out[skip + i] += data[c][i] / Float(channels) }
        }
        return out
    }

    /// One scale for all lanes (relative to the loudest stem), with a gentle curve so quiet parts stay visible.
    nonisolated static func sharedScale(_ raw: [StemKind: [Float]]) -> [StemKind: [Float]] {
        let top = raw.values.flatMap { $0 }.max() ?? 0
        guard top > 0 else { return raw }
        return raw.mapValues { env in env.map { pow(min($0 / top, 1), 0.7) } }
    }
}

extension StemsState {
    /// Before anything is known: separation is offered in dev builds, hidden in release.
    static var initial: StemsState { FeatureFlags.trackInfo ? .idle : .unavailable }
}
