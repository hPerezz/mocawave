import Accelerate
import AVFoundation

/// BPM analyzer implementing Ellis (2007) "Beat Tracking by Dynamic Programming."
///
/// Three stages:
/// 1. **Onset strength envelope** — STFT → Mel bands → dB → diff → HWR → sum → HP filter → smooth → normalize
/// 2. **Global tempo estimation** — weighted autocorrelation with duple/triple refinement
/// 3. **Beat tracking** — dynamic programming forward pass + backtrace
enum BPMAnalyzer4 {

    enum BPMError: Error {
        case invalidAudio
        case analysisUnavailable
    }

    // MARK: - Algorithm Parameters (Table 1 in paper)

    /// Audio is resampled to this rate before all processing.
    nonisolated private static let targetSR: Float = 8000
    /// STFT window length in samples — 32 ms at 8 kHz.
    nonisolated private static let windowSize = 256
    /// STFT hop length in samples — 4 ms, giving a 250 Hz frame rate.
    nonisolated private static let hopSize = 32
    /// Number of Mel-frequency bands.
    nonisolated private static let numMelBands = 40
    /// Onset-envelope frame rate (targetSR / hopSize).
    nonisolated private static let frameRate: Float = 250.0
    /// Centre of perceptual tempo-bias window (0.5 s ≡ 120 BPM).
    nonisolated private static let tau0: Float = 0.5
    /// Width of tempo-bias window in octaves.
    nonisolated private static let sigmaTau: Float = 0.9
    /// DP balance parameter between onset strength and tempo consistency.
    nonisolated private static let alpha: Float = 680.0
    /// Minimum BPM considered during tempo search.
    nonisolated private static let minBPM: Float = 30
    /// Maximum BPM considered during tempo search.
    nonisolated private static let maxBPM: Float = 300
    /// Maximum audio duration analysed (seconds).
    nonisolated private static let maxSeconds: Double = 60

    // MARK: - Public API

    /// Analyse the audio file at `url` and return the estimated BPM.
    ///
    /// The optional `logger` closure receives human-readable progress messages
    /// (same convention as `BPMAnalyzer`).
    nonisolated static func analyze(url: URL, logger: ((String) -> Void)? = nil) throws -> Int {
        logger?("[Ellis DP] Loading audio…")
        let samples = try loadAndResample(url: url, logger: logger)
        guard samples.count > windowSize * 4 else {
            throw BPMError.invalidAudio
        }

        // --- Stage 1 ---
        logger?("[Ellis DP] Stage 1: onset strength envelope (\(samples.count) samples)")
        let oenv = computeOnsetEnvelope(samples, logger: logger)
        guard oenv.count > Int(frameRate * 2) else {
            throw BPMError.analysisUnavailable
        }

        // --- Stage 2 ---
        logger?("[Ellis DP] Stage 2: global tempo estimation (\(oenv.count) frames)")
        let tempoResult = estimateTempo(oenv, logger: logger)
        let estBPM = 60.0 * frameRate / tempoResult.primaryPeriod
        logger?("  Primary: \(String(format: "%.1f", estBPM)) BPM " +
                "(period \(String(format: "%.1f", tempoResult.primaryPeriod)) frames)")
        if let sp = tempoResult.secondaryPeriod {
            logger?("  Secondary: \(String(format: "%.1f", 60.0 * frameRate / sp)) BPM")
        }

        // --- Stage 3 ---
        logger?("[Ellis DP] Stage 3: DP beat tracking")
        let beats = beatTrack(oenv, period: tempoResult.primaryPeriod, logger: logger)
        logger?("  Placed \(beats.count) beats")

        let bpm: Int
        if beats.count >= 4 {
            bpm = bpmFromBeats(beats, fallback: estBPM, logger: logger)
        } else {
            bpm = foldBPM(Int(estBPM.rounded()))
            logger?("  Too few beats – using Stage-2 estimate")
        }
        logger?("[Ellis DP] → \(bpm) BPM")
        return bpm
    }

    // MARK: - Audio Loading & Resampling

    nonisolated private static func loadAndResample(url: URL,
                                        logger: ((String) -> Void)?) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let fmt  = file.processingFormat
        let sr   = Float(fmt.sampleRate)
        guard sr > 0 else { throw BPMError.invalidAudio }

        let total = AVAudioFrameCount(file.length)
        let cap   = min(total, AVAudioFrameCount(maxSeconds * Double(sr)))
        guard cap > 0,
              let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: cap)
        else { throw BPMError.invalidAudio }

        try file.read(into: buf, frameCount: cap)
        guard let cd = buf.floatChannelData else { throw BPMError.invalidAudio }

        let n  = Int(buf.frameLength)
        let ch = Int(fmt.channelCount)
        guard n > 0 else { throw BPMError.invalidAudio }

        // Mix to mono
        var mono = [Float](repeating: 0, count: n)
        memcpy(&mono, cd[0], n * MemoryLayout<Float>.size)
        if ch > 1 {
            for c in 1..<ch {
                vDSP_vadd(mono, 1, cd[c], 1, &mono, 1, vDSP_Length(n))
            }
            var d = Float(ch)
            vDSP_vsdiv(mono, 1, &d, &mono, 1, vDSP_Length(n))
        }

        // Already at target rate?
        guard abs(sr - targetSR) > 1 else { return mono }

        // Linear-interpolation resample to 8 kHz
        let ratio = Double(targetSR) / Double(sr)
        let outN  = Int(Double(n) * ratio)
        var out   = [Float](repeating: 0, count: outN)
        for i in 0..<outN {
            let pos  = Double(i) / ratio
            let idx  = Int(pos)
            let frac = Float(pos - Double(idx))
            if idx + 1 < n {
                out[i] = mono[idx] * (1 - frac) + mono[idx + 1] * frac
            } else if idx < n {
                out[i] = mono[idx]
            }
        }
        logger?("  Resampled \(Int(sr)) → \(Int(targetSR)) Hz (\(n) → \(outN) samples)")
        return out
    }

    // MARK: - Stage 1: Onset Strength Envelope

    nonisolated private static func computeOnsetEnvelope(_ samples: [Float],
                                             logger: ((String) -> Void)?) -> [Float] {
        let half    = windowSize / 2                          // 128 FFT bins
        let nFrames = max(0, (samples.count - windowSize) / hopSize + 1)
        guard nFrames > 1 else { return [] }

        // FFT setup
        let log2n = vDSP_Length(log2(Double(windowSize)))
        guard let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            return []
        }
        defer { vDSP_destroy_fftsetup(fftSetup) }

        // Hann window
        var win = [Float](repeating: 0, count: windowSize)
        vDSP_hann_window(&win, vDSP_Length(windowSize), Int32(vDSP_HANN_NORM))

        // Mel filterbank  (40 bands × 128 bins)
        let melFB = melFilterbank(bands: numMelBands, fftSize: windowSize, sr: targetSR)

        // Reusable frame buffers
        var realBuf  = [Float](repeating: 0, count: half)
        var imagBuf  = [Float](repeating: 0, count: half)
        var windowed = [Float](repeating: 0, count: windowSize)
        var mag      = [Float](repeating: 0, count: half)

        var prevMel = [Float](repeating: 0, count: numMelBands)
        var odf     = [Float](repeating: 0, count: nFrames)

        // Process all frames inside safe pointer scopes
        realBuf.withUnsafeMutableBufferPointer { rp in
            imagBuf.withUnsafeMutableBufferPointer { ip in
                var sc = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)

                samples.withUnsafeBufferPointer { sp in
                    for f in 0..<nFrames {
                        let off = f * hopSize
                        guard off + windowSize <= samples.count else { break }

                        // 1. Apply Hann window
                        vDSP_vmul(sp.baseAddress! + off, 1, win, 1,
                                  &windowed, 1, vDSP_Length(windowSize))

                        // 2. Pack into split-complex for real FFT
                        windowed.withUnsafeBufferPointer { wp in
                            vDSP_ctoz(
                                UnsafePointer<DSPComplex>(OpaquePointer(wp.baseAddress!)), 2,
                                &sc, 1, vDSP_Length(half))
                        }

                        // 3. Forward FFT
                        vDSP_fft_zrip(fftSetup, &sc, 1, log2n, FFTDirection(FFT_FORWARD))

                        // 4. Power spectrum  |X(k)|²
                        vDSP_zvmags(&sc, 1, &mag, 1, vDSP_Length(half))

                        // 5-7. Mel mapping → dB → first-difference → HWR → sum across bands
                        var frameODF: Float = 0
                        for b in 0..<numMelBands {
                            var dot: Float = 0
                            vDSP_dotpr(mag, 1, melFB[b], 1, &dot, vDSP_Length(half))
                            let dB   = 10.0 * log10(max(dot, 1e-10))
                            let diff = dB - prevMel[b]
                            if diff > 0 { frameODF += diff }       // half-wave rectification
                            prevMel[b] = dB
                        }
                        odf[f] = frameODF
                    }
                }
            }
        }

        // 8. High-pass filter (cutoff ≈ 0.4 Hz) to remove slow drift
        var result = highPass(odf, sr: frameRate, cutoff: 0.4)

        // 9. Gaussian smooth (σ ≈ 2.5 frames ≈ 20 ms at 250 Hz)
        result = gaussianSmooth(result, sigma: 2.5)

        // 10. Zero-mean, unit-variance normalisation
        var mean: Float = 0
        vDSP_meanv(result, 1, &mean, vDSP_Length(result.count))
        var negMean = -mean
        vDSP_vsadd(result, 1, &negMean, &result, 1, vDSP_Length(result.count))

        var rms: Float = 0
        vDSP_rmsqv(result, 1, &rms, vDSP_Length(result.count))
        if rms > 0 {
            vDSP_vsdiv(result, 1, &rms, &result, 1, vDSP_Length(result.count))
        }

        logger?("  \(nFrames) frames → onset envelope ready")
        return result
    }

    // MARK: - Mel Filterbank

    nonisolated private static func hzToMel(_ hz: Float) -> Float {
        2595.0 * log10(1.0 + hz / 700.0)
    }

    nonisolated private static func melToHz(_ mel: Float) -> Float {
        700.0 * (powf(10.0, mel / 2595.0) - 1.0)
    }

    /// Build a bank of `bands` triangular Mel-spaced filters over `fftSize/2` bins.
    nonisolated private static func melFilterbank(bands: Int, fftSize: Int, sr: Float) -> [[Float]] {
        let nBins = fftSize / 2
        let hiMel = hzToMel(sr / 2.0)
        let nPts  = bands + 2                                           // filter edge count

        // Evenly spaced points in Mel domain
        let melPts = (0..<nPts).map { Float($0) * hiMel / Float(nPts - 1) }
        let hzPts  = melPts.map { melToHz($0) }
        let bins   = hzPts.map { min(nBins - 1, max(0, Int(($0 * Float(fftSize) / sr).rounded()))) }

        var fb = [[Float]](repeating: [Float](repeating: 0, count: nBins), count: bands)
        for i in 0..<bands {
            let s = bins[i], c = bins[i + 1], e = bins[i + 2]
            // Rising slope
            if c > s {
                for k in s...min(c, nBins - 1) {
                    fb[i][k] = Float(k - s) / Float(c - s)
                }
            }
            // Falling slope
            if e > c {
                for k in c...min(e, nBins - 1) {
                    fb[i][k] = Float(e - k) / Float(e - c)
                }
            }
        }
        return fb
    }

    // MARK: - Stage 2: Tempo Estimation

    nonisolated private static func estimateTempo(
        _ env: [Float],
        logger: ((String) -> Void)?
    ) -> (primaryPeriod: Float, secondaryPeriod: Float?, weight: Float) {

        let N      = env.count
        let minLag = max(1, Int(60.0 * frameRate / maxBPM))         // shortest period (300 BPM → 50 fr)
        let maxLag = min(N / 2, Int(60.0 * frameRate / minBPM))    // longest  period (30 BPM  → 500 fr)
        guard maxLag > minLag else {
            return (60.0 * frameRate / 120.0, nil, 0)
        }

        // --- 2.1  Autocorrelation  ACF(τ) = Σ_t O(t)·O(t−τ) ---
        var acf = [Float](repeating: 0, count: maxLag + 1)
        env.withUnsafeBufferPointer { p in
            for tau in minLag...maxLag {
                var s: Float = 0
                let count = N - tau
                guard count > 0 else { continue }
                vDSP_dotpr(p.baseAddress!, 1,
                           p.baseAddress! + tau, 1,
                           &s, vDSP_Length(count))
                acf[tau] = s
            }
        }

        // --- 2.2  Perceptual weighting  W(τ) = exp(−½ (log₂(τ/τ₀) / σ)²) ---
        let tau0f = tau0 * frameRate                                // 125 frames
        var wacf  = [Float](repeating: 0, count: maxLag + 1)
        for tau in minLag...maxLag {
            let lr = log2(Float(tau) / tau0f)
            let w  = exp(-0.5 * lr * lr / (sigmaTau * sigmaTau))
            wacf[tau] = acf[tau] * w
        }

        // --- 2.3  Duple / triple refinement ---
        //
        //  TPS2(τ) = TPS(τ) + 0.5·TPS(2τ) + 0.25·TPS(2τ−1) + 0.25·TPS(2τ+1)
        //  TPS3(τ) = TPS(τ) + 0.33·TPS(3τ) + 0.33·TPS(3τ−1) + 0.33·TPS(3τ+1)

        var tps2 = [Float](repeating: 0, count: maxLag + 1)
        var tps3 = [Float](repeating: 0, count: maxLag + 1)

        for tau in minLag...maxLag {
            // Duple
            var d = wacf[tau]
            let t2 = 2 * tau
            if t2     <= maxLag                     { d += 0.50 * wacf[t2]     }
            if t2 - 1 >= minLag && t2 - 1 <= maxLag { d += 0.25 * wacf[t2 - 1] }
            if t2 + 1 <= maxLag                     { d += 0.25 * wacf[t2 + 1] }
            tps2[tau] = d

            // Triple
            var tr = wacf[tau]
            let t3 = 3 * tau
            if t3     <= maxLag                     { tr += 0.33 * wacf[t3]     }
            if t3 - 1 >= minLag && t3 - 1 <= maxLag { tr += 0.33 * wacf[t3 - 1] }
            if t3 + 1 <= maxLag                     { tr += 0.33 * wacf[t3 + 1] }
            tps3[tau] = tr
        }

        // --- 2.4  Pick the dominant peak ---

        var max2: Float = -.infinity, idx2 = minLag
        var max3: Float = -.infinity, idx3 = minLag
        for tau in minLag...maxLag {
            if tps2[tau] > max2 { max2 = tps2[tau]; idx2 = tau }
            if tps3[tau] > max3 { max3 = tps3[tau]; idx3 = tau }
        }

        let primary:   Float
        let secondary: Float?

        if max2 >= max3 {
            // Duple meter — faster tempo at TPS2 peak, slower is 2×
            primary   = Float(idx2)
            let sec   = idx2 * 2
            secondary = sec <= maxLag ? Float(sec) : nil
            logger?("  Duple meter detected")
        } else {
            // Triple meter — faster tempo at TPS3 peak, slower is 3×
            primary   = Float(idx3)
            let sec   = idx3 * 3
            secondary = sec <= maxLag ? Float(sec) : nil
            logger?("  Triple meter detected")
        }

        return (primary, secondary, max(max2, max3))
    }

    // MARK: - Stage 3: Beat Tracking via Dynamic Programming

    /// Find the optimal beat sequence that maximises
    ///   C({t_i}) = Σ O(t_i) + α · Σ F(t_i − t_{i−1}, τ_p)
    /// where  F(Δt, τ) = −(ln(Δt/τ))².
    nonisolated private static func beatTrack(_ env: [Float],
                                  period: Float,
                                  logger: ((String) -> Void)?) -> [Int] {
        let N = env.count
        let p = max(1, Int(period.rounded()))

        // Predecessor search window:  [t − 2p … t − ⌊p/2⌋]
        let maxBack  = 2 * p
        let minBack  = max(1, p / 2)
        let rangeLen = maxBack - minBack + 1
        guard rangeLen > 0 else { return [] }

        // Pre-compute transition costs  txcost[i] for distance (i + minBack)
        //   F(d, τ) = −α · (ln(d / τ))²
        var txcost = [Float](repeating: 0, count: rangeLen)
        for i in 0..<rangeLen {
            let d  = Float(i + minBack)
            let lr = log(d / period)
            txcost[i] = -alpha * lr * lr
        }

        var cumscore = env                                  // cumulative DP score
        var backlink = [Int](repeating: -1, count: N)       // best predecessor

        // Forward pass
        for t in maxBack..<N {
            var best: Float = -.infinity
            var bestPred    = -1
            for i in 0..<rangeLen {
                let pred = t - (i + minBack)
                guard pred >= 0 else { continue }
                let score = txcost[i] + cumscore[pred]
                if score > best {
                    best     = score
                    bestPred = pred
                }
            }
            if bestPred >= 0 {
                cumscore[t] = best + env[t]
                backlink[t] = bestPred
            }
        }

        // Find the global best ending beat
        var bestIdx = 0
        var bestVal: Float = -.infinity
        for t in 0..<N {
            if cumscore[t] > bestVal {
                bestVal = cumscore[t]
                bestIdx = t
            }
        }

        // Backtrace
        var beats = [bestIdx]
        var cur   = bestIdx
        while backlink[cur] >= 0 {
            cur = backlink[cur]
            beats.append(cur)
        }
        beats.reverse()

        return beats
    }

    // MARK: - BPM from Beat Positions

    /// Derive BPM from the median inter-beat interval.
    nonisolated private static func bpmFromBeats(_ beats: [Int],
                                     fallback: Float,
                                     logger: ((String) -> Void)?) -> Int {
        guard beats.count >= 2 else { return foldBPM(Int(fallback.rounded())) }

        var intervals = [Float]()
        intervals.reserveCapacity(beats.count - 1)
        for i in 1..<beats.count {
            let d = Float(beats[i] - beats[i - 1])
            if d > 0 { intervals.append(d) }
        }
        guard !intervals.isEmpty else { return foldBPM(Int(fallback.rounded())) }

        let sorted = intervals.sorted()
        let median: Float
        let mid = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            median = (sorted[mid - 1] + sorted[mid]) / 2.0
        } else {
            median = sorted[mid]
        }

        let bpm = 60.0 * frameRate / median
        logger?("  Median IBI: \(String(format: "%.1f", median)) fr → " +
                "\(String(format: "%.1f", bpm)) BPM")

        return foldBPM(Int(bpm.rounded()))
    }

    /// Fold the BPM into a perceptually reasonable range [40, 240]
    /// by doubling or halving.
    nonisolated private static func foldBPM(_ raw: Int) -> Int {
        guard raw > 0 else { return 0 }
        var b = raw
        // DJ range (same as the dj-stack): 240 for a 120 BPM track is a doubled beat, not a tempo.
        while b < 70  { b *= 2 }
        while b > 180 { b /= 2 }
        return b
    }

    // MARK: - DSP Utilities

    /// First-order RC high-pass filter.
    nonisolated private static func highPass(_ sig: [Float], sr: Float, cutoff: Float) -> [Float] {
        guard sig.count > 1 else { return sig }
        let rc = 1.0 / (2.0 * Float.pi * cutoff)
        let dt = 1.0 / sr
        let a  = rc / (rc + dt)
        var out = [Float](repeating: 0, count: sig.count)
        out[0] = sig[0]
        for i in 1..<sig.count {
            out[i] = a * (out[i - 1] + sig[i] - sig[i - 1])
        }
        return out
    }

    /// Gaussian smoothing with edge-aware weight normalisation.
    nonisolated private static func gaussianSmooth(_ sig: [Float], sigma: Float) -> [Float] {
        let radius = Int(ceil(sigma * 3))
        let kLen   = 2 * radius + 1
        guard sig.count > kLen else { return sig }

        // Build normalised Gaussian kernel
        var kern = [Float](repeating: 0, count: kLen)
        var ksum: Float = 0
        for i in 0..<kLen {
            let x = Float(i - radius)
            kern[i] = exp(-0.5 * x * x / (sigma * sigma))
            ksum += kern[i]
        }
        for i in 0..<kLen { kern[i] /= ksum }

        // Convolve (re-normalise near edges)
        let N = sig.count
        var out = [Float](repeating: 0, count: N)
        for i in 0..<N {
            var sum: Float = 0, wt: Float = 0
            for j in 0..<kLen {
                let idx = i - radius + j
                if idx >= 0 && idx < N {
                    sum += sig[idx] * kern[j]
                    wt  += kern[j]
                }
            }
            out[i] = wt > 0 ? sum / wt : sig[i]
        }
        return out
    }
}
