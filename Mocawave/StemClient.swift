import Foundation

/// Asks the local dj-stack agent to separate a track, follows its progress, then copies the stems into the
/// app's `StemStore`. Contract: `docs/stems-contract.md`. Dev builds only (`FeatureFlags.trackInfo`), like labels.
actor StemClient {
    static let shared = StemClient()

    let base: URL
    private let session: URLSession

    init(base: URL = URL(string: "http://127.0.0.1:47321")!) {
        self.base = base
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 600
        config.waitsForConnectivity = false
        session = URLSession(configuration: config)
    }

    struct Envelope: Decodable {
        var status: String
        var key: String?
        var position: Int?
        var progress: Double?
        var eta: Double?
        var stage: String?
        var manifest: StemManifest?
        var error: String?
    }

    enum Step: Equatable {
        case state(StemsState)
        case ready(key: String, manifest: StemManifest)
    }

    /// Separates `url` (or finds it cached on the agent), reporting progress, and installs the result.
    func separate(_ url: URL, model: String = "roformer", store: StemStore = .shared,
                  progress: @Sendable @escaping (StemsState) async -> Void) async -> Result<StemSet, StemError> {
        var post = URLRequest(url: base.appendingPathComponent("stems"))
        post.httpMethod = "POST"
        post.setValue("application/json", forHTTPHeaderField: "Content-Type")
        post.httpBody = try? JSONSerialization.data(withJSONObject: ["path": url.path, "model": model])
        var components = URLComponents(url: base.appendingPathComponent("stems"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "path", value: url.path)]
        let poll = URLRequest(url: components.url!)

        var step = await send(post)
        let deadline = Date().addingTimeInterval(30 * 60)
        while !Task.isCancelled, Date() < deadline {
            switch step {
            case .ready(let key, let manifest):
                return await download(key: key, manifest: manifest, for: url, store: store, progress: progress)
            case .state(.offline):
                return .failure(.offline)
            case .state(.failed(let message)):
                return .failure(.agent(message))
            case .state(.idle):                     // agent restarted and forgot the job: ask again
                await progress(.queued(position: 0))
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                step = await send(post)
            case .state(let state):
                await progress(state)
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                step = await send(poll)
            }
        }
        return .failure(Task.isCancelled ? .cancelled : .agent("timed out"))
    }

    /// Quiet check when a track opens and the app cache misses: does the agent already have it separated
    /// (seeded from dj-stack/stems/out, or separated earlier)? GET only — never enqueues a separation. When it
    /// is ready, downloads and installs it (progress as `.downloading`); otherwise nil and the drawer keeps
    /// offering the button.
    func existing(_ url: URL, store: StemStore = .shared,
                  progress: @Sendable @escaping (StemsState) async -> Void) async -> StemSet? {
        var components = URLComponents(url: base.appendingPathComponent("stems"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "path", value: url.path)]
        guard case .ready(let key, let manifest) = await send(URLRequest(url: components.url!)), !Task.isCancelled else {
            return nil
        }
        if case .success(let set) = await download(key: key, manifest: manifest, for: url, store: store, progress: progress) {
            return set
        }
        return nil
    }

    private func send(_ request: URLRequest, retried: Bool = false) async -> Step {
        do {
            let (data, _) = try await session.data(for: request)
            return Self.decode(data)
        } catch let error as URLError where error.code == .networkConnectionLost && !retried {
            return await send(request, retried: true)
        } catch let error as URLError where [.cannotConnectToHost, .cannotFindHost].contains(error.code) {
            return .state(.offline)
        } catch let error as URLError where [.timedOut, .networkConnectionLost].contains(error.code) {
            return .state(.queued(position: 0))      // up but busy
        } catch {
            return .state(.failed(error.localizedDescription))
        }
    }

    static func decode(_ data: Data) -> Step {
        guard let e = try? StemManifest.decoder.decode(Envelope.self, from: data) else {
            return .state(.failed("unreadable response"))
        }
        switch e.status {
        case "ready":
            guard let key = e.key, let manifest = e.manifest else { return .state(.failed("empty response")) }
            return .ready(key: key, manifest: manifest)
        case "queued":
            return .state(.queued(position: e.position ?? 1))
        case "running":
            return .state(.separating(progress: e.progress ?? 0, eta: e.eta, stage: e.stage ?? "separating"))
        case "unknown":
            return .state(.idle)
        default:
            return .state(.failed(e.error ?? e.status))
        }
    }

    /// Downloads every stem into a staging folder, then installs it in one move.
    private func download(key: String, manifest: StemManifest, for url: URL, store: StemStore,
                          progress: @Sendable @escaping (StemsState) async -> Void) async -> Result<StemSet, StemError> {
        let staging: URL
        do { staging = try await store.makeStaging() } catch { return .failure(.disk(error.localizedDescription)) }
        let total = Double(max(manifest.stems.reduce(0) { $0 + ($1.bytes ?? 1) }, 1))
        var done = 0.0
        await progress(.downloading(progress: 0))
        for entry in manifest.stems {
            guard StemKind(rawValue: entry.name) != nil, !entry.file.contains("/") else { continue }
            var components = URLComponents(url: base.appendingPathComponent("stems/file"), resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "key", value: key), URLQueryItem(name: "name", value: entry.name)]
            do {
                let (temp, response) = try await session.download(from: components.url!)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    try? FileManager.default.removeItem(at: staging)
                    return .failure(.agent("missing stem \(entry.name)"))
                }
                try FileManager.default.moveItem(at: temp, to: staging.appendingPathComponent(entry.file))
            } catch {
                try? FileManager.default.removeItem(at: staging)
                return .failure(Task.isCancelled ? .cancelled : .agent(error.localizedDescription))
            }
            done += Double(entry.bytes ?? 1)
            await progress(.downloading(progress: done / total))
        }
        do {
            let data = try StemManifest.encoder.encode(manifest)
            try data.write(to: staging.appendingPathComponent("manifest.json"))
            return .success(try await store.install(staging: staging, for: url))
        } catch {
            try? FileManager.default.removeItem(at: staging)
            return .failure(.disk(error.localizedDescription))
        }
    }
}

enum StemError: Error, Equatable {
    case offline
    case cancelled
    case agent(String)
    case disk(String)

    var message: String {
        switch self {
        case .offline: return "Stems agent offline"
        case .cancelled: return "Cancelled"
        case .agent(let m): return m
        case .disk(let m): return "Couldn't save stems: \(m)"
        }
    }
}
