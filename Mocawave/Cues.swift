import CryptoKit
import Foundation
import SwiftUI

/// Structural markers on the track. Raw values are persisted — do not rename.
enum CueKind: String, Codable, CaseIterable, Sendable {
    case intro, build, drop, breakdown, outro, cue

    /// Single letter on the flag (colour is never the only signal).
    var letter: String {
        switch self {
        case .intro: return "I"
        case .build: return "B"
        case .drop: return "D"
        case .breakdown: return "R"
        case .outro: return "O"
        case .cue: return "C"
        }
    }

    var title: String {
        switch self {
        case .intro: return "Intro"
        case .build: return "Build"
        case .drop: return "Drop"
        case .breakdown: return "Break"
        case .outro: return "Outro"
        case .cue: return "Cue"
        }
    }

    var color: Color {
        switch self {
        case .intro, .outro: return MocaTheme.Cue.introOutro
        case .build: return MocaTheme.Cue.build
        case .drop: return MocaTheme.Cue.drop
        case .breakdown: return MocaTheme.Cue.breakdown
        case .cue: return Color.white.opacity(0.85)
        }
    }

    /// Keyboard letter that creates this kind at the playhead (K stays with the Camelot wheel).
    static func forShortcut(_ character: String) -> CueKind? {
        switch character.lowercased() {
        case "i": return .intro
        case "b": return .build
        case "d": return .drop
        case "r": return .breakdown
        case "o": return .outro
        case "c": return .cue
        default: return nil
        }
    }
}

struct Cue: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var kind: CueKind
    /// Seconds from the start of the file.
    var time: Double
    /// 0–1. Below `suggestionThreshold` the flag is drawn hollow and nothing downstream (CO2) uses it.
    var confidence: Float
    /// Placed or moved by the user. Manual cues always count as confident.
    var isManual: Bool = false

    static let suggestionThreshold: Float = 0.5
    var isSuggestion: Bool { !isManual && confidence < Self.suggestionThreshold }
}

/// Constant-tempo grid fitted over the whole track (electronic music is effectively fixed-tempo).
struct BeatGrid: Codable, Equatable, Sendable {
    var bpm: Double
    /// Time of a downbeat (beat 1 of a bar); any bar can be reached from it.
    var downbeat: Double
    var beatsPerBar: Int = 4

    var beatPeriod: Double { 60 / bpm }
    var barPeriod: Double { beatPeriod * Double(beatsPerBar) }

    func time(ofBar bar: Int) -> Double { downbeat + Double(bar) * barPeriod }
    func bar(at time: Double) -> Int { Int(((time - downbeat) / barPeriod).rounded(.down)) }
    func nearestBarTime(to time: Double) -> Double { self.time(ofBar: Int(((time - downbeat) / barPeriod).rounded())) }
    /// 1-based bar number as DJs count it (bar 1 starts at the first downbeat at or after 0 s).
    func displayBar(at time: Double) -> Int {
        let firstBar = Int((-downbeat / barPeriod).rounded(.up))
        return bar(at: time + 0.001) - firstBar + 1
    }
}

struct CueAnalysis: Codable, Equatable, Sendable {
    var grid: BeatGrid?
    var cues: [Cue]
    /// Why the detector withheld its cues (short track, non-dance tempo, no clear sections); nil = shown.
    var skippedReason: String? = nil

    /// Detector result plus the user's manual cues. A manual cue wins over a detected one within half a bar.
    func merging(manual: [Cue]) -> CueAnalysis {
        let keep = manual.filter(\.isManual)
        guard !keep.isEmpty else { return self }
        let tolerance = (grid?.barPeriod ?? 2) / 2
        let detected = cues.filter { cue in !keep.contains { abs($0.time - cue.time) < tolerance } }
        return CueAnalysis(grid: grid, cues: (detected + keep).sorted { $0.time < $1.time }, skippedReason: skippedReason)
    }
}

/// Cues live in their own small file so the main analysis cache (waveforms) never has to be invalidated
/// when the cue detector changes. Detector-made entries are re-detected when `detectorVersion` bumps;
/// entries the user edited are kept.
actor CueStore {
    static let shared = CueStore()
    static let detectorVersion = 9   // v9: section grammar (one drop per break, outro last)

    private struct Entry: Codable {
        var analysis: CueAnalysis
        var detectorVersion: Int
        var edited: Bool
        var fileSize: UInt64
        var modificationDate: Date
    }

    private var entries: [String: Entry]
    private let fileURL: URL

    init(directory: URL? = nil) {
        let folder = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("mocawave", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        fileURL = folder.appendingPathComponent("cues.json")
        entries = (try? JSONDecoder().decode([String: Entry].self, from: Data(contentsOf: fileURL))) ?? [:]
    }

    /// Stored cues for the file. `isCurrent` is false when they came from an older detector: the caller
    /// re-detects and keeps only the user's manual cues from them.
    func analysis(for url: URL) -> (analysis: CueAnalysis, isCurrent: Bool)? {
        guard let (key, size, date) = Self.identity(of: url), let entry = entries[key],
              entry.fileSize == size, entry.modificationDate == date else { return nil }
        return (entry.analysis, entry.detectorVersion == Self.detectorVersion)
    }

    func store(_ analysis: CueAnalysis, edited: Bool, for url: URL) {
        guard let (key, size, date) = Self.identity(of: url) else { return }
        entries[key] = Entry(analysis: analysis, detectorVersion: Self.detectorVersion,
                             edited: edited || (entries[key]?.edited ?? false), fileSize: size, modificationDate: date)
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    private static func identity(of url: URL) -> (String, UInt64, Date)? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? UInt64, let date = attrs[.modificationDate] as? Date else { return nil }
        let digest = SHA256.hash(data: Data(url.path.utf8))
        return (digest.map { String(format: "%02x", $0) }.joined(), size, date)
    }
}
