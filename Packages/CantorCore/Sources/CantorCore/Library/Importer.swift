import AVFoundation
import Darwin
import Foundation

public enum ImportError: LocalizedError {
    case unsupported(String)
    case failed(String, String)

    public var errorDescription: String? {
        switch self {
        case .unsupported(let name): "\(name) is in a format macOS can't read, so it can't be imported."
        case .failed(let name, let reason): "Could not import \(name): \(reason)"
        }
    }
}

/// Brings a file the operator picked into the managed folder as an m4a. Lossless and
/// uncompressed sources (WAV, AIFF, FLAC, ALAC) are encoded to 256 kbps AAC with Apple's
/// encoder. Files that are already compressed are copied as they are, since encoding them
/// again would only lose quality. The original is left where it is.
public enum Importer {
    /// Formats copied unchanged.
    static let compressedExtensions: Set<String> = ["m4a", "mp3", "aac"]
    /// What the open panel offers. Anything else Core Audio reads can still be chosen by name.
    public static let pickableExtensions = ["wav", "wave", "aif", "aiff", "aifc", "flac", "caf", "m4a", "mp3", "aac"]
    static let stereoBitRate = 256_000
    /// The AAC encoder takes up to 48 kHz. Higher rates are resampled down to this.
    static let maxSampleRate = 48_000.0

    /// Imports one file and returns where it landed. Blocks while it encodes, so call it off the main thread.
    public static func importFile(_ source: URL, into folder: URL = ManagedFolder.url) throws -> URL {
        let name = source.lastPathComponent
        let manager = FileManager.default
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
            return destination
        }

        // Hidden, so a scan never picks up a half-written file.
        let partial = folder.appendingPathComponent(".\(UUID().uuidString).m4a")
        do {
            try encode(source, to: partial)
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
    /// so the title, artist and comments still help filing and matching.
    static func encode(_ source: URL, to destination: URL) throws {
        let name = source.lastPathComponent
        let asset = AVURLAsset(url: source)
        guard let loaded = load(asset),
              let basic = CMAudioFormatDescriptionGetStreamBasicDescription(loaded.format)?.pointee,
              basic.mSampleRate > 0
        else { throw ImportError.unsupported(name) }
        let track = loaded.track

        // Cantator plays two channels, so wider files are mixed down here.
        let channels = min(max(Int(basic.mChannelsPerFrame), 1), 2)
        let sampleRate = min(basic.mSampleRate, maxSampleRate)
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
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: pcm)
        output.alwaysCopiesSampleData = false
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: aac)
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

        // Feeds the encoder on this thread. A writer that is not ready yet gets a moment.
        while reader.status == .reading {
            guard input.isReadyForMoreMediaData else {
                usleep(1000)
                continue
            }
            guard let buffer = output.copyNextSampleBuffer() else { break }
            guard input.append(buffer) else { break }
        }
        input.markAsFinished()

        if reader.status == .failed || writer.status == .failed {
            reader.cancelReading()
            writer.cancelWriting()
            let reason = (writer.error ?? reader.error)?.localizedDescription ?? "the conversion stopped partway"
            throw ImportError.failed(name, reason)
        }

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
    }

    /// Loads the audio track, its format and the tags, waiting here: the importer already runs off the main thread.
    private static func load(_ asset: AVURLAsset) -> Loaded? {
        let result = Box<Loaded?>(nil)
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            defer { done.signal() }
            guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
                  let format = try? await track.load(.formatDescriptions).first
            else { return }
            let metadata = (try? await asset.load(.commonMetadata)) ?? []
            result.value = Loaded(track: track, format: format, metadata: metadata)
        }
        done.wait()
        return result.value
    }

    private final class Box<Value>: @unchecked Sendable {
        var value: Value
        init(_ value: Value) { self.value = value }
    }
}
