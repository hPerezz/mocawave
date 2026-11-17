import AVFoundation
import Foundation

/// Real-time follower of the low end (kick + bass, ≲150 Hz) of what is actually playing, fed by the mixer
/// tap. Used to *confirm* a drop as it happens instead of trusting a precomputed cue time.
///
/// Thread-safe: `process` runs on the audio tap thread, `rise()` / `reset()` on the main actor.
final class LowEndListener {
    private let lock = NSLock()
    private let alpha: Float
    private let blockSize: Int
    private var stage1: Float = 0
    private var stage2: Float = 0
    private var accumulator: Double = 0
    private var accumulated = 0
    /// Low-end level per 50 ms block, in dB, newest last (4 s kept).
    private var blocks: [Float] = []

    static let blockSeconds = 0.05
    private static let keptBlocks = 80

    init(sampleRate: Double) {
        // Two cascaded one-pole low-passes at ~150 Hz.
        alpha = Float(1 - exp(-2 * Double.pi * 150 / sampleRate))
        blockSize = max(1, Int(sampleRate * Self.blockSeconds))
    }

    func process(buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard frames > 0, channels > 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        for i in 0..<frames {
            var x: Float = 0
            for c in 0..<channels { x += data[c][i] }
            x /= Float(channels)
            stage1 += alpha * (x - stage1)
            stage2 += alpha * (stage1 - stage2)
            accumulator += Double(stage2 * stage2)
            accumulated += 1
            if accumulated == blockSize {
                blocks.append(Float(10 * log10(accumulator / Double(accumulated) + 1e-12)))
                if blocks.count > Self.keptBlocks { blocks.removeFirst(blocks.count - Self.keptBlocks) }
                accumulator = 0
                accumulated = 0
            }
        }
    }

    /// How much the low end of the last 0.3 s rose over the 2 s before it (dB, power means).
    /// nil until 2.3 s of audio has been heard since the last reset.
    func rise() -> Float? {
        lock.lock()
        defer { lock.unlock() }
        let recent = 6, history = 40
        guard blocks.count >= recent + history else { return nil }
        func powerMeanDB(_ slice: ArraySlice<Float>) -> Float {
            let mean = slice.reduce(0) { $0 + pow(10, $1 / 10) } / Float(slice.count)
            return 10 * log10(mean + 1e-12)
        }
        let now = powerMeanDB(blocks.suffix(recent))
        let before = powerMeanDB(blocks.dropLast(recent).suffix(history))
        return now - before
    }

    /// Forget the history (after a seek, so a jump in position is not mistaken for a drop).
    func reset() {
        lock.lock()
        blocks.removeAll()
        accumulator = 0
        accumulated = 0
        lock.unlock()
    }
}
