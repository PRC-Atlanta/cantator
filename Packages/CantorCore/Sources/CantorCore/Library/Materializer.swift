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
    public static func managedFilename(track: Track, sourceExtension: String) -> String {
        let tag = track.tags.first.map { " [\($0)]" } ?? ""
        let base = (track.title + tag).components(separatedBy: CharacterSet(charactersIn: "/:\\")).joined(separator: "-")
        // Two tracks can share a title and tag, so the name carries the track's identity.
        let unique = track.contentID.map { String($0.prefix(8)) } ?? String(track.id.uuidString.prefix(8))
        return "\(base) \(unique).\(sourceExtension)"
    }

    public static func makeLocal(track: Track, timeout: TimeInterval = 300) async throws -> TrackFile {
        let managedPath = ManagedFolder.path
        guard track.files.first(where: { $0.path.hasPrefix(managedPath) && $0.locality == .local }) == nil else {
            return track.files.first { $0.path.hasPrefix(managedPath) && $0.locality == .local }!
        }
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

    private static func copyAndVerify(from source: URL, to destination: URL) throws -> TrackFile {
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: ManagedFolder.url, withIntermediateDirectories: true)
            let partial = destination.appendingPathExtension("partial")
            try? manager.removeItem(at: partial)
            try manager.copyItem(at: source, to: partial)
            if manager.fileExists(atPath: destination.path) {
                try manager.removeItem(at: destination)
            }
            try manager.moveItem(at: partial, to: destination)
        } catch {
            throw MaterializeError.failed("Could not copy \(source.lastPathComponent): \(error.localizedDescription)")
        }
        _ = try PCMDecoder.decode(url: destination)
        return TrackFile(path: destination.path, locality: .local)
    }
}
