import AVFoundation
import XCTest
@testable import Mocawave

final class StemTests: XCTestCase {
    /// The agent's ready envelope, shaped like docs/stems-contract.md (snake_case all the way down).
    static let readyEnvelope = #"""
{"status":"ready","key":"0123456789abcdef","manifest":{"version":1,"model":"BS-Roformer-SW.ckpt",
"source":{"path":"/x/01. Next to Me.mp3","size":12582912,"duration":314.4359},"sample_rate":44100,
"created":"2026-11-17T12:00:00Z","stems":[{"name":"vocals","file":"vocals.flac","bytes":27000000,"rms_db":-19.5},
{"name":"guitar","file":"guitar.flac","bytes":686218,"rms_db":-64.5}]}}
"""#

    func testDecodesAgentEnvelopes() {
        guard case .ready(let key, let manifest) = StemClient.decode(Data(Self.readyEnvelope.utf8)) else {
            return XCTFail("expected ready")
        }
        XCTAssertEqual(key, "0123456789abcdef")
        XCTAssertEqual(manifest.modelName, "BS-Roformer")
        XCTAssertEqual(manifest.sampleRate, 44100)
        XCTAssertEqual(manifest.source.duration ?? 0, 314.4359, accuracy: 1e-6)
        XCTAssertEqual(manifest.stems.first?.rmsDb ?? 0, -19.5, accuracy: 1e-9)

        let running = #"{"status":"running","key":"k","position":0,"progress":0.42,"eta":80,"stage":"separating"}"#
        XCTAssertEqual(StemClient.decode(Data(running.utf8)), .state(.separating(progress: 0.42, eta: 80, stage: "separating")))
        let queued = #"{"status":"queued","key":"k","position":2,"progress":0,"eta":null,"stage":null}"#
        XCTAssertEqual(StemClient.decode(Data(queued.utf8)), .state(.queued(position: 2)))
        XCTAssertEqual(StemClient.decode(Data(#"{"status":"unknown"}"#.utf8)), .state(.idle))
        XCTAssertEqual(StemClient.decode(Data(#"{"status":"error","key":"k","error":"boom"}"#.utf8)), .state(.failed("boom")))
        XCTAssertEqual(StemClient.decode(Data("<html>".utf8)), .state(.failed("unreadable response")))
    }

    func testManifestRoundTripsInContractCase() throws {
        let manifest = StemManifest(version: 1, model: "htdemucs_6s", source: .init(path: "/a.mp3", size: 1, duration: 2),
                                    sampleRate: 44100, created: nil,
                                    stems: [.init(name: "bass", file: "bass.flac", bytes: 3, rmsDb: -20)])
        let json = String(decoding: try StemManifest.encoder.encode(manifest), as: UTF8.self)
        XCTAssertTrue(json.contains("\"rms_db\""))
        XCTAssertTrue(json.contains("\"sample_rate\""))
        XCTAssertEqual(try StemManifest.decoder.decode(StemManifest.self, from: Data(json.utf8)), manifest)
        XCTAssertEqual(manifest.modelName, "Demucs 6s")
    }

    func testLaneGainMuteAndSolo() {
        var vocals = StemLane(kind: .vocals, peaks: [], rmsDb: -19.5)
        var drums = StemLane(kind: .drums, peaks: [], rmsDb: -16.6)
        vocals.volume = 1.2
        XCTAssertEqual(vocals.gain(anySolo: false), 1.2, accuracy: 1e-6)
        drums.isSoloed = true
        XCTAssertEqual(vocals.gain(anySolo: true), 0)          // someone else soloed
        XCTAssertEqual(drums.gain(anySolo: true), 1)
        drums.isMuted = true
        XCTAssertEqual(drums.gain(anySolo: true), 0)           // mute wins over solo
        XCTAssertFalse(vocals.isNearlySilent)
        XCTAssertTrue(StemLane(kind: .guitar, peaks: [], rmsDb: -64.5).isNearlySilent)
        XCTAssertFalse(StemLane(kind: .other, peaks: [], rmsDb: nil).isNearlySilent)   // unknown: show it
    }

    @MainActor
    func testExclusiveSoloAndReset() {
        let model = AudioPlayerViewModel(userDefaults: UserDefaults(suiteName: "StemTests-\(UUID())")!)
        model.stemLanes = StemKind.allCases.map { StemLane(kind: $0, peaks: [], rmsDb: -20) }
        model.toggleStemSolo(.vocals)
        model.toggleStemSolo(.drums)
        XCTAssertEqual(model.stemLanes.filter(\.isSoloed).map(\.kind), [.vocals, .drums])
        model.toggleStemSolo(.bass, exclusive: true)
        XCTAssertEqual(model.stemLanes.filter(\.isSoloed).map(\.kind), [.bass])
        model.toggleStemSolo(.bass, exclusive: true)            // ⌥-click again: nothing soloed
        XCTAssertTrue(model.stemLanes.allSatisfy { !$0.isSoloed })
        model.setStemVolume(.piano, 9)
        XCTAssertEqual(model.stemLanes.first { $0.kind == .piano }?.volume, 1.5)
        model.toggleStemMute(.other)
        XCTAssertTrue(model.isStemMixDirty)
        model.resetStemMix()
        XCTAssertFalse(model.isStemMixDirty)
    }

    func testDrawerFormatting() {
        XCTAssertEqual(StemLane.dbText(1), "0.0")
        XCTAssertEqual(StemLane.dbText(0), "−∞")
        XCTAssertEqual(StemLane.dbText(1.5), "+3.5")
        XCTAssertEqual(StemLane.dbText(0.5), "−6.0")
        XCTAssertEqual(StemsState.separating(progress: 0.42, eta: 80, stage: "separating").etaText, "~1:20 left")
        XCTAssertNil(StemsState.separating(progress: 0.01, eta: nil, stage: "loading").etaText)
        XCTAssertEqual(StemsState.separating(progress: 0, eta: nil, stage: "loading").stageLabel, "Loading model")
        // The bar never runs backwards from separating into saving.
        let end = StemsState.separating(progress: 1, eta: 0, stage: "writing").displayProgress ?? 0
        let saving = StemsState.downloading(progress: 0).displayProgress ?? 0
        XCTAssertLessThanOrEqual(end, saving)
    }

    func testPanelHeightFollowsLanes() {
        let lanes = StemKind.allCases.map { StemLane(kind: $0, peaks: [], rmsDb: $0 == .guitar ? -64.5 : -20) }
        let ready = StemLanesView.contentHeight(state: .ready, lanes: lanes)
        XCTAssertEqual(ready, 5 * StemLaneMetrics.laneHeight + StemLaneMetrics.collapsedHeight + 5 * StemLaneMetrics.spacing)
        let working = StemLanesView.contentHeight(state: .separating(progress: 0.5, eta: nil, stage: "separating"), lanes: [])
        XCTAssertGreaterThan(working, ready)
        XCTAssertEqual(StemLanesView.contentHeight(state: .idle, lanes: []), StemLaneMetrics.messageHeight)
        XCTAssertEqual(InspectorDrawer.allCases.first, .stems)                         // stacks above Camelot
        XCTAssertEqual(InspectorDrawer.extraHeight(for: [.stems], stemsHeight: 100), 100 + InspectorDrawer.bottomInset)
    }

    // MARK: Store

    /// A short stereo WAV with a constant-amplitude sine (peak = `amplitude`).
    static func writeTone(_ url: URL, seconds: Double = 1, amplitude: Float, rate: Double = 44_100) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2,
                                       AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let frames = AVAudioFrameCount(seconds * rate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for c in 0..<2 {
            for i in 0..<Int(frames) { buffer.floatChannelData![c][i] = amplitude * sin(Float(i) * 0.05) }
        }
        try file.write(from: buffer)
    }

    /// Stages a two-stem set for `source` the way StemClient does (files + manifest) and installs it.
    static func install(_ store: StemStore, for source: URL, loud: Float = 0.8, quiet: Float = 0.2) async throws -> StemSet {
        let staging = try await store.makeStaging()
        try writeTone(staging.appendingPathComponent("drums.wav"), amplitude: loud)
        try writeTone(staging.appendingPathComponent("vocals.wav"), amplitude: quiet)
        let manifest = StemManifest(version: 1, model: "BS-Roformer-SW.ckpt", source: .init(path: source.path, size: nil, duration: 1),
                                    sampleRate: 44_100, created: nil,
                                    stems: [.init(name: "vocals", file: "vocals.wav", bytes: nil, rmsDb: -17),
                                            .init(name: "drums", file: "drums.wav", bytes: nil, rmsDb: -5)])
        try StemManifest.encoder.encode(manifest).write(to: staging.appendingPathComponent("manifest.json"))
        return try await store.install(staging: staging, for: source)
    }

    static func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("StemTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testInstallCachedAndPeaks() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("track.mp3")
        try Data(repeating: 7, count: 10_000).write(to: source)
        let store = StemStore(root: dir.appendingPathComponent("stems"))

        let installed = try await Self.install(store, for: source)
        XCTAssertEqual(installed.files.map(\.kind), [.vocals, .drums])     // lane order, not manifest order
        let cached = await store.cached(for: source)
        XCTAssertEqual(cached, installed)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: store.root.path).filter { $0.hasPrefix(".staging") }
        XCTAssertEqual(leftovers, [])

        let peaks = await store.peaks(for: installed)
        XCTAssertEqual(peaks[.drums]?.count, StemStore.peakBins)
        XCTAssertEqual(peaks[.drums]?.max() ?? 0, 1, accuracy: 0.01)        // loudest stem tops the shared scale
        let quiet = peaks[.vocals]?.max() ?? 0
        XCTAssertEqual(quiet, pow(0.25, 0.7), accuracy: 0.02)              // 0.2 / 0.8, same curve
        XCTAssertTrue(FileManager.default.fileExists(atPath: installed.directory.appendingPathComponent("peaks.json").path))
        let again = await store.peaks(for: installed)
        XCTAssertEqual(again, peaks)

        // A missing stem file makes the entry incomplete (never half-loaded).
        try FileManager.default.removeItem(at: installed.directory.appendingPathComponent("drums.wav"))
        let broken = await store.cached(for: source)
        XCTAssertNil(broken)
    }

    /// Stems that kept a decoder delay (529 frames, like the real MP3 separation) are measured and the
    /// offset cached; aligned stems measure 0.
    func testMeasuresStemOffset() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let rate = 44_100.0, frames = Int(3 * rate), delay = 529
        var seed: UInt32 = 1
        let noise: [Float] = (0..<frames).map { _ in seed = seed &* 1_664_525 &+ 1_013_904_223; return Float(seed >> 8) / Float(1 << 24) - 0.5 }
        func write(_ name: String, _ samples: [Float]) throws -> URL {
            let url = dir.appendingPathComponent(name)
            let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
            let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
                                           AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true]
            let file = try AVAudioFile(forWriting: url, settings: settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
            buffer.frameLength = AVAudioFrameCount(samples.count)
            for i in samples.indices { buffer.floatChannelData![0][i] = samples[i] }
            try file.write(from: buffer)
            return url
        }
        let source = try write("source.wav", noise)
        let late = [Float](repeating: 0, count: delay) + noise.prefix(frames - delay)
        let a = try write("a.wav", late.map { $0 * 0.7 }), b = try write("b.wav", late.map { $0 * 0.3 })
        let measured = StemStore.measureOffset(stems: [a, b], source: source)
        XCTAssertEqual(measured?.lag, delay)
        XCTAssertGreaterThan(measured?.score ?? 0, 0.95)
        XCTAssertEqual(StemStore.measureOffset(stems: [source], source: source)?.lag, 0)
    }

    func testEvictsLeastRecentlyUsed() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sources = (0..<3).map { dir.appendingPathComponent("t\($0).mp3") }
        for (i, s) in sources.enumerated() { try Data(repeating: UInt8(i), count: 100).write(to: s) }
        // One entry ≈ 2 × 353 KB of float WAV: the limit holds two, not three.
        let store = StemStore(root: dir.appendingPathComponent("stems"), byteLimit: 1_600_000)
        _ = try await Self.install(store, for: sources[0])
        try await Task.sleep(nanoseconds: 20_000_000)
        _ = try await Self.install(store, for: sources[1])
        try await Task.sleep(nanoseconds: 20_000_000)
        _ = await store.cached(for: sources[0])                            // touch: t0 is now newer than t1
        try await Task.sleep(nanoseconds: 20_000_000)
        _ = try await Self.install(store, for: sources[2])
        let t0 = await store.cached(for: sources[0])
        let t1 = await store.cached(for: sources[1])
        let t2 = await store.cached(for: sources[2])
        XCTAssertNotNil(t0)
        XCTAssertNil(t1)
        XCTAssertNotNil(t2)
        await store.clear()
        let total = await store.totalBytes()
        XCTAssertEqual(total, 0)
    }
}
