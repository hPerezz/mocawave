import Accelerate
import AVFoundation

enum WaveformAnalyzer {
    enum WaveformError: LocalizedError {
        case audioFileOpen(url: URL, underlying: NSError)
        case audioRead(
            url: URL,
            framePosition: AVAudioFramePosition,
            chunkIndex: Int,
            processing: String,
            file: String,
            underlying: NSError
        )
        case unsupportedProcessingFormat(processing: String, file: String)
        case readBufferAllocationFailed(format: String, frameCapacity: AVAudioFrameCount)
        case missingChannelData(format: String)
        case fftSetupFailed
        case conversionFailed
        case invalidDuration

        var errorDescription: String? {
            switch self {
            case let .audioFileOpen(url, underlying):
                return "audio file open failed for \(url.lastPathComponent) [\(underlying.domain) \(underlying.code)]: \(underlying.localizedDescription)"
            case let .audioRead(url, framePosition, chunkIndex, processing, file, underlying):
                return "audio read failed for \(url.lastPathComponent) at frame=\(framePosition) chunk=\(chunkIndex) processing=\(processing) file=\(file) [\(underlying.domain) \(underlying.code)]: \(underlying.localizedDescription)"
            case let .unsupportedProcessingFormat(processing, file):
                return "unsupported processing format: processing=\(processing), file=\(file)"
            case let .readBufferAllocationFailed(format, frameCapacity):
                return "buffer allocation failed for format=\(format), frameCapacity=\(frameCapacity)"
            case let .missingChannelData(format):
                return "missing PCM channel data for format=\(format)"
            case .fftSetupFailed:
                return "FFT setup failed"
            case .conversionFailed:
                return "audio conversion failed"
            case .invalidDuration:
                return "invalid audio duration"
            }
        }
    }

    // MARK: - Audio Quality Types

    enum EstimatedBitrate: String, Codable, Sendable {
        case kbps128 = "128k"
        case kbps192 = "192k"
        case kbps256 = "256k"
        case kbps320 = "320k"
        case lossless = "Lossless"
    }

    struct AudioQualityResult: Codable, Sendable {
        let maxEffectiveFrequency: Float
        let highFreqEnergyRatio: Float
        let cutoffSharpness: Float
        let estimatedBitrate: EstimatedBitrate
    }

    struct ColoredWaveformData: Codable, Equatable, Sendable {
        struct Column: Codable, Equatable, Sendable {
            var height: Float
            var red: Float
            var green: Float
            var blue: Float
        }

        var columns: [Column]
    }

    // FFT configuration
    nonisolated private static let fftSize = 4096
    nonisolated private static let bassMaxHz: Float = 250.0
    nonisolated private static let bassMinHz: Float = 20.0
    nonisolated private static let midMaxHz: Float = 4000.0
    nonisolated private static let highMaxHz: Float = 16000.0
    nonisolated private static let coloredWaveformHeightBassWeight: Float = 2.8
    nonisolated private static let coloredWaveformHeightMidWeight: Float = 0.55
    nonisolated private static let coloredWaveformHeightHighWeight: Float = 0.28
    nonisolated private static let coloredWaveformBassPresenceFloor: Float = 0.28
    nonisolated private static let coloredWaveformBassPresenceExponent: Float = 0.35
    nonisolated private static let coloredWaveformColorBassWeight: Float = 2.6
    nonisolated private static let coloredWaveformColorMidWeight: Float = 0.9
    nonisolated private static let coloredWaveformColorHighWeight: Float = 0.75
    nonisolated private static let coloredWaveformRedDominanceThreshold: Float = 0.42
    nonisolated private static let coloredWaveformPureRedThreshold: Float = 0.58
    nonisolated private static let coloredWaveformRedDominanceBoost: Float = 1.8
    nonisolated private static let coloredWaveformGreenSuppression: Float = 0.55
    nonisolated private static let coloredWaveformBlueSuppression: Float = 0.65

    private final class MonoPCMDecoder {
        let totalFrames: Int64
        let sampleRate: Float

        private let sourceURL: URL
        private let audioFile: AVAudioFile
        private let readBuffer: AVAudioPCMBuffer
        private var monoScratch: [Float]

        init(url: URL, bufferSize: AVAudioFrameCount = 4096) throws {
            let audioFile: AVAudioFile
            do {
                audioFile = try AVAudioFile(
                    forReading: url,
                    commonFormat: .pcmFormatFloat32,
                    interleaved: false
                )
            } catch {
                throw WaveformError.audioFileOpen(url: url, underlying: error as NSError)
            }

            let processingFormat = audioFile.processingFormat
            guard processingFormat.commonFormat == .pcmFormatFloat32,
                  !processingFormat.isInterleaved else {
                throw WaveformError.unsupportedProcessingFormat(
                    processing: Self.describe(format: processingFormat),
                    file: Self.describe(format: audioFile.fileFormat)
                )
            }
            guard let readBuffer = AVAudioPCMBuffer(pcmFormat: processingFormat, frameCapacity: bufferSize) else {
                throw WaveformError.readBufferAllocationFailed(
                    format: Self.describe(format: processingFormat),
                    frameCapacity: bufferSize
                )
            }

            self.sourceURL = url
            self.audioFile = audioFile
            self.readBuffer = readBuffer
            self.monoScratch = [Float](repeating: 0, count: Int(bufferSize))
            self.totalFrames = max(Int64(audioFile.length), 0)
            self.sampleRate = Float(processingFormat.sampleRate)
        }

        func decode(_ body: (UnsafePointer<Float>, Int) throws -> Void) throws {
            var chunkIndex = 0
            while true {
                try Task.checkCancellation()
                let remainingFrames = totalFrames - Int64(audioFile.framePosition)
                if remainingFrames <= 0 { break }

                readBuffer.frameLength = 0
                let requestedFrameCount = AVAudioFrameCount(
                    min(Int64(readBuffer.frameCapacity), remainingFrames)
                )

                do {
                    try autoreleasepool {
                        try audioFile.read(into: readBuffer, frameCount: requestedFrameCount)
                    }
                } catch {
                    throw WaveformError.audioRead(
                        url: sourceURL,
                        framePosition: audioFile.framePosition,
                        chunkIndex: chunkIndex,
                        processing: Self.describe(format: audioFile.processingFormat),
                        file: Self.describe(format: audioFile.fileFormat),
                        underlying: error as NSError
                    )
                }

                let frameLength = Int(readBuffer.frameLength)
                if frameLength == 0 { break }
                chunkIndex += 1

                guard let channelData = readBuffer.floatChannelData else {
                    throw WaveformError.missingChannelData(format: Self.describe(format: readBuffer.format))
                }

                let channelCount = Int(readBuffer.format.channelCount)
                guard channelCount > 0 else {
                    throw WaveformError.missingChannelData(format: Self.describe(format: readBuffer.format))
                }

                if channelCount == 1 {
                    try body(UnsafePointer(channelData[0]), frameLength)
                    continue
                }

                if monoScratch.count < frameLength {
                    monoScratch = [Float](repeating: 0, count: frameLength)
                }

                let scale = 1.0 / Float(channelCount)
                try monoScratch.withUnsafeMutableBufferPointer { monoBuffer in
                    guard let monoBase = monoBuffer.baseAddress else {
                        throw WaveformError.missingChannelData(format: Self.describe(format: readBuffer.format))
                    }

                    for sampleIndex in 0..<frameLength {
                        var mixedSample: Float = 0
                        for channel in 0..<channelCount {
                            mixedSample += channelData[channel][sampleIndex]
                        }
                        monoBase[sampleIndex] = mixedSample * scale
                    }

                    try body(UnsafePointer(monoBase), frameLength)
                }
            }
        }

        private static func describe(format: AVAudioFormat) -> String {
            let commonFormat: String
            switch format.commonFormat {
            case .otherFormat:
                commonFormat = "other"
            case .pcmFormatFloat32:
                commonFormat = "float32"
            case .pcmFormatFloat64:
                commonFormat = "float64"
            case .pcmFormatInt16:
                commonFormat = "int16"
            case .pcmFormatInt32:
                commonFormat = "int32"
            @unknown default:
                commonFormat = "unknown"
            }

            return "\(Int(format.channelCount))ch @ \(Int(format.sampleRate))Hz, \(commonFormat), \(format.isInterleaved ? "interleaved" : "non-interleaved")"
        }
    }

    nonisolated static func analyze(url: URL, targetSamples: Int) throws -> [Float] {
        try analyzeWithAudioFile(url: url, targetSamples: targetSamples)
    }

    nonisolated static func analyzeColoredWaveform(url: URL, targetColumns: Int = 2000) throws -> ColoredWaveformData {
        try coloredWaveformWithAudioFile(url: url, targetColumns: targetColumns)
    }

    // MARK: - FFT Bass Energy

    /// Compute bass energy (20-250 Hz) from a buffer of audio frames using FFT.
    private static func bassEnergy(
        from buffer: UnsafePointer<Float>,
        count: Int,
        fftSetup: FFTSetup,
        window: UnsafePointer<Float>,
        sampleRate: Float
    ) -> Float {
        let n = fftSize
        let halfN = n / 2

        // Copy and apply Hann window
        var windowed = [Float](repeating: 0, count: n)
        vDSP_vmul(buffer, 1, window, 1, &windowed, 1, vDSP_Length(count))
        // Zero-pad if count < n (already zero from initialization)

        // Pack into split complex for real FFT
        var realp = [Float](repeating: 0, count: halfN)
        var imagp = [Float](repeating: 0, count: halfN)

        realp.withUnsafeMutableBufferPointer { realBuf in
            imagp.withUnsafeMutableBufferPointer { imagBuf in
                var splitComplex = DSPSplitComplex(
                    realp: realBuf.baseAddress!,
                    imagp: imagBuf.baseAddress!
                )
                windowed.withUnsafeBufferPointer { windowedBuf in
                    let typePtr = windowedBuf.baseAddress!
                        .withMemoryRebound(to: DSPComplex.self, capacity: halfN) { $0 }
                    vDSP_ctoz(typePtr, 2, &splitComplex, 1, vDSP_Length(halfN))
                }
                // Perform FFT
                let log2n = vDSP_Length(log2(Float(n)))
                vDSP_fft_zrip(fftSetup, &splitComplex, 1, log2n, FFTDirection(FFT_FORWARD))

                // Compute magnitudes squared
                var magnitudes = [Float](repeating: 0, count: halfN)
                vDSP_zvmags(&splitComplex, 1, &magnitudes, 1, vDSP_Length(halfN))

                // Sum bass bins (bassMinHz to bassMaxHz)
                let binResolution = sampleRate / Float(n)
                let minBin = max(1, Int(bassMinHz / binResolution))
                let maxBin = min(halfN - 1, Int(bassMaxHz / binResolution))

                if maxBin >= minBin {
                    let binCount = maxBin - minBin + 1
                    var sum: Float = 0
                    vDSP_sve(magnitudes.withUnsafeBufferPointer { $0.baseAddress! + minBin }, 1, &sum, vDSP_Length(binCount))
                    // RMS-like: sqrt of mean magnitude squared
                    let mean = sum / Float(binCount)
                    let result = sqrtf(mean)
                    // Store in realp[0] to get it out of the closure
                    realBuf.baseAddress![0] = result
                } else {
                    realBuf.baseAddress![0] = 0
                }
            }
        }
        return realp[0]
    }

    // MARK: - Analyze with AudioFile

    private static func analyzeWithAudioFile(url: URL, targetSamples: Int) throws -> [Float] {
        let decoder = try MonoPCMDecoder(url: url)
        let totalFrames = decoder.totalFrames
        guard totalFrames > 0 else { return [] }

        let maxTarget = Int(min(totalFrames, Int64(Int.max)))
        let clampedTarget = max(1, min(targetSamples, maxTarget))
        let framesPerSample = Double(totalFrames) / Double(clampedTarget)

        let log2n = vDSP_Length(log2(Float(fftSize)))
        guard let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(FFT_RADIX2)) else {
            throw WaveformError.fftSetupFailed
        }
        defer { vDSP_destroy_fftsetup(fftSetup) }

        var hannWindow = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&hannWindow, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))

        let sampleRate = decoder.sampleRate
        var fftBuffer = [Float](repeating: 0, count: fftSize)
        var fftBufferPos = 0
        var samples = [Float](repeating: 0, count: clampedTarget)
        var currentSample = 0
        var currentBassEnergy: Float = 0
        var fftCountInSample = 0
        var frameIndex: Int64 = 0

        try decoder.decode { monoData, frameLength in
            for frame in 0..<frameLength {
                if frame.isMultiple(of: 1024) {
                    try Task.checkCancellation()
                }

                fftBuffer[fftBufferPos] = monoData[frame]
                fftBufferPos += 1

                if fftBufferPos >= fftSize {
                    let energy = bassEnergy(
                        from: fftBuffer, count: fftSize,
                        fftSetup: fftSetup, window: hannWindow,
                        sampleRate: sampleRate
                    )
                    currentBassEnergy += energy
                    fftCountInSample += 1
                    fftBufferPos = 0
                }

                frameIndex += 1
                let sampleIndex = Int(Double(frameIndex) / framesPerSample)
                if sampleIndex > currentSample {
                    if fftBufferPos > 0 {
                        for index in fftBufferPos..<fftSize { fftBuffer[index] = 0 }
                        let energy = bassEnergy(
                            from: fftBuffer, count: fftBufferPos,
                            fftSetup: fftSetup, window: hannWindow,
                            sampleRate: sampleRate
                        )
                        currentBassEnergy += energy
                        fftCountInSample += 1
                        fftBufferPos = 0
                    }
                    samples[currentSample] = fftCountInSample > 0
                        ? currentBassEnergy / Float(fftCountInSample) : 0
                    currentBassEnergy = 0
                    fftCountInSample = 0
                    currentSample = min(sampleIndex, clampedTarget - 1)
                }
            }
        }

        if currentSample < samples.count {
            if fftBufferPos > 0 {
                for index in fftBufferPos..<fftSize { fftBuffer[index] = 0 }
                let energy = bassEnergy(
                    from: fftBuffer, count: fftBufferPos,
                    fftSetup: fftSetup, window: hannWindow,
                    sampleRate: sampleRate
                )
                currentBassEnergy += energy
                fftCountInSample += 1
            }
            samples[currentSample] = fftCountInSample > 0
                ? currentBassEnergy / Float(fftCountInSample) : 0
        }

        normalize(&samples)
        return samples
    }

    // MARK: - RGB Waveform Analysis

    private struct RGBFrameEnergy {
        let total: Float
        let low: Float
        let mid: Float
        let high: Float
    }

    private static func averageEnergy(
        in magnitudes: [Float],
        minHz: Float,
        maxHz: Float,
        sampleRate: Float
    ) -> Float {
        let maxSupportedHz = min(maxHz, sampleRate / 2.0)
        guard maxSupportedHz > minHz else { return 0 }

        let binResolution = sampleRate / Float(fftSize)
        let halfN = fftSize / 2
        let lower = max(1, Int(floor(minHz / binResolution)))
        let upper = min(halfN - 1, Int(ceil(maxSupportedHz / binResolution)))
        guard upper >= lower else { return 0 }

        var sum: Float = 0
        for bin in lower...upper {
            sum += magnitudes[bin]
        }
        return sum / Float(upper - lower + 1)
    }

    private static func rgbFrameEnergy(
        from buffer: UnsafePointer<Float>,
        count: Int,
        fftSetup: FFTSetup,
        window: UnsafePointer<Float>,
        sampleRate: Float
    ) -> RGBFrameEnergy {
        let n = fftSize
        let halfN = n / 2

        var windowed = [Float](repeating: 0, count: n)
        vDSP_vmul(buffer, 1, window, 1, &windowed, 1, vDSP_Length(count))

        var realp = [Float](repeating: 0, count: halfN)
        var imagp = [Float](repeating: 0, count: halfN)
        var magnitudes = [Float](repeating: 0, count: halfN)

        realp.withUnsafeMutableBufferPointer { realBuf in
            imagp.withUnsafeMutableBufferPointer { imagBuf in
                var splitComplex = DSPSplitComplex(
                    realp: realBuf.baseAddress!,
                    imagp: imagBuf.baseAddress!
                )
                windowed.withUnsafeBufferPointer { windowedBuf in
                    let typePtr = windowedBuf.baseAddress!
                        .withMemoryRebound(to: DSPComplex.self, capacity: halfN) { $0 }
                    vDSP_ctoz(typePtr, 2, &splitComplex, 1, vDSP_Length(halfN))
                }
                let log2n = vDSP_Length(log2(Float(n)))
                vDSP_fft_zrip(fftSetup, &splitComplex, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&splitComplex, 1, &magnitudes, 1, vDSP_Length(halfN))
            }
        }

        let low = averageEnergy(
            in: magnitudes,
            minHz: bassMinHz,
            maxHz: bassMaxHz,
            sampleRate: sampleRate
        )
        let mid = averageEnergy(
            in: magnitudes,
            minHz: bassMaxHz,
            maxHz: midMaxHz,
            sampleRate: sampleRate
        )
        let high = averageEnergy(
            in: magnitudes,
            minHz: midMaxHz,
            maxHz: highMaxHz,
            sampleRate: sampleRate
        )

        let totalEnergy = max(low + mid + high, 1e-12)
        let bassPresence = low / totalEnergy
        let bassHeightScale = max(
            coloredWaveformBassPresenceFloor,
            powf(bassPresence, coloredWaveformBassPresenceExponent)
        )
        let weightedHeight =
            (low * coloredWaveformHeightBassWeight) +
            (mid * coloredWaveformHeightMidWeight) +
            (high * coloredWaveformHeightHighWeight)

        return RGBFrameEnergy(
            total: weightedHeight * bassHeightScale,
            low: low * coloredWaveformColorBassWeight,
            mid: mid * coloredWaveformColorMidWeight,
            high: high * coloredWaveformColorHighWeight
        )
    }

    private static func normalizeColoredWaveform(_ data: inout ColoredWaveformData) {
        guard !data.columns.isEmpty else { return }

        // Levels in dB relative to each band's own maximum over the track (DJ-software convention): the
        // colour then says how loud each band is *for this track*, and the drops stand out.
        let raw = data.columns
        let maxHeight = max(raw.map(\.height).max() ?? 0, 1e-12)
        let maxRed = max(raw.map(\.red).max() ?? 0, 1e-12)
        let maxGreen = max(raw.map(\.green).max() ?? 0, 1e-12)
        let maxBlue = max(raw.map(\.blue).max() ?? 0, 1e-12)
        func db(_ x: Float, _ top: Float) -> Float { 10 * log10f(max(x / top, 1e-9)) }
        func clamp01(_ x: Float) -> Float { min(max(x, 0), 1) }
        let maxLogHeight = log1p(maxHeight)

        for index in data.columns.indices {
            let column = raw[index]
            // Bar height: unchanged from the original renderer.
            data.columns[index].height = powf(log1p(column.height) / maxLogHeight, 0.55)

            let low = db(column.red, maxRed), mid = db(column.green, maxGreen), high = db(column.blue, maxBlue)
            let total = db(column.height, maxHeight)

            // Hue: each band 0…1 over its top 18 dB, squared so the dominant band shows.
            var r = powf(clamp01((low + 18) / 18), 2)
            var g = powf(clamp01((mid + 18) / 18), 2) * 0.8
            var b = powf(clamp01((high + 18) / 18), 2) * 0.6
            // Kick + bass at the track's own peak (drops) turn red: from −6 dB (none) to −1.5 dB (full).
            let kick = clamp01((low + 6) / 4.5)
            r += (1 - r) * kick * 0.7
            g *= 1 - kick * 0.6
            b *= 1 - kick * 0.7
            let dominant = max(r, g, b)
            guard dominant > 0 else {
                data.columns[index].red = 0
                data.columns[index].green = 0
                data.columns[index].blue = 0
                continue
            }
            // Brightness from the overall level: −2 dB → full, −15 dB → 30 %. Quiet sections read dimmer.
            let brightness = 0.3 + 0.7 * clamp01((total + 15) / 13)
            data.columns[index].red = r / dominant * brightness
            data.columns[index].green = g / dominant * brightness
            data.columns[index].blue = b / dominant * brightness
        }
    }

    private static func coloredWaveformWithAudioFile(url: URL, targetColumns: Int) throws -> ColoredWaveformData {
        let decoder = try MonoPCMDecoder(url: url)
        let totalFrames = decoder.totalFrames
        guard totalFrames > 0 else { return ColoredWaveformData(columns: []) }

        let clampedTarget = max(1, min(targetColumns, Int(min(totalFrames, Int64(Int.max)))))
        let framesPerColumn = Double(totalFrames) / Double(clampedTarget)

        let log2n = vDSP_Length(log2(Float(fftSize)))
        guard let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(FFT_RADIX2)) else {
            throw WaveformError.fftSetupFailed
        }
        defer { vDSP_destroy_fftsetup(fftSetup) }

        var hannWindow = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&hannWindow, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))

        let sampleRate = decoder.sampleRate
        var fftBuffer = [Float](repeating: 0, count: fftSize)
        var fftBufferPos = 0

        var columns = [ColoredWaveformData.Column](
            repeating: ColoredWaveformData.Column(height: 0, red: 0, green: 0, blue: 0),
            count: clampedTarget
        )
        var currentColumn = 0
        var currentTotal: Float = 0
        var currentLow: Float = 0
        var currentMid: Float = 0
        var currentHigh: Float = 0
        var fftCountInColumn = 0
        var frameIndex: Int64 = 0

        func flushColumn() {
            guard currentColumn < columns.count, fftCountInColumn > 0 else { return }
            let divisor = Float(fftCountInColumn)
            columns[currentColumn] = ColoredWaveformData.Column(
                height: currentTotal / divisor,
                red: currentLow / divisor,
                green: currentMid / divisor,
                blue: currentHigh / divisor
            )
            currentTotal = 0
            currentLow = 0
            currentMid = 0
            currentHigh = 0
            fftCountInColumn = 0
        }

        try decoder.decode { monoData, frameLength in
            for frame in 0..<frameLength {
                if frame.isMultiple(of: 1024) {
                    try Task.checkCancellation()
                }

                fftBuffer[fftBufferPos] = monoData[frame]
                fftBufferPos += 1

                if fftBufferPos >= fftSize {
                    let energy = rgbFrameEnergy(
                        from: fftBuffer,
                        count: fftSize,
                        fftSetup: fftSetup,
                        window: hannWindow,
                        sampleRate: sampleRate
                    )
                    currentTotal += energy.total
                    currentLow += energy.low
                    currentMid += energy.mid
                    currentHigh += energy.high
                    fftCountInColumn += 1
                    fftBufferPos = 0
                }

                frameIndex += 1
                let nextColumn = Int(Double(frameIndex) / framesPerColumn)
                if nextColumn > currentColumn {
                    if fftBufferPos > 0 {
                        for index in fftBufferPos..<fftSize { fftBuffer[index] = 0 }
                        let energy = rgbFrameEnergy(
                            from: fftBuffer,
                            count: fftBufferPos,
                            fftSetup: fftSetup,
                            window: hannWindow,
                            sampleRate: sampleRate
                        )
                        currentTotal += energy.total
                        currentLow += energy.low
                        currentMid += energy.mid
                        currentHigh += energy.high
                        fftCountInColumn += 1
                        fftBufferPos = 0
                    }
                    flushColumn()
                    currentColumn = min(nextColumn, clampedTarget - 1)
                }
            }
        }

        if currentColumn < columns.count {
            if fftBufferPos > 0 {
                for index in fftBufferPos..<fftSize { fftBuffer[index] = 0 }
                let energy = rgbFrameEnergy(
                    from: fftBuffer,
                    count: fftBufferPos,
                    fftSetup: fftSetup,
                    window: hannWindow,
                    sampleRate: sampleRate
                )
                currentTotal += energy.total
                currentLow += energy.low
                currentMid += energy.mid
                currentHigh += energy.high
                fftCountInColumn += 1
            }
            flushColumn()
        }

        var data = ColoredWaveformData(columns: columns)
        normalizeColoredWaveform(&data)
        return data
    }

    // MARK: - Spectrogram Analysis

    nonisolated static func analyzeSpectrogram(url: URL, targetColumns: Int = 2000, freqBins: Int = 128) throws -> [[Float]] {
        try spectrogramWithAudioFile(url: url, targetColumns: targetColumns, freqBins: freqBins)
    }

    /// Build a mel-scale triangular filterbank matrix.
    /// Returns [freqBins][halfN] weights.
    private static func buildMelFilterbank(freqBins: Int, halfN: Int, sampleRate: Float) -> [[Float]] {
        func hzToMel(_ hz: Float) -> Float { 2595.0 * log10f(1.0 + hz / 700.0) }
        func melToHz(_ mel: Float) -> Float { 700.0 * (powf(10.0, mel / 2595.0) - 1.0) }

        let minHz: Float = 20.0
        let maxHz: Float = min(16000.0, sampleRate / 2.0)
        let minMel = hzToMel(minHz)
        let maxMel = hzToMel(maxHz)

        // freqBins + 2 points for triangular filters
        let melPoints = (0...(freqBins + 1)).map { i in
            minMel + Float(i) * (maxMel - minMel) / Float(freqBins + 1)
        }
        let hzPoints = melPoints.map { melToHz($0) }
        let binResolution = sampleRate / Float(fftSize)
        let fftBins = hzPoints.map { $0 / binResolution }

        var filterbank = [[Float]](repeating: [Float](repeating: 0, count: halfN), count: freqBins)
        for m in 0..<freqBins {
            let left = fftBins[m]
            let center = fftBins[m + 1]
            let right = fftBins[m + 2]
            for k in 0..<halfN {
                let freq = Float(k)
                if freq >= left && freq < center && center > left {
                    filterbank[m][k] = (freq - left) / (center - left)
                } else if freq >= center && freq <= right && right > center {
                    filterbank[m][k] = (right - freq) / (right - center)
                }
            }
        }
        return filterbank
    }

    /// Compute full magnitude spectrum for one FFT frame, then project onto mel bins.
    private static func melSpectrum(
        from buffer: UnsafePointer<Float>,
        count: Int,
        fftSetup: FFTSetup,
        window: UnsafePointer<Float>,
        filterbank: [[Float]],
        freqBins: Int
    ) -> [Float] {
        let n = fftSize
        let halfN = n / 2

        var windowed = [Float](repeating: 0, count: n)
        vDSP_vmul(buffer, 1, window, 1, &windowed, 1, vDSP_Length(count))

        var realp = [Float](repeating: 0, count: halfN)
        var imagp = [Float](repeating: 0, count: halfN)
        var magnitudes = [Float](repeating: 0, count: halfN)

        realp.withUnsafeMutableBufferPointer { realBuf in
            imagp.withUnsafeMutableBufferPointer { imagBuf in
                var splitComplex = DSPSplitComplex(
                    realp: realBuf.baseAddress!,
                    imagp: imagBuf.baseAddress!
                )
                windowed.withUnsafeBufferPointer { windowedBuf in
                    let typePtr = windowedBuf.baseAddress!
                        .withMemoryRebound(to: DSPComplex.self, capacity: halfN) { $0 }
                    vDSP_ctoz(typePtr, 2, &splitComplex, 1, vDSP_Length(halfN))
                }
                let log2n = vDSP_Length(log2(Float(n)))
                vDSP_fft_zrip(fftSetup, &splitComplex, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&splitComplex, 1, &magnitudes, 1, vDSP_Length(halfN))
            }
        }

        // Project onto mel filterbank
        var melBins = [Float](repeating: 0, count: freqBins)
        for m in 0..<freqBins {
            var dot: Float = 0
            vDSP_dotpr(magnitudes, 1, filterbank[m], 1, &dot, vDSP_Length(halfN))
            melBins[m] = dot
        }
        return melBins
    }

    private static func spectrogramWithAudioFile(url: URL, targetColumns: Int, freqBins: Int) throws -> [[Float]] {
        let decoder = try MonoPCMDecoder(url: url)
        let totalFrames = decoder.totalFrames
        guard totalFrames > 0 else { return [] }

        let clampedTarget = max(1, min(targetColumns, Int(min(totalFrames, Int64(Int.max)))))
        let framesPerColumn = Double(totalFrames) / Double(clampedTarget)

        let log2n = vDSP_Length(log2(Float(fftSize)))
        guard let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(FFT_RADIX2)) else {
            throw WaveformError.fftSetupFailed
        }
        defer { vDSP_destroy_fftsetup(fftSetup) }

        var hannWindow = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&hannWindow, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))

        let sampleRate = decoder.sampleRate
        let halfN = fftSize / 2
        let filterbank = buildMelFilterbank(freqBins: freqBins, halfN: halfN, sampleRate: sampleRate)

        var fftBuffer = [Float](repeating: 0, count: fftSize)
        var fftBufferPos = 0

        var columns = [[Float]](repeating: [Float](repeating: 0, count: freqBins), count: clampedTarget)
        var currentColumn = 0
        var currentMelSum = [Float](repeating: 0, count: freqBins)
        var fftCountInColumn = 0
        var frameIndex: Int64 = 0

        try decoder.decode { monoData, frameLength in
            for frame in 0..<frameLength {
                if frame.isMultiple(of: 1024) {
                    try Task.checkCancellation()
                }

                fftBuffer[fftBufferPos] = monoData[frame]
                fftBufferPos += 1

                if fftBufferPos >= fftSize {
                    let mel = melSpectrum(
                        from: fftBuffer,
                        count: fftSize,
                        fftSetup: fftSetup,
                        window: hannWindow,
                        filterbank: filterbank,
                        freqBins: freqBins
                    )
                    vDSP_vadd(currentMelSum, 1, mel, 1, &currentMelSum, 1, vDSP_Length(freqBins))
                    fftCountInColumn += 1
                    fftBufferPos = 0
                }

                frameIndex += 1
                let columnIndex = Int(Double(frameIndex) / framesPerColumn)
                if columnIndex > currentColumn {
                    if fftBufferPos > 0 {
                        for index in fftBufferPos..<fftSize { fftBuffer[index] = 0 }
                        let mel = melSpectrum(
                            from: fftBuffer,
                            count: fftBufferPos,
                            fftSetup: fftSetup,
                            window: hannWindow,
                            filterbank: filterbank,
                            freqBins: freqBins
                        )
                        vDSP_vadd(currentMelSum, 1, mel, 1, &currentMelSum, 1, vDSP_Length(freqBins))
                        fftCountInColumn += 1
                        fftBufferPos = 0
                    }
                    if fftCountInColumn > 0 {
                        var divisor = Float(fftCountInColumn)
                        columns[currentColumn].withUnsafeMutableBufferPointer { dst in vDSP_vsdiv(currentMelSum, 1, &divisor, dst.baseAddress!, 1, vDSP_Length(freqBins)) }
                    }
                    currentMelSum = [Float](repeating: 0, count: freqBins)
                    fftCountInColumn = 0
                    currentColumn = min(columnIndex, clampedTarget - 1)
                }
            }
        }

        if currentColumn < columns.count {
            if fftBufferPos > 0 {
                for index in fftBufferPos..<fftSize { fftBuffer[index] = 0 }
                let mel = melSpectrum(
                    from: fftBuffer,
                    count: fftBufferPos,
                    fftSetup: fftSetup,
                    window: hannWindow,
                    filterbank: filterbank,
                    freqBins: freqBins
                )
                vDSP_vadd(currentMelSum, 1, mel, 1, &currentMelSum, 1, vDSP_Length(freqBins))
                fftCountInColumn += 1
            }
            if fftCountInColumn > 0 {
                var divisor = Float(fftCountInColumn)
                columns[currentColumn].withUnsafeMutableBufferPointer { dst in vDSP_vsdiv(currentMelSum, 1, &divisor, dst.baseAddress!, 1, vDSP_Length(freqBins)) }
            }
        }

        normalizeSpectrogram(&columns)
        return columns
    }

    private static func normalizeSpectrogram(_ columns: inout [[Float]]) {
        guard !columns.isEmpty else { return }
        let freqBins = columns[0].count

        // Apply log1p compression
        for col in 0..<columns.count {
            for bin in 0..<freqBins {
                columns[col][bin] = log1p(columns[col][bin])
            }
        }

        // Find global max
        var globalMax: Float = 0
        for col in columns {
            var colMax: Float = 0
            vDSP_maxv(col, 1, &colMax, vDSP_Length(freqBins))
            if colMax > globalMax { globalMax = colMax }
        }

        guard globalMax > 0 else { return }

        // Normalize and apply power curve
        for col in 0..<columns.count {
            columns[col].withUnsafeMutableBufferPointer { p in vDSP_vsdiv(p.baseAddress!, 1, &globalMax, p.baseAddress!, 1, vDSP_Length(freqBins)) }
            for bin in 0..<freqBins {
                columns[col][bin] = powf(columns[col][bin], 0.6)
            }
        }
    }

    private static func normalize(_ samples: inout [Float]) {
        guard !samples.isEmpty else { return }

        // Vectorized max finding
        var maxSample: Float = 0
        vDSP_maxv(samples, 1, &maxSample, vDSP_Length(samples.count))

        guard maxSample > 0 else { return }

        // Vectorized division to normalize to 0-1
        vDSP_vsdiv(samples, 1, &maxSample, &samples, 1, vDSP_Length(samples.count))

        // Apply power curve for more contrast on bass energy
        // pow(x, 0.4) gives more punch than sqrt (0.5)
        var count = Int32(samples.count)
        let exponent = Float(0.4)
        // vvpowf(result, exponent, base, count) = base[i]^exponent[i]
        var expArray = [Float](repeating: exponent, count: samples.count)
        vvpowf(&samples, &expArray, samples, &count)
    }

    // MARK: - Raw Magnitude Spectrum (for quality analysis)

    /// Compute full magnitude spectrum in dB for one FFT frame (no mel projection).
    private static func rawMagnitudeSpectrumDB(
        from buffer: UnsafePointer<Float>,
        count: Int,
        fftSetup: FFTSetup,
        window: UnsafePointer<Float>
    ) -> [Float] {
        let n = fftSize
        let halfN = n / 2

        var windowed = [Float](repeating: 0, count: n)
        vDSP_vmul(buffer, 1, window, 1, &windowed, 1, vDSP_Length(count))

        var realp = [Float](repeating: 0, count: halfN)
        var imagp = [Float](repeating: 0, count: halfN)
        var magnitudes = [Float](repeating: 0, count: halfN)

        realp.withUnsafeMutableBufferPointer { realBuf in
            imagp.withUnsafeMutableBufferPointer { imagBuf in
                var splitComplex = DSPSplitComplex(
                    realp: realBuf.baseAddress!,
                    imagp: imagBuf.baseAddress!
                )
                windowed.withUnsafeBufferPointer { windowedBuf in
                    let typePtr = windowedBuf.baseAddress!
                        .withMemoryRebound(to: DSPComplex.self, capacity: halfN) { $0 }
                    vDSP_ctoz(typePtr, 2, &splitComplex, 1, vDSP_Length(halfN))
                }
                let log2n = vDSP_Length(log2(Float(n)))
                vDSP_fft_zrip(fftSetup, &splitComplex, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&splitComplex, 1, &magnitudes, 1, vDSP_Length(halfN))
            }
        }

        // Convert to dB: 10 * log10(mag) with floor at -100 dB
        for i in 0..<halfN {
            let val = magnitudes[i]
            magnitudes[i] = val > 1e-10 ? 10.0 * log10f(val) : -100.0
        }
        return magnitudes
    }

    // MARK: - Audio Quality Analysis

    struct QualityDebugInfo: Sendable {
        let medianRel16k: Float
        let medianRel17k: Float
        let medianRel18k: Float
        let medianRel19k: Float
        let medianRel20k: Float
        let totalFrames: Int
    }

    nonisolated static func analyzeQuality(url: URL) throws -> (AudioQualityResult, QualityDebugInfo) {
        try qualityWithAudioFile(url: url)
    }

    private static func qualityWithAudioFile(url: URL) throws -> (AudioQualityResult, QualityDebugInfo) {
        let decoder = try MonoPCMDecoder(url: url)
        let sampleRate = decoder.sampleRate
        guard sampleRate > 0 else { throw WaveformError.conversionFailed }
        guard decoder.totalFrames > 0 else { throw WaveformError.invalidDuration }

        let framesPerWindow = Int64(fftSize)
        let hopFrames = max(framesPerWindow, Int64(sampleRate * 0.5))

        let log2n = vDSP_Length(log2(Float(fftSize)))
        guard let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(FFT_RADIX2)) else {
            throw WaveformError.fftSetupFailed
        }
        defer { vDSP_destroy_fftsetup(fftSetup) }

        var hannWindow = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&hannWindow, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))

        var fftBuffer = [Float](repeating: 0, count: fftSize)
        var fftBufferPos = 0
        var frameIndex: Int64 = 0
        var nextAnalysisFrame: Int64 = 0
        var accumulator = QualityAccumulator(sampleRate: sampleRate)

        try decoder.decode { monoData, frameLength in
            for frame in 0..<frameLength {
                if frame.isMultiple(of: 1024) {
                    try Task.checkCancellation()
                }

                if frameIndex >= nextAnalysisFrame {
                    fftBuffer[fftBufferPos] = monoData[frame]
                    fftBufferPos += 1

                    if fftBufferPos >= fftSize {
                        let spectrum = rawMagnitudeSpectrumDB(
                            from: fftBuffer,
                            count: fftSize,
                            fftSetup: fftSetup,
                            window: hannWindow
                        )
                        accumulator.processFrame(spectrum)
                        fftBufferPos = 0
                        nextAnalysisFrame = frameIndex + hopFrames
                    }
                }
                frameIndex += 1
            }
        }

        return accumulator.classify()
    }

    // MARK: - Quality Classification Accumulator

    /// Uses **relative** energy: compares high-frequency bands against a
    /// mid-range reference (2–8 kHz) so the result is immune to overall
    /// volume, noise floor, and encoding artifacts that sit at low absolute dB.
    private struct QualityAccumulator {
        let sampleRate: Float
        let halfN: Int
        let binResolution: Float

        // Per-frame: relative energy (dB) at each test band vs reference
        // Stored as arrays so we can take medians, not just means
        var rel16k: [Float] = []
        var rel17k: [Float] = []
        var rel18k: [Float] = []
        var rel19k: [Float] = []
        var rel20k: [Float] = []

        var totalFrames: Int = 0
        var highFreqEnergySum: Float = 0
        var totalEnergySum: Float = 0
        var maxCutoffSharpness: Float = 0

        init(sampleRate: Float) {
            self.sampleRate = sampleRate
            self.halfN = fftSize / 2
            self.binResolution = sampleRate / Float(fftSize)
        }

        private func binFor(_ freq: Float) -> Int {
            min(halfN - 1, max(0, Int(freq / binResolution)))
        }

        /// Average linear energy in a 1 kHz-wide band centered at `freq`
        private func bandEnergy(_ spectrumDB: [Float], centerFreq: Float) -> Float {
            let lo = binFor(centerFreq - 500)
            let hi = binFor(centerFreq + 500)
            guard hi >= lo else { return 1e-20 }
            var sum: Float = 0
            for b in lo...hi {
                sum += powf(10.0, spectrumDB[b] / 10.0)
            }
            return max(sum / Float(hi - lo + 1), 1e-20)
        }

        mutating func processFrame(_ spectrumDB: [Float]) {
            totalFrames += 1

            // Reference: average energy across 2–8 kHz (always present in music)
            let refLo = binFor(2000)
            let refHi = binFor(8000)
            var refSum: Float = 0
            for b in refLo...refHi {
                refSum += powf(10.0, spectrumDB[b] / 10.0)
            }
            let refEnergy = max(refSum / Float(refHi - refLo + 1), 1e-20)
            let refDB = 10.0 * log10f(refEnergy)

            // Relative energy at test frequencies (dB below reference)
            let e16 = 10.0 * log10f(bandEnergy(spectrumDB, centerFreq: 16000)) - refDB
            let e17 = 10.0 * log10f(bandEnergy(spectrumDB, centerFreq: 17000)) - refDB
            let e18 = 10.0 * log10f(bandEnergy(spectrumDB, centerFreq: 18000)) - refDB
            let e19 = 10.0 * log10f(bandEnergy(spectrumDB, centerFreq: 19000)) - refDB
            let e20 = 10.0 * log10f(bandEnergy(spectrumDB, centerFreq: 20000)) - refDB

            rel16k.append(e16)
            rel17k.append(e17)
            rel18k.append(e18)
            rel19k.append(e19)
            rel20k.append(e20)

            // Absolute energy ratio for the result struct
            let bin16k = binFor(16000)
            var highSum: Float = 0
            var totalSum: Float = 0
            for bin in 0..<halfN {
                let lin = powf(10.0, spectrumDB[bin] / 10.0)
                totalSum += lin
                if bin >= bin16k { highSum += lin }
            }
            highFreqEnergySum += highSum
            totalEnergySum += totalSum

            // Track sharpest drop for the result struct
            let searchStart = binFor(14000)
            let searchEnd = min(halfN - 1, binFor(22000))
            let wallBandBins = max(1, Int(500.0 / binResolution))
            for bin in searchStart..<max(searchStart, searchEnd - wallBandBins) {
                let drop = spectrumDB[bin] - spectrumDB[bin + wallBandBins]
                maxCutoffSharpness = max(maxCutoffSharpness, drop)
            }
        }

        /// Median of a Float array
        private func median(_ arr: [Float]) -> Float {
            guard !arr.isEmpty else { return -100 }
            let s = arr.sorted()
            let mid = s.count / 2
            return s.count % 2 == 0 ? (s[mid - 1] + s[mid]) / 2.0 : s[mid]
        }

        func classify() -> (AudioQualityResult, QualityDebugInfo) {
            let debugInfo = QualityDebugInfo(
                medianRel16k: median(rel16k),
                medianRel17k: median(rel17k),
                medianRel18k: median(rel18k),
                medianRel19k: median(rel19k),
                medianRel20k: median(rel20k),
                totalFrames: totalFrames
            )

            guard totalFrames > 0 else {
                return (AudioQualityResult(
                    maxEffectiveFrequency: 0,
                    highFreqEnergyRatio: 0,
                    cutoffSharpness: 0,
                    estimatedBitrate: .kbps128
                ), debugInfo)
            }

            let m16 = debugInfo.medianRel16k
            let m17 = debugInfo.medianRel17k
            let m18 = debugInfo.medianRel18k
            let m19 = debugInfo.medianRel19k
            let m20 = debugInfo.medianRel20k

            let highFreqRatio = totalEnergySum > 0 ? highFreqEnergySum / totalEnergySum : 0

            let cutoffThreshold: Float = -40.0
            let testFreqs: [(Float, Float)] = [
                (20000, m20), (19000, m19), (18000, m18), (17000, m17), (16000, m16)
            ]
            var effectiveFreq: Float = 15000
            for (freq, mVal) in testFreqs {
                if mVal > cutoffThreshold {
                    effectiveFreq = freq
                    break
                }
            }

            // Classification using relative energy thresholds.
            // Based on measured data (same track at different bitrates):
            //   128k: rel16k≈-22, rel17k≈-68 (cliff between 16-17k)
            //   256k: rel18k≈-30, rel19k≈-42 (cliff between 18-19k)
            //   320k: rel18k≈-26, rel19k≈-32 (gradual rolloff, content at 19k)
            //
            // Strategy: detect where the "cliff" is by looking at the drop
            // between adjacent bands, not just absolute level.

            let drop16to17 = m16 - m17  // 128k: ~46 dB gap,  320k: ~3 dB
            let drop18to19 = m18 - m19  // 256k: ~12 dB gap,  320k: ~6 dB
            let drop19to20 = m19 - m20  // 320k: ~14 dB gap,  lossless: small

            let bitrate: EstimatedBitrate
            if m17 < -40 || drop16to17 > 20 {
                // Massive cliff after 16kHz → 128k
                bitrate = .kbps128
            } else if m18 < -40 || (m17 > -30 && m18 < -35) {
                // Content at 17k but dies at 18k → 192k
                bitrate = .kbps192
            } else if m19 < -35 || drop18to19 > 10 {
                // Content at 18k but cliff at 19k → 256k
                bitrate = .kbps256
            } else if m20 > -20 && drop19to20 < 8 {
                // Strong energy at 20kHz, gentle slope → lossless
                bitrate = .lossless
            } else {
                // Content at 19k but attenuated at 20k → 320k
                bitrate = .kbps320
            }

            return (AudioQualityResult(
                maxEffectiveFrequency: effectiveFreq,
                highFreqEnergyRatio: highFreqRatio,
                cutoffSharpness: maxCutoffSharpness,
                estimatedBitrate: bitrate
            ), debugInfo)
        }
    }

}
