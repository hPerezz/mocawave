import Accelerate
import AVFoundation
import Foundation

/// Thread-safe real-time LUFS and peak amplitude meter.
/// Processes AVAudioPCMBuffer from an audio engine tap.
/// Implements ITU-R BS.1770-4 K-weighting and short-term (3s) LUFS.
final class LUFSMeter {
    private let lock = NSLock()
    private let computeLUFS: Bool

    // K-weighting biquad filter states (per channel)
    private var preFilterStates: [[Double]]  // [channel][2]
    private var rlbFilterStates: [[Double]]  // [channel][2]

    // K-weighting coefficients
    private let preB: [Double]  // high-shelf pre-filter b0, b1, b2
    private let preA: [Double]  // high-shelf pre-filter a1, a2
    private let rlbB: [Double]  // RLB high-pass b0, b1, b2
    private let rlbA: [Double]  // RLB high-pass a1, a2

    // Sliding window for short-term LUFS (3 seconds of 100ms blocks)
    private let blockDurationSeconds: Double = 0.1
    private let windowBlocks: Int = 30  // 3s / 0.1s
    private var meanSquareBlocks: [Double] = []  // circular buffer of per-block mean squares
    private var blockAccumulator: Double = 0
    private var blockSampleCount: Int = 0
    private let blockSize: Int  // samples per 100ms block

    private let channelCount: Int

    // Published values (read from main thread via lock)
    private var _shortTermLUFS: Float?
    private var _peakAmplitudeDB: Float?

    var shortTermLUFS: Float? {
        lock.lock()
        defer { lock.unlock() }
        return _shortTermLUFS
    }

    var peakAmplitudeDB: Float? {
        lock.lock()
        defer { lock.unlock() }
        return _peakAmplitudeDB
    }

    init(sampleRate: Double, channelCount: Int, computeLUFS: Bool = true) {
        self.computeLUFS = computeLUFS
        self.channelCount = max(channelCount, 1)
        self.blockSize = Int(sampleRate * blockDurationSeconds)

        // Compute K-weighting filter coefficients for the given sample rate
        // Stage 1: High-shelf pre-filter (boost ~+4dB above 1.5kHz)
        let (pB, pA) = LUFSMeter.preFilterCoefficients(sampleRate: sampleRate)
        self.preB = pB
        self.preA = pA

        // Stage 2: RLB high-pass filter (roll off below ~60Hz)
        let (rB, rA) = LUFSMeter.rlbFilterCoefficients(sampleRate: sampleRate)
        self.rlbB = rB
        self.rlbA = rA

        self.preFilterStates = Array(repeating: [0.0, 0.0], count: self.channelCount)
        self.rlbFilterStates = Array(repeating: [0.0, 0.0], count: self.channelCount)
    }

    /// Process a buffer from an audio engine tap.
    func process(buffer: AVAudioPCMBuffer) {
        guard let floatData = buffer.floatChannelData else { return }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return }

        let channels = min(Int(buffer.format.channelCount), channelCount)

        // Find peak amplitude across all channels
        var peak: Float = 0
        for ch in 0..<channels {
            let data = floatData[ch]
            var chPeak: Float = 0
            // Use vDSP to find max absolute value
            let length = vDSP_Length(frameCount)
            vDSP_maxmgv(data, 1, &chPeak, length)
            if chPeak > peak { peak = chPeak }
        }

        let peakDB: Float = peak > 0 ? 20.0 * log10f(peak) : -Float.infinity

        guard computeLUFS else {
            lock.lock()
            _peakAmplitudeDB = peakDB
            lock.unlock()
            return
        }

        // Apply K-weighting and accumulate mean square for LUFS
        // Process sample-by-sample to maintain filter state
        var newLUFS: Float? = nil

        for i in 0..<frameCount {
            var channelMeanSquare: Double = 0

            for ch in 0..<channels {
                let sample = Double(floatData[ch][i])

                // Stage 1: Pre-filter (high-shelf)
                let preOut = applyBiquad(
                    sample: sample,
                    b: preB, a: preA,
                    state: &preFilterStates[ch]
                )

                // Stage 2: RLB high-pass
                let kWeighted = applyBiquad(
                    sample: preOut,
                    b: rlbB, a: rlbA,
                    state: &rlbFilterStates[ch]
                )

                channelMeanSquare += kWeighted * kWeighted
            }

            // Average across channels (BS.1770 uses sum with channel weights,
            // but for stereo L/R both have weight 1.0, so average = sum/channels)
            channelMeanSquare /= Double(channels)

            blockAccumulator += channelMeanSquare
            blockSampleCount += 1

            if blockSampleCount >= blockSize {
                let blockMeanSquare = blockAccumulator / Double(blockSampleCount)
                meanSquareBlocks.append(blockMeanSquare)
                if meanSquareBlocks.count > windowBlocks {
                    meanSquareBlocks.removeFirst(meanSquareBlocks.count - windowBlocks)
                }

                blockAccumulator = 0
                blockSampleCount = 0

                // Compute short-term LUFS from sliding window
                if !meanSquareBlocks.isEmpty {
                    let sum = meanSquareBlocks.reduce(0, +)
                    let mean = sum / Double(meanSquareBlocks.count)
                    if mean > 0 {
                        newLUFS = Float(-0.691 + 10.0 * log10(mean))
                    }
                }
            }
        }

        lock.lock()
        _peakAmplitudeDB = peakDB
        if let lufs = newLUFS {
            _shortTermLUFS = lufs
        }
        lock.unlock()
    }

    func reset() {
        lock.lock()
        _shortTermLUFS = nil
        _peakAmplitudeDB = nil
        if computeLUFS {
            meanSquareBlocks.removeAll()
            blockAccumulator = 0
            blockSampleCount = 0
            for ch in 0..<channelCount {
                preFilterStates[ch] = [0.0, 0.0]
                rlbFilterStates[ch] = [0.0, 0.0]
            }
        }
        lock.unlock()
    }

    // MARK: - Biquad Filter

    /// Direct Form I biquad: y[n] = b0*x[n] + b1*x[n-1] + b2*x[n-2] - a1*y[n-1] - a2*y[n-2]
    /// state[0] = x[n-1], state[1] = x[n-2] (input delays)
    /// We use transposed Direct Form II for efficiency.
    private func applyBiquad(sample: Double, b: [Double], a: [Double], state: inout [Double]) -> Double {
        // Transposed Direct Form II:
        // y[n] = b0*x[n] + s0
        // s0 = b1*x[n] - a1*y[n] + s1
        // s1 = b2*x[n] - a2*y[n]
        let y = b[0] * sample + state[0]
        state[0] = b[1] * sample - a[0] * y + state[1]
        state[1] = b[2] * sample - a[1] * y
        return y
    }

    // MARK: - ITU-R BS.1770-4 K-Weighting Coefficients

    /// Stage 1: High-shelf pre-filter.
    /// Attempt to model the head/acoustic response (+4dB shelf above ~1.5kHz).
    private static func preFilterCoefficients(sampleRate: Double) -> (b: [Double], a: [Double]) {
        // Coefficients from ITU-R BS.1770-4 Table 1
        // These are specified for 48kHz; we use bilinear transform pre-warping for other rates.
        if abs(sampleRate - 48000.0) < 1.0 {
            // Exact 48kHz coefficients from the standard
            let b0 = 1.53512485958697
            let b1 = -2.69169618940638
            let b2 = 1.19839281085285
            let a1 = -1.69065929318241
            let a2 = 0.73248077421585
            return ([b0, b1, b2], [a1, a2])
        }

        // For other sample rates, compute via analog prototype + bilinear transform
        let db = 3.999843853973347
        let f0 = 1681.974450955533
        let Q = 0.7071752369554196

        let K = tan(.pi * f0 / sampleRate)
        let Vh = pow(10.0, db / 20.0)
        let Vb = pow(Vh, 0.4996667741545416)

        let a0_ = 1.0 + K / Q + K * K
        let b0 = (Vh + Vb * K / Q + K * K) / a0_
        let b1 = 2.0 * (K * K - Vh) / a0_
        let b2 = (Vh - Vb * K / Q + K * K) / a0_
        let a1 = 2.0 * (K * K - 1.0) / a0_
        let a2 = (1.0 - K / Q + K * K) / a0_

        return ([b0, b1, b2], [a1, a2])
    }

    /// Stage 2: Revised Low-Band (RLB) high-pass filter.
    /// Removes content below ~60Hz.
    private static func rlbFilterCoefficients(sampleRate: Double) -> (b: [Double], a: [Double]) {
        if abs(sampleRate - 48000.0) < 1.0 {
            // Exact 48kHz coefficients from the standard
            let b0 = 1.0
            let b1 = -2.0
            let b2 = 1.0
            let a1 = -1.99004745483398
            let a2 = 0.99007225036621
            return ([b0, b1, b2], [a1, a2])
        }

        // Second-order high-pass Butterworth at ~38.1Hz
        let f0 = 38.13547087602444
        let Q = 0.5003270373238773
        let K = tan(.pi * f0 / sampleRate)

        let a0_ = 1.0 + K / Q + K * K
        let b0 = 1.0 / a0_
        let b1 = -2.0 / a0_
        let b2 = 1.0 / a0_
        let a1 = 2.0 * (K * K - 1.0) / a0_
        let a2 = (1.0 - K / Q + K * K) / a0_

        return ([b0, b1, b2], [a1, a2])
    }
}
