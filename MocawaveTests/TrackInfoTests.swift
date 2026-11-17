import XCTest
@testable import Mocawave

final class TrackInfoTests: XCTestCase {
    /// Real response from the dj-stack agent for "Rafael Cerato - Distain" (mood/why trimmed).
    static let distain = #"""
{"status":"ready","info":{"artist":"Rafael Cerato","title":"Distain","mix":"","labels":{"style":{"value":"Deep & Organic","agree":["Our audio analysis","Beatport"],"of":3},"genre":{"value":"Deep House","source":"Beatport"},"sub_genre":null,"energy":{"value":4,"source":"Our audio analysis"},"bpm":{"value":114.8,"source":"Our audio analysis"},"key":{"value":"D Minor","source":"Beatport"},"year":{"value":"2017","source":"Beatport"},"label":{"value":"Einmusika Recordings","source":"Beatport"},"beatport_url":"https://www.beatport.com/track/-/18144725"},"sources":[{"name":"Our audio analysis","kind":"audio","origin":"analysis","genre":"Downtempo & Warmup","style":null,"styles":[{"label":"Deep House","p":0.214},{"label":"Ambient","p":0.156},{"label":"House","p":0.143}],"energy":4,"lufs":-10.8,"bpm":114.8,"key":"Dm","camelot":"7A","key_strength":0.87,"sub_pct":57.0,"bass_pct":22.9,"groove":"4x4"},{"name":"Beatport","kind":"store","genre":"Deep House","sub_genre":"","label":"Einmusika Recordings","year":"2017","bpm":165,"key":"D Minor","url":"https://www.beatport.com/track/-/18144725","match":5.3},{"name":"Apple Music","kind":"store","genre":"House","year":"2017","album":"Antika - Single"},{"name":"Deezer","kind":"store","bpm":null,"year":"2017"},{"name":"File tag","kind":"tag","genre":"Электронная музыка"}]}}
"""#

    func testDecodesAgentResponse() throws {
        let state = TrackInfoClient.shared.decode(Data(Self.distain.utf8))
        guard case .ready(let info) = state else { return XCTFail("expected ready, got \(state)") }
        XCTAssertEqual(info.artist, "Rafael Cerato")
        XCTAssertEqual(info.labels.style?.value, "Deep & Organic")
        XCTAssertEqual(info.labels.style?.agree, ["Our audio analysis", "Beatport"])
        XCTAssertEqual(info.labels.style?.of, 3)
        XCTAssertEqual(info.labels.bpm?.source, "Our audio analysis")
        XCTAssertEqual(info.labels.bpm?.value.description, "114.8")
        XCTAssertEqual(info.labels.year?.value.description, "2017")
        XCTAssertEqual(info.sources.first?.kind, "audio")
        XCTAssertEqual(info.sources.first(where: { $0.name == "Beatport" })?.label, "Einmusika Recordings")
        XCTAssertNotNil(info.sources.first?.styles?.first)
    }

    func testQueuedAndErrorEnvelopes() {
        let client = TrackInfoClient.shared
        XCTAssertEqual(client.decode(Data(#"{"status":"queued","position":3}"#.utf8)), .queued(position: 3))
        XCTAssertEqual(client.decode(Data(#"{"status":"running","position":1}"#.utf8)), .queued(position: 1))
        XCTAssertEqual(client.decode(Data(#"{"status":"error","error":"boom"}"#.utf8)), .failed("boom"))
        XCTAssertEqual(client.decode(Data("not json".utf8)), .failed("unreadable response"))
    }

    func testLabelValueFormatting() {
        XCTAssertEqual(LabelValue.number(122).description, "122")
        XCTAssertEqual(LabelValue.number(114.8).description, "114.8")
        XCTAssertEqual(LabelValue.text("D Minor").description, "D Minor")
    }

    func testOfflineWhenNoAgentListens() async {
        let client = TrackInfoClient(base: URL(string: "http://127.0.0.1:9")!)   // discard port: nothing listens
        let state = await client.fetch(URL(fileURLWithPath: "/tmp/x.mp3")) { _ in }
        XCTAssertEqual(state, .offline)
    }
}
