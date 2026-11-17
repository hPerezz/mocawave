import AppKit

/// The local dj-stack agent (labels + stems) as seen from the app: start it, check it's up.
///
/// The sandbox can't launch processes, so starting goes through a tiny helper app that handles
/// `mocawave-agent://start` by kickstarting a LaunchAgent (installed once with
/// `tools/install-mocawave-agent.sh`). Nothing here needs the internet.
enum LocalEngine {
    static let startURL = URL(string: "mocawave-agent://start")!
    static let healthURL = URL(string: "http://127.0.0.1:47321/health")!

    static var isInstalled: Bool { NSWorkspace.shared.urlForApplication(toOpen: startURL) != nil }

    /// Asks the helper to start the agent. False when the helper isn't installed.
    @MainActor
    static func requestStart() -> Bool {
        guard isInstalled else { return false }
        return NSWorkspace.shared.open(startURL)
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 1.5
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    static func isUp() async -> Bool {
        guard let (_, response) = try? await session.data(from: healthURL) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    /// Polls until the agent answers or `timeout` passes.
    static func waitUntilUp(timeout: TimeInterval = 30) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !Task.isCancelled {
            if await isUp() { return true }
            try? await Task.sleep(nanoseconds: 600_000_000)
        }
        return false
    }
}

/// The "Start engine" button's own state (separate from what the engine is asked to do).
enum EngineStartState: Equatable, Sendable {
    case idle
    case starting
    /// The helper app / LaunchAgent isn't installed yet.
    case notInstalled
    /// Asked to start but it didn't answer in time.
    case failed
}
