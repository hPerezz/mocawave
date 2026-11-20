import AVFoundation
import Foundation

/// Files Core Audio's AVAudioFile can't read but AVFoundation can, e.g. Opus inside an .m4a/.mp4 (what
/// Suno downloads are): AVAudioFile opens them with length 0 and fails to read. They're decoded once with
/// AVAssetReader into a CAF in the app cache, and the player and every analysis use that copy; the original
/// stays the track's identity (tab, title, agents).
enum AudioDecoding {
    enum Status {
        /// AVAudioFile reads it: nothing to do.
        case native
        /// Decoded before: play this copy.
        case cached(URL)
        /// Needs one decode into this destination.
        case needsDecoding(URL)
    }

    static func status(of url: URL) -> Status {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        if let file = try? AVAudioFile(forReading: url), file.length > 0 { return .native }
        guard let dest = destination(for: url) else { return .native }
        if FileManager.default.fileExists(atPath: dest.path) { return .cached(dest) }
        return .needsDecoding(dest)
    }

    static func destination(for url: URL) -> URL? {
        guard let key = AudioCache.trackKey(for: url) else { return nil }
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return caches.appendingPathComponent("mocawave/decoded/\(key).caf")
    }

    enum DecodeError: LocalizedError {
        case noAudioTrack, unreadable(String)
        var errorDescription: String? {
            switch self {
            case .noAudioTrack: return "No audio track in the file"
            case .unreadable(let why): return "Can't decode this file (\(why))"
            }
        }
    }

    /// Decodes `url` to 16-bit PCM CAF at `dest` (written to a temp file, then moved into place).
    static func decode(_ url: URL, to dest: URL) async throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw DecodeError.noAudioTrack }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ])
        reader.add(output)
        guard reader.startReading() else { throw DecodeError.unreadable(reader.error?.localizedDescription ?? "reader") }

        let fm = FileManager.default
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temp = dest.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).caf")
        defer { try? fm.removeItem(at: temp) }
        var frames = 0
        do {
            var file: AVAudioFile?
            while let sample = output.copyNextSampleBuffer() {
                try Task.checkCancellation()
                let count = CMSampleBufferGetNumSamples(sample)
                guard count > 0, let description = CMSampleBufferGetFormatDescription(sample) else { continue }
                let format = AVAudioFormat(cmAudioFormatDescription: description)
                if file == nil {
                    file = try AVAudioFile(forWriting: temp, settings: [
                        AVFormatIDKey: kAudioFormatLinearPCM,
                        AVSampleRateKey: format.sampleRate,
                        AVNumberOfChannelsKey: format.channelCount,
                        AVLinearPCMBitDepthKey: 16,
                        AVLinearPCMIsFloatKey: false,
                        AVLinearPCMIsBigEndianKey: false,
                    ], commonFormat: .pcmFormatFloat32, interleaved: format.isInterleaved)
                }
                // Interleaved float32 (as requested above): copy the block's bytes straight into the buffer.
                // (CMSampleBufferCopyPCMDataIntoAudioBufferList fails on these with -12731.)
                guard let block = CMSampleBufferGetDataBuffer(sample),
                      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
                      let destination = buffer.mutableAudioBufferList.pointee.mBuffers.mData else { continue }
                let bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
                let length = min(CMBlockBufferGetDataLength(block), count * bytesPerFrame)
                let status = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: destination)
                guard status == kCMBlockBufferNoErr, bytesPerFrame > 0 else { throw DecodeError.unreadable("PCM copy \(status)") }
                buffer.frameLength = AVAudioFrameCount(length / bytesPerFrame)
                try file?.write(from: buffer)
                frames += Int(buffer.frameLength)
            }
        }   // the writer closes here, before the move
        guard reader.status == .completed, frames > 0 else {
            throw DecodeError.unreadable(reader.error?.localizedDescription ?? "no audio decoded")
        }
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try fm.moveItem(at: temp, to: dest)
    }
}
