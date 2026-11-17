import Foundation

/// Mocawave is offline-first: everything it shows by default is computed on this Mac from the file.
/// Features that need a network (even the local one) are dev-only and off unless explicitly enabled.
enum FeatureFlags {
    /// Genre / energy / store labels from the local dj-stack track-info agent (127.0.0.1).
    /// On when built with `-D MOCA_TRACK_INFO` (the local dev build script) or run with the
    /// environment variable `MOCA_TRACK_INFO=1` (e.g. an Xcode scheme). Off in regular builds:
    /// no footer, no requests, no network entitlement needed.
    static let trackInfo: Bool = {
        #if MOCA_TRACK_INFO
        return true
        #else
        return ProcessInfo.processInfo.environment["MOCA_TRACK_INFO"] == "1"
        #endif
    }()
}
