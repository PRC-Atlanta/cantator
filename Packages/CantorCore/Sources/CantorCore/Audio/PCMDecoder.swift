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
        try decode(url: url, chunkFrames: 1 << 20)
    }

    /// Reads to the end of the file, not to its reported length: a compressed file's length is an
    /// estimate, and a VBR MP3 without a length header can report less than it holds.
    static func decode(url: URL, chunkFrames: Int) throws -> PCMBuffer {
        let name = url.lastPathComponent
        guard let file = try? AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false) else {
            throw DecodeError.unreadable(name)
        }
        let format = file.processingFormat
        let expected = Int(file.length)
        let stereo = format.channelCount > 1
        guard expected > 0, let chunk = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(chunkFrames, 1))) else {
            throw DecodeError.unreadable(name)
        }

        var capacity = expected
        var left = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
        var right: UnsafeMutablePointer<Float>? = stereo ? .allocate(capacity: capacity) : nil
        var frames = 0
        var complete = false
        defer {
            if !complete {
                left.deallocate()
                right?.deallocate()
            }
        }

        while true {
            do {
                try file.read(into: chunk)
            } catch {
                // AVAudioFile reports the end of the file as an error. The length check below decides
                // whether it came too early.
                break
            }
            let count = Int(chunk.frameLength)
            guard count > 0 else { break }
            guard let channels = chunk.floatChannelData else { throw DecodeError.unreadable(name) }
            if frames + count > capacity {
                capacity = max(capacity * 2, frames + count)
                left = grow(left, frames: frames, to: capacity)
                right = right.map { grow($0, frames: frames, to: capacity) }
            }
            (left + frames).update(from: channels[0], count: count)
            if let right { (right + frames).update(from: channels[1], count: count) }
            frames += count
        }

        guard frames > 0 else { throw DecodeError.unreadable(name) }
        // Compressed lengths are estimates, so allow one second before calling a file truncated.
        guard Double(expected) - Double(frames) <= format.sampleRate else { throw DecodeError.truncated(name) }
        complete = true
        return PCMBuffer(adoptingLeft: left, right: right, frames: frames, sampleRate: format.sampleRate)
    }

    private static func grow(_ pointer: UnsafeMutablePointer<Float>, frames: Int, to capacity: Int) -> UnsafeMutablePointer<Float> {
        let bigger = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
        bigger.update(from: pointer, count: frames)
        pointer.deallocate()
        return bigger
    }
}
