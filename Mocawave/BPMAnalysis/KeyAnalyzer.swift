import Accelerate
import AVFoundation
import Foundation

/// Musical key analyzer implementing segment-based HPCP matching.
enum KeyAnalyzer {

    enum KeyError: Error {
        case invalidAudio
        case analysisUnavailable
        case silentAudio
    }

    enum KeyStatus: String, Codable, Sendable {
        case resolved
        case uncertain
    }

    enum UncertaintyReason: String, Codable, Sendable {
        case insufficientTonalFrames
        case lowAbsoluteScore
        case smallRunnerUpMargin
        case relativeMajorMinorTie
    }

    struct KeyAnalysisResult: Codable, Equatable, Sendable {
        let status: KeyStatus
        let key: String?
        let camelot: String?
        let confidence: Float
        let runnerUpKey: String?
        let uncertaintyReason: UncertaintyReason?

        init(
            status: KeyStatus,
            key: String?,
            camelot: String?,
            confidence: Float,
            runnerUpKey: String?,
            uncertaintyReason: UncertaintyReason?
        ) {
            self.status = status
            self.key = key
            self.camelot = camelot
            self.confidence = confidence
            self.runnerUpKey = runnerUpKey
            self.uncertaintyReason = uncertaintyReason
        }

        var isResolved: Bool {
            status == .resolved
        }
    }

    private struct SegmentWindow {
        let startTime: Double
        let duration: Double
    }

    private struct SpectralPeak {
        let frequency: Float
        let magnitude: Float
    }

    private struct FrameSnapshot {
        let peaks: [SpectralPeak]
        let rms: Float
        let flatness: Float
    }

    private struct SegmentVote {
        let scoreSums: [Float]
        let winnerWeightSums: [Float]
        let totalWeight: Float
        let tonalFrames: Int
    }

    private struct KeyCandidate {
        let keyName: String
        let camelot: String
        let pitchClass: Int
        let isMajor: Bool
    }

    private struct ProfileFamily {
        let name: String
        let profiles: [[Float]]
    }

    nonisolated private static let targetSampleRate: Double = 22_050
    nonisolated private static let windowSize = 8_192
    nonisolated private static let hopSize = 2_048
    nonisolated private static let segmentDuration: Double = 12
    nonisolated private static let shortTrackFullAnalysisThreshold: Double = 18
    nonisolated private static let maxSegments = 6
    nonisolated private static let excludedEdgeFraction: Double = 0.05
    nonisolated private static let minFrequency: Float = 65
    nonisolated private static let maxFrequency: Float = 5_000
    nonisolated private static let minTonalFrames = 24
    nonisolated private static let minimumResolvedScore: Float = 0.5
    nonisolated private static let minimumRunnerUpMargin: Float = 0.03
    nonisolated private static let minimumRelativeMargin: Float = 0.015
    nonisolated private static let minimumConfidenceForAmbiguousResolution: Float = 0.47
    nonisolated private static let minimumWinnerShareForAmbiguousResolution: Float = 0.16
    nonisolated private static let silenceThreshold: Float = 1e-5
    nonisolated private static let maxPeakCountPerFrame = 24
    nonisolated private static let spectralFlatnessThreshold: Float = 0.55
    nonisolated private static let minimumTopThreePitchShare: Float = 0.45

    nonisolated private static let pitchClasses = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]

    nonisolated private static let camelotMap: [[String]] = [
        ["5A", "8B"],
        ["12A", "3B"],
        ["7A", "10B"],
        ["2A", "5B"],
        ["9A", "12B"],
        ["4A", "7B"],
        ["11A", "2B"],
        ["6A", "9B"],
        ["1A", "4B"],
        ["8A", "11B"],
        ["3A", "6B"],
        ["10A", "1B"],
    ]

    nonisolated private static let krumhanslMajorProfile: [Float] = [
        6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88
    ]

    nonisolated private static let krumhanslMinorProfile: [Float] = [
        6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17
    ]

    nonisolated private static let temperleyMajorProfile: [Float] = [
        0.748, 0.060, 0.488, 0.082, 0.670, 0.460, 0.096, 0.715, 0.104, 0.366, 0.057, 0.400
    ]

    nonisolated private static let temperleyMinorProfile: [Float] = [
        0.712, 0.084, 0.474, 0.618, 0.049, 0.460, 0.105, 0.747, 0.404, 0.067, 0.133, 0.330
    ]

    nonisolated private static let candidates: [KeyCandidate] = {
        var all: [KeyCandidate] = []
        for pitchClass in 0..<12 {
            all.append(KeyCandidate(
                keyName: pitchClasses[pitchClass] + " Major",
                camelot: camelotMap[pitchClass][1],
                pitchClass: pitchClass,
                isMajor: true
            ))
        }
        for pitchClass in 0..<12 {
            all.append(KeyCandidate(
                keyName: pitchClasses[pitchClass] + " Minor",
                camelot: camelotMap[pitchClass][0],
                pitchClass: pitchClass,
                isMajor: false
            ))
        }
        return all
    }()

    nonisolated private static let profileFamilies: [ProfileFamily] = [
        ProfileFamily(
            name: "Krumhansl",
            profiles: buildProfileFamily(major: krumhanslMajorProfile, minor: krumhanslMinorProfile)
        ),
        ProfileFamily(
            name: "Temperley",
            profiles: buildProfileFamily(major: temperleyMajorProfile, minor: temperleyMinorProfile)
        ),
    ]

    nonisolated static func analyze(url: URL, logger: ((String) -> Void)? = nil) throws -> KeyAnalysisResult {
        logger?("[Key] Loading audio...")

        let file = try AVAudioFile(forReading: url)
        let sourceSampleRate = file.processingFormat.sampleRate
        guard sourceSampleRate > 0, file.length > 0 else {
            throw KeyError.invalidAudio
        }

        let duration = Double(file.length) / sourceSampleRate
        let segments = buildSegments(totalDuration: duration)
        logger?("[Key] Segments: \(segments.count) x \(String(format: "%.1f", segmentDuration))s target windows")

        let halfWindow = windowSize / 2
        let bandStartBin = max(1, Int(floor(Double(minFrequency) * Double(windowSize) / targetSampleRate)))
        let bandEndBin = min(halfWindow - 2, Int(ceil(Double(maxFrequency) * Double(windowSize) / targetSampleRate)))

        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        )
        guard let targetFormat else {
            throw KeyError.analysisUnavailable
        }

        let log2n = vDSP_Length(log2(Double(windowSize)))
        guard let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            throw KeyError.analysisUnavailable
        }
        defer { vDSP_destroy_fftsetup(fftSetup) }

        var window = [Float](repeating: 0, count: windowSize)
        vDSP_hann_window(&window, vDSP_Length(windowSize), Int32(vDSP_HANN_NORM))

        var combinedScores = [Float](repeating: 0, count: candidates.count)
        var combinedWinnerShares = [Float](repeating: 0, count: candidates.count)
        var totalWeight: Float = 0
        var totalTonalFrames = 0
        var sawNonSilentAudio = false

        for (index, segment) in segments.enumerated() {
            let samples = try readSegment(
                from: file,
                startTime: segment.startTime,
                duration: segment.duration,
                targetFormat: targetFormat
            )
            guard !samples.isEmpty else { continue }

            if samples.contains(where: { abs($0) > silenceThreshold }) {
                sawNonSilentAudio = true
            }

            logger?("[Key] Segment \(index + 1)/\(segments.count): \(String(format: "%.1f", segment.startTime))s → \(String(format: "%.1f", segment.startTime + segment.duration))s")
            let vote = analyzeSegment(
                samples: samples,
                fftSetup: fftSetup,
                window: window,
                bandStartBin: bandStartBin,
                bandEndBin: bandEndBin,
                logger: logger
            )

            guard vote.totalWeight > 0 else { continue }
            for candidateIndex in combinedScores.indices {
                combinedScores[candidateIndex] += vote.scoreSums[candidateIndex]
                combinedWinnerShares[candidateIndex] += vote.winnerWeightSums[candidateIndex]
            }
            totalWeight += vote.totalWeight
            totalTonalFrames += vote.tonalFrames
        }

        guard sawNonSilentAudio else {
            throw KeyError.silentAudio
        }

        let result = finalizeResult(
            combinedScores: combinedScores,
            combinedWinnerShares: combinedWinnerShares,
            totalWeight: totalWeight,
            tonalFrames: totalTonalFrames,
            logger: logger
        )
        logger?("[Key] Result: \(result.key ?? "UNCERTAIN") confidence: \(String(format: "%.2f", result.confidence))")
        return result
    }

    nonisolated private static func buildSegments(totalDuration: Double) -> [SegmentWindow] {
        guard totalDuration > 0 else { return [] }

        if totalDuration < shortTrackFullAnalysisThreshold {
            return [SegmentWindow(startTime: 0, duration: totalDuration)]
        }

        let usableStart = totalDuration * excludedEdgeFraction
        let usableEnd = totalDuration * (1 - excludedEdgeFraction)
        let usableDuration = max(segmentDuration, usableEnd - usableStart)
        let segmentCount = min(maxSegments, max(1, Int(ceil(usableDuration / segmentDuration))))
        let actualSegmentDuration = min(segmentDuration, usableDuration)
        let firstCenter = usableStart + actualSegmentDuration / 2
        let lastCenter = usableEnd - actualSegmentDuration / 2

        if segmentCount == 1 || lastCenter <= firstCenter {
            return [SegmentWindow(
                startTime: max(0, min(totalDuration - actualSegmentDuration, usableStart)),
                duration: actualSegmentDuration
            )]
        }

        let stride = (lastCenter - firstCenter) / Double(segmentCount - 1)
        return (0..<segmentCount).map { index in
            let center = firstCenter + Double(index) * stride
            let start = max(0, min(totalDuration - actualSegmentDuration, center - actualSegmentDuration / 2))
            return SegmentWindow(startTime: start, duration: actualSegmentDuration)
        }
    }

    nonisolated private static func readSegment(
        from file: AVAudioFile,
        startTime: Double,
        duration: Double,
        targetFormat: AVAudioFormat
    ) throws -> [Float] {
        let sourceSampleRate = file.processingFormat.sampleRate
        let startFrame = AVAudioFramePosition(startTime * sourceSampleRate)
        let requestedFrameCount = AVAudioFrameCount(duration * sourceSampleRate)
        let clampedStartFrame = min(max(0, startFrame), file.length)
        file.framePosition = clampedStartFrame

        let remainingFrames = AVAudioFrameCount(max(0, file.length - clampedStartFrame))
        let sourceFrameCount = min(requestedFrameCount, remainingFrames)
        guard sourceFrameCount > 0,
              let sourceBuffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: sourceFrameCount
              ) else {
            throw KeyError.invalidAudio
        }

        try file.read(into: sourceBuffer, frameCount: sourceFrameCount)
        guard sourceBuffer.frameLength > 0 else {
            throw KeyError.invalidAudio
        }

        guard let converter = AVAudioConverter(from: file.processingFormat, to: targetFormat) else {
            throw KeyError.analysisUnavailable
        }

        let outputCapacity = AVAudioFrameCount(
            ceil(Double(sourceBuffer.frameLength) * targetSampleRate / file.processingFormat.sampleRate)
        ) + 512
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: outputCapacity
        ) else {
            throw KeyError.analysisUnavailable
        }

        var suppliedBuffer = false
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            if suppliedBuffer {
                outStatus.pointee = .endOfStream
                return nil
            }
            suppliedBuffer = true
            outStatus.pointee = .haveData
            return sourceBuffer
        }

        if conversionError != nil || (status != .haveData && status != .endOfStream) {
            throw KeyError.analysisUnavailable
        }

        guard let channelData = outputBuffer.floatChannelData else {
            throw KeyError.analysisUnavailable
        }

        let frameCount = Int(outputBuffer.frameLength)
        guard frameCount > 0 else {
            throw KeyError.invalidAudio
        }
        return Array(UnsafeBufferPointer(start: channelData[0], count: frameCount))
    }

    nonisolated private static func analyzeSegment(
        samples: [Float],
        fftSetup: FFTSetup,
        window: [Float],
        bandStartBin: Int,
        bandEndBin: Int,
        logger: ((String) -> Void)?
    ) -> SegmentVote {
        guard samples.count >= windowSize else {
            return SegmentVote(
                scoreSums: [Float](repeating: 0, count: candidates.count),
                winnerWeightSums: [Float](repeating: 0, count: candidates.count),
                totalWeight: 0,
                tonalFrames: 0
            )
        }

        let halfWindow = windowSize / 2
        let frameCount = max(0, (samples.count - windowSize) / hopSize + 1)
        guard frameCount > 0 else {
            return SegmentVote(
                scoreSums: [Float](repeating: 0, count: candidates.count),
                winnerWeightSums: [Float](repeating: 0, count: candidates.count),
                totalWeight: 0,
                tonalFrames: 0
            )
        }

        var snapshots: [FrameSnapshot] = []
        snapshots.reserveCapacity(frameCount)

        var tuningX: Float = 0
        var tuningY: Float = 0
        var rmsValues: [Float] = []
        rmsValues.reserveCapacity(frameCount)

        var real = [Float](repeating: 0, count: halfWindow)
        var imag = [Float](repeating: 0, count: halfWindow)
        var windowed = [Float](repeating: 0, count: windowSize)
        var magnitudes = [Float](repeating: 0, count: halfWindow)

        real.withUnsafeMutableBufferPointer { realPointer in
            imag.withUnsafeMutableBufferPointer { imagPointer in
                var splitComplex = DSPSplitComplex(
                    realp: realPointer.baseAddress!,
                    imagp: imagPointer.baseAddress!
                )

                samples.withUnsafeBufferPointer { samplePointer in
                    for frameIndex in 0..<frameCount {
                        let offset = frameIndex * hopSize
                        guard offset + windowSize <= samples.count else { break }

                        vDSP_vmul(
                            samplePointer.baseAddress! + offset, 1,
                            window, 1,
                            &windowed, 1,
                            vDSP_Length(windowSize)
                        )

                        var rms: Float = 0
                        vDSP_rmsqv(windowed, 1, &rms, vDSP_Length(windowSize))
                        rmsValues.append(rms)

                        windowed.withUnsafeBufferPointer { windowedPointer in
                            vDSP_ctoz(
                                UnsafePointer<DSPComplex>(OpaquePointer(windowedPointer.baseAddress!)),
                                2,
                                &splitComplex,
                                1,
                                vDSP_Length(halfWindow)
                            )
                        }

                        let log2n = vDSP_Length(log2(Double(windowSize)))
                        vDSP_fft_zrip(fftSetup, &splitComplex, 1, log2n, FFTDirection(FFT_FORWARD))
                        vDSP_zvabs(&splitComplex, 1, &magnitudes, 1, vDSP_Length(halfWindow))

                        let flatness = spectralFlatness(
                            magnitudes: magnitudes,
                            startBin: bandStartBin,
                            endBin: bandEndBin
                        )
                        let peaks = detectPeaks(
                            magnitudes: magnitudes,
                            startBin: bandStartBin,
                            endBin: bandEndBin
                        )
                        for peak in peaks {
                            let midiPitch = 69 + 12 * log2(peak.frequency / 440)
                            let nearest = midiPitch.rounded()
                            let deviation = midiPitch - nearest
                            let angle = deviation * 2 * .pi
                            let weight = sqrt(max(peak.magnitude, 1e-9))
                            tuningX += cos(angle) * weight
                            tuningY += sin(angle) * weight
                        }

                        snapshots.append(FrameSnapshot(peaks: peaks, rms: rms, flatness: flatness))
                    }
                }
            }
        }

        guard !snapshots.isEmpty, !rmsValues.isEmpty else {
            return SegmentVote(
                scoreSums: [Float](repeating: 0, count: candidates.count),
                winnerWeightSums: [Float](repeating: 0, count: candidates.count),
                totalWeight: 0,
                tonalFrames: 0
            )
        }

        let tuningOffset = tuningOffsetSemitones(x: tuningX, y: tuningY)
        let energyFloor = rmsFloor(rmsValues: rmsValues)
        logger?("[Key]   tuning offset: \(String(format: "%.3f", tuningOffset * 100)) cents; rms floor: \(String(format: "%.5f", energyFloor))")

        var scoreSums = [Float](repeating: 0, count: candidates.count)
        var winnerWeightSums = [Float](repeating: 0, count: candidates.count)
        var totalWeight: Float = 0
        var tonalFrames = 0
        let maxRMS = max(rmsValues.max() ?? energyFloor, energyFloor)

        for snapshot in snapshots {
            guard snapshot.rms >= energyFloor else { continue }
            guard snapshot.flatness <= spectralFlatnessThreshold else { continue }

            let hpcp = buildHPCP(from: snapshot.peaks, tuningOffset: tuningOffset)
            guard let topThreeShare = topThreePitchShare(hpcp), topThreeShare >= minimumTopThreePitchShare else {
                continue
            }

            let scores = scoreFrame(hpcp: hpcp)
            guard let winnerIndex = argmax(scores) else { continue }

            let rmsWeight = sqrt(max(snapshot.rms, 1e-6) / maxRMS)
            let tonalWeight = min(1, max(0.1, (topThreeShare - 0.25) / 0.55))
            let flatnessWeight = max(0.1, 1 - snapshot.flatness)
            let frameWeight = rmsWeight * tonalWeight * flatnessWeight
            guard frameWeight > 0 else { continue }

            for index in scoreSums.indices {
                scoreSums[index] += scores[index] * frameWeight
            }
            winnerWeightSums[winnerIndex] += frameWeight
            totalWeight += frameWeight
            tonalFrames += 1
        }

        return SegmentVote(
            scoreSums: scoreSums,
            winnerWeightSums: winnerWeightSums,
            totalWeight: totalWeight,
            tonalFrames: tonalFrames
        )
    }

    nonisolated private static func detectPeaks(
        magnitudes: [Float],
        startBin: Int,
        endBin: Int
    ) -> [SpectralPeak] {
        guard startBin + 1 < endBin else { return [] }

        let bandSlice = magnitudes[startBin...endBin]
        let bandMax = bandSlice.max() ?? 0
        let bandMean = bandSlice.reduce(0, +) / Float(max(1, bandSlice.count))
        let threshold = max(bandMax * 0.18, bandMean * 2.5, 1e-6)

        var peaks: [SpectralPeak] = []
        peaks.reserveCapacity(maxPeakCountPerFrame)

        for bin in (startBin + 1)..<(endBin - 1) {
            let left = magnitudes[bin - 1]
            let center = magnitudes[bin]
            let right = magnitudes[bin + 1]

            guard center >= threshold, center > left, center >= right else { continue }

            let denominator = left - 2 * center + right
            var fractionalOffset: Float = 0
            if abs(denominator) > 1e-12 {
                fractionalOffset = 0.5 * (left - right) / denominator
                fractionalOffset = min(max(fractionalOffset, -1), 1)
            }

            let refinedBin = Float(bin) + fractionalOffset
            let refinedFrequency = refinedBin * Float(targetSampleRate) / Float(windowSize)
            let refinedMagnitude = max(center - 0.25 * (left - right) * fractionalOffset, 0)

            guard refinedFrequency >= minFrequency, refinedFrequency <= maxFrequency else { continue }
            peaks.append(SpectralPeak(frequency: refinedFrequency, magnitude: refinedMagnitude))
        }

        peaks.sort { $0.magnitude > $1.magnitude }
        if peaks.count > maxPeakCountPerFrame {
            peaks.removeLast(peaks.count - maxPeakCountPerFrame)
        }
        return peaks
    }

    nonisolated private static func buildHPCP(from peaks: [SpectralPeak], tuningOffset: Float) -> [Float] {
        var chroma = [Float](repeating: 0, count: 12)

        for peak in peaks {
            let midiPitch = 69 + 12 * log2(peak.frequency / 440) - tuningOffset
            let pitchClassPosition = positiveModulo(midiPitch, modulus: 12)
            let nearestPitchClass = Int(round(pitchClassPosition)) % 12
            let harmonicPenalty = max(1, sqrt(peak.frequency / minFrequency))
            let baseWeight = pow(max(peak.magnitude, 1e-9), 0.6) / harmonicPenalty

            for offset in -1...1 {
                let pitchClassIndex = (nearestPitchClass + offset + 12) % 12
                let target = Float(pitchClassIndex)
                let distance = circularDistance(value: pitchClassPosition, target: target, modulus: 12)
                guard distance <= 1 else { continue }
                let spreadWeight = pow(cos(distance * .pi / 2), 2)
                chroma[pitchClassIndex] += baseWeight * spreadWeight
            }
        }

        return normalizeToUnitSum(chroma)
    }

    nonisolated private static func scoreFrame(hpcp: [Float]) -> [Float] {
        let normalizedHPCP = normalizeZeroMean(hpcp)
        let triadScores = candidates.map { candidate in
            let root = candidate.pitchClass
            let third = (candidate.pitchClass + (candidate.isMajor ? 4 : 3)) % 12
            let fifth = (candidate.pitchClass + 7) % 12
            let triadEnergy = hpcp[root] + hpcp[third] + 0.8 * hpcp[fifth]
            return triadEnergy
        }
        let normalizedTriads = minMaxNormalize(triadScores)
        let modeScores = candidates.map { candidate in
            let desiredThird = (candidate.pitchClass + (candidate.isMajor ? 4 : 3)) % 12
            let oppositeThird = (candidate.pitchClass + (candidate.isMajor ? 3 : 4)) % 12
            return max(0, hpcp[desiredThird] - hpcp[oppositeThird])
        }
        let normalizedModes = minMaxNormalize(modeScores)

        var familyScores: [[Float]] = []
        familyScores.reserveCapacity(profileFamilies.count)

        for family in profileFamilies {
            var scores = [Float](repeating: 0, count: candidates.count)
            for index in candidates.indices {
                var dot: Float = 0
                vDSP_dotpr(
                    normalizedHPCP, 1,
                    family.profiles[index], 1,
                    &dot,
                    vDSP_Length(12)
                )
                scores[index] = dot
            }
            familyScores.append(minMaxNormalize(scores))
        }

        var combined = [Float](repeating: 0, count: candidates.count)
        for index in combined.indices {
            let familyAverage = familyScores.reduce(0) { partial, scores in
                partial + scores[index]
            } / Float(familyScores.count)
            combined[index] = min(1, familyAverage + normalizedTriads[index] * 0.08 + normalizedModes[index] * 0.06)
        }
        return combined
    }

    nonisolated private static func finalizeResult(
        combinedScores: [Float],
        combinedWinnerShares: [Float],
        totalWeight: Float,
        tonalFrames: Int,
        logger: ((String) -> Void)?
    ) -> KeyAnalysisResult {
        guard tonalFrames > 0, totalWeight > 0 else {
            return KeyAnalysisResult(
                status: .uncertain,
                key: nil,
                camelot: nil,
                confidence: 0,
                runnerUpKey: nil,
                uncertaintyReason: .insufficientTonalFrames
            )
        }

        let averageScores = combinedScores.map { $0 / totalWeight }
        let sortedIndices = averageScores.indices.sorted { lhs, rhs in
            averageScores[lhs] > averageScores[rhs]
        }
        guard let bestIndex = sortedIndices.first else {
            return KeyAnalysisResult(
                status: .uncertain,
                key: nil,
                camelot: nil,
                confidence: 0,
                runnerUpKey: nil,
                uncertaintyReason: .insufficientTonalFrames
            )
        }

        let runnerUpIndex = sortedIndices.dropFirst().first
        let bestScore = averageScores[bestIndex]
        let runnerUpScore = runnerUpIndex.map { averageScores[$0] } ?? 0
        let runnerUpMargin = bestScore - runnerUpScore
        let winnerShare = combinedWinnerShares[bestIndex] / totalWeight
        let relativeIndex = relativeKeyIndex(for: bestIndex)
        let relativeMargin = bestScore - averageScores[relativeIndex]
        let confidence = confidenceScore(
            bestScore: bestScore,
            runnerUpMargin: runnerUpMargin,
            winnerShare: winnerShare
        )
        let hasStrongOverallEvidence =
            confidence >= minimumConfidenceForAmbiguousResolution ||
            bestScore >= 0.64 ||
            winnerShare >= minimumWinnerShareForAmbiguousResolution
        let extremelySmallRunnerUpMargin = runnerUpMargin < minimumRunnerUpMargin * 0.5
        let extremelySmallRelativeMargin = relativeMargin < minimumRelativeMargin * 0.5

        let topSummary = sortedIndices.prefix(3).map { index in
            "\(candidates[index].keyName)=\(String(format: "%.3f", averageScores[index]))"
        }.joined(separator: ", ")
        logger?("[Key] Top scores: \(topSummary)")

        let uncertaintyReason: UncertaintyReason?
        if tonalFrames < minTonalFrames {
            uncertaintyReason = .insufficientTonalFrames
        } else if bestScore < minimumResolvedScore {
            uncertaintyReason = .lowAbsoluteScore
        } else if extremelySmallRelativeMargin {
            uncertaintyReason = .relativeMajorMinorTie
        } else if relativeMargin < minimumRelativeMargin && !hasStrongOverallEvidence {
            uncertaintyReason = .relativeMajorMinorTie
        } else if extremelySmallRunnerUpMargin && !hasStrongOverallEvidence {
            uncertaintyReason = .smallRunnerUpMargin
        } else if runnerUpMargin < minimumRunnerUpMargin && !hasStrongOverallEvidence && winnerShare < minimumWinnerShareForAmbiguousResolution {
            uncertaintyReason = .smallRunnerUpMargin
        } else {
            uncertaintyReason = nil
        }

        if let uncertaintyReason {
            logger?("[Key] Uncertain: \(uncertaintyReason.rawValue), best=\(candidates[bestIndex].keyName), runnerUpMargin=\(String(format: "%.3f", runnerUpMargin)), relativeMargin=\(String(format: "%.3f", relativeMargin))")
            return KeyAnalysisResult(
                status: .uncertain,
                key: nil,
                camelot: nil,
                confidence: confidence,
                runnerUpKey: runnerUpIndex.map { candidates[$0].keyName },
                uncertaintyReason: uncertaintyReason
            )
        }

        let winningCandidate = candidates[bestIndex]
        return KeyAnalysisResult(
            status: .resolved,
            key: winningCandidate.keyName,
            camelot: winningCandidate.camelot,
            confidence: confidence,
            runnerUpKey: runnerUpIndex.map { candidates[$0].keyName },
            uncertaintyReason: nil
        )
    }

    nonisolated private static func confidenceScore(
        bestScore: Float,
        runnerUpMargin: Float,
        winnerShare: Float
    ) -> Float {
        let marginComponent = min(1, max(0, runnerUpMargin / 0.2))
        let confidence = bestScore * 0.5 + marginComponent * 0.3 + winnerShare * 0.2
        return min(1, max(0, confidence))
    }

    nonisolated private static func buildProfileFamily(major: [Float], minor: [Float]) -> [[Float]] {
        var profiles: [[Float]] = []
        profiles.reserveCapacity(24)

        let majorProfile = normalizeZeroMean(major)
        let minorProfile = normalizeZeroMean(minor)

        for shift in 0..<12 {
            profiles.append(circularShift(majorProfile, by: shift))
        }
        for shift in 0..<12 {
            profiles.append(circularShift(minorProfile, by: shift))
        }
        return profiles
    }

    nonisolated private static func normalizeZeroMean(_ values: [Float]) -> [Float] {
        guard !values.isEmpty else { return values }
        let mean = values.reduce(0, +) / Float(values.count)
        let centered = values.map { $0 - mean }
        var norm: Float = 0
        vDSP_svesq(centered, 1, &norm, vDSP_Length(centered.count))
        norm = sqrt(norm)
        guard norm > 0 else { return centered }
        return centered.map { $0 / norm }
    }

    nonisolated private static func normalizeToUnitSum(_ values: [Float]) -> [Float] {
        let total = values.reduce(0, +)
        guard total > 0 else { return values }
        return values.map { $0 / total }
    }

    nonisolated private static func circularShift(_ profile: [Float], by shift: Int) -> [Float] {
        guard !profile.isEmpty else { return profile }
        var shifted = [Float](repeating: 0, count: profile.count)
        for index in profile.indices {
            shifted[index] = profile[(index - shift + profile.count) % profile.count]
        }
        return shifted
    }

    nonisolated private static func spectralFlatness(
        magnitudes: [Float],
        startBin: Int,
        endBin: Int
    ) -> Float {
        guard startBin < endBin else { return 1 }
        let epsilon: Float = 1e-9
        let slice = magnitudes[startBin...endBin]
        let arithmeticMean = slice.reduce(0, +) / Float(max(1, slice.count))
        guard arithmeticMean > 0 else { return 1 }
        let logMean = slice.reduce(0) { partial, value in
            partial + log(max(value, epsilon))
        } / Float(slice.count)
        let geometricMean = exp(logMean)
        return geometricMean / arithmeticMean
    }

    nonisolated private static func tuningOffsetSemitones(x: Float, y: Float) -> Float {
        let magnitude = sqrt(x * x + y * y)
        guard magnitude > 1e-4 else { return 0 }
        return atan2(y, x) / (2 * .pi)
    }

    nonisolated private static func rmsFloor(rmsValues: [Float]) -> Float {
        let sorted = rmsValues.sorted()
        guard let maxRMS = sorted.last else { return silenceThreshold }
        let percentileIndex = Int(Float(max(0, sorted.count - 1)) * 0.3)
        let percentile = sorted[min(sorted.count - 1, percentileIndex)]
        return max(silenceThreshold, min(maxRMS * 0.35, percentile * 0.75))
    }

    nonisolated private static func topThreePitchShare(_ chroma: [Float]) -> Float? {
        let total = chroma.reduce(0, +)
        guard total > 0 else { return nil }
        let topThree = chroma.sorted(by: >).prefix(3).reduce(0, +)
        return topThree / total
    }

    nonisolated private static func minMaxNormalize(_ values: [Float]) -> [Float] {
        guard let minimum = values.min(), let maximum = values.max(), maximum > minimum else {
            return [Float](repeating: 0, count: values.count)
        }
        let span = maximum - minimum
        return values.map { ($0 - minimum) / span }
    }

    nonisolated private static func argmax(_ values: [Float]) -> Int? {
        guard !values.isEmpty else { return nil }
        var bestIndex = 0
        var bestValue = values[0]
        for index in values.indices.dropFirst() where values[index] > bestValue {
            bestIndex = index
            bestValue = values[index]
        }
        return bestIndex
    }

    nonisolated private static func relativeKeyIndex(for candidateIndex: Int) -> Int {
        let candidate = candidates[candidateIndex]
        if candidate.isMajor {
            return 12 + ((candidate.pitchClass + 9) % 12)
        }
        return (candidate.pitchClass + 3) % 12
    }

    nonisolated private static func positiveModulo(_ value: Float, modulus: Float) -> Float {
        let result = value.truncatingRemainder(dividingBy: modulus)
        return result >= 0 ? result : result + modulus
    }

    nonisolated private static func circularDistance(value: Float, target: Float, modulus: Float) -> Float {
        let diff = abs(value - target)
        return min(diff, modulus - diff)
    }
}
