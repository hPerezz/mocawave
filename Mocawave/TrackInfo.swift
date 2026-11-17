import Foundation

/// What we believe a track is (consensus) and what each source says, as served by the dj-stack track-info
/// agent on 127.0.0.1 (`dj-stack/agent/trackinfo_agent.py`). Every field is optional: sources disagree, go
/// missing, or don't know.
struct TrackInfo: Codable, Equatable, Sendable {
    var artist: String?
    var title: String?
    var mix: String?
    var labels: Labels
    var sources: [Source]

    struct Labels: Codable, Equatable, Sendable {
        var style: Consensus?
        var genre: Pick?
        var subGenre: Pick?
        var energy: Pick?
        var bpm: Pick?
        var key: Pick?
        var year: Pick?
        var label: Pick?
        var beatportUrl: String?
    }

    /// The style domain voted across sources: `agree` are the sources that voted for `value`, out of `of`.
    struct Consensus: Codable, Equatable, Sendable {
        var value: String
        var agree: [String]
        var of: Int
    }

    /// One label with the source it was taken from.
    struct Pick: Codable, Equatable, Sendable {
        var value: LabelValue
        var source: String
    }

    struct Source: Codable, Equatable, Sendable, Identifiable {
        var name: String
        var kind: String?           // audio · store · tag
        var origin: String?         // audio: "catalog" (dj-stack library) or "analysis" (computed now)
        var genre: String?
        var subGenre: String?
        var style: String?
        var styles: [StyleProbability]?
        var label: String?
        var year: String?
        var album: String?
        var key: String?
        var camelot: String?
        var groove: String?
        var bpm: Double?
        var energy: Double?
        var lufs: Double?
        var subPct: Double?
        var bassPct: Double?
        var url: String?

        var id: String { name }
    }

    struct StyleProbability: Codable, Equatable, Sendable {
        var label: String
        var p: Double
    }
}

/// Numbers and strings both appear as label values (BPM 114.8, key "D Minor", year "2017").
enum LabelValue: Codable, Equatable, Sendable, CustomStringConvertible {
    case number(Double)
    case text(String)

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let d = try? c.decode(Double.self) { self = .number(d) } else { self = .text(try c.decode(String.self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .number(let d): try c.encode(d)
        case .text(let s): try c.encode(s)
        }
    }

    var description: String {
        switch self {
        case .number(let d): return d.rounded() == d ? String(Int(d)) : String(format: "%.1f", d)
        case .text(let s): return s
        }
    }
}

enum TrackInfoState: Equatable, Sendable {
    case idle
    case queued(position: Int)
    case ready(TrackInfo)
    case offline
    case failed(String)
}

/// Talks to the local agent. Requests go out one at a time (the agent itself analyses in order); a request
/// is answered at once when cached, otherwise it is queued and polled until ready.
actor TrackInfoClient {
    static let shared = TrackInfoClient()

    let base: URL
    private let session: URLSession
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    init(base: URL = URL(string: "http://127.0.0.1:47321")!) {
        self.base = base
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        config.waitsForConnectivity = false
        session = URLSession(configuration: config)
    }

    /// Asks for `url`'s info, reporting progress, until ready / offline / failed (or the task is cancelled).
    func fetch(_ url: URL, progress: @Sendable @escaping (TrackInfoState) async -> Void) async -> TrackInfoState {
        var request = URLRequest(url: base.appendingPathComponent("track/info"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["path": url.path])
        var state = await send(request)
        let deadline = Date().addingTimeInterval(180)
        while case .queued = state, !Task.isCancelled, Date() < deadline {
            await progress(state)
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            var components = URLComponents(url: base.appendingPathComponent("track/info"), resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "path", value: url.path)]
            state = await send(URLRequest(url: components.url!))
        }
        if case .queued = state { return .failed("timed out") }
        return state
    }

    private struct Envelope: Decodable {
        var status: String
        var position: Int?
        var info: TrackInfo?
        var error: String?
    }

    /// One retry on a dropped connection: Python's http.server closes keep-alive connections, so the first
    /// reuse of a pooled connection can fail with "connection lost" even though the agent is up.
    private func send(_ request: URLRequest, retried: Bool = false) async -> TrackInfoState {
        do {
            let (data, _) = try await session.data(for: request)
            return decode(data)
        } catch let error as URLError where error.code == .networkConnectionLost && !retried {
            return await send(request, retried: true)
        } catch let error as URLError where [.cannotConnectToHost, .networkConnectionLost, .timedOut, .cannotFindHost].contains(error.code) {
            return .offline
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    nonisolated func decode(_ data: Data) -> TrackInfoState {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        guard let envelope = try? d.decode(Envelope.self, from: data) else { return .failed("unreadable response") }
        switch envelope.status {
        case "ready": return envelope.info.map { .ready($0) } ?? .failed("empty response")
        case "queued", "running": return .queued(position: envelope.position ?? 1)
        default: return .failed(envelope.error ?? envelope.status)
        }
    }
}
