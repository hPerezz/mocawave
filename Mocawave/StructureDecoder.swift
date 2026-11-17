import Foundation

/// Section structure, decoded the way music-structure-analysis systems do it instead of with chained
/// threshold rules:
///
/// 1. **Blocks on the bar counter.** The track is cut into 4-bar blocks aligned to its 8-bar phrase grid;
///    each block is a vector of band levels (low / mid / high / total, dB).
/// 2. **Boundaries from novelty.** A section boundary is where the music *before* a point differs from the
///    music *after* it: the distance between the mean block vectors of the 8 bars on each side (Foote-style
///    novelty at two scales). Peaks of that curve are boundaries — no fixed "−5 dB" rules.
/// 3. **Labels from a grammar, decoded globally.** Each segment gets a score for every section type
///    (Intro, Build, Drop, Break, Body, Outro) from its level relative to the track's own peak, its trend and
///    its position. A Viterbi pass over the segment sequence picks the best labelling that obeys the
///    grammar (Intro → … → Build → Drop → Break → … → Outro): one global optimum instead of greedy rules
///    fixed up afterwards.
/// 4. **Cues** go on the first bar of each labelled section (refined to the sharpest change within ±1 bar),
///    with a confidence from how clearly the winning label beat the runner-up.
enum StructureDecoder {
    enum Section: Int, CaseIterable {
        case intro, build, drop, breakdown, body, outro

        var cueKind: CueKind? {
            switch self {
            case .intro: return .intro
            case .build: return .build
            case .drop: return .drop
            case .breakdown: return .breakdown
            case .outro: return .outro
            case .body: return nil   // mid-energy groove: part of the flow, no cue of its own
            }
        }
    }

    struct Segment {
        var start: Int          // bar index in the profile
        var end: Int            // exclusive
        var total: Float        // mean dB relative to the track's peak tier (0 = peak, negative = quieter)
        var low: Float          // low end relative to its peak tier
        var mid: Float          // body relative to the peak sections' body
        var slope: Float        // dB per bar across the segment (build-ups rise)
        var position: Float     // centre of the segment, 0…1 of the active track
        var rise: Float = 0     // vs the previous segment: max(total change, half the low-end change), dB
        var bars: Int { end - start }
    }

    // MARK: - Entry

    nonisolated static func decode(_ p: CueDetector.BarProfile, grid: BeatGrid, duration: Double) -> [Cue] {
        let n = p.lowDB.count
        guard n >= 16 else { return [] }
        let loudest = p.totalDB.max() ?? 0
        let active = (0..<n).filter { p.totalDB[$0] > loudest - 30 }
        guard let firstActive = active.first, let lastActive = active.last, lastActive - firstActive >= 16 else { return [] }

        func percentile(_ x: [Float], _ q: Double) -> Float {
            let s = x.sorted()
            return s[min(s.count - 1, max(0, Int(Double(s.count - 1) * q)))]
        }
        let peakTotal = percentile(active.map { p.totalDB[$0] }, 0.9)
        let peakLow = percentile(active.map { p.lowDB[$0] }, 0.9)
        let peakBars = active.filter { p.totalDB[$0] >= peakTotal - 2.5 && p.lowDB[$0] >= peakLow - 2.5 }
        let peakMid = peakBars.isEmpty ? percentile(active.map { p.midDB[$0] }, 0.9)
                                       : percentile(peakBars.map { p.midDB[$0] }, 0.5)

        let phrase = phraseOffset(p)
        let boundaries = sectionBoundaries(p, firstActive: firstActive, lastActive: lastActive, phrase: phrase)

        // Segments between boundaries, described relative to the track itself.
        var segments: [Segment] = []
        for (k, start) in boundaries.enumerated() {
            let end = k + 1 < boundaries.count ? boundaries[k + 1] : lastActive + 1
            guard end > start else { continue }
            let r = start..<end
            func mean(_ x: [Float]) -> Float { x[r].reduce(0, +) / Float(r.count) }
            let span = Float(lastActive - firstActive + 1)
            segments.append(Segment(start: start, end: end,
                                    total: mean(p.totalDB) - peakTotal,
                                    low: mean(p.lowDB) - peakLow,
                                    mid: mean(p.midDB) - peakMid,
                                    slope: slope(p.totalDB, r, lowWeight: p.lowDB),
                                    position: (Float(start + end) / 2 - Float(firstActive)) / span))
        }
        guard !segments.isEmpty else { return [] }
        // Context the labels need: a build rises from what came before (the kick coming back), a break doesn't.
        for i in segments.indices.dropFirst() {
            segments[i].rise = max(segments[i].total - segments[i - 1].total, 0.5 * (segments[i].low - segments[i - 1].low))
        }

        let (labels, margins) = viterbi(segments)
        if ProcessInfo.processInfo.environment["MOCA_DEBUG"] != nil {
            for (i, sg) in segments.enumerated() {
                print(String(format: "  seg %6.1fs %3d bars  total %5.1f low %5.1f mid %5.1f slope %5.2f pos %.2f → %@",
                             grid.time(ofBar: sg.start + p.firstBar), sg.bars, sg.total, sg.low, sg.mid, sg.slope, sg.position,
                             "\(labels[i])"))
            }
        }

        // Merge consecutive equal labels; place cues on section starts.
        var cues: [Cue] = []
        var previous: Section?
        for (i, segment) in segments.enumerated() {
            let label = labels[i]
            defer { previous = label }
            guard label != previous, let kind = label.cueKind else { continue }
            let bar = refine(segment.start, kind: kind, p, phrase: phrase)
            let time = max(0, grid.time(ofBar: bar + p.firstBar))
            guard time < duration else { continue }
            let confidence = kind == .intro ? 0.9 : min(1, 0.45 + margins[i] / 6)
            cues.append(Cue(kind: kind, time: time, confidence: Float(confidence)))
        }
        appendOutroIfMissing(&cues, p, grid: grid, firstActive: firstActive, lastActive: lastActive, phrase: phrase)
        return cues
    }

    /// Every track ends in an outro (the DJ's mix-out block). When the decoder found none (the track ends at
    /// full energy), use the last step down in level (total, or half the low end; 4 bars after vs before,
    /// ≥ 1.5 dB) in the final quarter, at least 8 bars after the last drop/break; else the last 16 bars.
    nonisolated static func appendOutroIfMissing(_ cues: inout [Cue], _ p: CueDetector.BarProfile, grid: BeatGrid,
                                                 firstActive: Int, lastActive: Int, phrase: Int) {
        guard !cues.contains(where: { $0.kind == .outro }) else { return }
        let n = p.lowDB.count
        func mean(_ x: [Float], _ r: Range<Int>) -> Float {
            let r = max(0, r.lowerBound)..<min(n, r.upperBound)
            return r.isEmpty ? 0 : x[r].reduce(0, +) / Float(r.count)
        }
        let lastStructural = cues.filter { $0.kind == .drop || $0.kind == .breakdown }.map(\.time).max() ?? 0
        let from = max(firstActive + 8, Int(Double(lastActive) * 0.75), grid.bar(at: lastStructural + 0.01) - p.firstBar + 8)
        var bar = max(from, lastActive - 16)
        if from < lastActive - 4 {
            let falls = (from...(lastActive - 4)).filter { k in
                let total = mean(p.totalDB, k - 4..<k) - mean(p.totalDB, k..<k + 4)
                let low = mean(p.lowDB, k - 4..<k) - mean(p.lowDB, k..<k + 4)
                return max(total, 0.5 * low) >= 1.5
            }
            if let last = falls.last {
                // Snap to the nearest 8-bar phrase start within ±3 bars when the step there is at least half
                // as strong: that is where DJ outros start.
                func fall(_ k: Int) -> Float {
                    max(mean(p.totalDB, k - 4..<k) - mean(p.totalDB, k..<k + 4),
                        0.5 * (mean(p.lowDB, k - 4..<k) - mean(p.lowDB, k..<k + 4)))
                }
                // The dip before an outro is usually a short fill; the outro block starts on the next phrase
                // line, where the music comes back for the mix-out.
                _ = fall
                bar = (last...min(last + 7, lastActive - 3)).first { (($0 + p.firstBar - phrase) % 8 + 8) % 8 == 0 } ?? last
            }
        }
        guard bar < lastActive - 2 else { return }
        let time = grid.time(ofBar: bar + p.firstBar)
        guard time > lastStructural else { return }
        cues.append(Cue(kind: .outro, time: time, confidence: 0.55))
    }

    // MARK: - 1–2. Blocks and boundaries

    /// Phrase phase (of 8 bars): where bar-to-bar changes concentrate.
    nonisolated static func phraseOffset(_ p: CueDetector.BarProfile) -> Int {
        var score = [Float](repeating: 0, count: 8)
        for i in 1..<p.lowDB.count {
            score[(i + p.firstBar) & 7] += abs(p.lowDB[i] - p.lowDB[i - 1]) + abs(p.midDB[i] - p.midDB[i - 1])
        }
        return score.indices.max { score[$0] < score[$1] } ?? 0
    }

    /// Candidate boundaries every 4 bars on the phrase grid, kept where the 8 bars after differ from the 8
    /// bars before (and, at a finer scale, 4 vs 4) more than anywhere around them.
    nonisolated static func sectionBoundaries(_ p: CueDetector.BarProfile, firstActive: Int, lastActive: Int,
                                              phrase: Int) -> [Int] {
        let n = p.lowDB.count
        // Weighted band vector per bar: the low end and overall level drive DJ sections the most.
        let weights: [Float] = [1.0, 0.6, 0.4, 0.8]
        func vector(_ i: Int) -> [Float] { [p.lowDB[i], p.midDB[i], p.highDB[i], p.totalDB[i]] }
        func meanVector(_ r: Range<Int>) -> [Float]? {
            let r = max(firstActive, r.lowerBound)..<min(lastActive + 1, r.upperBound)
            guard !r.isEmpty else { return nil }
            var acc = [Float](repeating: 0, count: 4)
            for i in r { for (j, v) in vector(i).enumerated() { acc[j] += v } }
            return acc.map { $0 / Float(r.count) }
        }
        func distance(_ a: [Float], _ b: [Float]) -> Float {
            var d: Float = 0
            for j in 0..<4 { d += weights[j] * (a[j] - b[j]) * (a[j] - b[j]) }
            return d.squareRoot()
        }
        func novelty(_ i: Int) -> Float {
            var score: Float = 0
            for (w, weight) in [(4, Float(0.5)), (8, Float(0.5))] {
                if let before = meanVector(i - w..<i), let after = meanVector(i..<i + w) {
                    score += weight * distance(before, after)
                }
            }
            return score
        }

        let aligned = { (i: Int) in ((i + p.firstBar - phrase) % 4 + 4) % 4 == 0 }
        let grid = (firstActive + 1...max(firstActive + 1, lastActive - 3)).filter(aligned)
        let curve = grid.map(novelty)
        guard !curve.isEmpty else { return [firstActive] }
        let sorted = curve.sorted()
        let median = sorted[sorted.count / 2]
        let threshold = max(2.5, median * 1.6)   // dB-scale distance: a real section change is a few dB

        var boundaries = [firstActive]
        for (k, i) in grid.enumerated() where curve[k] >= threshold {
            let left = k > 0 ? curve[k - 1] : 0, right = k + 1 < curve.count ? curve[k + 1] : 0
            guard curve[k] >= left, curve[k] >= right else { continue }   // local maximum
            if i - boundaries.last! < 4 { continue }                       // at least one block per segment
            boundaries.append(i)
        }
        return boundaries
    }

    /// Least-squares slope of the level across a range (dB per bar), using total and low end together.
    nonisolated static func slope(_ total: [Float], _ r: Range<Int>, lowWeight low: [Float]) -> Float {
        guard r.count >= 3 else { return 0 }
        let xs = r.map { Float($0 - r.lowerBound) }
        let ys = r.map { 0.5 * total[$0] + 0.5 * low[$0] }
        let mx = xs.reduce(0, +) / Float(xs.count), my = ys.reduce(0, +) / Float(ys.count)
        var num: Float = 0, den: Float = 0
        for (x, y) in zip(xs, ys) { num += (x - mx) * (y - my); den += (x - mx) * (x - mx) }
        return den > 0 ? num / den : 0
    }

    // MARK: - 3. Labels (Viterbi over the section grammar)

    /// Log-score of a segment being each section type. Soft, scale-aware penalties (dB relative to the
    /// track's own peak) rather than hard thresholds; the grammar does the rest.
    nonisolated static func emission(_ s: Segment, _ section: Section) -> Float {
        func below(_ x: Float, _ limit: Float, _ scale: Float) -> Float { x < limit ? -pow((limit - x) / scale, 2) : 0 }
        func above(_ x: Float, _ limit: Float, _ scale: Float) -> Float { x > limit ? -pow((x - limit) / scale, 2) : 0 }
        switch section {
        case .drop:      // at (or near) the track's peak, low end in full
            return below(s.total, -2.5, 1.5) + below(s.low, -3.5, 1.5) + (s.bars < 8 ? -1.5 : 0)
        case .breakdown: // the low end leaves, and it does not rise from what came before
            return above(s.low, -7, 2.5) + above(s.rise, 3, 1.5) + (s.bars < 8 ? -2 : 0)
        case .build:     // between break and peak (the grammar puts it right before a drop); rising helps
            // The kick/bass are not fully in yet: across the corrected tracks build-ups sit 8–22 dB under the
            // peak low end, drops within 5 dB.
            // It rises: from the previous section, or within itself.
            return above(s.total, -1.5, 1) + below(s.total, -12, 3) + above(s.low, -6, 1.5)
                + below(max(s.rise, s.slope * 8), 1.5, 1.5) + (s.bars > 32 ? -2 : 0)
        case .body:      // groove below the peak, not a break
            return above(s.total, -2, 1) + below(s.low, -8, 2.5) - 0.8
        case .intro:     // opens the track, below the peak
            return above(s.position, 0.2, 0.08) + above(s.total, -2.5, 1.5)
        case .outro:     // closes the track: the body (melody) gone, or very quiet
            return below(s.position, 0.8, 0.08) + max(above(s.mid, -4, 1.5), above(s.total, -10, 3))
                + (s.mid < -6 && s.position > 0.85 ? 0.6 : 0)
        }
    }

    /// Allowed section → section moves (log-penalties; nil = forbidden).
    nonisolated static func transition(_ from: Section, _ to: Section) -> Float? {
        switch (from, to) {
        case (.intro, .intro): return -2
        case (.intro, .build), (.intro, .drop), (.intro, .body): return 0
        case (.body, .build), (.body, .drop), (.body, .breakdown), (.body, .outro): return 0
        case (.body, .body): return -2
        case (.build, .drop): return 0
        case (.build, .build): return -1.5
        case (.drop, .breakdown), (.drop, .outro), (.drop, .body): return 0
        case (.drop, .drop): return 0             // the drop section continues (merged: one cue)
        case (.breakdown, .build), (.breakdown, .drop): return 0
        case (.breakdown, .body): return -1
        case (.breakdown, .breakdown): return 0   // the break continues (merged: one cue)
        case (.breakdown, .outro): return 0
        case (.outro, .outro): return 0
        default: return nil
        }
    }

    nonisolated static func viterbi(_ segments: [Segment]) -> (labels: [Section], margins: [Double]) {
        let states = Section.allCases
        let m = segments.count
        var score = [[Float]](repeating: [Float](repeating: -.infinity, count: states.count), count: m)
        var back = [[Int]](repeating: [Int](repeating: -1, count: states.count), count: m)
        // Start: the first segment is an intro, or (tracks that open at full energy) body/drop.
        for (j, s) in states.enumerated() {
            let start: Float? = s == .intro ? 0 : (s == .body || s == .drop ? -1.5 : nil)
            if let start { score[0][j] = start + emission(segments[0], s) }
        }
        for i in 1..<max(m, 1) {
            for (j, s) in states.enumerated() {
                let e = emission(segments[i], s)
                for (k, prev) in states.enumerated() where score[i - 1][k] > -.infinity {
                    guard let t = transition(prev, s) else { continue }
                    let v = score[i - 1][k] + t + e
                    if v > score[i][j] { score[i][j] = v; back[i][j] = k }
                }
            }
        }
        // End: the track closes on an outro or a drop (no outro of its own).
        let endable: Set<Section> = [.outro, .drop, .body]
        var best = 0
        for (j, s) in states.enumerated() where endable.contains(s) && score[m - 1][j] > score[m - 1][best] { best = j }
        var labels = [Section](repeating: .body, count: m)
        var j = best
        for i in stride(from: m - 1, through: 0, by: -1) {
            labels[i] = states[j]
            if i > 0 { j = max(0, back[i][j]) }
        }
        // Margin: how much better the chosen label fits the segment than the best alternative.
        let margins = segments.enumerated().map { i, s -> Double in
            let chosen = emission(s, labels[i])
            let other = states.filter { $0 != labels[i] }.map { emission(s, $0) }.max() ?? chosen
            return Double(max(0, chosen - other) + 1.5)
        }
        return (labels, margins)
    }

    // MARK: - 4. Cue placement

    /// Within ±2 bars of a block boundary, the bar with the sharpest change in the direction the section
    /// implies (rise into drops/builds, fall into breaks/outros); phrase starts win near-ties.
    nonisolated static func refine(_ bar: Int, kind: CueKind, _ p: CueDetector.BarProfile, phrase: Int) -> Int {
        let n = p.lowDB.count
        let rising = kind == .drop || kind == .build
        // Breaks are the low end leaving; outros the body (melody) leaving; drops/builds the overall rise.
        let series = kind == .breakdown ? p.lowDB : (kind == .outro ? p.midDB : p.totalDB)
        let candidates = (max(1, bar - 2)...min(n - 1, bar + 2))
        let change = { (k: Int) -> Float in
            let a = series[max(0, k - 2)..<k].reduce(0, +) / Float(max(1, k - max(0, k - 2)))
            let b = series[k..<min(n, k + 2)].reduce(0, +) / Float(max(1, min(n, k + 2) - k))
            return rising ? b - a : a - b
        }
        let onPhrase8 = { (k: Int) in ((k + p.firstBar - phrase) % 8 + 8) % 8 == 0 }
        // An outro starts on a phrase line (often right after a short fill): take it when one is in reach.
        if kind == .outro, let line = candidates.first(where: onPhrase8) { return line }
        let sharpest = candidates.map(change).max() ?? 0
        guard sharpest > 0 else { return bar }
        let onPhrase = { (k: Int) in ((k + p.firstBar - phrase) % 8 + 8) % 8 == 0 ? 1 : 0 }
        return candidates.filter { change($0) >= sharpest * 0.75 }
            .max { (onPhrase($0), change($0)) < (onPhrase($1), change($1)) } ?? bar
    }
}
