import Foundation
import XCTest
@testable import Mocawave

final class MocawaveTests: XCTestCase {
    private final class ConcurrencyTracker: @unchecked Sendable {
        private let lock = NSLock()
        private var activeCount = 0
        private var peakCount = 0
        private var callCount = 0
        private var events: [String] = []

        func start(_ name: String) {
            lock.lock()
            callCount += 1
            activeCount += 1
            peakCount = max(peakCount, activeCount)
            events.append("start-\(name)")
            lock.unlock()
        }

        func finish(_ name: String) {
            lock.lock()
            activeCount = max(0, activeCount - 1)
            events.append("finish-\(name)")
            lock.unlock()
        }

        func snapshot() -> (callCount: Int, peakCount: Int, events: [String]) {
            lock.lock()
            defer { lock.unlock() }
            return (callCount, peakCount, events)
        }
    }

    private static func makeURL(_ name: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(name)
    }

    private static var dummyColoredWaveform: WaveformAnalyzer.ColoredWaveformData {
        WaveformAnalyzer.ColoredWaveformData(
            columns: [.init(height: 0.5, red: 1, green: 0.25, blue: 0.1)]
        )
    }

    private static var dummyQuality: (WaveformAnalyzer.AudioQualityResult, WaveformAnalyzer.QualityDebugInfo) {
        (
            WaveformAnalyzer.AudioQualityResult(
                maxEffectiveFrequency: 18_000,
                highFreqEnergyRatio: 0.22,
                cutoffSharpness: 3.5,
                estimatedBitrate: .kbps320
            ),
            WaveformAnalyzer.QualityDebugInfo(
                medianRel16k: -12,
                medianRel17k: -18,
                medianRel18k: -22,
                medianRel19k: -28,
                medianRel20k: -33,
                totalFrames: 24
            )
        )
    }

    func testWaveformRequestsForSameURLAreDeduplicated() async throws {
        let tracker = ConcurrencyTracker()
        let coordinator = WaveformAnalysisCoordinator(
            waveformOperation: { _, _ in
                tracker.start("waveform")
                defer { tracker.finish("waveform") }
                Thread.sleep(forTimeInterval: 0.05)
                return [0.25, 0.5, 0.75]
            },
            coloredWaveformOperation: { _, _ in Self.dummyColoredWaveform },
            spectrogramOperation: { _, _, _ in [[0.1, 0.2]] },
            qualityOperation: { _ in Self.dummyQuality }
        )

        let url = Self.makeURL("dedupe.wav")
        async let first = coordinator.waveform(url: url, targetSamples: 64)
        async let second = coordinator.waveform(url: url, targetSamples: 64)
        let (firstResult, secondResult) = try await (first, second)

        XCTAssertEqual(firstResult, secondResult)
        XCTAssertEqual(tracker.snapshot().callCount, 1)
    }

    func testWaveformFamilyRequestsSerializeForSameURL() async throws {
        let tracker = ConcurrencyTracker()
        let coordinator = WaveformAnalysisCoordinator(
            waveformOperation: { _, _ in
                tracker.start("waveform")
                defer { tracker.finish("waveform") }
                Thread.sleep(forTimeInterval: 0.05)
                return [0.1]
            },
            coloredWaveformOperation: { _, _ in
                tracker.start("colored")
                defer { tracker.finish("colored") }
                Thread.sleep(forTimeInterval: 0.01)
                return Self.dummyColoredWaveform
            },
            spectrogramOperation: { _, _, _ in [[0.1, 0.2]] },
            qualityOperation: { _ in Self.dummyQuality }
        )

        let url = Self.makeURL("serialized.wav")
        async let waveform = coordinator.waveform(url: url, targetSamples: 32)
        async let colored = coordinator.coloredWaveform(url: url, targetColumns: 32)
        _ = try await (waveform, colored)

        let snapshot = tracker.snapshot()
        XCTAssertEqual(snapshot.peakCount, 1)
        XCTAssertTrue(
            snapshot.events == ["start-waveform", "finish-waveform", "start-colored", "finish-colored"] ||
            snapshot.events == ["start-colored", "finish-colored", "start-waveform", "finish-waveform"],
            "Expected serialized waveform-family execution, got \(snapshot.events)"
        )
    }

    func testCancelAllStopsQueuedWaveformFamilyWorkForURL() async throws {
        let tracker = ConcurrencyTracker()
        let coordinator = WaveformAnalysisCoordinator(
            waveformOperation: { _, _ in
                tracker.start("waveform")
                defer { tracker.finish("waveform") }
                for _ in 0..<100 {
                    if Task.isCancelled {
                        throw CancellationError()
                    }
                    Thread.sleep(forTimeInterval: 0.005)
                }
                return [0.2]
            },
            coloredWaveformOperation: { _, _ in
                tracker.start("colored")
                defer { tracker.finish("colored") }
                return Self.dummyColoredWaveform
            },
            spectrogramOperation: { _, _, _ in [[0.3]] },
            qualityOperation: { _ in Self.dummyQuality }
        )

        let url = Self.makeURL("cancel.wav")
        let waveformTask = Task {
            try await coordinator.waveform(url: url, targetSamples: 16)
        }
        let coloredTask = Task {
            try await coordinator.coloredWaveform(url: url, targetColumns: 16)
        }

        try await Task.sleep(nanoseconds: 50_000_000)
        await coordinator.cancelAll(for: url)

        do {
            _ = try await waveformTask.value
            XCTFail("Expected waveform task to be cancelled")
        } catch is CancellationError {
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }

        do {
            _ = try await coloredTask.value
            XCTFail("Expected colored waveform task to be cancelled")
        } catch is CancellationError {
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }

        XCTAssertFalse(tracker.snapshot().events.contains("start-colored"))
    }
}
