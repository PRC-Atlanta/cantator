import AVFoundation
import Darwin
import Foundation
import Synchronization

public enum ImportError: LocalizedError {
    case unsupported(String)
    case needsFFmpeg(String)
    case noAudio(String)
    case failed(String, String)

    public var errorDescription: String? {
        switch self {
        case .unsupported(let name): "\(name) is in a format macOS can't read, so it can't be imported."
        case .needsFFmpeg(let name): "\(name) needs FFmpeg to import. This file type can't be read without it."
        case .noAudio(let name): "\(name) has no audio to import."
        case .failed(let name, let reason): "Could not import \(name): \(reason)"
        }
    }
}

/// Brings a file the operator picked into the managed folder as an m4a. Lossless and
/// uncompressed sources (WAV, AIFF, FLAC, ALAC) are encoded to 256 kbps AAC with Apple's
/// encoder. Files that are already compressed are copied as they are, since encoding them
/// again would only lose quality, and a movie's AAC soundtrack is copied out the same way.
/// Formats macOS can't read go through FFmpeg when it is installed. The original is left where it is.
public enum Importer {
    /// Formats copied unchanged. An m4a can hold ALAC as well as AAC, so it goes through the
    /// encoder, which passes AAC straight through and converts anything else.
    static let compressedExtensions: Set<String> = ["mp3", "aac"]
    /// What the open panel offers: what macOS reads, plus what FFmpeg is there for.
    public static let pickableExtensions = [
        "wav", "wave", "aif", "aiff", "aifc", "flac", "caf", "m4a", "mp3", "aac", "mov", "mp4", "m4v",
    ] + FFmpeg.extensions
    static let stereoBitRate = 256_000
    /// The AAC encoder takes up to 48 kHz. Higher rates are resampled down to this.
    static let maxSampleRate = 48_000.0

    /// How far one file has got, from 0 to 1. Called on the importing thread.
    public typealias Progress = @Sendable (Double) -> Void

    /// Imports one file and returns where it landed. Blocks while it encodes, so call it off the main thread.
    /// `ffmpeg` is the FFmpeg to use for formats macOS can't read, or nil for none.
    public static func importFile(
        _ source: URL, into folder: URL = ManagedFolder.url, ffmpeg: String? = FFmpeg.locate(), progress: Progress? = nil
    ) throws -> URL {
        let name = source.lastPathComponent
        let manager = FileManager.default
        // The steps below each report their share. This keeps the whole moving forward, with no repeats.
        let progress = progress.map { report -> Progress in
            let last = Mutex(-1.0)
            return { value in
                let isNew = last.withLock { last in
                    guard value > last else { return false }
                    last = value
                    return true
                }
                if isNew { report(value) }
            }
        }
        do {
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw ImportError.failed(name, error.localizedDescription)
        }
        let ext = source.pathExtension.lowercased()
        let keepsFormat = compressedExtensions.contains(ext)
        let destination = availableURL(in: folder, base: source.deletingPathExtension().lastPathComponent, ext: keepsFormat ? ext : "m4a")

        if keepsFormat {
            do {
                _ = try Materializer.copyAndVerify(from: source, to: destination)
            } catch {
                throw ImportError.failed(name, error.localizedDescription)
            }
            progress?(1)
            return destination
        }

        // Hidden, so a scan never picks up a half-written file.
        let partial = folder.appendingPathComponent(".\(UUID().uuidString).m4a")
        do {
            do {
                try encode(source, to: partial, progress: progress)
            } catch ImportError.unsupported {
                guard let ffmpeg else { throw ImportError.needsFFmpeg(name) }
                // FFmpeg decodes to a lossless file Apple's encoder can take, so the audio is only encoded once.
                // Each step counts for half.
                let extracted = try FFmpeg.extractAudio(from: source, ffmpeg: ffmpeg, progress: progress.map { report in { report($0 / 2) } })
                defer { try? manager.removeItem(at: extracted.deletingLastPathComponent()) }
                try encode(extracted, to: partial, name: name, progress: progress.map { report in { report(0.5 + $0 / 2) } })
            }
            try Materializer.verify(partial, name: name)
        } catch {
            try? manager.removeItem(at: partial)
            if let error = error as? ImportError { throw error }
            throw ImportError.failed(name, error.localizedDescription)
        }
        guard rename(partial.path, destination.path) == 0 else {
            let reason = String(cString: strerror(errno))
            try? manager.removeItem(at: partial)
            throw ImportError.failed(name, reason)
        }
        progress?(1)
        return destination
    }

    /// The source's own name, with " 2", " 3" and so on added if that name is taken.
    static func availableURL(in folder: URL, base: String, ext: String) -> URL {
        // A leading dot would hide the file from the scan.
        var base = String(base.drop { $0 == "." || $0 == " " })
        if base.isEmpty { base = "Imported" }
        var candidate = folder.appendingPathComponent("\(base).\(ext)")
        var number = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) \(number).\(ext)")
            number += 1
        }
        return candidate
    }

    /// Decodes with AVAssetReader and encodes with AVAssetWriter, carrying the source's tags over
    /// so the title, artist and comments still help filing and matching. AAC that already fits,
    /// such as a movie's soundtrack, is copied across without being decoded.
    static func encode(_ source: URL, to destination: URL, name: String? = nil, progress: Progress? = nil) throws {
        let name = name ?? source.lastPathComponent
        let asset = AVURLAsset(url: source)
        let loaded: Loaded
        switch load(asset) {
        case .audio(let value): loaded = value
        case .noAudio: throw ImportError.noAudio(name)
        case .unreadable: throw ImportError.unsupported(name)
        }
        guard let basic = CMAudioFormatDescriptionGetStreamBasicDescription(loaded.format)?.pointee, basic.mSampleRate > 0 else {
            throw ImportError.unsupported(name)
        }
        let track = loaded.track

        // Cantator plays two channels, so wider files are mixed down here.
        let channels = min(max(Int(basic.mChannelsPerFrame), 1), 2)
        let sampleRate = min(basic.mSampleRate, maxSampleRate)
        let passThrough = basic.mFormatID == kAudioFormatMPEG4AAC && Int(basic.mChannelsPerFrame) == channels && basic.mSampleRate == sampleRate
        let pcm: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let aac: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: stereoBitRate * channels / 2,
        ]

        let reader: AVAssetReader
        let writer: AVAssetWriter
        do {
            reader = try AVAssetReader(asset: asset)
            writer = try AVAssetWriter(outputURL: destination, fileType: .m4a)
        } catch {
            throw ImportError.unsupported(name)
        }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: passThrough ? nil : pcm)
        output.alwaysCopiesSampleData = false
        let input = passThrough
            ? AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: loaded.format)
            : AVAssetWriterInput(mediaType: .audio, outputSettings: aac)
        input.expectsMediaDataInRealTime = false
        guard reader.canAdd(output), writer.canAdd(input) else { throw ImportError.unsupported(name) }
        reader.add(output)
        writer.add(input)
        writer.metadata = metadata(loaded.metadata, tags: AudioTags.read(url: source))

        guard reader.startReading() else { throw ImportError.unsupported(name) }
        guard writer.startWriting() else {
            reader.cancelReading()
            throw ImportError.failed(name, writer.error?.localizedDescription ?? "the encoder would not start")
        }
        writer.startSession(atSourceTime: .zero)

        var reporter = ProgressThrottle()
        // Feeds the encoder on this thread. A writer that is not ready yet gets a moment. A writer
        // that fails on its own (a full disk) is never ready again, so its status ends the loop too.
        while reader.status == .reading, writer.status == .writing {
            guard input.isReadyForMoreMediaData else {
                usleep(1000)
                continue
            }
            guard let buffer = output.copyNextSampleBuffer() else { break }
            guard input.append(buffer) else { break }
            if let progress, loaded.durationSec > 0 {
                let end = CMSampleBufferGetPresentationTimeStamp(buffer) + CMSampleBufferGetDuration(buffer)
                if end.isNumeric { reporter.report(end.seconds / loaded.durationSec, to: progress) }
            }
        }
        // A reader that finished cleanly reads .completed. Anything else, on either side, is a failure.
        if reader.status == .failed || reader.status == .cancelled || writer.status != .writing {
            reader.cancelReading()
            if writer.status == .writing { writer.cancelWriting() }
            let reason = (writer.error ?? reader.error)?.localizedDescription ?? "the conversion stopped partway"
            throw ImportError.failed(name, reason)
        }
        input.markAsFinished()

        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        guard writer.status == .completed else {
            throw ImportError.failed(name, writer.error?.localizedDescription ?? "the file could not be finished")
        }
    }

    /// AVFoundation misses the info tags Core Audio reads from WAV, AIFF and CAF, which are the
    /// ones Cantator files by, so those fill any gaps in what AVFoundation found.
    static func metadata(_ found: [AVMetadataItem], tags: [String: String]) -> [AVMetadataItem] {
        let keys: [(String, AVMetadataIdentifier)] = [
            ("title", .commonIdentifierTitle), ("artist", .commonIdentifierArtist), ("album", .commonIdentifierAlbumName),
            ("genre", .iTunesMetadataUserGenre), ("comments", .iTunesMetadataUserComment),
        ]
        var items = found
        for (key, identifier) in keys {
            guard let value = tags[key], !found.contains(where: { $0.identifier == identifier }) else { continue }
            let item = AVMutableMetadataItem()
            item.identifier = identifier
            item.value = value as NSString
            items.append(item)
        }
        return items
    }

    private struct Loaded {
        var track: AVAssetTrack
        var format: CMAudioFormatDescription
        var metadata: [AVMetadataItem]
        var durationSec: Double
    }

    private enum Loading {
        case audio(Loaded)
        /// A movie macOS reads that has no sound.
        case noAudio
        case unreadable
    }

    /// Loads the first audio track, its format and the tags, waiting here: the importer already
    /// runs off the main thread. A movie's first audio track is its main mix.
    private static func load(_ asset: AVURLAsset) -> Loading {
        let result = Box<Loading>(.unreadable)
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            defer { done.signal() }
            guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
                  let format = try? await track.load(.formatDescriptions).first
            else {
                if let video = try? await asset.loadTracks(withMediaType: .video), !video.isEmpty { result.value = .noAudio }
                return
            }
            let metadata = (try? await asset.load(.commonMetadata)) ?? []
            let duration = (try? await asset.load(.duration)).map(\.seconds) ?? 0
            result.value = .audio(Loaded(track: track, format: format, metadata: metadata, durationSec: duration.isFinite ? duration : 0))
        }
        done.wait()
        return result.value
    }

    /// Passes progress on in whole-percent steps, so a caller is not called for every buffer.
    struct ProgressThrottle {
        private var last = -1

        mutating func report(_ fraction: Double, to progress: Progress) {
            let percent = Int((min(max(fraction, 0), 1) * 100).rounded(.down))
            guard percent > last else { return }
            last = percent
            progress(Double(percent) / 100)
        }
    }

    private final class Box<Value>: @unchecked Sendable {
        var value: Value
        init(_ value: Value) { self.value = value }
    }
}
