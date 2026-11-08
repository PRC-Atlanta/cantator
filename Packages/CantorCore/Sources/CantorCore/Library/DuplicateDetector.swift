import Foundation

/// Copies of one playback that are not the same bytes, such as an MP3 and a WAV of a song, or a
/// file downloaded twice as "Song (1).mp3". Identical files are already one track. One of each set
/// stays and the rest are excluded, so the song is matched and listed once.
public enum DuplicateDetector {
    /// An MP3 runs a few hundredths of a second longer than its WAV. Versions of a song with
    /// different names are never compared, so this only has to absorb encoding.
    static let lengthToleranceSec = 0.5
    static let losslessExtensions: Set<String> = ["wav", "aif", "aiff", "caf"]

    /// Reasons for the copies to set aside. `skipping` tracks (stems found in the same pass) are
    /// left out. Tracks the operator kept or excluded, and `protected` ones, are never returned, but
    /// a kept or protected track is the one that stays.
    public static func detect(tracks: [Track], protected: Set<UUID> = [], skipping: Set<UUID> = []) -> [UUID: String] {
        // A file not downloaded from a cloud drive has no length yet, but it has a size.
        let candidates = tracks.filter { track in
            track.exclusion?.byOperator != true && !skipping.contains(track.id) && (track.durationSec > 0 || size(of: track) != nil)
        }
        let named = candidates.compactMap { track -> (key: String, track: Track)? in
            guard let file = StemDetector.sourceFile(track) else { return nil }
            let key = nameKey(file.filename)
            return key.isEmpty ? nil : (key, track)
        }
        var reasons: [UUID: String] = [:]
        for (_, members) in Dictionary(grouping: named, by: \.key) where members.count > 1 {
            for set in copySets(members.map(\.track)) where set.count > 1 {
                let keeper = keeper(of: set, protected)
                let name = StemDetector.sourceFile(keeper).map { describe($0) } ?? keeper.title
                for track in set where track.id != keeper.id && !track.keptByOperator && !protected.contains(track.id) {
                    reasons[track.id] = "Duplicate of \(name)"
                }
            }
        }
        return reasons
    }

    /// The filename without what a copy adds: the extension, a copy suffix ("(1)", "copy"), a
    /// leading track number and a bitrate. Every other word has to match, so "Full Mix" and
    /// "Instrumental", or two keys of a song, are never copies of each other.
    static func nameKey(_ filename: String) -> String {
        var value = (filename as NSString).deletingPathExtension
        value = value.replacingOccurrences(of: #"(\s*\(\d+\)|[\s_-]+copy(\s*\d+|\s*\(\d+\))?)+$"#, with: "", options: [.regularExpression, .caseInsensitive])
        let words = TitleNormalizer.tokens(value)
            .drop { $0.allSatisfy(\.isNumber) }
            .filter { $0.range(of: #"^\d+(k|kbps)$"#, options: .regularExpression) == nil }
        return words.joined(separator: " ")
    }

    /// Same-named tracks that are copies of each other: lengths within the tolerance, or, when a
    /// length is not known, nearly the same number of bytes. Copies of copies join one set.
    static func copySets(_ tracks: [Track]) -> [[Track]] {
        var parent = Array(tracks.indices)
        func root(_ index: Int) -> Int {
            var index = index
            while parent[index] != index { index = parent[index] }
            return index
        }
        let sizes = tracks.map { size(of: $0) }
        for a in tracks.indices {
            for b in tracks.indices where b > a {
                let lengths = tracks[a].durationSec > 0 && tracks[b].durationSec > 0
                let copies = lengths
                    ? abs(tracks[a].durationSec - tracks[b].durationSec) <= lengthToleranceSec
                    : sameSize(sizes[a], sizes[b])
                if copies { parent[root(b)] = root(a) }
            }
        }
        return Array(Dictionary(grouping: tracks.indices, by: root).values.map { $0.map { tracks[$0] } })
    }

    /// Bytes within 0.1%: a copy whose title or artist tag was edited is a few kilobytes off. About
    /// the length tolerance's worth of audio at MP3 rates, and far apart for an MP3 and a WAV.
    static let sizeTolerance = 0.001

    static func sameSize(_ a: Int64?, _ b: Int64?) -> Bool {
        guard let a, let b, a > 0, b > 0 else { return false }
        return Double(abs(a - b)) <= Double(max(a, b)) * sizeTolerance
    }

    /// The source file's size from the last scan.
    static func size(of track: Track) -> Int64? {
        StemDetector.sourceFile(track)?.sizeBytes
    }

    /// Which copy stays: the one the operator chose or a service uses, then the one with their
    /// work on it, then one on this Mac, then lossless, then one already copied into
    /// ~/Music/Cantor. The first path settles a tie, so the same copy stays scan after scan.
    static func keeper(of set: [Track], _ protected: Set<UUID>) -> Track {
        set.min { a, b in
            let left = rank(a, protected), right = rank(b, protected)
            guard left == right else { return left.lexicographicallyPrecedes(right, by: >) }
            return (StemDetector.sourceFile(a)?.path ?? "") < (StemDetector.sourceFile(b)?.path ?? "")
        }!
    }

    static func rank(_ track: Track, _ protected: Set<UUID>) -> [Int] {
        let worked = track.endSec != nil || track.startSec > 0 || !track.markers.isEmpty || !track.tags.isEmpty
            || !track.notes.isEmpty || !track.pcoSongIDs.isEmpty || track.playCount > 0
        let lossless = StemDetector.sourceFile(track).map { losslessExtensions.contains($0.url.pathExtension.lowercased()) } ?? false
        let copied = track.files.contains { $0.path.hasPrefix(ManagedFolder.path + "/") }
        return [track.keptByOperator || protected.contains(track.id), worked, track.isLocal, lossless, copied].map { $0 ? 1 : 0 }
    }

    static func describe(_ file: TrackFile) -> String {
        let folder = file.url.deletingLastPathComponent().lastPathComponent
        return "“\(file.filename)” in \(folder)"
    }
}
