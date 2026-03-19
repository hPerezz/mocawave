import Accelerate
import AVFoundation

/// High-precision BPM analyzer implementing techniques from:
/// - Percival & Tzanetakis (2014): "Streamlined Tempo Estimation Based on
///   Autocorrelation and Cross-correlation With Pulses" (STEM algorithm)
/// - Ellis (2007): Perceptual tempo weighting with Rayleigh distribution
/// - Multi-band onset strength signal with log-magnitude spectral flux
///
/// Key improvements over naive approaches:
/// 1. Onset Strength Signal (OSS) via log-magnitude spectral flux across 8 bands
/// 2. Generalized autocorrelation: IFFT(|FFT(x)|^exponent) with exponent=0.5
/// 3. Harmonic enhancement of autocorrelation (adds energy at 2x and 4x multiples)
/// 4. Pulse train cross-correlation for candidate scoring (not just peak picking)
/// 5. Perceptual tempo weighting (Rayleigh distribution centered at ~120 BPM)
/// 6. Overlapping frame analysis with Gaussian accumulation
/// 7. Octave-error correction via doubling heuristic
enum BPMAnalyzer2 {

    enum BPMError: Error {
        case invalidAudio
        case analysisUnavailable
    }

    // MARK: - Configuration

    private static let minBPM: Float = 50
    private static let maxBPM: Float = 220

    /// Analysis window in seconds (longer = more stable for constant-tempo tracks)
    private static let analysisWindowSeconds: Double = 30

    /// FFT parameters for OSS computation
    private static let stftWindowSize: Int = 1024
    private static let stftHopSize: Int = 128

    /// OSS sample rate = audioSampleRate / stftHopSize (computed dynamically)
    /// For 44100 Hz audio: 44100/128 ≈ 344.5 Hz (matches Percival paper)

    /// Autocorrelation frame parameters (in OSS samples)
    private static let acfFrameSize: Int = 2048
    private static let acfHopSize: Int = 128

    /// Generalized autocorrelation exponent (0.5 per Percival; 2.0 = standard)
    private static let gacExponent: Float = 0.5

    /// Number of frequency sub-bands for onset computation
    private static let numBands: Int = 8

    /// Perceptual weighting: Rayleigh distribution peak in seconds
    private static let rayleighPeakBPM: Float = 120.0
    private static let rayleighSigmaOctaves: Float = 1.4

    /// Number of tempo candidates to extract from autocorrelation peaks
    private static let numTempoCandidates: Int = 10

    /// Gaussian width for accumulator (in BPM)
    private static let accumulatorGaussianWidth: Float = 5.0

    // MARK: - Public API

    static func analyze(url: URL, logger: ((String) -> Void)? = nil) throws -> Int {
        logger?("Opening audio file...")
        let audioFile = try AVAudioFile(forReading: url)
        let format = audioFile.processingFormat
        let sampleRate = Float(format.sampleRate)
        guard sampleRate > 0 else { throw BPMError.invalidAudio }
        logger?("Sample rate: \(sampleRate) Hz")

        // --- Read audio into mono float buffer ---
        let totalFrames = AVAudioFrameCount(audioFile.length)
        let maxFrames = AVAudioFrameCount(analysisWindowSeconds * Double(sampleRate))
        let framesToRead = min(totalFrames, maxFrames)
        guard framesToRead > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: framesToRead)
        else { throw BPMError.invalidAudio }

        try audioFile.read(into: buffer, frameCount: framesToRead)
        guard let channelData = buffer.floatChannelData else { throw BPMError.invalidAudio }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > stftWindowSize else { throw BPMError.invalidAudio }

        let channelCount = Int(format.channelCount)

        // Step 1: Mix to mono
        logger?("Converting to mono (\(frameCount) samples)...")
        var mono = [Float](repeating: 0, count: frameCount)
        if channelCount == 1 {
            memcpy(&mono, channelData[0], frameCount * MemoryLayout<Float>.size)
        } else {
            memcpy(&mono, channelData[0], frameCount * MemoryLayout<Float>.size)
            for ch in 1..<channelCount {
                vDSP_vadd(mono, 1, channelData[ch], 1, &mono, 1, vDSP_Length(frameCount))
            }
            var divisor = Float(channelCount)
            vDSP_vsdiv(mono, 1, &divisor, &mono, 1, vDSP_Length(frameCount))
        }

        // Step 2: Compute Onset Strength Signal (OSS)
        logger?("Computing Onset Strength Signal (log-magnitude spectral flux, \(numBands) bands)...")
        let ossSampleRate = sampleRate / Float(stftHopSize)
        let oss = computeOSS(mono, sampleRate: sampleRate, logger: logger)
        guard oss.count > acfFrameSize else {
            logger?("OSS too short for analysis (\(oss.count) samples)")
            throw BPMError.analysisUnavailable
        }
        logger?("OSS: \(oss.count) samples at \(String(format: "%.1f", ossSampleRate)) Hz")

        // Step 3: Low-pass filter the OSS (smooth, matches Percival paper)
        let ossSmoothed = lowPassFilterOSS(oss, cutoffHz: 7.0, sampleRate: ossSampleRate)

        // Step 4: Overlapping frame analysis with generalized autocorrelation
        logger?("Analyzing tempo with generalized autocorrelation + pulse train scoring...")
        let bpmResult = estimateTempo(
            oss: ossSmoothed,
            ossSampleRate: ossSampleRate,
            logger: logger
        )

        logger?("Final BPM: \(bpmResult)")
        return bpmResult
    }

    // MARK: - Onset Strength Signal (OSS) Computation
    //
    // Implements the standard onset detection approach:
    // 1. STFT with Hanning window
    // 2. Log-magnitude spectrum per frame
    // 3. First-order difference (spectral flux) across time
    // 4. Half-wave rectification (keep only increases)
    // 5. Sum across frequency bands (or all bins)
    //
    // Multi-band version: split spectrum into `numBands` logarithmic bands,
    // compute onset strength per band, then sum.

    private static func computeOSS(
        _ samples: [Float],
        sampleRate: Float,
        logger: ((String) -> Void)?
    ) -> [Float] {
        let windowSize = stftWindowSize
        let hopSize = stftHopSize
        let halfFFT = windowSize / 2
        let numFrames = (samples.count - windowSize) / hopSize + 1
        guard numFrames > 2 else { return [] }

        // Setup FFT
        let log2n = vDSP_Length(log2(Double(windowSize)))
        guard let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return [] }
        defer { vDSP_destroy_fftsetup(fftSetup) }

        // Hanning window
        var window = [Float](repeating: 0, count: windowSize)
        vDSP_hann_window(&window, vDSP_Length(windowSize), Int32(vDSP_HANN_NORM))

        // Compute band boundaries (logarithmic spacing from ~20 Hz to Nyquist)
        let nyquist = sampleRate / 2.0
        let minFreq: Float = 30.0
        let bandEdges = computeLogBandEdges(
            numBands: numBands,
            minFreq: minFreq,
            maxFreq: min(nyquist, 16000),
            fftSize: windowSize,
            sampleRate: sampleRate
        )

        // Allocate storage
        var oss = [Float](repeating: 0, count: numFrames)
        var prevLogMag = [[Float]](repeating: [Float](repeating: 0, count: 0), count: numBands)

        // Temporary buffers
        var realp = [Float](repeating: 0, count: halfFFT)
        var imagp = [Float](repeating: 0, count: halfFFT)

        samples.withUnsafeBufferPointer { samplesPtr in
            for frame in 0..<numFrames {
                let startIdx = frame * hopSize
                guard startIdx + windowSize <= samples.count else { break }

                // Apply window
                var windowed = [Float](repeating: 0, count: windowSize)
                vDSP_vmul(samplesPtr.baseAddress! + startIdx, 1,
                          window, 1, &windowed, 1, vDSP_Length(windowSize))

                // Pack into split complex
                var splitComplex = DSPSplitComplex(realp: &realp, imagp: &imagp)
                windowed.withUnsafeBufferPointer { wPtr in
                    vDSP_ctoz(UnsafePointer<DSPComplex>(OpaquePointer(wPtr.baseAddress!)),
                              2, &splitComplex, 1, vDSP_Length(halfFFT))
                }

                // Forward FFT
                vDSP_fft_zrip(fftSetup, &splitComplex, 1, log2n, FFTDirection(FFT_FORWARD))

                // Magnitude spectrum
                var magnitude = [Float](repeating: 0, count: halfFFT)
                vDSP_zvmags(&splitComplex, 1, &magnitude, 1, vDSP_Length(halfFFT))

                // Square root to get actual magnitude (zvmags gives squared magnitude)
                var sqrtMag = [Float](repeating: 0, count: halfFFT)
                var count = Int32(halfFFT)
                vvsqrtf(&sqrtMag, magnitude, &count)

                // Log-magnitude (add small epsilon to avoid log(0))
                var logMag = [Float](repeating: 0, count: halfFFT)
                var epsilon: Float = 1e-10
                vDSP_vsadd(sqrtMag, 1, &epsilon, &logMag, 1, vDSP_Length(halfFFT))
                count = Int32(halfFFT)
                vvlog10f(&logMag, logMag, &count)

                // Compute onset strength per band
                var frameOnsetStrength: Float = 0.0

                for band in 0..<numBands {
                    let binStart = bandEdges[band]
                    let binEnd = bandEdges[band + 1]
                    let bandSize = binEnd - binStart
                    guard bandSize > 0 else { continue }

                    // Extract band log-magnitudes
                    let bandLogMag = Array(logMag[binStart..<binEnd])

                    if frame > 0 && prevLogMag[band].count == bandSize {
                        // Spectral flux: sum of positive differences in log-magnitude
                        var flux: Float = 0
                        for i in 0..<bandSize {
                            let diff = bandLogMag[i] - prevLogMag[band][i]
                            if diff > 0 {
                                flux += diff
                            }
                        }
                        frameOnsetStrength += flux
                    }

                    prevLogMag[band] = bandLogMag
                }

                oss[frame] = frameOnsetStrength
            }
        }

        // Normalize OSS to [0, 1] range
        var maxVal: Float = 0
        vDSP_maxv(oss, 1, &maxVal, vDSP_Length(oss.count))
        if maxVal > 0 {
            var scale = 1.0 / maxVal
            vDSP_vsmul(oss, 1, &scale, &oss, 1, vDSP_Length(oss.count))
        }

        return oss
    }

    /// Compute logarithmically-spaced band edges as FFT bin indices
    private static func computeLogBandEdges(
        numBands: Int, minFreq: Float, maxFreq: Float,
        fftSize: Int, sampleRate: Float
    ) -> [Int] {
        let freqPerBin = sampleRate / Float(fftSize)
        var edges = [Int]()
        for i in 0...numBands {
            let t = Float(i) / Float(numBands)
            let freq = minFreq * pow(maxFreq / minFreq, t)
            let bin = min(max(Int(freq / freqPerBin), 0), fftSize / 2 - 1)
            edges.append(bin)
        }
        // Ensure monotonically increasing
        for i in 1...numBands {
            if edges[i] <= edges[i - 1] {
                edges[i] = edges[i - 1] + 1
            }
        }
        return edges
    }

    // MARK: - OSS Low-pass Filter

    /// Simple IIR low-pass to remove high-frequency noise from OSS
    private static func lowPassFilterOSS(_ oss: [Float], cutoffHz: Float, sampleRate: Float) -> [Float] {
        guard oss.count > 1 else { return oss }
        let rc = 1.0 / (2.0 * Float.pi * cutoffHz)
        let dt = 1.0 / sampleRate
        let alpha = dt / (rc + dt)

        var output = [Float](repeating: 0, count: oss.count)
        output[0] = oss[0]
        for i in 1..<oss.count {
            output[i] = output[i - 1] + alpha * (oss[i] - output[i - 1])
        }
        return output
    }

    // MARK: - Tempo Estimation (Percival STEM-style)
    //
    // Pipeline per frame of OSS:
    //   1. Generalized autocorrelation: GAC(x) = IFFT(|FFT(x)|^exponent)
    //   2. Harmonic enhancement: add energy at 2x and 4x lag
    //   3. Extract top-N peaks as tempo candidates
    //   4. Score each candidate via cross-correlation with ideal pulse trains
    //   5. Apply perceptual weighting (Rayleigh distribution)
    //   6. Accumulate scores across all frames via Gaussian histogram

    private static func estimateTempo(
        oss: [Float],
        ossSampleRate: Float,
        logger: ((String) -> Void)?
    ) -> Int {
        let frameSize = acfFrameSize
        let hopSize = acfHopSize
        let numFrames = (oss.count - frameSize) / hopSize + 1
        guard numFrames > 0 else { return 0 }

        // Lag range corresponding to BPM range
        let minLag = max(1, Int(ossSampleRate * 60.0 / maxBPM))
        let maxLag = min(frameSize / 2 - 1, Int(ossSampleRate * 60.0 / minBPM))
        guard minLag < maxLag else { return 0 }

        // BPM histogram for accumulation (0.5 BPM resolution)
        let bpmResolution: Float = 0.5
        let histogramSize = Int((maxBPM - minBPM) / bpmResolution) + 1
        var bpmHistogram = [Float](repeating: 0, count: histogramSize)

        // Precompute perceptual weights for each lag
        var perceptualWeights = [Float](repeating: 0, count: maxLag + 1)
        for lag in minLag...maxLag {
            let bpm = 60.0 * ossSampleRate / Float(lag)
            perceptualWeights[lag] = rayleighWeight(bpm: bpm)
        }

        // FFT setup for generalized autocorrelation (padded to 2x length)
        let paddedSize = nextPowerOf2(frameSize * 2)
        let log2Padded = vDSP_Length(log2(Double(paddedSize)))
        guard let fftSetup = vDSP_create_fftsetup(log2Padded, FFTRadix(kFFTRadix2)) else {
            return 0
        }
        defer { vDSP_destroy_fftsetup(fftSetup) }

        logger?("Processing \(numFrames) OSS frames (frameSize=\(frameSize), hop=\(hopSize))...")

        for frameIdx in 0..<numFrames {
            let startIdx = frameIdx * hopSize
            guard startIdx + frameSize <= oss.count else { break }

            let ossFrame = Array(oss[startIdx..<(startIdx + frameSize)])

            // 1. Generalized autocorrelation
            let gac = generalizedAutocorrelation(
                ossFrame, paddedSize: paddedSize, fftSetup: fftSetup,
                log2n: log2Padded, exponent: gacExponent
            )

            // 2. Harmonic enhancement: GAC_enhanced[lag] = GAC[lag] + 0.5*GAC[2*lag] + 0.25*GAC[4*lag]
            var enhanced = [Float](repeating: 0, count: maxLag + 1)
            for lag in minLag...maxLag {
                var val = gac[lag]
                let lag2 = lag * 2
                let lag4 = lag * 4
                if lag2 < gac.count { val += 0.5 * gac[lag2] }
                if lag4 < gac.count { val += 0.25 * gac[lag4] }
                // Apply perceptual weighting
                enhanced[lag] = val * perceptualWeights[lag]
            }

            // 3. Find top-N peaks in enhanced autocorrelation
            let candidates = findTopPeaks(enhanced, minLag: minLag, maxLag: maxLag,
                                          count: numTempoCandidates)

            guard !candidates.isEmpty else { continue }

            // 4. Score each candidate with pulse train cross-correlation
            let scored = scoreCandidatesWithPulseTrains(
                ossFrame: ossFrame,
                candidates: candidates,
                ossSampleRate: ossSampleRate
            )

            // 5. Accumulate into BPM histogram with Gaussian weighting
            for (lag, score) in scored {
                let bpm = 60.0 * ossSampleRate / Float(lag)
                if bpm >= minBPM && bpm <= maxBPM {
                    let histIdx = Int((bpm - minBPM) / bpmResolution)
                    // Add Gaussian-shaped contribution
                    let gaussianHalfWidth = Int(accumulatorGaussianWidth / bpmResolution)
                    for offset in -gaussianHalfWidth...gaussianHalfWidth {
                        let idx = histIdx + offset
                        if idx >= 0 && idx < histogramSize {
                            let dist = Float(offset) * bpmResolution
                            let gaussWeight = exp(-0.5 * (dist * dist) /
                                                  (accumulatorGaussianWidth * accumulatorGaussianWidth / 4.0))
                            bpmHistogram[idx] += score * gaussWeight
                        }
                    }
                }
            }
        }

        // 6. Find best BPM from histogram
        var bestIdx = 0
        var bestVal: Float = 0
        for i in 0..<histogramSize {
            if bpmHistogram[i] > bestVal {
                bestVal = bpmHistogram[i]
                bestIdx = i
            }
        }

        let rawBPM = minBPM + Float(bestIdx) * bpmResolution
        logger?("Raw histogram peak: \(String(format: "%.1f", rawBPM)) BPM (score: \(String(format: "%.2f", bestVal)))")

        // 7. Octave correction: check if half or double tempo has significant support
        let finalBPM = octaveCorrect(bpmHistogram: bpmHistogram, peakBPM: rawBPM,
                                      bpmResolution: bpmResolution, logger: logger)

        return Int(finalBPM.rounded())
    }

    // MARK: - Generalized Autocorrelation
    //
    // GAC(x) = IFFT( |FFT(x)|^exponent )
    // With exponent=0.5, this sharpens peaks compared to standard autocorrelation (exponent=2)
    // and is more robust to noise.

    private static func generalizedAutocorrelation(
        _ frame: [Float],
        paddedSize: Int,
        fftSetup: FFTSetup,
        log2n: vDSP_Length,
        exponent: Float
    ) -> [Float] {
        let halfPadded = paddedSize / 2

        // Zero-pad frame to paddedSize
        var padded = [Float](repeating: 0, count: paddedSize)
        let copyCount = min(frame.count, paddedSize)
        for i in 0..<copyCount { padded[i] = frame[i] }

        // Pack into split complex
        var realp = [Float](repeating: 0, count: halfPadded)
        var imagp = [Float](repeating: 0, count: halfPadded)
        var splitComplex = DSPSplitComplex(realp: &realp, imagp: &imagp)

        padded.withUnsafeBufferPointer { ptr in
            vDSP_ctoz(UnsafePointer<DSPComplex>(OpaquePointer(ptr.baseAddress!)),
                       2, &splitComplex, 1, vDSP_Length(halfPadded))
        }

        // Forward FFT
        vDSP_fft_zrip(fftSetup, &splitComplex, 1, log2n, FFTDirection(FFT_FORWARD))

        // Compute |FFT(x)|^exponent
        // magnitude = sqrt(real^2 + imag^2), then raise to exponent
        for i in 0..<halfPadded {
            let mag = sqrt(realp[i] * realp[i] + imagp[i] * imagp[i])
            let scaled = pow(max(mag, 1e-20), exponent)
            // Replace with real=scaled, imag=0 (magnitude-only, zero phase)
            realp[i] = scaled
            imagp[i] = 0
        }

        // Inverse FFT
        splitComplex = DSPSplitComplex(realp: &realp, imagp: &imagp)
        vDSP_fft_zrip(fftSetup, &splitComplex, 1, log2n, FFTDirection(FFT_INVERSE))

        // Unpack result
        var result = [Float](repeating: 0, count: paddedSize)
        result.withUnsafeMutableBufferPointer { rPtr in
            var sc = DSPSplitComplex(realp: &realp, imagp: &imagp)
            vDSP_ztoc(&sc, 1, UnsafeMutablePointer<DSPComplex>(OpaquePointer(rPtr.baseAddress!)),
                       2, vDSP_Length(halfPadded))
        }

        // Normalize
        var scale = 1.0 / Float(paddedSize)
        vDSP_vsmul(result, 1, &scale, &result, 1, vDSP_Length(paddedSize))

        return result
    }

    // MARK: - Peak Finding in Autocorrelation

    private static func findTopPeaks(
        _ data: [Float], minLag: Int, maxLag: Int, count: Int
    ) -> [(lag: Int, value: Float)] {
        var peaks: [(lag: Int, value: Float)] = []

        // Find all local maxima
        for i in max(minLag, 2)..<min(maxLag, data.count - 2) {
            if data[i] > data[i - 1] && data[i] > data[i + 1] &&
               data[i] > data[i - 2] && data[i] > data[i + 2] &&
               data[i] > 0 {
                peaks.append((i, data[i]))
            }
        }

        // Sort by value (descending) and return top-N
        peaks.sort { $0.value > $1.value }
        return Array(peaks.prefix(count))
    }

    // MARK: - Pulse Train Cross-correlation Scoring
    //
    // For each candidate tempo lag, generate an ideal pulse train
    // (a spike every `lag` samples) and cross-correlate it with the OSS frame.
    // Try multiple phase offsets and take the best score.
    // This is the key insight from Percival: it scores how well the OSS
    // actually fits a regular beat pattern at that tempo.

    private static func scoreCandidatesWithPulseTrains(
        ossFrame: [Float],
        candidates: [(lag: Int, value: Float)],
        ossSampleRate: Float
    ) -> [(lag: Int, score: Float)] {
        let frameLength = ossFrame.count
        var results: [(lag: Int, score: Float)] = []

        for (lag, acfValue) in candidates {
            guard lag > 0 else { continue }

            var bestCorrelation: Float = 0

            // Try all possible phase offsets (0 to lag-1)
            // For efficiency, sample a reasonable number of offsets
            let numPhases = min(lag, 32)
            let phaseStep = max(1, lag / numPhases)

            for phaseStart in stride(from: 0, to: lag, by: phaseStep) {
                var correlation: Float = 0
                var numPulses: Float = 0

                var pos = phaseStart
                while pos < frameLength {
                    correlation += ossFrame[pos]
                    numPulses += 1
                    pos += lag
                }

                if numPulses > 0 {
                    // Normalize by number of pulses
                    let score = correlation / numPulses
                    bestCorrelation = max(bestCorrelation, score)
                }
            }

            // Combine autocorrelation peak value with pulse train score
            // Both contribute: ACF captures periodicity, pulse train captures alignment
            let combinedScore = acfValue * 0.4 + bestCorrelation * 0.6
            results.append((lag, combinedScore))
        }

        return results
    }

    // MARK: - Perceptual Tempo Weighting (Rayleigh Distribution)
    //
    // Human tempo perception is biased towards ~120 BPM.
    // Ellis (2007) uses a Rayleigh distribution in log-tempo space.

    private static func rayleighWeight(bpm: Float) -> Float {
        guard bpm > 0 else { return 0 }
        // Log-Gaussian centered at rayleighPeakBPM
        let logRatio = log2(bpm / rayleighPeakBPM)
        let sigma = rayleighSigmaOctaves
        return exp(-0.5 * (logRatio * logRatio) / (sigma * sigma))
    }

    // MARK: - Octave Error Correction
    //
    // The most common error in tempo estimation is "octave errors" — reporting
    // half or double the true tempo. We check if the half-tempo or double-tempo
    // has significant support in the histogram and apply a simple heuristic.

    private static func octaveCorrect(
        bpmHistogram: [Float],
        peakBPM: Float,
        bpmResolution: Float,
        logger: ((String) -> Void)?
    ) -> Float {
        let histogramSize = bpmHistogram.count

        // Get score around the peak BPM (sum in a ±3 BPM window)
        func scoreAround(_ bpm: Float) -> Float {
            let idx = Int((bpm - minBPM) / bpmResolution)
            let window = Int(3.0 / bpmResolution)
            var sum: Float = 0
            for offset in -window...window {
                let i = idx + offset
                if i >= 0 && i < histogramSize {
                    sum += bpmHistogram[i]
                }
            }
            return sum
        }

        let peakScore = scoreAround(peakBPM)
        let halfBPM = peakBPM / 2.0
        let doubleBPM = peakBPM * 2.0

        // Check half tempo
        if halfBPM >= minBPM && halfBPM <= maxBPM {
            let halfScore = scoreAround(halfBPM)
            // If half tempo has at least 80% of the support AND is in a more
            // "natural" range, prefer it (avoids reporting double-time)
            if halfScore > peakScore * 0.8 && halfBPM >= 60 && halfBPM <= 180 {
                logger?("Octave correction: \(String(format: "%.1f", peakBPM)) → \(String(format: "%.1f", halfBPM)) (half tempo preferred)")
                return halfBPM
            }
        }

        // Check double tempo
        if doubleBPM >= minBPM && doubleBPM <= maxBPM {
            let doubleScore = scoreAround(doubleBPM)
            if doubleScore > peakScore * 0.8 && doubleBPM >= 60 && doubleBPM <= 180 {
                logger?("Octave correction: \(String(format: "%.1f", peakBPM)) → \(String(format: "%.1f", doubleBPM)) (double tempo preferred)")
                return doubleBPM
            }
        }

        // Apply the Percival heuristic: if BPM < threshold and double is valid, double it
        let doublingThreshold: Float = 90.0
        if peakBPM < doublingThreshold {
            let doubled = peakBPM * 2
            if doubled >= minBPM && doubled <= maxBPM {
                logger?("Octave correction (threshold heuristic): \(String(format: "%.1f", peakBPM)) → \(String(format: "%.1f", doubled))")
                return doubled
            }
        }

        return peakBPM
    }

    // MARK: - Utility

    private static func nextPowerOf2(_ n: Int) -> Int {
        var v = n - 1
        v |= v >> 1; v |= v >> 2; v |= v >> 4; v |= v >> 8; v |= v >> 16
        return v + 1
    }
}

