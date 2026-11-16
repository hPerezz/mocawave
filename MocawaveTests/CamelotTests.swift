import XCTest
@testable import Mocawave

final class CamelotTests: XCTestCase {
    private func key(_ code: String) -> CamelotKey { CamelotKey(code)! }

    func testParsing() {
        XCTAssertEqual(CamelotKey("8A"), CamelotKey(number: 8, isMajor: false))
        XCTAssertEqual(CamelotKey(" 12b "), CamelotKey(number: 12, isMajor: true))
        XCTAssertNil(CamelotKey("13A"))
        XCTAssertNil(CamelotKey("8C"))
        XCTAssertNil(CamelotKey(""))
        XCTAssertEqual(CamelotKey(number: 13, isMajor: false).code, "1A")
        XCTAssertEqual(CamelotKey(number: 0, isMajor: true).code, "12B")
    }

    func testKeyNamesMatchAnalyzerTable() {
        XCTAssertEqual(CamelotKey(keyName: "A Minor")?.code, "8A")
        XCTAssertEqual(CamelotKey(keyName: "C Major")?.code, "8B")
        XCTAssertEqual(CamelotKey(keyName: "F# Major")?.code, "2B")
        XCTAssertEqual(CamelotKey(keyName: "G# Minor")?.code, "1A")
        XCTAssertNil(CamelotKey(keyName: "H Minor"))
        XCTAssertEqual(key("8A").musicalName, "A minor")
        XCTAssertEqual(key("8B").musicalName, "C major")
        XCTAssertEqual(key("8A").shortName, "Am")
        XCTAssertEqual(key("8B").shortName, "C")
        XCTAssertEqual(key("11A").shortName, "F#m")
        XCTAssertEqual(key("5A").shortName, "Cm")
        // Every one of the 24 keys round-trips through its musical name.
        for k in CamelotKey.all {
            let name = k.musicalName.replacingOccurrences(of: " minor", with: " Minor").replacingOccurrences(of: " major", with: " Major")
            XCTAssertEqual(CamelotKey(keyName: name), k)
        }
    }

    func testRelationsFromMinor() {
        let source = key("8A")
        XCTAssertEqual(CamelotRelation(from: source, to: key("8A")), .same)
        XCTAssertEqual(CamelotRelation(from: source, to: key("7A")), .adjacent)
        XCTAssertEqual(CamelotRelation(from: source, to: key("9A")), .adjacent)
        XCTAssertEqual(CamelotRelation(from: source, to: key("8B")), .relative)
        XCTAssertEqual(CamelotRelation(from: source, to: key("9B")), .diagonal)
        XCTAssertEqual(CamelotRelation(from: source, to: key("7B")), .clash)
        XCTAssertEqual(CamelotRelation(from: source, to: key("10A")), .energyBoost)
        XCTAssertEqual(CamelotRelation(from: source, to: key("3A")), .semitone)
        XCTAssertEqual(CamelotRelation(from: source, to: key("2A")), .clash)
    }

    func testRelationsFromMajorAndWrapAround() {
        XCTAssertEqual(CamelotRelation(from: key("8B"), to: key("7A")), .diagonal)
        XCTAssertEqual(CamelotRelation(from: key("8B"), to: key("9A")), .clash)
        XCTAssertEqual(CamelotRelation(from: key("12A"), to: key("1A")), .adjacent)
        XCTAssertEqual(CamelotRelation(from: key("1B"), to: key("12B")), .adjacent)
        XCTAssertEqual(CamelotRelation(from: key("11A"), to: key("1A")), .energyBoost)
        XCTAssertEqual(CamelotRelation(from: key("12A"), to: key("1B")), .diagonal)
        XCTAssertEqual(CamelotRelation(from: key("1B"), to: key("12A")), .diagonal)
    }

    func testTiers() {
        XCTAssertEqual(CamelotRelation.same.tier, .perfect)
        XCTAssertEqual(CamelotRelation.adjacent.tier, .perfect)
        XCTAssertEqual(CamelotRelation.relative.tier, .good)
        XCTAssertEqual(CamelotRelation.diagonal.tier, .good)
        XCTAssertEqual(CamelotRelation.energyBoost.tier, .energy)
        XCTAssertEqual(CamelotRelation.semitone.tier, .energy)
        XCTAssertEqual(CamelotRelation.clash.tier, .avoid)
    }

    func testCompatibleKeysOrderedStrongestFirst() {
        let codes = key("8A").compatibleKeys.map(\.key.code)
        XCTAssertEqual(codes, ["8A", "7A", "9A", "8B", "9B", "10A", "3A"])
        // Same count from every key: 1 same + 2 adjacent + 1 relative + 1 diagonal + 1 boost + 1 semitone.
        for k in CamelotKey.all {
            XCTAssertEqual(k.compatibleKeys.count, 7)
        }
    }

    func testHitTestingFindsSliceUnderPointer() {
        let size = CGSize(width: 200, height: 200)
        // Every slice's own label point resolves back to that slice.
        for k in CamelotKey.all {
            XCTAssertEqual(SliceGeometry.key(at: SliceGeometry(key: k).labelPoint(in: size), in: size), k)
        }
        XCTAssertEqual(SliceGeometry.key(at: CGPoint(x: 100, y: 5), in: size), CamelotKey("12B"))   // top, outer
        XCTAssertEqual(SliceGeometry.key(at: CGPoint(x: 100, y: 55), in: size), CamelotKey("12A"))  // top, inner
        XCTAssertEqual(SliceGeometry.key(at: CGPoint(x: 195, y: 100), in: size), CamelotKey("3B"))  // right
        XCTAssertNil(SliceGeometry.key(at: CGPoint(x: 100, y: 100), in: size))                      // centre hole
        XCTAssertNil(SliceGeometry.key(at: CGPoint(x: 2, y: 2), in: size))                          // outside
    }

    func testTrackCamelotFromAnalyzerResult() {
        let resolved = KeyAnalyzer.KeyAnalysisResult(status: .resolved, key: "A Minor", camelot: "8A", confidence: 0.9,
                                                     runnerUpKey: "C Major", uncertaintyReason: nil)
        XCTAssertEqual(TrackCamelot(resolved).primary, key("8A"))
        XCTAssertFalse(TrackCamelot(resolved).isUncertain)

        let uncertain = KeyAnalyzer.KeyAnalysisResult(status: .uncertain, key: nil, camelot: nil, confidence: 0.4,
                                                      runnerUpKey: "C Major", uncertaintyReason: .relativeMajorMinorTie,
                                                      candidateKey: "A Minor")
        let track = TrackCamelot(uncertain)
        XCTAssertTrue(track.isUncertain)
        XCTAssertEqual(track.primary, key("8A"))
        XCTAssertEqual(track.runnerUp, key("8B"))
        XCTAssertEqual(TrackCamelot(nil), .empty)
    }

    func testOldCachedResultWithoutCandidateKeyStillDecodes() throws {
        let json = #"{"status":"uncertain","confidence":0.4,"runnerUpKey":"C Major","uncertaintyReason":"smallRunnerUpMargin"}"#
        let result = try JSONDecoder().decode(KeyAnalyzer.KeyAnalysisResult.self, from: Data(json.utf8))
        XCTAssertNil(result.candidateKey)
        XCTAssertEqual(TrackCamelot(result).runnerUp, key("8B"))
        XCTAssertNil(TrackCamelot(result).primary)
    }
}
