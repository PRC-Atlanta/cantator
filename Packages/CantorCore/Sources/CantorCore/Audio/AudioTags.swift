import AudioToolbox
import Foundation

/// Reads a file's embedded title, artist, album, genre and comment tags. Call only on a local
/// file: opening a Drive placeholder would start a download.
public enum AudioTags {
    static let keys = ["title", "artist", "album", "genre", "comments"]

    public static func read(url: URL) -> [String: String] {
        var file: AudioFileID?
        guard AudioFileOpenURL(url as CFURL, .readPermission, 0, &file) == noErr, let file else { return [:] }
        defer { AudioFileClose(file) }
        var info: Unmanaged<CFDictionary>?
        var size = UInt32(MemoryLayout<Unmanaged<CFDictionary>?>.size)
        guard AudioFileGetProperty(file, kAudioFilePropertyInfoDictionary, &size, &info) == noErr,
              let dictionary = info?.takeRetainedValue() as? [String: Any]
        else { return [:] }
        return clean(dictionary)
    }

    static func clean(_ dictionary: [String: Any]) -> [String: String] {
        var tags: [String: String] = [:]
        for key in keys {
            guard let value = (dictionary[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { continue }
            tags[key] = String(value.prefix(120))
        }
        return tags
    }
}
