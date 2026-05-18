import Accelerate
import AVFoundation

enum BPMAnalyzer {
    enum BPMError: Error {
        case invalidAudio
        case analysisUnavailable
    }

    private static let minBPM: Float = 60
    private static let maxBPM: Float = 190
    private static let analysisWindowSeconds: Double = 30
    private static let targetSampleRate: Float = 200  // Lower rate for energy envelope
    private static let fftSize: Int = 2048  // FFT size for spectral analysis

    static func analyze(url: URL, logger: ((String) -> Void)? = nil) throws -> Int {
        logger?("Opening audio file...")
        let audioFile = try AVAudioFile(forReading: url)
        let format = audioFile.processingFormat
        let sampleRate = Float(format.sampleRate)

        guard sampleRate > 0 else {
            throw BPMError.invalidAudio
        }

        logger?("Sample rate: \(sampleRate) Hz")

        let totalFrames = AVAudioFrameCount(audioFile.length)
        let maxFrames = AVAudioFrameCount(analysisWindowSeconds * Double(sampleRate))
        let framesToRead = min(totalFrames, maxFrames)

        logger?("Reading \(framesToRead) frames...")

        guard framesToRead > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: framesToRead) else {
            throw BPMError.invalidAudio
        }

        try audioFile.read(into: buffer, frameCount: framesToRead)

        guard let channelData = buffer.floatChannelData else {
            throw BPMError.invalidAudio
        }

        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else {
            throw BPMError.invalidAudio
        }

        let channelCount = Int(format.channelCount)

        // Step 1: Convert to mono
        logger?("Converting to mono...")
        var monoSamples = [Float](repeating: 0, count: frameCount)

        if channelCount == 1 {
            memcpy(&monoSamples, channelData[0], frameCount * MemoryLayout<Float>.size)
        } else {
            memcpy(&monoSamples, channelData[0], frameCount * MemoryLayout<Float>.size)
            for ch in 1..<channelCount {
                vDSP_vadd(monoSamples, 1, channelData[ch], 1, &monoSamples, 1, vDSP_Length(frameCount))
            }
            var divisor = Float(channelCount)
            vDSP_vsdiv(monoSamples, 1, &divisor, &monoSamples, 1, vDSP_Length(frameCount))
        }

        // Step 2: Multi-band analysis - analyze different frequency bands
        logger?("Performing multi-band analysis...")
        
        // Bass band (40-200Hz) - for kick drums
        let bassFiltered = applyBandpassFilter(monoSamples, sampleRate: sampleRate, lowFreq: 40, highFreq: 200)
        let bassEnvelope = computeEnergyEnvelope(bassFiltered, sampleRate: sampleRate, logger: logger)
        
        // Mid band (200-2000Hz) - for snare and percussion
        let midFiltered = applyBandpassFilter(monoSamples, sampleRate: sampleRate, lowFreq: 200, highFreq: 2000)
        let midEnvelope = computeEnergyEnvelope(midFiltered, sampleRate: sampleRate, logger: nil)
        
        // High band (2000-8000Hz) - for hi-hats and cymbals
        let highFiltered = applyBandpassFilter(monoSamples, sampleRate: sampleRate, lowFreq: 2000, highFreq: 8000)
        let highEnvelope = computeEnergyEnvelope(highFiltered, sampleRate: sampleRate, logger: nil)
        
        // Combine envelopes with weighted sum (bass is most important)
        let combinedEnvelope = combineEnvelopes([bassEnvelope, midEnvelope, highEnvelope], weights: [0.5, 0.3, 0.2])
        let smoothed = smoothEnvelope(combinedEnvelope, windowSize: 5)

        // Step 3: Spectral Flux onset detection (more robust than energy-based)
        logger?("Computing spectral flux...")
        let spectralFlux = computeSpectralFlux(monoSamples, sampleRate: sampleRate, logger: logger)
        let fluxSmoothed = smoothEnvelope(spectralFlux, windowSize: 3)

        // Step 4: Detect onsets using multiple methods
        logger?("Detecting onsets...")
        let energyOnsets = detectOnsets(smoothed, sampleRate: targetSampleRate)
        let fluxOnsets = detectOnsets(fluxSmoothed, sampleRate: targetSampleRate)
        
        // Combine onsets from both methods (union with distance filtering)
        let combinedOnsets = mergeOnsets([energyOnsets, fluxOnsets], sampleRate: targetSampleRate)
        logger?("Found \(combinedOnsets.count) onsets (energy: \(energyOnsets.count), flux: \(fluxOnsets.count))")

        // Collect BPM candidates from multiple methods
        var candidates: [(bpm: Float, confidence: Float, method: String)] = []

        // Method 1: Onset interval histogram (improved clustering)
        if combinedOnsets.count >= 8 {
            let onsetBPMs = estimateBPMFromOnsetsImproved(combinedOnsets, sampleRate: targetSampleRate)
            for (bpm, conf) in onsetBPMs {
                if bpm >= minBPM && bpm <= maxBPM {
                    candidates.append((bpm, conf, "onset"))
                    logger?("Onset-based BPM candidate: \(Int(bpm)) (confidence: \(String(format: "%.2f", conf)))")
                }
            }
        }

        // Method 2: Autocorrelation (improved with short-time windows)
        logger?("Computing autocorrelation...")
        if let autoResults = estimateBPMFromAutocorrelationImproved(smoothed, sampleRate: targetSampleRate) {
            for (bpm, conf) in autoResults {
                candidates.append((bpm, conf, "autocorr"))
                logger?("Autocorrelation BPM candidate: \(Int(bpm)) (confidence: \(String(format: "%.2f", conf)))")
            }
        }

        // Method 3: Fourier Tempogram (frequency domain analysis)
        logger?("Computing Fourier tempogram...")
        if let fourierBPMs = estimateBPMFromFourierTempogram(smoothed, sampleRate: targetSampleRate, logger: logger) {
            for (bpm, conf) in fourierBPMs {
                candidates.append((bpm, conf, "fourier"))
                logger?("Fourier tempogram BPM candidate: \(Int(bpm)) (confidence: \(String(format: "%.2f", conf)))")
            }
        }

        // Method 4: Autocorrelation on spectral flux
        if let fluxAutoResults = estimateBPMFromAutocorrelationImproved(fluxSmoothed, sampleRate: targetSampleRate) {
            for (bpm, conf) in fluxAutoResults {
                candidates.append((bpm, conf * 0.8, "flux_autocorr"))  // Slightly lower weight
                logger?("Spectral flux autocorrelation BPM candidate: \(Int(bpm)) (confidence: \(String(format: "%.2f", conf * 0.8)))")
            }
        }

        guard !candidates.isEmpty else {
            logger?("No valid BPM candidates found")
            return 0
        }

        // Step 5: Score and select best BPM using comb filter and consensus
        logger?("Scoring candidates with comb filter and consensus...")
        let finalBPM = selectBestBPMWithConsensus(
            candidates: candidates,
            samples: smoothed,
            sampleRate: targetSampleRate,
            logger: logger
        )

        logger?("Final BPM: \(finalBPM)")
        return finalBPM
    }
    
    // MARK: - Energy Envelope Computation
    
    private static func computeEnergyEnvelope(_ samples: [Float], sampleRate: Float, logger: ((String) -> Void)?) -> [Float] {
        let downsampleFactor = Int(sampleRate / targetSampleRate)
        let downsampledCount = samples.count / max(downsampleFactor, 1)
        
        var energyEnvelope = [Float](repeating: 0, count: downsampledCount)
        
        samples.withUnsafeBufferPointer { samplesPtr in
            for i in 0..<downsampledCount {
                let srcIdx = i * downsampleFactor
                let validCount = min(downsampleFactor, samples.count - srcIdx)
                if validCount > 0 {
                    var rms: Float = 0
                    vDSP_rmsqv(samplesPtr.baseAddress! + srcIdx, 1, &rms, vDSP_Length(validCount))
                    energyEnvelope[i] = rms
                }
            }
        }
        
        logger?("Energy envelope: \(downsampledCount) samples at \(targetSampleRate) Hz")
        return energyEnvelope
    }
    
    private static func combineEnvelopes(_ envelopes: [[Float]], weights: [Float]) -> [Float] {
        guard !envelopes.isEmpty, envelopes.count == weights.count else { return envelopes.first ?? [] }
        
        let minLength = envelopes.map { $0.count }.min() ?? 0
        guard minLength > 0 else { return [] }
        
        var combined = [Float](repeating: 0, count: minLength)
        
        for i in 0..<minLength {
            var sum: Float = 0
            var weightSum: Float = 0
            for (envelope, weight) in zip(envelopes, weights) {
                if i < envelope.count {
                    sum += envelope[i] * weight
                    weightSum += weight
                }
            }
            combined[i] = weightSum > 0 ? sum / weightSum : 0
        }
        
        return combined
    }

    // MARK: - Bandpass Filter (IIR Butterworth-style)

    private static func applyBandpassFilter(_ samples: [Float], sampleRate: Float, lowFreq: Float, highFreq: Float) -> [Float] {
        guard samples.count > 0 else { return [] }

        // Use cascaded high-pass and low-pass filters (simple IIR)
        let highPassed = applyHighPassFilter(samples, sampleRate: sampleRate, cutoff: lowFreq)
        let bandPassed = applyLowPassFilter(highPassed, sampleRate: sampleRate, cutoff: highFreq)

        return bandPassed
    }

    private static func applyHighPassFilter(_ samples: [Float], sampleRate: Float, cutoff: Float) -> [Float] {
        guard samples.count > 0 else { return [] }

        // RC high-pass filter
        let rc = 1.0 / (2.0 * Float.pi * cutoff)
        let dt = 1.0 / sampleRate
        let alpha = rc / (rc + dt)

        var output = [Float](repeating: 0, count: samples.count)
        output[0] = samples[0]

        for i in 1..<samples.count {
            output[i] = alpha * (output[i - 1] + samples[i] - samples[i - 1])
        }

        return output
    }

    private static func applyLowPassFilter(_ samples: [Float], sampleRate: Float, cutoff: Float) -> [Float] {
        guard samples.count > 0 else { return [] }

        // RC low-pass filter
        let rc = 1.0 / (2.0 * Float.pi * cutoff)
        let dt = 1.0 / sampleRate
        let alpha = dt / (rc + dt)

        var output = [Float](repeating: 0, count: samples.count)
        output[0] = samples[0]

        for i in 1..<samples.count {
            output[i] = output[i - 1] + alpha * (samples[i] - output[i - 1])
        }

        return output
    }

    // MARK: - Envelope Smoothing

    private static func smoothEnvelope(_ samples: [Float], windowSize: Int) -> [Float] {
        guard samples.count > windowSize else { return samples }

        let count = samples.count
        var smoothed = [Float](repeating: 0, count: count)

        // Use vDSP_vswsum for O(n) sliding window sum
        // vDSP_vswsum computes running sum of windowSize consecutive elements
        let windowLength = vDSP_Length(windowSize)
        var windowSums = [Float](repeating: 0, count: count - windowSize + 1)

        samples.withUnsafeBufferPointer { samplesPtr in
            vDSP_vswsum(samplesPtr.baseAddress!, 1, &windowSums, 1, vDSP_Length(windowSums.count), windowLength)
        }

        // Divide by window size to get averages
        var divisor = Float(windowSize)
        vDSP_vsdiv(windowSums, 1, &divisor, &windowSums, 1, vDSP_Length(windowSums.count))

        // Copy to output with proper offset (center the window)
        let halfWindow = windowSize / 2

        // Handle edges manually
        for i in 0..<halfWindow {
            var sum: Float = 0
            var cnt: Float = 0
            for j in 0...min(count - 1, i + halfWindow) {
                sum += samples[j]
                cnt += 1
            }
            smoothed[i] = sum / cnt
        }

        // Copy the vectorized middle portion
        for i in halfWindow..<(count - halfWindow) {
            smoothed[i] = windowSums[i - halfWindow]
        }

        // Handle trailing edge
        for i in (count - halfWindow)..<count {
            var sum: Float = 0
            var cnt: Float = 0
            for j in max(0, i - halfWindow)...(count - 1) {
                sum += samples[j]
                cnt += 1
            }
            smoothed[i] = sum / cnt
        }

        return smoothed
    }

    // MARK: - Spectral Flux Computation
    
    private static func computeSpectralFlux(_ samples: [Float], sampleRate: Float, logger: ((String) -> Void)?) -> [Float] {
        // Use shorter FFT for spectral flux (more temporal resolution)
        let hopSize = 512
        let fftSize = 1024
        let numFrames = (samples.count - fftSize) / hopSize + 1
        
        guard numFrames > 1 else { return [] }
        
        var spectralFlux = [Float](repeating: 0, count: numFrames)
        var prevMagnitude = [Float](repeating: 0, count: fftSize / 2)
        
        // Setup FFT
        let log2n = vDSP_Length(log2(Double(fftSize)))
        guard let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            logger?("Failed to create FFT setup")
            return []
        }
        defer { vDSP_destroy_fftsetup(fftSetup) }
        
        var realp = [Float](repeating: 0, count: fftSize / 2)
        var imagp = [Float](repeating: 0, count: fftSize / 2)
        
        // Window function (Hanning)
        var window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        
        realp.withUnsafeMutableBufferPointer { realBuffer in
            imagp.withUnsafeMutableBufferPointer { imagBuffer in
                var splitComplex = DSPSplitComplex(
                    realp: realBuffer.baseAddress!,
                    imagp: imagBuffer.baseAddress!
                )

                samples.withUnsafeBufferPointer { samplesPtr in
                    for frame in 0..<numFrames {
                        let startIdx = frame * hopSize
                        guard startIdx + fftSize <= samples.count else { break }

                        // Apply window and copy to FFT buffer
                        var windowed = [Float](repeating: 0, count: fftSize)
                        vDSP_vmul(samplesPtr.baseAddress! + startIdx, 1, window, 1, &windowed, 1, vDSP_Length(fftSize))

                        // Copy to split complex format
                        windowed.withUnsafeBufferPointer { windowedPtr in
                            vDSP_ctoz(UnsafePointer<DSPComplex>(OpaquePointer(windowedPtr.baseAddress!)), 2,
                                      &splitComplex, 1, vDSP_Length(fftSize / 2))
                        }

                        // Perform FFT
                        vDSP_fft_zrip(fftSetup, &splitComplex, 1, log2n, FFTDirection(FFT_FORWARD))

                        // Compute magnitude spectrum
                        var magnitude = [Float](repeating: 0, count: fftSize / 2)
                        vDSP_zvmags(&splitComplex, 1, &magnitude, 1, vDSP_Length(fftSize / 2))

                        // Compute spectral flux: sum of positive differences
                        var flux: Float = 0
                        for i in 0..<magnitude.count {
                            let diff = magnitude[i] - prevMagnitude[i]
                            if diff > 0 {
                                flux += diff
                            }
                        }

                        spectralFlux[frame] = flux
                        prevMagnitude = magnitude
                    }
                }
            }
        }
        
        // Downsample to target sample rate
        let downsampleFactor = Int(sampleRate / Float(hopSize) / targetSampleRate)
        guard downsampleFactor > 0 else { return spectralFlux }
        
        let downsampledCount = spectralFlux.count / downsampleFactor
        var downsampled = [Float](repeating: 0, count: downsampledCount)
        
        for i in 0..<downsampledCount {
            let startIdx = i * downsampleFactor
            let endIdx = min(startIdx + downsampleFactor, spectralFlux.count)
            var sum: Float = 0
            for j in startIdx..<endIdx {
                sum += spectralFlux[j]
            }
            downsampled[i] = sum / Float(endIdx - startIdx)
        }
        
        logger?("Spectral flux: \(downsampled.count) samples")
        return downsampled
    }
    
    // MARK: - Onset Detection

    private static func detectOnsets(_ samples: [Float], sampleRate: Float) -> [Int] {
        guard samples.count > 4 else { return [] }

        // Compute first derivative (energy change) using vectorized operations
        var diff = [Float](repeating: 0, count: samples.count)

        diff.withUnsafeMutableBufferPointer { diffPtr in
            samples.withUnsafeBufferPointer { samplesPtr in
                vDSP_vsub(samplesPtr.baseAddress!, 1,
                          samplesPtr.baseAddress! + 1, 1,
                          diffPtr.baseAddress!.advanced(by: 1), 1,
                          vDSP_Length(samples.count - 1))
            }
        }

        // Half-wave rectification: keep only positive values
        var low: Float = 0
        var high: Float = Float.greatestFiniteMagnitude
        vDSP_vclip(diff, 1, &low, &high, &diff, 1, vDSP_Length(samples.count))

        // Compute adaptive threshold using local statistics
        let windowSeconds: Float = 0.5
        let windowSize = max(1, Int(sampleRate * windowSeconds))
        let minDistance = Int(sampleRate * 60.0 / maxBPM * 0.8)

        var onsets: [Int] = []

        for i in 2..<(samples.count - 2) {
            let windowStart = max(0, i - windowSize / 2)
            let windowEnd = min(samples.count, i + windowSize / 2)

            var localSum: Float = 0
            var localMax: Float = 0
            for j in windowStart..<windowEnd {
                localSum += diff[j]
                localMax = max(localMax, diff[j])
            }
            let localMean = localSum / Float(windowEnd - windowStart)

            // Improved threshold: mean + adaptive fraction
            let threshold = localMean + 0.5 * (localMax - localMean)

            if diff[i] > threshold && diff[i] > 0 {
                // Must be local maximum with wider neighborhood check
                if diff[i] >= diff[i - 1] && diff[i] >= diff[i + 1] &&
                   diff[i] >= diff[i - 2] && diff[i] >= diff[i + 2] {
                    if onsets.isEmpty || (i - onsets.last!) >= minDistance {
                        onsets.append(i)
                    }
                }
            }
        }

        return onsets
    }
    
    private static func mergeOnsets(_ onsetSets: [[Int]], sampleRate: Float) -> [Int] {
        guard !onsetSets.isEmpty else { return [] }
        
        // Combine all onsets
        var allOnsets = onsetSets.flatMap { $0 }
        allOnsets.sort()
        
        // Remove duplicates within minimum distance
        let minDistance = Int(sampleRate * 60.0 / maxBPM * 0.6)
        var merged: [Int] = []
        
        for onset in allOnsets {
            if merged.isEmpty || (onset - merged.last!) >= minDistance {
                merged.append(onset)
            } else {
                // Keep the one with better position (average if close)
                let lastIdx = merged.count - 1
                merged[lastIdx] = (merged[lastIdx] + onset) / 2
            }
        }
        
        return merged
    }

    // MARK: - Onset-based BPM Estimation (Improved)

    private static func estimateBPMFromOnsetsImproved(_ onsets: [Int], sampleRate: Float) -> [(bpm: Float, confidence: Float)] {
        guard onsets.count >= 4 else { return [] }

        // Collect inter-onset intervals
        var intervals: [Float] = []
        for i in 1..<onsets.count {
            let intervalSamples = Float(onsets[i] - onsets[i - 1])
            let intervalSeconds = intervalSamples / sampleRate
            if intervalSeconds > 0 && intervalSeconds < 2.0 {  // Max 2 seconds between beats
                intervals.append(intervalSeconds)
            }
        }

        guard intervals.count >= 3 else { return [] }

        // Build histogram with better resolution and clustering
        var bpmHistogram: [Float: Float] = [:]  // BPM -> weighted count
        
        for interval in intervals {
            // Consider multiple octaves
            for octave in [1, 2, 4] {
                var bpm = 60.0 * Float(octave) / interval
                
                // Normalize to valid range
                while bpm < minBPM { bpm *= 2 }
                while bpm > maxBPM { bpm /= 2 }
                
                if bpm >= minBPM && bpm <= maxBPM {
                    // Use Gaussian weighting for smoother histogram
                    let rounded = (bpm / 0.5).rounded() * 0.5  // 0.5 BPM bins
                    let weight = 1.0 / Float(octave)  // Lower weight for higher octaves
                    bpmHistogram[rounded, default: 0] += weight
                }
            }
        }

        guard !bpmHistogram.isEmpty else { return [] }

        // Find peaks with improved clustering
        var candidates: [(bpm: Float, confidence: Float)] = []
        
        // Sort by count
        let sorted = bpmHistogram.sorted { $0.value > $1.value }
        
        // Find local maxima with minimum distance
        let minBPMDistance: Float = 5.0  // Minimum 5 BPM between candidates
        
        for (bpm, count) in sorted {
            // Check if this is a local maximum
            var isLocalMax = true
            for (otherBPM, otherCount) in bpmHistogram {
                if abs(otherBPM - bpm) < minBPMDistance && otherCount > count {
                    isLocalMax = false
                    break
                }
            }
            
            if isLocalMax {
                // Compute confidence: normalize by max count and apply Gaussian smoothing
                let maxCount = sorted.first?.value ?? 1.0
                let normalizedConf = min(1.0, count / maxCount)
                
                // Boost confidence for common tempos
                let boostedConf = normalizedConf * tempoLikelihood(bpm) / 1.5
                
                candidates.append((bpm, boostedConf))
            }
        }
        
        // Sort by confidence and return top candidates
        candidates.sort { $0.confidence > $1.confidence }
        return Array(candidates.prefix(3))  // Return top 3
    }

    // MARK: - Autocorrelation BPM Estimation (Improved)

    private static func estimateBPMFromAutocorrelationImproved(_ samples: [Float], sampleRate: Float) -> [(bpm: Float, confidence: Float)]? {
        let minLag = Int(sampleRate * 60.0 / maxBPM)
        let maxLag = Int(sampleRate * 60.0 / minBPM)

        guard maxLag < samples.count / 2 && minLag > 0 else {
            return nil
        }

        // Compute mean and subtract for zero-mean signal
        var mean: Float = 0
        vDSP_meanv(samples, 1, &mean, vDSP_Length(samples.count))

        var centered = samples
        var negativeMean = -mean
        vDSP_vsadd(samples, 1, &negativeMean, &centered, 1, vDSP_Length(samples.count))

        // Compute variance for normalization
        var variance: Float = 0
        vDSP_measqv(centered, 1, &variance, vDSP_Length(samples.count))

        guard variance > 0 else { return nil }

        // Compute normalized autocorrelation with improved normalization
        var autocorr = [Float](repeating: 0, count: maxLag + 1)

        centered.withUnsafeBufferPointer { ptr in
            for lag in minLag...maxLag {
                var sum: Float = 0
                let count = samples.count - lag
                
                guard count > 0 else { continue }

                // Compute dot product
                vDSP_dotpr(ptr.baseAddress!, 1, ptr.baseAddress! + lag, 1, &sum, vDSP_Length(count))

                // Improved normalization: divide by sqrt of variances
                let normFactor = variance * Float(count)
                autocorr[lag] = normFactor > 0 ? sum / sqrt(normFactor) : 0
            }
        }

        // Find peaks with improved peak picking
        var peaks: [(lag: Int, value: Float, prominence: Float)] = []

        // Compute local mean for prominence calculation
        let prominenceWindow = 10
        for lag in (minLag + prominenceWindow)..<(maxLag - prominenceWindow) {
            if autocorr[lag] > autocorr[lag - 1] && autocorr[lag] > autocorr[lag + 1] {
                // Compute prominence: value - mean of neighbors
                var neighborSum: Float = 0
                for i in (lag - prominenceWindow)...(lag + prominenceWindow) where i != lag {
                    neighborSum += autocorr[i]
                }
                let neighborMean = neighborSum / Float(2 * prominenceWindow)
                let prominence = autocorr[lag] - neighborMean
                
                if prominence > 0 {
                    peaks.append((lag, autocorr[lag], prominence))
                }
            }
        }

        guard !peaks.isEmpty else { return nil }

        // Sort by prominence and extract multiple candidates
        peaks.sort { $0.prominence > $1.prominence }
        
        var candidates: [(bpm: Float, confidence: Float)] = []
        let minBPMDistance: Float = 5.0
        
        for peak in peaks.prefix(10) {  // Consider top 10 peaks
            let bpm = 60.0 * sampleRate / Float(peak.lag)
            
            // Normalize to valid range (check harmonics)
            var normalizedBPM = bpm
            while normalizedBPM < minBPM && normalizedBPM > 0 { normalizedBPM *= 2 }
            while normalizedBPM > maxBPM { normalizedBPM /= 2 }
            
            if normalizedBPM >= minBPM && normalizedBPM <= maxBPM {
                // Check if too close to existing candidate
                let isDuplicate = candidates.contains { abs($0.bpm - normalizedBPM) < minBPMDistance }
                
                if !isDuplicate {
                    // Confidence based on prominence, normalized
                    let maxProminence = peaks.first?.prominence ?? 1.0
                    let confidence = min(1.0, peak.prominence / maxProminence)
                    candidates.append((normalizedBPM, confidence))
                }
            }
        }
        
        return candidates.isEmpty ? nil : Array(candidates.prefix(3))
    }
    
    // MARK: - Fourier Tempogram
    
    private static func estimateBPMFromFourierTempogram(_ samples: [Float], sampleRate: Float, logger: ((String) -> Void)?) -> [(bpm: Float, confidence: Float)]? {
        // Use windowed FFT to find periodic patterns in the onset strength envelope
        let windowSize = 4096  // Larger window for better frequency resolution
        let hopSize = 512
        let numWindows = (samples.count - windowSize) / hopSize + 1
        
        guard numWindows > 4 else { return nil }
        
        // Setup FFT
        let log2n = vDSP_Length(log2(Double(windowSize)))
        guard let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            return nil
        }
        defer { vDSP_destroy_fftsetup(fftSetup) }
        
        // Accumulate magnitude spectrum across windows
        var magnitudeSum = [Float](repeating: 0, count: windowSize / 2)
        
        var realp = [Float](repeating: 0, count: windowSize / 2)
        var imagp = [Float](repeating: 0, count: windowSize / 2)
        
        // Hanning window
        var window = [Float](repeating: 0, count: windowSize)
        vDSP_hann_window(&window, vDSP_Length(windowSize), Int32(vDSP_HANN_NORM))
        
        realp.withUnsafeMutableBufferPointer { realBuffer in
            imagp.withUnsafeMutableBufferPointer { imagBuffer in
                var splitComplex = DSPSplitComplex(
                    realp: realBuffer.baseAddress!,
                    imagp: imagBuffer.baseAddress!
                )

                samples.withUnsafeBufferPointer { samplesPtr in
                    for win in 0..<numWindows {
                        let startIdx = win * hopSize
                        guard startIdx + windowSize <= samples.count else { break }

                        // Apply window
                        var windowed = [Float](repeating: 0, count: windowSize)
                        vDSP_vmul(samplesPtr.baseAddress! + startIdx, 1, window, 1, &windowed, 1, vDSP_Length(windowSize))

                        // Copy to split complex
                        windowed.withUnsafeBufferPointer { windowedPtr in
                            vDSP_ctoz(UnsafePointer<DSPComplex>(OpaquePointer(windowedPtr.baseAddress!)), 2,
                                      &splitComplex, 1, vDSP_Length(windowSize / 2))
                        }

                        // FFT
                        vDSP_fft_zrip(fftSetup, &splitComplex, 1, log2n, FFTDirection(FFT_FORWARD))

                        // Accumulate magnitude
                        var magnitude = [Float](repeating: 0, count: windowSize / 2)
                        vDSP_zvmags(&splitComplex, 1, &magnitude, 1, vDSP_Length(windowSize / 2))

                        vDSP_vadd(magnitudeSum, 1, magnitude, 1, &magnitudeSum, 1, vDSP_Length(windowSize / 2))
                    }
                }
            }
        }
        
        // Average magnitude
        var divisor = Float(numWindows)
        vDSP_vsdiv(magnitudeSum, 1, &divisor, &magnitudeSum, 1, vDSP_Length(windowSize / 2))
        
        // Convert frequency bins to BPM
        // Frequency resolution: sampleRate / windowSize
        // BPM = frequency * 60
        let freqResolution = sampleRate / Float(windowSize)
        let minFreqBin = Int((minBPM / 60.0) / freqResolution)
        let maxFreqBin = min(Int((maxBPM / 60.0) / freqResolution), magnitudeSum.count - 1)
        
        guard minFreqBin < maxFreqBin else { return nil }
        
        // Find peaks in the magnitude spectrum
        var peaks: [(bpm: Float, confidence: Float)] = []
        
        for bin in (minFreqBin + 2)..<(maxFreqBin - 2) {
            if magnitudeSum[bin] > magnitudeSum[bin - 1] && magnitudeSum[bin] > magnitudeSum[bin + 1] &&
               magnitudeSum[bin] > magnitudeSum[bin - 2] && magnitudeSum[bin] > magnitudeSum[bin + 2] {
                
                let freq = Float(bin) * freqResolution
                var bpm = freq * 60.0
                
                // Normalize to valid range
                while bpm < minBPM { bpm *= 2 }
                while bpm > maxBPM { bpm /= 2 }
                
                if bpm >= minBPM && bpm <= maxBPM {
                    // Compute prominence
                    var neighborSum: Float = 0
                    for i in (bin - 5)...(bin + 5) where i != bin && i >= 0 && i < magnitudeSum.count {
                        neighborSum += magnitudeSum[i]
                    }
                    let neighborMean = neighborSum / 10.0
                    let prominence = magnitudeSum[bin] - neighborMean
                    
                    if prominence > 0 {
                        let maxMag = magnitudeSum[max(minFreqBin, 0)...min(maxFreqBin, magnitudeSum.count - 1)].max() ?? 1.0
                        let confidence = min(1.0, prominence / maxMag)
                        peaks.append((bpm, confidence))
                    }
                }
            }
        }
        
        // Sort by confidence and return top candidates
        peaks.sort { $0.confidence > $1.confidence }
        let minBPMDistance: Float = 5.0
        var filtered: [(bpm: Float, confidence: Float)] = []
        
        for peak in peaks {
            let isDuplicate = filtered.contains { abs($0.bpm - peak.bpm) < minBPMDistance }
            if !isDuplicate {
                filtered.append(peak)
            }
        }
        
        logger?("Fourier tempogram found \(filtered.count) candidates")
        return filtered.isEmpty ? nil : Array(filtered.prefix(3))
    }

    // MARK: - Consensus-based BPM Selection

    private static func selectBestBPMWithConsensus(
        candidates: [(bpm: Float, confidence: Float, method: String)],
        samples: [Float],
        sampleRate: Float,
        logger: ((String) -> Void)? = nil
    ) -> Int {
        guard !candidates.isEmpty else { return 0 }

        // Group candidates by similar BPM (within 3 BPM)
        var bpmGroups: [Float: [(bpm: Float, confidence: Float, method: String)]] = [:]
        
        for candidate in candidates {
            // Find existing group or create new one
            var foundGroup = false
            for (groupBPM, _) in bpmGroups {
                if abs(candidate.bpm - groupBPM) < 3.0 {
                    bpmGroups[groupBPM]?.append(candidate)
                    foundGroup = true
                    break
                }
            }
            if !foundGroup {
                bpmGroups[candidate.bpm] = [candidate]
            }
        }
        
        // Expand candidates with harmonics (half/double tempo)
        var expandedCandidates: [(bpm: Float, baseConfidence: Float, method: String, isHarmonic: Bool)] = []
        
        for (bpm, conf, method) in candidates {
            expandedCandidates.append((bpm, conf, method, false))
            
            // Add half tempo
            let halfBPM = bpm / 2
            if halfBPM >= minBPM && halfBPM <= maxBPM {
                expandedCandidates.append((halfBPM, conf * 0.6, method, true))
            }
            
            // Add double tempo
            let doubleBPM = bpm * 2
            if doubleBPM >= minBPM && doubleBPM <= maxBPM {
                expandedCandidates.append((doubleBPM, conf * 0.6, method, true))
            }
        }
        
        // Score each candidate
        var scoredCandidates: [(bpm: Float, score: Float)] = []
        
        for (bpm, baseConfidence, method, isHarmonic) in expandedCandidates {
            // Method weights (based on reliability)
            let methodWeight: Float
            switch method {
            case "onset": methodWeight = 1.2  // Onset detection is very reliable
            case "autocorr": methodWeight = 1.0
            case "fourier": methodWeight = 1.1  // Fourier tempogram is good
            case "flux_autocorr": methodWeight = 0.9
            default: methodWeight = 1.0
            }
            
            // Harmonic penalty
            let harmonicPenalty: Float = isHarmonic ? 0.8 : 1.0
            
            // Comb filter score
            let combScore = computeCombFilterScore(samples: samples, sampleRate: sampleRate, bpm: bpm)
            
            // Prior likelihood
            let priorScore = tempoLikelihood(bpm)
            
            // Consensus bonus: if multiple methods agree
            let consensusBonus: Float
            if let group = bpmGroups[bpm] {
                let uniqueMethods = Set(group.map { $0.method }).count
                consensusBonus = Float(uniqueMethods) * 0.3
            } else {
                consensusBonus = 0
            }
            
            // Total score
            let totalScore = baseConfidence * methodWeight * harmonicPenalty * 2.0 +
                           combScore * 1.5 +
                           priorScore * 0.5 +
                           consensusBonus
            
            scoredCandidates.append((bpm, totalScore))
            
            logger?("  BPM \(Int(bpm.rounded())) [\(method)\(isHarmonic ? ", harmonic" : "")]: conf=\(String(format: "%.2f", baseConfidence)) comb=\(String(format: "%.2f", combScore)) prior=\(String(format: "%.2f", priorScore)) consensus=\(String(format: "%.2f", consensusBonus)) total=\(String(format: "%.2f", totalScore))")
        }
        
        // Find best candidate
        scoredCandidates.sort { $0.score > $1.score }
        
        guard let best = scoredCandidates.first else { return 0 }
        
        // Final check: if multiple high-scoring candidates are close, prefer the one with more consensus
        let topCandidates = scoredCandidates.prefix(5)
        var bestBPM = best.bpm
        
        for candidate in topCandidates {
            if abs(candidate.bpm - best.bpm) < 5.0 && candidate.score > best.score * 0.9 {
                // Check consensus for this candidate
                let candidateConsensus = bpmGroups[candidate.bpm]?.count ?? 0
                let bestConsensus = bpmGroups[best.bpm]?.count ?? 0
                
                if candidateConsensus > bestConsensus {
                    bestBPM = candidate.bpm
                }
            }
        }
        
        return snapToCommonTempo(bestBPM)
    }

    private static func computeCombFilterScore(samples: [Float], sampleRate: Float, bpm: Float) -> Float {
        let beatPeriodSamples = sampleRate * 60.0 / bpm
        guard beatPeriodSamples > 1 else { return 0 }

        let numBeats = Int(Float(samples.count) / beatPeriodSamples)
        guard numBeats >= 4 else { return 0 }

        // Sum energy at beat positions across multiple phases
        var bestPhaseScore: Float = 0

        // Try different phase offsets
        let numPhases = 8
        for phase in 0..<numPhases {
            let phaseOffset = Float(phase) * beatPeriodSamples / Float(numPhases)
            var beatSum: Float = 0
            var beatCount: Float = 0

            var position = phaseOffset
            while Int(position) < samples.count {
                let idx = Int(position)
                if idx >= 0 && idx < samples.count {
                    beatSum += samples[idx]
                    beatCount += 1
                }
                position += beatPeriodSamples
            }

            if beatCount > 0 {
                let phaseScore = beatSum / beatCount
                bestPhaseScore = max(bestPhaseScore, phaseScore)
            }
        }

        // Compute overall mean for comparison
        var mean: Float = 0
        vDSP_meanv(samples, 1, &mean, vDSP_Length(samples.count))

        guard mean > 0 else { return 0 }

        // Score is ratio of beat energy to mean energy
        return bestPhaseScore / mean
    }

    private static func tempoLikelihood(_ bpm: Float) -> Float {
        let roundedTo5 = (bpm / 5).rounded() * 5
        let distanceFrom5 = abs(bpm - roundedTo5)

        var score: Float = 1.0

        if distanceFrom5 < 2 { score += 0.3 }

        let commonTempos: [Float] = [80, 90, 100, 110, 120, 125, 128, 130, 140, 150, 160, 170, 180]
        for common in commonTempos {
            if abs(bpm - common) < 3 {
                score += 0.5
                break
            }
        }

        return score
    }

    private static func snapToCommonTempo(_ bpm: Float) -> Int {
        // Just round to nearest integer - no snapping to preserve accuracy
        return Int(bpm.rounded())
    }
}
