import Foundation

/// A position on the Camelot wheel: 1–12 plus ring (A = minor, inner; B = major, outer).
struct CamelotKey: Hashable, Sendable {
    let number: Int
    let isMajor: Bool

    init(number: Int, isMajor: Bool) {
        self.number = ((number - 1) % 12 + 12) % 12 + 1
        self.isMajor = isMajor
    }

    /// Parses "8A", "12b", " 3B ".
    init?(_ code: String) {
        let trimmed = code.trimmingCharacters(in: .whitespaces).uppercased()
        guard let ring = trimmed.last, ring == "A" || ring == "B",
              let number = Int(trimmed.dropLast()), (1...12).contains(number) else { return nil }
        self.init(number: number, isMajor: ring == "B")
    }

    /// Parses KeyAnalyzer names such as "A Minor" or "C# Major".
    init?(keyName: String) {
        let parts = keyName.split(separator: " ")
        guard parts.count == 2, let pitch = Self.pitchClasses.firstIndex(of: String(parts[0])) else { return nil }
        switch parts[1] {
        case "Major": self.init(Self.camelotByPitchClass[pitch][1])
        case "Minor": self.init(Self.camelotByPitchClass[pitch][0])
        default: return nil
        }
    }

    var code: String { "\(number)\(isMajor ? "B" : "A")" }

    /// "A minor", "C major".
    var musicalName: String {
        let pitch = Self.camelotByPitchClass.firstIndex { $0[isMajor ? 1 : 0] == code } ?? 0
        return "\(Self.pitchClasses[pitch]) \(isMajor ? "major" : "minor")"
    }

    /// DJ shorthand, same style as the top bar: "Am", "C", "F#m".
    var shortName: String {
        let pitch = musicalName.split(separator: " ")[0]
        return isMajor ? String(pitch) : "\(pitch)m"
    }

    func shifted(by steps: Int) -> CamelotKey { CamelotKey(number: number + steps, isMajor: isMajor) }
    var otherRing: CamelotKey { CamelotKey(number: number, isMajor: !isMajor) }

    static let all: [CamelotKey] = (1...12).flatMap { [CamelotKey(number: $0, isMajor: false), CamelotKey(number: $0, isMajor: true)] }

    // Same table as KeyAnalyzer.camelotMap: [minor, major] per pitch class C…B.
    static let pitchClasses = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
    static let camelotByPitchClass: [[String]] = [
        ["5A", "8B"], ["12A", "3B"], ["7A", "10B"], ["2A", "5B"], ["9A", "12B"], ["4A", "7B"],
        ["11A", "2B"], ["6A", "9B"], ["1A", "4B"], ["8A", "11B"], ["3A", "6B"], ["10A", "1B"],
    ]
}

/// How a target key mixes from a source key, strongest first.
enum CamelotRelation: Int, CaseIterable, Comparable, Sendable {
    case same
    case adjacent      // ±1 on the same ring
    case relative      // same number, other ring (8A ↔ 8B)
    case diagonal      // 8A → 9B, 8B → 7A
    case energyBoost   // +2 on the same ring
    case semitone      // +7 on the same ring (one semitone up)
    case clash

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    init(from source: CamelotKey, to target: CamelotKey) {
        let sameRing = source.isMajor == target.isMajor
        let step = ((target.number - source.number) % 12 + 12) % 12  // clockwise distance 0…11
        switch (sameRing, step) {
        case (true, 0): self = .same
        case (true, 1), (true, 11): self = .adjacent
        case (false, 0): self = .relative
        case (false, 1) where !source.isMajor, (false, 11) where source.isMajor: self = .diagonal
        case (true, 2): self = .energyBoost
        case (true, 7): self = .semitone
        default: self = .clash
        }
    }

    var tier: CamelotTier {
        switch self {
        case .same, .adjacent: return .perfect
        case .relative, .diagonal: return .good
        case .energyBoost, .semitone: return .energy
        case .clash: return .avoid
        }
    }

    var label: String {
        switch self {
        case .same: return "same key"
        case .adjacent: return "±1 · smooth change"
        case .relative: return "relative · same energy, new mood"
        case .diagonal: return "diagonal · ring change + neighbour"
        case .energyBoost: return "+2 · energy boost"
        case .semitone: return "+7 · semitone lift"
        case .clash: return "clash · avoid"
        }
    }
}

enum CamelotTier: Int, CaseIterable, Sendable {
    case perfect, good, energy, avoid

    var title: String {
        switch self {
        case .perfect: return "Perfect"
        case .good: return "Good"
        case .energy: return "Energy"
        case .avoid: return "Avoid"
        }
    }

    var detail: String {
        switch self {
        case .perfect: return "same key · ±1"
        case .good: return "relative · diagonal"
        case .energy: return "+2 boost · +7 lift"
        case .avoid: return "everything else"
        }
    }

    /// Shape glyph so the tier never depends on colour alone.
    var glyph: String {
        switch self {
        case .perfect: return "●"
        case .good: return "◆"
        case .energy: return "▲"
        case .avoid: return ""
        }
    }
}

extension CamelotKey {
    /// Keys that mix from this one, strongest relation first (stable order inside a relation).
    var compatibleKeys: [(key: CamelotKey, relation: CamelotRelation)] {
        Self.all
            .map { ($0, CamelotRelation(from: self, to: $0)) }
            .filter { $0.1 != .clash }
            .sorted { $0.1 != $1.1 ? $0.1 < $1.1 : ($0.0.number, $0.0.isMajor ? 1 : 0) < ($1.0.number, $1.0.isMajor ? 1 : 0) }
            .map { (key: $0.0, relation: $0.1) }
    }
}
