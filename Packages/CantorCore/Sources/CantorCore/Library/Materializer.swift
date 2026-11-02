import AVFoundation
import Darwin
import Foundation
import Synchronization

public enum MaterializeError: LocalizedError {
    case noSource
    case timedOut(String)
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .noSource: "No copy of this file is available."
        case .timedOut(let name): "\(name) did not finish downloading in time. Check that Drive is online."
        case .failed(let message): message
        }
    }
}

/// Copies a track into the managed folder. Reading a Drive placeholder downloads it, so this is
/// also how a cloud-only file becomes safe to use. Originals are left where they are.
public enum Materializer {
    /// APFS and HFS+ allow 255 bytes of UTF-8 per name.
    static let maxFilenameBytes = 255

    public static func managedFilename(track: Track, sourceExtension: String) -> String {
        let tag = track.tags.first.map { " [\($0)]" } ?? ""
        var base = (track.title + tag).components(separatedBy: CharacterSet(charactersIn: "/:\\")).joined(separator: "-")
        // A leading dot would hide the copy from the scan.
        base = String(base.drop { $0 == "." || $0 == " " })
        // Two tracks can share a title and tag, so the name carries the track's identity.
        let unique = track.contentID.map { String($0.prefix(8)) } ?? String(track.id.uuidString.prefix(8))
        let suffix = " \(unique).\(sourceExtension)"
        while base.utf8.count + suffix.utf8.count > maxFilenameBytes, !base.isEmpty {
            base.removeLast()
        }
        return base.trimmingCharacters(in: .whitespaces) + suffix
    }

    /// The track's local copy in the managed folder, if it has one. The trailing slash keeps a
    /// sibling such as ~/Music/Cantor Old from counting.
    static func managedCopy(of track: Track, managedPath: String = ManagedFolder.path) -> TrackFile? {
        let prefix = managedPath.hasSuffix("/") ? managedPath : managedPath + "/"
        return track.files.first { $0.path.hasPrefix(prefix) && $0.locality == .local }
    }

    public static func makeLocal(track: Track, timeout: TimeInterval = 300) async throws -> TrackFile {
        if let existing = managedCopy(of: track) { return existing }
        guard let source = track.bestFile() ?? track.files.first(where: { $0.locality == .cloudOnly }) else {
            throw MaterializeError.noSource
        }

        let destination = ManagedFolder.url.appendingPathComponent(
            managedFilename(track: track, sourceExtension: source.url.pathExtension)
        )
        let name = source.filename
        let copy = Task.detached(priority: .userInitiated) { () throws -> TrackFile in
            try copyAndVerify(from: source.url, to: destination)
        }
        let watchdog = Task.detached { () throws -> TrackFile in
            try await Task.sleep(for: .seconds(timeout))
            throw MaterializeError.timedOut(name)
        }
        defer { watchdog.cancel() }

        // A blocked copy cannot be cancelled, so whichever finishes first answers and the other is ignored.
        // Each copy writes its own partial file, so one left running after a timeout cannot collide with a retry.
        let resumed = Mutex(false)
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<TrackFile, Error>) in
            let finish = { @Sendable (result: Result<TrackFile, Error>) in
                let isFirst = resumed.withLock { done in
                    defer { done = true }
                    return !done
                }
                if isFirst { continuation.resume(with: result) }
            }
            for task in [copy, watchdog] {
                Task { finish(await task.result) }
            }
        }
    }

    /// Copies to a hidden partial file beside the destination, proves it reads as audio, then
    /// renames it into place in one step. A copy that fails is removed.
    static func copyAndVerify(from source: URL, to destination: URL) throws -> TrackFile {
        let manager = FileManager.default
        let folder = destination.deletingLastPathComponent()
        // Hidden, so a scan never picks it up. It keeps the extension, which the decoder needs.
        let partial = folder.appendingPathComponent(".\(UUID().uuidString).\(destination.pathExtension)")
        do {
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
            try manager.copyItem(at: source, to: partial)
        } catch {
            try? manager.removeItem(at: partial)
            throw MaterializeError.failed("Could not copy \(source.lastPathComponent): \(error.localizedDescription)")
        }
        do {
            try verify(partial, name: source.lastPathComponent)
        } catch {
            try? manager.removeItem(at: partial)
            throw error
        }
        // rename(2) replaces an older copy atomically, so the destination is never half written.
        guard rename(partial.path, destination.path) == 0 else {
            let reason = String(cString: strerror(errno))
            try? manager.removeItem(at: partial)
            throw MaterializeError.failed("Could not copy \(source.lastPathComponent): \(reason)")
        }
        return TrackFile(path: destination.path, locality: .local)
    }

    /// Opens the copy and reads its first and last frames, which proves it is audio and complete
    /// without decoding the whole song into memory. Load Service decodes it in full later.
    static func verify(_ url: URL, name: String) throws {
        guard let file = try? AVAudioFile(forReading: url), file.length > 0 else { throw DecodeError.unreadable(name) }
        let frames = AVAudioFrameCount(min(file.length, 4096))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else {
            throw DecodeError.unreadable(name)
        }
        do {
            try file.read(into: buffer, frameCount: frames)
            buffer.frameLength = 0
            // Compressed lengths are estimates, so the tail read starts a second early.
            file.framePosition = max(file.length - AVAudioFramePosition(frames) - AVAudioFramePosition(file.processingFormat.sampleRate), 0)
            try file.read(into: buffer, frameCount: frames)
        } catch {
            throw DecodeError.truncated(name)
        }
        guard buffer.frameLength > 0 else { throw DecodeError.truncated(name) }
    }
}
