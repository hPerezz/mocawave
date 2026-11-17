import AVFoundation
import Foundation

/// Stems as files for a DAW: drag a lane into Ableton (or copy it) and get a WAV that
/// - is sample-aligned with the original track (same decoder offset the player compensates),
/// - carries the track tempo in an ACID chunk, which Ableton (and most DAWs) read to set the clip's tempo,
/// - is named "Artist - Title - Drums 120bpm.wav".
/// Files live in ~/Music/Mocawave/Stems/<track>/ — a plain folder any app can read (the sandbox grants
/// Music read-write), and they're reused until the stems change.
enum StemExport {
    struct Request: Sendable {
        var source: URL            // cached stem (FLAC)
        var kind: StemKind
        var trackName: String
        var bpm: Double?
        var offsetFrames: Int       // stem frames to skip so it lines up with the source as decoded
    }

    /// Real ~/Music (inside the sandbox the container's Music is a symlink to it).
    static var root: URL {
        let music = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first!
        return music.resolvingSymlinksInPath().appendingPathComponent("Mocawave/Stems", isDirectory: true)
    }

    static func destination(for request: Request) -> URL {
        let track = sanitize(request.trackName)
        var name = "\(track) - \(request.kind.rawValue.capitalized)"
        if let bpm = request.bpm, bpm > 0 { name += " \(formatBPM(bpm))bpm" }
        return root.appendingPathComponent(track, isDirectory: true).appendingPathComponent(name + ".wav")
    }

    /// The exported file, writing it first if it's missing or older than the cached stem.
    static func file(for request: Request) throws -> URL {
        let url = destination(for: request)
        let fm = FileManager.default
        if let done = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
           let stem = try? request.source.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
           done >= stem {
            return url
        }
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temp = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).wav")
        defer { try? fm.removeItem(at: temp) }
        let frames = try writeWAV(from: request.source, to: temp, skip: request.offsetFrames)
        if let bpm = request.bpm, bpm > 0 {
            try appendACIDChunk(to: temp, bpm: bpm, frames: frames, sampleRate: 44_100)
        }
        if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
        try fm.moveItem(at: temp, to: url)
        return url
    }

    // MARK: Writing

    /// 16-bit PCM WAV, same rate/channels as the stem; `skip` frames dropped at the start (negative = pad).
    /// Returns the number of frames written.
    @discardableResult
    static func writeWAV(from source: URL, to destination: URL, skip: Int) throws -> AVAudioFramePosition {
        let input = try AVAudioFile(forReading: source)
        let format = input.processingFormat
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        var written: AVAudioFramePosition = 0
        do {
            let output = try AVAudioFile(forWriting: destination, settings: settings,
                                         commonFormat: .pcmFormatFloat32, interleaved: false)
            let chunk: AVAudioFrameCount = 65_536
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else {
                throw CocoaError(.fileWriteUnknown)
            }
            if skip < 0, let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(-skip)) {
                silence.frameLength = AVAudioFrameCount(-skip)   // zero-filled
                try output.write(from: silence)
                written += AVAudioFramePosition(-skip)
            }
            input.framePosition = AVAudioFramePosition(max(skip, 0))
            while input.framePosition < input.length {
                try input.read(into: buffer, frameCount: chunk)
                if buffer.frameLength == 0 { break }
                try output.write(from: buffer)
                written += AVAudioFramePosition(buffer.frameLength)
            }
        }   // output closes here (deinit), before the ACID chunk is appended
        return written
    }

    /// ACID chunk ("acid", 24 bytes): flags, root note, 2 reserved, beats, meter 4/4, tempo. Appended at the
    /// end of the RIFF and the RIFF size updated.
    static func appendACIDChunk(to url: URL, bpm: Double, frames: AVAudioFramePosition, sampleRate: Double) throws {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let beats = UInt32(max(1, (Double(frames) / sampleRate * bpm / 60).rounded()))
        var chunk = Data("acid".utf8)
        chunk.append(le32(24))
        chunk.append(le32(0x04))          // flags: stretch on (a loop, not a one-shot); no root note
        chunk.append(le16(0x3C))          // root note C4 (ignored, flag not set)
        chunk.append(le16(0x8000))        // reserved
        chunk.append(le32(0))             // reserved (float 0)
        chunk.append(le32(beats))
        chunk.append(le16(4))             // meter denominator
        chunk.append(le16(4))             // meter numerator
        chunk.append(le32(Float(bpm).bitPattern))
        let end = try handle.seekToEnd()
        if end % 2 == 1 { handle.write(Data([0])) }   // chunks start on even offsets
        handle.write(chunk)
        let total = try handle.seekToEnd()
        try handle.seek(toOffset: 4)
        handle.write(le32(UInt32(total - 8)))
    }

    // MARK: Helpers

    static func formatBPM(_ bpm: Double) -> String {
        bpm.rounded() == bpm ? String(Int(bpm)) : String(format: "%.1f", bpm)
    }

    private static func sanitize(_ name: String) -> String {
        let bad = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        return name.components(separatedBy: bad).joined(separator: "-").trimmingCharacters(in: .whitespaces)
    }

    private static func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
    private static func le16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
}
