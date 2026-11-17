import AVFoundation

/// Plays the stems of the current track on the player's engine, sample-locked to the main node.
///
/// The main player node keeps running (muted) and stays the transport clock: position, seek, the end of
/// the track and the meters work unchanged. Each stem gets its own player node into the main mixer; all
/// nodes, main included, start on the same host time, so they never drift (same device clock).
@MainActor
final class StemPlayer {
    private weak var engine: AVAudioEngine?
    private var nodes: [StemKind: AVAudioPlayerNode] = [:]
    private var files: [StemKind: AVAudioFile] = [:]
    /// Stem frames to skip so they line up with the source as Core Audio plays it (`StemStore.alignment`).
    private(set) var offsetFrames = 0

    var isAttached: Bool { !nodes.isEmpty }

    /// Attaches one node per stem. Returns false (and attaches nothing) if a file can't be opened.
    @discardableResult
    func attach(_ set: StemSet, to engine: AVAudioEngine, offsetFrames: Int = 0) -> Bool {
        detach()
        self.offsetFrames = offsetFrames
        var opened: [StemKind: AVAudioFile] = [:]
        for file in set.files {
            guard let f = try? AVAudioFile(forReading: file.url) else { return false }
            opened[file.kind] = f
        }
        for (kind, file) in opened {
            let node = AVAudioPlayerNode()
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: file.processingFormat)
            nodes[kind] = node
        }
        files = opened
        self.engine = engine
        return true
    }

    func detach() {
        for node in nodes.values {
            node.stop()
            engine?.detach(node)
        }
        nodes = [:]
        files = [:]
        engine = nil
    }

    /// Schedules every stem from `seconds` and starts it at `time` (shared with the main node).
    func play(from seconds: TimeInterval, at time: AVAudioTime) {
        for (kind, node) in nodes {
            guard let file = files[kind] else { continue }
            let rate = file.processingFormat.sampleRate
            let start = min(max(AVAudioFramePosition(seconds * rate) + AVAudioFramePosition(offsetFrames), 0), file.length)
            let count = AVAudioFrameCount(max(file.length - start, 0))
            node.stop()
            guard count > 0 else { continue }
            node.scheduleSegment(file, startingFrame: start, frameCount: count, at: nil)
            node.play(at: time)
        }
    }

    func stop() {
        nodes.values.forEach { $0.stop() }
    }

    func apply(_ lanes: [StemLane]) {
        let anySolo = lanes.contains { $0.isSoloed }
        for lane in lanes {
            nodes[lane.kind]?.volume = lane.gain(anySolo: anySolo)
        }
    }

    /// A start time a little in the future so every node can be scheduled before it (~2 IO cycles).
    static func sharedStartTime(lead: TimeInterval = 0.05) -> AVAudioTime {
        AVAudioTime(hostTime: mach_absolute_time() + AVAudioTime.hostTime(forSeconds: lead))
    }
}
