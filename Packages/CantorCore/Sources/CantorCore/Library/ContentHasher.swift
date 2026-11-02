import CryptoKit
import Foundation

public enum ContentHashError: LocalizedError {
    case truncated(String)

    public var errorDescription: String? {
        switch self {
        case .truncated(let name): "\(name) got shorter while it was being read."
        }
    }
}

/// Identifies audio by its payload, so retagging a file does not make it a new track.
public enum ContentHasher {
    static let chunkSize = 1 << 20

    /// Streams the file. A memory-mapped file that Drive truncates mid-read would crash the app with
    /// SIGBUS, while a short read here is only an error. Gives the same hash as `contentID(data:isMP3:)`.
    public static func contentID(url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let count = Int(try handle.seekToEnd())
        let name = url.lastPathComponent

        func read(_ offset: Int, _ length: Int) throws -> [UInt8] {
            try handle.seek(toOffset: UInt64(offset))
            let data = try handle.read(upToCount: length) ?? Data()
            guard data.count == length else { throw ContentHashError.truncated(name) }
            return [UInt8](data)
        }

        let range = url.pathExtension.lowercased() == "mp3" ? try mp3AudioRange(count: count, read: read) : 0..<count
        var hasher = SHA256()
        try handle.seek(toOffset: UInt64(range.lowerBound))
        var remaining = range.count
        while remaining > 0 {
            try autoreleasepool {
                guard let chunk = try handle.read(upToCount: min(chunkSize, remaining)), !chunk.isEmpty else {
                    throw ContentHashError.truncated(name)
                }
                hasher.update(data: chunk)
                remaining -= chunk.count
            }
        }
        return hex(hasher.finalize())
    }

    public static func contentID(data: Data, isMP3: Bool) -> String {
        let range = isMP3 ? mp3AudioRange(data) : 0..<data.count
        let offset = data.startIndex
        return hex(SHA256.hash(data: data[(offset + range.lowerBound)..<(offset + range.upperBound)]))
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    static func mp3AudioRange(_ data: Data) -> Range<Int> {
        let base = data.startIndex
        // The reads stay inside `data`, so this cannot throw.
        return try! mp3AudioRange(count: data.count) { offset, length in
            [UInt8](data[(base + offset)..<(base + offset + length)])
        }
    }

    /// The audio between the tags, read through `read(offset, length)` so a file need not be in memory.
    static func mp3AudioRange(count: Int, read: (Int, Int) throws -> [UInt8]) throws -> Range<Int> {
        var start = 0
        var end = count

        // ID3v2 at the head: 10-byte header with a 28-bit synchsafe size, optional footer.
        while end - start >= 10 {
            let header = try read(start, 10)
            guard header[0] == 0x49, header[1] == 0x44, header[2] == 0x33 else { break }
            let flags = header[5]
            let size = (0..<4).reduce(0) { $0 << 7 | Int(header[6 + $1] & 0x7F) }
            let total = 10 + size + (flags & 0x10 != 0 ? 10 : 0)
            guard start + total <= end else { break }
            start += total
        }

        // ID3v1 at the tail.
        if end - start >= 128, try read(end - 128, 3) == [0x54, 0x41, 0x47] {
            end -= 128
        }
        // APEv2 footer at the tail.
        if end - start >= 32 {
            let footer = try read(end - 32, 32)
            if footer[0..<8].elementsEqual("APETAGEX".utf8) {
                let size = footer[12..<16].reversed().reduce(0) { $0 << 8 | Int($1) }
                let hasHeader = footer[23] & 0x80 != 0
                let total = size + (hasHeader ? 32 : 0)
                if total <= end - start { end -= total }
            }
        }
        return start..<end
    }
}
