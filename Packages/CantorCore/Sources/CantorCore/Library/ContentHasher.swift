import CryptoKit
import Foundation

/// Identifies audio by its payload, so retagging a file does not make it a new track.
public enum ContentHasher {
    public static func contentID(url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return contentID(data: data, isMP3: url.pathExtension.lowercased() == "mp3")
    }

    public static func contentID(data: Data, isMP3: Bool) -> String {
        let range = isMP3 ? mp3AudioRange(data) : 0..<data.count
        let offset = data.startIndex
        let digest = SHA256.hash(data: data[(offset + range.lowerBound)..<(offset + range.upperBound)])
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func mp3AudioRange(_ data: Data) -> Range<Int> {
        let bytes = data.startIndex
        var start = 0
        var end = data.count

        // ID3v2 at the head: 10-byte header with a 28-bit synchsafe size, optional footer.
        while end - start >= 10,
              data[bytes + start] == 0x49, data[bytes + start + 1] == 0x44, data[bytes + start + 2] == 0x33 {
            let flags = data[bytes + start + 5]
            let size = (0..<4).reduce(0) { $0 << 7 | Int(data[bytes + start + 6 + $1] & 0x7F) }
            let total = 10 + size + (flags & 0x10 != 0 ? 10 : 0)
            guard start + total <= end else { break }
            start += total
        }

        // ID3v1 at the tail.
        if end - start >= 128,
           data[bytes + end - 128] == 0x54, data[bytes + end - 127] == 0x41, data[bytes + end - 126] == 0x47 {
            end -= 128
        }
        // APEv2 footer at the tail.
        if end - start >= 32, data[(bytes + end - 32)..<(bytes + end - 24)].elementsEqual("APETAGEX".utf8) {
            let sizeBytes = data[(bytes + end - 20)..<(bytes + end - 16)]
            let size = sizeBytes.reversed().reduce(0) { $0 << 8 | Int($1) }
            let flags = data[bytes + end - 9]
            let hasHeader = flags & 0x80 != 0
            let total = size + (hasHeader ? 32 : 0)
            if total <= end - start { end -= total }
        }
        return start..<end
    }
}
