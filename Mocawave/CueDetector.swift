import Accelerate
import AVFoundation

/// Finds Intro / Build / Drop / Break / Outro on a bar grid.
///
/// 1. Decode once to mono ~11 kHz; STFT (1024 / hop 128 ≈ 86 fps) → energy in three bands:
///    low 30–150 Hz (kick + bass), mid 150–2000 Hz (body), high 2.5–5 kHz (hats, risers, snare rolls).
/// 2. Tempo + phase: comb filter over the low-band onset envelope across the *whole* track (the app's BPM
///    is an integer from the first 60 s; ±0.5 BPM drifts > 1 s over five minutes). The app's BPM is used
///    to pick the octave when it fits nearly as well.
/// 3. Downbeat: the beat phase (of 4) where energy changes concentrate. Phrase phase (of 8 bars) the same way.
/// 4. Bars → full / thin states (low-band dB vs the track median, with hysteresis); thin runs ≥ 4 bars
///    between full runs are breaks, the bar where the low end returns is the drop, a rising high band
///    right before it is the build, a thin tail is the outro.
enum CueDetector {
    enum DetectorError: Error { case unreadable, tooShort }

    struct Features: Sendable {
        var fps: Double
        var low: [Float]      // linear power per frame
        var mid: [Float]
        var high: [Float]
        var onset: [Float]    // low-band onset strength, local mean removed
        var duration: Double
    }

    struct BarProfile: Sendable {
        var lowDB: [Float]
        var midDB: [Float]
        var highDB: [Float]
        var totalDB: [Float]
        var firstBar: Int    // index of bar 0 in grid terms (grid bar number of lowDB[0])
    }

    nonisolated static func analyze(url: URL, bpmHint: Double?) throws -> CueAnalysis {
        let features = try extractFeatures(url: url)
        guard let grid = fitGrid(features, bpmHint: bpmHint) else { return CueAnalysis(grid: nil, cues: []) }
        let profile = barProfile(features, grid: grid)
        let cues = detectCues(profile, grid: grid, duration: features.duration)
        if let reason = structureGate(cues: cues, grid: grid, duration: features.duration) {
            return CueAnalysis(grid: grid, cues: [], skippedReason: reason)
        }
        return CueAnalysis(grid: grid, cues: cues)
    }

    // MARK: - 0. When to show cues at all

    static let minimumDuration: Double = 210        // 3:30 — radio edits / songs are shorter than club mixes
    static let danceTempo: ClosedRange<Double> = 100...180

    /// Cues only make sense on electronic tracks built from clear sections. Returns why they are withheld,
    /// or nil when the track qualifies: long enough, dance tempo, and at least one confident drop or break.
    nonisolated static func structureGate(cues: [Cue], grid: BeatGrid, duration: Double) -> String? {
        if duration < minimumDuration {
            return String(format: "short track (%d:%02d < 3:30)", Int(duration) / 60, Int(duration) % 60)
        }
        if !danceTempo.contains(grid.bpm) {
            return String(format: "%.0f BPM is outside the dance range (100–180)", grid.bpm)
        }
        if !cues.contains(where: { ($0.kind == .drop || $0.kind == .breakdown) && !$0.isSuggestion }) {
            return "no clear sections"
        }
        return nil
    }

    // MARK: - 1. Features

    private static let analysisRate = 11_025.0
    private static let fftSize = 1024
    private static let hop = 128
    /// Latency between a kick's attack and the onset frame that registers it (see fitGrid).
    static let onsetLatency = 0.076
    /// Cap on one frame's log-energy rise (≈ 9 dB): a kick, not a section change, should drive the comb.
    private static let maxOnset: Float = 2
    static let minimumConfidence: Float = 0.35

    nonisolated static func extractFeatures(url: URL) throws -> Features {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let sourceRate = format.sampleRate
        guard sourceRate > 0, file.length > 0 else { throw DetectorError.unreadable }
        let decimation = max(1, Int((sourceRate / analysisRate).rounded()))
        let rate = sourceRate / Double(decimation)

        // Decode in chunks, mix to mono, box-filter decimate (good enough below ~5 kHz).
        var mono: [Float] = []
        mono.reserveCapacity(Int(file.length) / decimation + 1)
        let chunk: AVAudioFrameCount = 1 << 16
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { throw DetectorError.unreadable }
        let channels = Int(format.channelCount)
        var carry: Float = 0
        var carryCount = 0
        while file.framePosition < file.length {
            try file.read(into: buffer, frameCount: chunk)
            let n = Int(buffer.frameLength)
            guard n > 0, let data = buffer.floatChannelData else { break }
            for i in 0..<n {
                var s: Float = 0
                for c in 0..<channels { s += data[c][i] }
                carry += s / Float(channels)
                carryCount += 1
                if carryCount == decimation {
                    mono.append(carry / Float(decimation))
                    carry = 0
                    carryCount = 0
                }
            }
        }
        guard mono.count > fftSize * 8 else { throw DetectorError.tooShort }

        let frames = (mono.count - fftSize) / hop + 1
        let log2n = vDSP_Length(log2(Double(fftSize)))
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { throw DetectorError.unreadable }
        defer { vDSP_destroy_fftsetup(setup) }

        var window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        let half = fftSize / 2
        let binHz = rate / Double(fftSize)
        func bin(_ hz: Double) -> Int { min(half - 1, max(1, Int(hz / binHz))) }
        let lowRange = bin(30)..<bin(150)
        let midRange = bin(150)..<bin(2000)
        let highRange = bin(2500)..<bin(min(5000, rate / 2 - binHz))

        var low = [Float](repeating: 0, count: frames)
        var mid = [Float](repeating: 0, count: frames)
        var high = [Float](repeating: 0, count: frames)
        var frame = [Float](repeating: 0, count: fftSize)
        var real = [Float](repeating: 0, count: half)
        var imag = [Float](repeating: 0, count: half)
        var power = [Float](repeating: 0, count: half)

        mono.withUnsafeBufferPointer { samples in
            for f in 0..<frames {
                vDSP_vmul(samples.baseAddress! + f * hop, 1, window, 1, &frame, 1, vDSP_Length(fftSize))
                real.withUnsafeMutableBufferPointer { re in
                    imag.withUnsafeMutableBufferPointer { im in
                        var split = DSPSplitComplex(realp: re.baseAddress!, imagp: im.baseAddress!)
                        frame.withUnsafeBufferPointer { fp in
                            fp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                                vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                            }
                        }
                        vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                        vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(half))
                    }
                }
                power[0] = 0 // packed Nyquist lives in imag[0]
                low[f] = power[lowRange].reduce(0, +)
                mid[f] = power[midRange].reduce(0, +)
                high[f] = power[highRange].reduce(0, +)
            }
        }

        let fps = rate / Double(hop)
        // Onset: half-wave rectified rise of log low-band energy (kicks), minus a 1 s moving average.
        // Energy is floored 80 dB under the track's peak and each rise is clipped, otherwise the jump out
        // of silence (or the first kick after a break) outweighs hundreds of ordinary kicks in the comb.
        let floor = max((low.max() ?? 0) * 1e-8, 1e-12)
        var onset = [Float](repeating: 0, count: frames)
        var previous = log(max(low[0], floor))
        for f in 1..<frames {
            let current = log(max(low[f], floor))
            onset[f] = min(maxOnset, max(0, current - previous))
            previous = current
        }
        let radius = Int(fps / 2)
        var prefix = [Double](repeating: 0, count: frames + 1)
        for f in 0..<frames { prefix[f + 1] = prefix[f] + Double(onset[f]) }
        var cleaned = [Float](repeating: 0, count: frames)
        for f in 0..<frames {
            let a = max(0, f - radius), b = min(frames, f + radius + 1)
            cleaned[f] = max(0, onset[f] - Float((prefix[b] - prefix[a]) / Double(b - a)))
        }
        return Features(fps: fps, low: low, mid: mid, high: high, onset: cleaned,
                        duration: Double(file.length) / sourceRate)
    }

    // MARK: - 2. Grid

    /// Mean onset under a comb of period `60/bpm` at the best phase. Linear interpolation between frames.
    nonisolated static func combScore(_ onset: [Float], fps: Double, bpm: Double, phaseStep: Double) -> (score: Double, phase: Double) {
        let period = fps * 60 / bpm
        let n = onset.count
        var best = (score: -1.0, phase: 0.0)
        var phase = 0.0
        while phase < period {
            var sum = 0.0
            var count = 0
            var t = phase
            while t < Double(n - 1) {
                let i = Int(t)
                let frac = Float(t - Double(i))
                sum += Double(onset[i] * (1 - frac) + onset[i + 1] * frac)
                count += 1
                t += period
            }
            let mean = count > 0 ? sum / Double(count) : 0
            if mean > best.score { best = (mean, phase) }
            phase += phaseStep
        }
        return best
    }

    nonisolated static func fitGrid(_ features: Features, bpmHint: Double?) -> BeatGrid? {
        let onset = features.onset
        let fps = features.fps
        guard onset.count > Int(fps * 8) else { return nil }

        // Coarse search with a mild prior around 120 BPM (breaks half/double-time ties).
        func prior(_ bpm: Double) -> Double {
            let octaves = log2(bpm / 120)
            return exp(-0.5 * pow(octaves / 1.0, 2))
        }
        var bestOwn = (bpm: 120.0, score: -1.0)
        var bpm = 70.0
        while bpm <= 180 {
            let s = combScore(onset, fps: fps, bpm: bpm, phaseStep: 1).score
            let weighted = s * (0.85 + 0.15 * prior(bpm))
            if weighted > bestOwn.score { bestOwn = (bpm, weighted) }
            bpm += 0.5
        }

        func refine(around center: Double, span: Double) -> (bpm: Double, score: Double, phase: Double) {
            var best = (bpm: center, score: -1.0, phase: 0.0)
            var b = center - span
            while b <= center + span {
                let r = combScore(onset, fps: fps, bpm: b, phaseStep: 1)
                if r.score > best.score { best = (b, r.score, r.phase) }
                b += 0.01
            }
            // Fine phase at the chosen tempo.
            let fine = combScore(onset, fps: fps, bpm: best.bpm, phaseStep: 0.25)
            return (best.bpm, fine.score, fine.phase)
        }

        let own = refine(around: bestOwn.bpm, span: 0.6)
        var chosen = own
        if let hint = bpmHint, hint >= 60, hint <= 200 {
            let viaHint = refine(around: hint, span: 0.8)
            // Prefer the app's BPM (what the user sees) when it explains the onsets almost as well.
            if viaHint.score >= own.score * 0.85 { chosen = viaHint }
        }
        guard chosen.score > 0 else { return nil }

        // Downbeat: which of the 4 beat phases carries the energy changes.
        let beatFrames = fps * 60 / chosen.bpm
        let lowLog = features.low.map { log10($0 + 1e-9) }
        let midLog = features.mid.map { log10($0 + 1e-9) }
        func mean(_ x: [Float], from a: Double, length: Double) -> Float {
            let lo = max(0, Int(a)), hi = min(x.count, Int(a + length))
            guard hi > lo else { return 0 }
            return x[lo..<hi].reduce(0, +) / Float(hi - lo)
        }
        // Per-beat band means, then bar-scale change at each beat: |mean of next 4 beats − previous 4|².
        // Sections start on a downbeat, so the phase (of 4) holding the big changes is beat 1.
        let highLog = features.high.map { log10($0 + 1e-9) }
        var beatMeans: [(Float, Float, Float)] = []
        var t = chosen.phase
        while t + beatFrames < Double(lowLog.count) {
            beatMeans.append((mean(lowLog, from: t, length: beatFrames), mean(midLog, from: t, length: beatFrames),
                              mean(highLog, from: t, length: beatFrames)))
            t += beatFrames
        }
        var novelty = [Float](repeating: 0, count: 4)
        if beatMeans.count > 8 {
            for k in 4..<(beatMeans.count - 4) {
                var after: (Float, Float, Float) = (0, 0, 0), before: (Float, Float, Float) = (0, 0, 0)
                for j in 0..<4 {
                    after.0 += beatMeans[k + j].0; after.1 += beatMeans[k + j].1; after.2 += beatMeans[k + j].2
                    before.0 += beatMeans[k - 4 + j].0; before.1 += beatMeans[k - 4 + j].1; before.2 += beatMeans[k - 4 + j].2
                }
                let d0 = (after.0 - before.0) / 4, d1 = (after.1 - before.1) / 4, d2 = (after.2 - before.2) / 4
                novelty[k % 4] += d0 * d0 + d1 * d1 + d2 * d2
            }
        }
        let offset = novelty.indices.max { novelty[$0] < novelty[$1] } ?? 0
        // Frames are stamped at the window start but a kick's rise registers around the window centre:
        // measured against Rekordbox grids on 36 tracks, raw beats were ~76 ms early.
        let downbeat = (chosen.phase + Double(offset) * beatFrames) / fps + onsetLatency
        let rounded = (chosen.bpm * 100).rounded() / 100
        return BeatGrid(bpm: rounded, downbeat: downbeat)
    }

    // MARK: - 3. Bars

    nonisolated static func barProfile(_ features: Features, grid: BeatGrid) -> BarProfile {
        let fps = features.fps
        let firstBar = Int((-grid.downbeat / grid.barPeriod).rounded(.up))   // first bar starting at ≥ 0 s
        var lowDB: [Float] = [], midDB: [Float] = [], highDB: [Float] = [], totalDB: [Float] = []
        // Only frames whose whole 93 ms window lies inside the bar: otherwise the last frames of a quiet bar
        // already hear the next bar's kick and (in a power mean) lift the whole bar by ~30 dB.
        let window = Double(fftSize) / analysisRate
        var bar = firstBar
        while true {
            let a = Int((grid.time(ofBar: bar) * fps).rounded(.up))
            let b = Int(((grid.time(ofBar: bar + 1) - window) * fps).rounded(.down))
            guard b <= features.low.count, b > a else { break }
            func db(_ x: [Float]) -> Float { 10 * log10(x[a..<b].reduce(0, +) / Float(b - a) + 1e-12) }
            let l = db(features.low), m = db(features.mid), h = db(features.high)
            lowDB.append(l); midDB.append(m); highDB.append(h)
            totalDB.append(10 * log10(pow(10, l / 10) + pow(10, m / 10) + pow(10, h / 10)))
            bar += 1
        }
        // Silence would read as −120 dB and swamp every contrast; floor each band 60 dB under its loudest bar.
        func floored(_ x: [Float]) -> [Float] { let top = x.max() ?? 0; return x.map { max($0, top - 60) } }
        return BarProfile(lowDB: floored(lowDB), midDB: floored(midDB), highDB: floored(highDB),
                          totalDB: floored(totalDB), firstBar: firstBar)
    }

    // MARK: - 4. Cues

    private struct Run { var full: Bool; var start: Int; var length: Int; var end: Int { start + length } }

    nonisolated static func detectCues(_ p: BarProfile, grid: BeatGrid, duration: Double) -> [Cue] {
        let n = p.lowDB.count
        guard n >= 8 else { return [] }
        let loudest = p.totalDB.max() ?? 0
        let active = (0..<n).filter { p.totalDB[$0] > loudest - 30 }
        guard let firstActive = active.first, let lastActive = active.last else { return [] }
        func median(_ values: [Float]) -> Float {
            let s = values.sorted()
            return s.isEmpty ? 0 : s[s.count / 2]
        }
        let medLow = median(active.map { p.lowDB[$0] })
        let medMid = median(active.map { p.midDB[$0] })

        // Full / thin with hysteresis so a bar hovering at the edge doesn't flicker.
        var full = [Bool](repeating: true, count: n)
        var state = p.lowDB[firstActive] >= medLow - 7
        for i in 0..<n {
            if p.lowDB[i] >= medLow - 5 { state = true } else if p.lowDB[i] <= medLow - 9 { state = false }
            full[i] = i < firstActive ? false : state
        }
        var runs: [Run] = []
        for i in 0..<n {
            if let last = runs.last, last.full == full[i] { runs[runs.count - 1].length += 1 }
            else { runs.append(Run(full: full[i], start: i, length: 1)) }
        }
        // Absorb 1-bar blips (fills, a single dropped kick bar) into the surrounding run.
        var merged: [Run] = []
        for run in runs {
            if run.length <= 1, var last = merged.popLast() { last.length += run.length; merged.append(last) }
            else if var last = merged.last, last.full == run.full { last.length += run.length; merged[merged.count - 1] = last }
            else { merged.append(run) }
        }
        runs = merged

        // Phrase phase (of 8 bars): where bar-to-bar changes concentrate.
        var phraseScore = [Float](repeating: 0, count: 8)
        for i in 1..<n {
            phraseScore[(i + p.firstBar) & 7] += abs(p.lowDB[i] - p.lowDB[i - 1]) + abs(p.midDB[i] - p.midDB[i - 1])
        }
        let phrase = phraseScore.indices.max { phraseScore[$0] < phraseScore[$1] } ?? 0
        func alignment(_ i: Int) -> Float {
            let r = ((i + p.firstBar - phrase) % 8 + 8) % 8
            return r == 0 ? 1 : (r == 4 ? 0.5 : 0)
        }
        func meanDB(_ x: [Float], _ range: Range<Int>) -> Float {
            let r = max(0, range.lowerBound)..<min(n, range.upperBound)
            return r.isEmpty ? 0 : x[r].reduce(0, +) / Float(r.count)
        }
        func clamp01(_ x: Float) -> Float { min(1, max(0, x)) }
        /// Bar within ±1 of `i` with the sharpest change of `series` in `direction` (+1 rise, −1 fall).
        /// Phrase alignment only breaks near-ties (within 25 % of the sharpest change).
        func snap(_ i: Int, direction: Float, _ series: [Float]? = nil) -> Int {
            let x = series ?? p.lowDB
            let candidates = Array(max(1, i - 1)...min(n - 1, i + 1))
            let change = { (k: Int) in direction * (x[k] - x[k - 1]) }
            guard let sharpest = candidates.map(change).max(), sharpest > 0 else { return i }
            return candidates.filter { change($0) >= sharpest * 0.75 }
                .max { (alignment($0), change($0)) < (alignment($1), change($1)) } ?? i
        }
        func time(_ i: Int) -> Double { max(0, grid.time(ofBar: i + p.firstBar)) }

        // Peak tier: bars near the track's own loudest level (90th percentile of total energy). A drop is
        // where the track *arrives* there — the start of a sustained peak section — not merely where the low
        // end returns (indie/melodic tracks step up in stages: verse → chorus → peak).
        let energy = p.totalDB
        let sortedEnergy = active.map { energy[$0] }.sorted()
        let peakRef = sortedEnergy[min(sortedEnergy.count - 1, Int(Double(sortedEnergy.count) * 0.9))]
        // …and the low end at its own peak too (kick + bass at full): a build-up where the kick is back but the
        // bass/sub isn't fully in sits right under the total-energy threshold and must not count as a drop.
        let sortedLow = active.map { p.lowDB[$0] }.sorted()
        let lowRef = sortedLow[min(sortedLow.count - 1, Int(Double(sortedLow.count) * 0.9))]
        var peak = [Bool](repeating: false, count: n)
        var inPeak = false
        for i in firstActive...lastActive {
            let enters = energy[i] >= peakRef - 2.5 && p.lowDB[i] >= lowRef - 2.5
            let leaves = energy[i] < peakRef - 4 || p.lowDB[i] < lowRef - 4
            if enters { inPeak = true } else if leaves { inPeak = false }
            peak[i] = inPeak
        }
        var peakRuns: [Run] = []
        for i in 0..<n where peak[i] {
            if let last = peakRuns.last, i - last.end <= 2 { peakRuns[peakRuns.count - 1].length = i - last.start + 1 }
            else { peakRuns.append(Run(full: true, start: i, length: 1)) }
        }
        peakRuns = peakRuns.filter { $0.length >= 8 }
        /// Bars of non-peak music right before `b` (how long the track built towards this arrival).
        func approach(_ b: Int) -> Int {
            var k = b - 1
            while k >= firstActive, !peak[k] { k -= 1 }
            return b - 1 - k
        }

        var cues: [Cue] = [Cue(kind: .intro, time: time(firstActive), confidence: 0.9)]
        var drops: [Int] = []
        func addDrop(_ b: Int, confidence: Float) {
            guard !drops.contains(where: { abs($0 - b) <= 2 }) else { return }
            drops.append(b)
            cues.append(Cue(kind: .drop, time: time(b), confidence: clamp01(confidence)))
        }
        for run in peakRuns where run.start > firstActive + 2 {
            let b = snap(run.start, direction: 1, energy)
            let contrast = meanDB(energy, b..<b + 4) - meanDB(energy, b - 4..<b)
            let lead = approach(b)
            addDrop(b, confidence: 0.35 + 0.4 * clamp01((contrast - 2) / 6) + 0.15 * alignment(b) + (lead >= 8 ? 0.1 : 0))
        }
        // The low end coming back after a break also counts, when it lands near the peak tier (EDM drops whose
        // section is a touch quieter than the loudest one) — unless a real peak arrives within 32 bars: then
        // the kick coming back is the start of the build-up towards that peak, not a drop.
        var kickReturns: [Int] = []
        for (r, run) in runs.enumerated() where r > 0 && run.full && !runs[r - 1].full && runs[r - 1].length >= 4 {
            let b = snap(run.start, direction: 1)
            if peakRuns.contains(where: { $0.start > b + 2 && $0.start - b <= 32 }) {
                kickReturns.append(b)
                continue
            }
            guard meanDB(energy, b..<b + 4) >= peakRef - 5 else { continue }
            let contrast = meanDB(p.lowDB, b..<b + 4) - meanDB(p.lowDB, b - 4..<b)
            var confidence = 0.3 + 0.4 * clamp01((contrast - 6) / 10) + 0.15 * alignment(b) + (runs[r - 1].length >= 8 ? 0.15 : 0)
            if runs[r - 1].start <= firstActive { confidence -= 0.1 }
            addDrop(b, confidence: confidence)
        }
        let lastDrop = drops.max() ?? -1

        // Build: the biggest step up in energy during the run-up to a drop (4 bars after vs 4 before, ≥ 3 dB,
        // the later one on near-ties) — the moment the break turns into a build-up. Else the longest window
        // (16/8/4 bars) where the high band keeps rising, else the 8-bar phrase before a drop reached after a
        // long approach (hollow: a guess).
        for b in drops {
            let lead = approach(b)
            var placedBuild = false
            let window = max(b - min(32, lead), 1)..<max(b - 2, 1)
            // Step = total energy rise, or half the low-end rise (the kick coming back moves the low band a lot
            // more than the total).
            let steps = window.map { bar -> (bar: Int, rise: Float) in
                let total = meanDB(energy, bar..<bar + 4) - meanDB(energy, bar - 4..<bar)
                let low = meanDB(p.lowDB, bar..<bar + 4) - meanDB(p.lowDB, bar - 4..<bar)
                return (bar, max(total, 0.5 * low))
            }
            if let top = steps.map(\.rise).max(), top >= 3,
               let step = steps.last(where: { $0.rise >= top - 0.75 }) {
                cues.append(Cue(kind: .build, time: time(step.bar), confidence: clamp01(0.5 + 0.4 * clamp01((top - 3) / 6))))
                placedBuild = true
            }
            for length in [16, 8, 4] where length <= lead && !placedBuild {
                let start = b - length
                guard start >= 0 else { continue }
                let rise = meanDB(p.highDB, b - 2..<b) - meanDB(p.highDB, start..<start + 2)
                let steps = (start + 1..<b).filter { p.highDB[$0] >= p.highDB[$0 - 1] - 0.5 }.count
                let monotonic = Float(steps) / Float(max(1, length - 1))
                if rise >= 3, monotonic >= 0.55 {
                    let conf = 0.35 + 0.35 * clamp01((rise - 3) / 8) + 0.3 * monotonic * alignment(start).squareRoot()
                    cues.append(Cue(kind: .build, time: time(start), confidence: clamp01(conf)))
                    placedBuild = true
                    break
                }
            }
            if !placedBuild, lead >= 12 {
                cues.append(Cue(kind: .build, time: time(b - 8), confidence: 0.4))
            }
        }

        // Break: where a peak (drop) section ends — the kick stops — if another peak follows. The low end
        // vanishing completely often comes later (the bass rings on), so it is only a fallback for gaps
        // that have no peak ending in them. A peak that ends for good, with 8+ bars left, is the outro.
        var breakBars: [Int] = []
        var outroBar: Int?
        for (k, run) in peakRuns.enumerated() {
            let e = run.end
            guard e < lastActive - 3 else { continue }
            let b = snap(e, direction: -1, energy)
            let contrast = meanDB(energy, b - 4..<b) - meanDB(energy, b..<b + 4)
            if k + 1 < peakRuns.count {
                guard peakRuns[k + 1].start - e >= 4 else { continue }
                breakBars.append(b)
                cues.append(Cue(kind: .breakdown, time: time(b),
                                confidence: clamp01(0.4 + 0.4 * clamp01((contrast - 2) / 6) + 0.2 * alignment(b))))
            } else if lastActive - e >= 8 {
                outroBar = b
                cues.append(Cue(kind: .outro, time: time(b), confidence: clamp01(0.5 + 0.3 * clamp01((contrast - 2) / 6))))
            }
        }
        for (r, run) in runs.enumerated() where r > 0 {
            let previous = runs[r - 1]
            guard !run.full, previous.full, run.length >= 4, run.end < lastActive - 1 else { continue }
            let b = snap(run.start, direction: -1)
            // Already covered: a peak ended earlier in this same gap (no peak restarts between it and b).
            let covered = breakBars.contains { e in e <= b && !peakRuns.contains { $0.start > e && $0.start <= b } }
            if covered || (outroBar.map { b >= $0 } ?? false) { continue }
            // A dip of a few bars right before a drop is the pre-drop gap, not a break.
            if drops.contains(where: { $0 > b && $0 - b <= 8 }) { continue }
            let contrast = meanDB(p.lowDB, b - 4..<b) - meanDB(p.lowDB, b..<b + 4)
            let confidence = 0.3 + 0.4 * clamp01((contrast - 6) / 10) + 0.15 * alignment(b) + (previous.length >= 8 ? 0.15 : 0)
            cues.append(Cue(kind: .breakdown, time: time(b), confidence: clamp01(confidence)))
        }

        // Outro fallback: a thin tail, or (kick-only DJ outros) the point where the body drops out for good.
        if outroBar != nil {
            // already placed at the end of the last peak section
        } else if let tail = runs.last, !tail.full, tail.length >= 4, runs.count >= 2, runs[runs.count - 2].length >= 8, tail.start > lastDrop {
            cues.append(Cue(kind: .outro, time: time(snap(tail.start, direction: -1)), confidence: 0.7))
        } else {
            var m = lastActive
            while m > 0, p.midDB[m - 1] < medMid - 8 { m -= 1 }
            if lastActive - m >= 8, m > lastDrop, m > firstActive + 8 {
                cues.append(Cue(kind: .outro, time: time(m), confidence: 0.55))
            }
        }

        // A break leaves a peak section: anything flagged as a break before the track first reaches its peak
        // (or its first drop) is the intro breathing, so it goes. Tracks that open at full energy keep theirs.
        let firstPeak = [peakRuns.first?.start, drops.min()].compactMap { $0 }.min()
        if let firstPeak {
            let firstPeakTime = time(firstPeak)
            cues.removeAll { $0.kind == .breakdown && $0.time < firstPeakTime }
        } else {
            cues.removeAll { $0.kind == .breakdown }
        }

        // Bar counter: electronic music changes on 8-bar phrases (16/32 are multiples). Move each structural
        // cue to the nearest phrase boundary (else a 4-bar half-phrase) when the change there is at least
        // half as strong as at the detected bar — measured as 2 bars after vs 2 bars before.
        func blockChange(_ i: Int, _ x: [Float]) -> Float {
            abs(meanDB(x, i..<i + 2) - meanDB(x, i - 2..<i))
        }
        func phraseSnap(_ bar: Int, kind: CueKind) -> Int {
            let series = kind == .breakdown || kind == .outro ? p.lowDB : energy
            let here = max(blockChange(bar, series), 0.5)
            func offset(_ i: Int, _ size: Int) -> Int { ((i + p.firstBar - phrase) % size + size) % size }
            for (size, reach) in [(8, 3), (4, 2)] {
                let candidates = (bar - reach...bar + reach).filter { $0 > 0 && $0 < n - 1 && offset($0, size) == 0 }
                if let best = candidates.min(by: { abs($0 - bar) < abs($1 - bar) }), blockChange(best, series) >= here * 0.5 {
                    return best
                }
            }
            return bar
        }
        cues = cues.map { cue in
            guard cue.kind != .intro, cue.kind != .cue else { return cue }
            var snapped = cue
            let bar = grid.bar(at: cue.time + 0.01) - p.firstBar
            snapped.time = time(phraseSnap(bar, kind: cue.kind))
            return snapped
        }

        // One cue per bar: keep the most important when two land within a bar of each other.
        let priority: [CueKind: Int] = [.drop: 0, .breakdown: 1, .build: 2, .outro: 3, .intro: 4, .cue: 5]
        var kept: [Cue] = []
        for cue in cues.sorted(by: { priority[$0.kind]! < priority[$1.kind]! }) {
            if !kept.contains(where: { abs($0.time - cue.time) < grid.barPeriod * 0.9 }) { kept.append(cue) }
        }
        // Below 0.35 a cue is noise even as a hollow suggestion (tracks whose low end breathes without
        // real breaks produced alternating drop/break pairs every few bars).
        return kept.filter { $0.time < duration && ($0.kind == .intro || $0.confidence >= minimumConfidence) }
            .sorted { $0.time < $1.time }
    }
}
