import Darwin
import Foundation
import Synchronization

public enum FileLocalityProbe {
    private static let datalessFlag: UInt32 = 0x4000_0000 // SF_DATALESS

    /// Decides locality from `lstat` only. Reading a File Provider placeholder would start a
    /// download, so this must never open the file.
    public static func locality(path: String) -> FileLocality {
        var info = stat()
        guard lstat(path, &info) == 0 else { return .missing }
        if info.st_flags & datalessFlag != 0 { return .cloudOnly }
        if info.st_size > 0, info.st_blocks == 0 { return .cloudOnly }
        return .local
    }
}

public struct ScannedFile: Equatable, Sendable {
    public var path: String
    public var locality: FileLocality
    public var contentID: String?
    public var durationSec: Double
    public var sampleRate: Double
    public var channels: Int
    /// When the file arrived in its folder. Decides whether it counts as new.
    public var addedDate: Date?

    public init(
        path: String, locality: FileLocality, contentID: String?, durationSec: Double = 0, sampleRate: Double = 0, channels: Int = 0,
        addedDate: Date? = nil
    ) {
        self.path = path
        self.locality = locality
        self.contentID = contentID
        self.durationSec = durationSec
        self.sampleRate = sampleRate
        self.channels = channels
        self.addedDate = addedDate
    }
}

public struct HashCache: Codable, Sendable {
    public struct Entry: Codable, Sendable {
        var size: Int64
        var mtime: Double
        var contentID: String
        var durationSec: Double
        var sampleRate: Double
        var channels: Int
    }

    public var entries: [String: Entry] = [:]
    public init() {}
}

/// Paths a scan could not see. Their tracks keep the state they had, rather than turning missing
/// because a download was unsettled, a file would not decode or a folder could not be listed.
public struct ScanGaps: Equatable, Sendable {
    public var paths: Set<String>
    /// Roots or subfolders that failed to enumerate. Everything under them is unknown.
    public var folders: [String]

    public init(paths: Set<String> = [], folders: [String] = []) {
        self.paths = paths
        self.folders = folders
    }

    public var isEmpty: Bool { paths.isEmpty && folders.isEmpty }

    public func contains(_ path: String) -> Bool {
        paths.contains(path) || folders.contains { path == $0 || path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
    }
}

public struct ScanResult: Sendable {
    public var files: [ScannedFile]
    /// A file was still being written, so another scan should follow shortly.
    public var hasUnsettledFiles: Bool
    public var unreadable: [String]
    /// What the scan skipped, for `Library.merge`.
    public var gaps: ScanGaps = ScanGaps()
}

public enum FolderScanner {
    public static let audioExtensions: Set<String> = ["mp3", "wav", "m4a", "aif", "aiff", "aac", "caf"]
    public static let settleSeconds: TimeInterval = 2

    public static func scan(roots: [String], cache: inout HashCache, now: Date = Date()) -> ScanResult {
        var files: [ScannedFile] = []
        var unsettled = false
        var unreadable: [String] = []
        var gaps = ScanGaps()
        var seen = Set<String>()
        let keys: [URLResourceKey] = [
            .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey, .addedToDirectoryDateKey, .creationDateKey,
        ]

        for root in roots {
            // Called for the root itself (no permission, Drive not running) and for any subfolder.
            let failed = Mutex([String]())
            guard let walker = FileManager.default.enumerator(
                at: URL(fileURLWithPath: root), includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: { url, _ in
                    failed.withLock { $0.append(url.path) }
                    return true
                }
            ) else {
                gaps.folders.append(root)
                // Listed paths have symlinks resolved, as in /private/var.
                if let resolved = realpath(root, nil) {
                    gaps.folders.append(String(cString: resolved))
                    free(resolved)
                }
                continue
            }

            for case let url as URL in walker {
                guard audioExtensions.contains(url.pathExtension.lowercased()) else { continue }
                let path = url.path
                guard seen.insert(path).inserted else { continue }
                guard var values = try? url.resourceValues(forKeys: Set(keys)) else {
                    gaps.paths.insert(path)
                    continue
                }
                let added = values.addedToDirectoryDate ?? values.creationDate

                // A linked file is read through its target but listed where the link is.
                var target = url
                if values.isSymbolicLink == true {
                    target = url.resolvingSymlinksInPath()
                    guard let resolved = try? target.resourceValues(forKeys: Set(keys)) else {
                        gaps.paths.insert(path)
                        continue
                    }
                    values = resolved
                }
                guard values.isRegularFile == true else { continue }

                let locality = FileLocalityProbe.locality(path: target.path)
                if locality != .local {
                    files.append(ScannedFile(path: path, locality: locality, contentID: nil, addedDate: added))
                    continue
                }

                let size = Int64(values.fileSize ?? 0)
                let mtime = values.contentModificationDate?.timeIntervalSince1970 ?? 0
                if let entry = cache.entries[path], entry.size == size, entry.mtime == mtime {
                    files.append(ScannedFile(
                        path: path, locality: .local, contentID: entry.contentID,
                        durationSec: entry.durationSec, sampleRate: entry.sampleRate, channels: entry.channels, addedDate: added
                    ))
                    continue
                }

                // AirDrop and Drive write in pieces. Wait until the file has stopped changing. A date
                // in the future (a zip made in another time zone) is not a file being written: waiting
                // for it would rescan every few seconds until the clock caught up.
                let age = now.timeIntervalSince1970 - mtime
                if age >= 0, age < settleSeconds {
                    unsettled = true
                    gaps.paths.insert(path)
                    continue
                }

                guard let contentID = try? ContentHasher.contentID(url: target), let info = PCMDecoder.info(url: target) else {
                    unreadable.append(path)
                    gaps.paths.insert(path)
                    continue
                }
                cache.entries[path] = HashCache.Entry(
                    size: size, mtime: mtime, contentID: contentID, durationSec: info.durationSec,
                    sampleRate: info.sampleRate, channels: info.channels
                )
                files.append(ScannedFile(
                    path: path, locality: .local, contentID: contentID, durationSec: info.durationSec,
                    sampleRate: info.sampleRate, channels: info.channels, addedDate: added
                ))
            }
            gaps.folders += failed.withLock { $0 }
        }
        return ScanResult(files: files, hasUnsettledFiles: unsettled, unreadable: unreadable, gaps: gaps)
    }
}
