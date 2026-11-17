import AVFoundation
import XCTest
@testable import Mocawave

final class CueTests: XCTestCase {
    func testBeatGridMath() {
        let grid = BeatGrid(bpm: 120, downbeat: 0.5)   // 2 s bars
        XCTAssertEqual(grid.barPeriod, 2, accuracy: 1e-9)
        XCTAssertEqual(grid.time(ofBar: 3), 6.5, accuracy: 1e-9)
        XCTAssertEqual(grid.bar(at: 6.4), 2)
        XCTAssertEqual(grid.nearestBarTime(to: 7.4), 6.5, accuracy: 1e-9)
        XCTAssertEqual(grid.nearestBarTime(to: 7.6), 8.5, accuracy: 1e-9)
        XCTAssertEqual(grid.displayBar(at: 0.5), 1)
        XCTAssertEqual(grid.displayBar(at: 6.5), 4)
    }

    func testShortcutsAvoidCamelotKey() {
        XCTAssertEqual(CueKind.forShortcut("d"), .drop)
        XCTAssertEqual(CueKind.forShortcut("R"), .breakdown)
        XCTAssertNil(CueKind.forShortcut("k"))   // K opens the Camelot wheel
        XCTAssertNil(CueKind.forShortcut("s"))   // S toggles the spectrogram
    }

    func testStoreRoundTripAndEditedFlag() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let audio = dir.appendingPathComponent("a.wav")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data([0, 1, 2]).write(to: audio)
        let store = CueStore(directory: dir)
        let analysis = CueAnalysis(grid: BeatGrid(bpm: 124, downbeat: 0.1), cues: [Cue(kind: .drop, time: 60, confidence: 0.8)])
        await store.store(analysis, edited: true, for: audio)
        let reloaded = CueStore(directory: dir)
        let fetched = await reloaded.analysis(for: audio)
        XCTAssertEqual(fetched?.analysis, analysis)
        XCTAssertEqual(fetched?.isCurrent, true)
    }

    /// 128 BPM: kick + bass on every beat, hats on off-beats. Bars 32–47 drop kick and bass (break with
    /// rising hats from bar 40), the low end returns on bar 48 (drop). Grid starts at 0.25 s.
    func testDetectsBreakAndDropOnSyntheticTrack() throws {
        let rate = 22_050.0, bpm = 128.0, offset = 0.25, bars = 112   // 3:30+ so the structure gate passes
        let beat = 60 / bpm
        let total = Int((offset + Double(bars * 4) * beat + 1) * rate)
        var samples = [Float](repeating: 0, count: total)
        var seed: UInt32 = 7
        func noise() -> Float { seed = seed &* 1_664_525 &+ 1_013_904_223; return Float(seed >> 8) / Float(1 << 24) * 2 - 1 }
        for b in 0..<(bars * 4) {
            let bar = b / 4
            let start = Int((offset + Double(b) * beat) * rate)
            let inBreak = (32..<48).contains(bar)
            if !inBreak {
                for i in 0..<Int(0.12 * rate) where start + i < total {   // kick: 55 Hz decaying sine
                    let t = Double(i) / rate
                    samples[start + i] += Float(sin(2 * .pi * 55 * t) * exp(-t * 25)) * 0.9
                }
                for i in 0..<Int(beat * rate) where start + i < total {   // bass: 45 Hz
                    samples[start + i] += Float(sin(2 * .pi * 45 * Double(start + i) / rate)) * 0.25
                }
            }
            let hatLevel: Float = inBreak ? (bar >= 40 ? 0.05 + 0.02 * Float(bar - 40) : 0.04) : 0.08
            let hat = start + Int(beat / 2 * rate)
            for i in 0..<Int(0.03 * rate) where hat + i < total { samples[hat + i] += noise() * hatLevel }
            for i in 0..<Int(beat * rate) where start + i < total {          // pad keeps the break audible
                samples[start + i] += Float(sin(2 * .pi * 440 * Double(start + i) / rate)) * 0.05
            }
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("synthetic-\(UUID().uuidString).wav")
        try Self.writeWAV(samples, rate: rate, to: url)   // writer must be closed before reading

        let analysis = try CueDetector.analyze(url: url, bpmHint: 128)
        let grid = try XCTUnwrap(analysis.grid)
        XCTAssertEqual(grid.bpm, 128, accuracy: 0.05)
        let barTime = { (bar: Int) in offset + Double(bar * 4) * beat }
        let drop = try XCTUnwrap(analysis.cues.first { $0.kind == .drop })
        let brk = try XCTUnwrap(analysis.cues.first { $0.kind == .breakdown })
        XCTAssertEqual(drop.time, barTime(48), accuracy: 0.1)
        XCTAssertEqual(brk.time, barTime(32), accuracy: 0.1)
        XCTAssertFalse(drop.isSuggestion)
        XCTAssertEqual(analysis.cues.first?.kind, .intro)
        XCTAssertNil(analysis.skippedReason)
    }

    func testStructureGate() {
        let grid = BeatGrid(bpm: 124, downbeat: 0)
        let confident = [Cue(kind: .drop, time: 60, confidence: 0.8)]
        XCTAssertNil(CueDetector.structureGate(cues: confident, grid: grid, duration: 300))
        XCTAssertNotNil(CueDetector.structureGate(cues: confident, grid: grid, duration: 184))            // 3:04 song
        XCTAssertNotNil(CueDetector.structureGate(cues: confident, grid: BeatGrid(bpm: 68, downbeat: 0), duration: 300))
        XCTAssertNotNil(CueDetector.structureGate(cues: [Cue(kind: .drop, time: 60, confidence: 0.4)], grid: grid, duration: 300))
    }

    private static func writeWAV(_ samples: [Float], rate: Double, to url: URL) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        try file.write(from: buffer)
    }
}
