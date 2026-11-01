import Darwin
import Foundation

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

    public init(path: String, locality: FileLocality, contentID: String?, durationSec: Double = 0, sampleRate: Double = 0, channels: Int = 0) {
        self.path = path
        self.locality = locality
        self.contentID = contentID
        self.durationSec = durationSec
        self.sampleRate = sampleRate
        self.channels = channels
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

public struct ScanResult: Sendable {
    public var files: [ScannedFile]
    /// A file was still being written, so another scan should follow shortly.
    public var hasUnsettledFiles: Bool
    public var unreadable: [String]
}

public enum FolderScanner {
    public static let audioExtensions: Set<String> = ["mp3", "wav", "m4a", "aif", "aiff", "aac", "caf"]
    public static let settleSeconds: TimeInterval = 2

    public static func scan(roots: [String], cache: inout HashCache, now: Date = Date()) -> ScanResult {
        var files: [ScannedFile] = []
        var unsettled = false
        var unreadable: [String] = []
        var seen = Set<String>()
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]

        for root in roots {
            guard let walker = FileManager.default.enumerator(
                at: URL(fileURLWithPath: root), includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            for case let url as URL in walker {
                guard audioExtensions.contains(url.pathExtension.lowercased()) else { continue }
                let path = url.path
                guard seen.insert(path).inserted else { continue }
                guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }

                let locality = FileLocalityProbe.locality(path: path)
                if locality != .local {
                    files.append(ScannedFile(path: path, locality: locality, contentID: nil))
                    continue
                }

                let size = Int64(values.fileSize ?? 0)
                let mtime = values.contentModificationDate?.timeIntervalSince1970 ?? 0
                if let entry = cache.entries[path], entry.size == size, entry.mtime == mtime {
                    files.append(ScannedFile(
                        path: path, locality: .local, contentID: entry.contentID,
                        durationSec: entry.durationSec, sampleRate: entry.sampleRate, channels: entry.channels
                    ))
                    continue
                }

                // AirDrop and Drive write in pieces. Wait until the file has stopped changing.
                if now.timeIntervalSince1970 - mtime < settleSeconds {
                    unsettled = true
                    continue
                }

                guard let contentID = try? ContentHasher.contentID(url: url), let info = PCMDecoder.info(url: url) else {
                    unreadable.append(path)
                    continue
                }
                cache.entries[path] = HashCache.Entry(
                    size: size, mtime: mtime, contentID: contentID, durationSec: info.durationSec,
                    sampleRate: info.sampleRate, channels: info.channels
                )
                files.append(ScannedFile(
                    path: path, locality: .local, contentID: contentID, durationSec: info.durationSec,
                    sampleRate: info.sampleRate, channels: info.channels
                ))
            }
        }
        return ScanResult(files: files, hasUnsettledFiles: unsettled, unreadable: unreadable)
    }
}
