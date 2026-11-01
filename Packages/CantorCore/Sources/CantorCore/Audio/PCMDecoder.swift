import AVFoundation
import Foundation

public enum DecodeError: LocalizedError {
    case unreadable(String)
    case truncated(String)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let name): "\(name) could not be read as audio."
        case .truncated(let name): "\(name) decoded short and may be incomplete."
        }
    }
}

public enum PCMDecoder {
    public struct FileInfo: Sendable {
        public var durationSec: Double
        public var sampleRate: Double
        public var channels: Int
    }

    public static func info(url: URL) -> FileInfo? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let rate = file.processingFormat.sampleRate
        return FileInfo(
            durationSec: rate > 0 ? Double(file.length) / rate : 0,
            sampleRate: rate,
            channels: Int(file.processingFormat.channelCount)
        )
    }

    /// Decodes the whole file. Files with more than two channels keep the first two.
    public static func decode(url: URL) throws -> PCMBuffer {
        let name = url.lastPathComponent
        guard let file = try? AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false) else {
            throw DecodeError.unreadable(name)
        }
        let format = file.processingFormat
        let capacity = AVAudioFrameCount(file.length)
        guard capacity > 0, let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw DecodeError.unreadable(name)
        }
        do {
            try file.read(into: pcm)
        } catch {
            throw DecodeError.truncated(name)
        }
        let frames = Int(pcm.frameLength)
        guard frames > 0, let channels = pcm.floatChannelData else { throw DecodeError.unreadable(name) }
        // Compressed lengths are estimates, so allow one second before calling a file truncated.
        guard Double(file.length) - Double(frames) <= format.sampleRate else { throw DecodeError.truncated(name) }

        let left = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        left.update(from: channels[0], count: frames)
        var right: UnsafeMutablePointer<Float>?
        if format.channelCount > 1 {
            let copy = UnsafeMutablePointer<Float>.allocate(capacity: frames)
            copy.update(from: channels[1], count: frames)
            right = copy
        }
        return PCMBuffer(adoptingLeft: left, right: right, frames: frames, sampleRate: format.sampleRate)
    }
}
