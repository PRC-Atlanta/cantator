import Foundation

/// Finds stems, click tracks, practice parts and demos that share folders with playbacks, from
/// filenames, folder names and sets of files with the same length. It only proposes exclusions. The operator can bring any track back.
public enum StemDetector {
    static let folderWords: Set<String> = ["stem", "stems", "multitrack", "multitracks", "multis", "practice", "rehearsal", "ptx"]
    /// Words that mark a stem on their own.
    static let strongWords: Set<String> = [
        "click", "clicktrack", "metronome", "stem", "stems", "multitrack", "multitracks", "bgv", "bgvs", "vox",
        "drums", "kick", "snare", "toms", "overheads", "perc", "percussion",
        // A part to learn from, such as "S PTX", "Practice Trax" or a listening demo, is never played in a service.
        "ptx", "practice", "rehearsal", "demo", "demos",
    ]
    /// Words that also appear in song titles and playback names, so they count only inside a same-length set.
    static let weakWords: Set<String> = [
        "guide", "cues", "bass", "keys", "piano", "organ", "pad", "pads", "synth", "strings", "guitar", "gtr", "eg", "ag",
        "acoustic", "electric", "vocal", "vocals", "lead", "harmony", "harmonies", "soprano", "alto", "tenor", "baritone",
        "horns", "brass", "sax", "cello", "violin", "fx", "sfx", "loop", "loops", "rhythm", "drum",
    ]
    /// Words that point to a full mix or a version of one, never to a stem.
    static let keepWords: Set<String> = [
        "mix", "full", "master", "mastered", "playback", "accompaniment", "instrumental", "performance", "split",
        "stereo", "no", "without", "minus", "with", "key",
    ]
    static let minimumSet = 3
    static let lengthToleranceSec = 0.1

    /// Reasons for the tracks that look like stems. Tracks the operator kept or excluded, and
    /// `protected` tracks (confirmed for a service), are never returned.
    public static func detect(tracks: [Track], protected: Set<UUID> = []) -> [UUID: String] {
        let eligible = Set(tracks.filter {
            !$0.keptByOperator && $0.exclusion?.byOperator != true && !protected.contains($0.id)
        }.map(\.id))
        var reasons: [UUID: String] = [:]
        for track in tracks where eligible.contains(track.id) {
            if let reason = reasonFromName(track) { reasons[track.id] = reason }
        }

        // Every track counts toward a set, including excluded ones, since a set is evidence about its members.
        let located = tracks.compactMap { track -> (folder: String, track: Track)? in
            guard track.durationSec > 0, let file = track.bestFile() ?? track.files.first else { return nil }
            return (file.url.deletingLastPathComponent().path, track)
        }
        for (folder, members) in Dictionary(grouping: located, by: \.folder) {
            for set in sameLength(members.map(\.track)) where set.count >= minimumSet {
                let words = set.map { nameWords(in: $0.primaryFilename) }
                let stemCount = words.filter { !$0.isDisjoint(with: strongWords.union(weakWords)) && $0.isDisjoint(with: keepWords) }.count
                let folderName = URL(fileURLWithPath: folder).lastPathComponent
                for (index, track) in set.enumerated() where eligible.contains(track.id) && reasons[track.id] == nil {
                    guard words[index].isDisjoint(with: keepWords) else { continue }
                    if let word = words[index].intersection(weakWords).sorted().first {
                        reasons[track.id] = "Name says \(word.capitalized), one of \(set.count) files the same length"
                    } else if stemCount >= 2 {
                        reasons[track.id] = "One of \(set.count) files the same length as stems in \(folderName)"
                    }
                }
            }
        }
        return reasons
    }

    private static func reasonFromName(_ track: Track) -> String? {
        guard let file = track.bestFile() ?? track.files.first else { return nil }
        let words = nameWords(in: file.filename)
        guard words.isDisjoint(with: keepWords) else { return nil }
        if let word = words.intersection(strongWords).sorted().first {
            return "Name says \(display(word))"
        }
        // Only the folder the file is in and the one above it, as in Stems/Song or Song/Stems.
        let folders = file.url.deletingLastPathComponent().pathComponents.suffix(2)
        if let folder = folders.last(where: { !nameWords(in: $0).isDisjoint(with: folderWords) }) {
            return "In a folder named \(folder)"
        }
        return nil
    }

    static func display(_ word: String) -> String {
        word == "ptx" ? "PTX" : word.capitalized
    }

    /// Tokens, plus pairs run back together when that makes a stem word, since "MultiTracks" and
    /// "Multi Tracks" tokenize as "multi" and "tracks".
    static func nameWords(in text: String) -> Set<String> {
        let tokens = TitleNormalizer.tokens(text)
        var words = Set(tokens)
        for (first, second) in zip(tokens, tokens.dropFirst()) {
            let joined = first + second
            if strongWords.contains(joined) || folderWords.contains(joined) { words.insert(joined) }
        }
        return words
    }

    /// Runs of tracks whose lengths are each within the tolerance of the next.
    private static func sameLength(_ tracks: [Track]) -> [[Track]] {
        var sets: [[Track]] = []
        for track in tracks.sorted(by: { $0.durationSec < $1.durationSec }) {
            if let last = sets.last?.last, track.durationSec - last.durationSec <= lengthToleranceSec {
                sets[sets.count - 1].append(track)
            } else {
                sets.append([track])
            }
        }
        return sets
    }
}
