import Foundation

public struct DuplicateGroup: Identifiable, Equatable, Sendable {
    public enum Kind: Sendable { case sameAudio, possible }
    public var id: String
    public var kind: Kind
    public var trackIDs: [UUID]
}

/// The track collection and its merge rules. Pure value logic, persisted by JSONFile.
public struct Library: Codable, Equatable, Sendable {
    public var tracks: [Track] = []

    public init(tracks: [Track] = []) {
        self.tracks = tracks
    }

    public func track(id: UUID) -> Track? { tracks.first { $0.id == id } }
    /// Tracks used for matching and the library lists. Stems and other excluded audio are left out.
    public var playbackTracks: [Track] { tracks.filter { !$0.isExcluded } }
    public var excludedTracks: [Track] { tracks.filter(\.isExcluded) }
    public func track(contentID: String) -> Track? { tracks.first { $0.contentID == contentID } }

    public mutating func update(id: UUID, _ change: (inout Track) -> Void) {
        guard let index = tracks.firstIndex(where: { $0.id == id }) else { return }
        change(&tracks[index])
    }

    /// Folds a scan into the library. Originals on disk are never touched. A track with no file
    /// left stays, with its files marked missing, because its cue points are worth keeping. Files
    /// in `gaps` were not seen by the scan, so they keep the state they had.
    /// Returns tracks replaced by another, so cues pointing at them can follow.
    @discardableResult
    public mutating func merge(scan: [ScannedFile], gaps: ScanGaps = ScanGaps(), defaultFadeOutSec: Double = 3) -> [UUID: UUID] {
        var replaced: [UUID: UUID] = [:]
        let scannedPaths = Set(scan.map(\.path))
        followMovedPlaceholders(scan: scan, scannedPaths: scannedPaths, gaps: gaps)
        for index in tracks.indices {
            for fileIndex in tracks[index].files.indices {
                let path = tracks[index].files[fileIndex].path
                guard !scannedPaths.contains(path), !gaps.contains(path) else { continue }
                tracks[index].files[fileIndex].locality = .missing
            }
        }

        // Lookups built once and kept current, so a scan costs the same per file however large the
        // library is. A library of thousands of files merged on the main thread otherwise took seconds.
        // Indices stay valid: tracks are only appended until the clean-up below.
        var holders: [String: [Int]] = [:]
        var byContent: [String: Int] = [:]
        for index in tracks.indices {
            for file in tracks[index].files { holders[file.path, default: []].append(index) }
            if let contentID = tracks[index].contentID, byContent[contentID] == nil { byContent[contentID] = index }
        }
        func add(_ file: ScannedFile, to index: Int, entry: TrackFile) {
            apply(file, to: index, entry: entry)
            if holders[file.path]?.contains(index) != true { holders[file.path, default: []].append(index) }
        }
        func append(_ track: Track, path: String) {
            tracks.append(track)
            holders[path, default: []].append(tracks.count - 1)
            if let contentID = track.contentID, byContent[contentID] == nil { byContent[contentID] = tracks.count - 1 }
        }

        for file in scan {
            let entry = TrackFile(path: file.path, locality: file.locality, sizeBytes: file.sizeBytes)
            if let contentID = file.contentID {
                let holder = holders[file.path]?.min()
                if let holder, tracks[holder].contentID == nil {
                    // A placeholder finished downloading. Keep whichever record already has this audio.
                    if let existing = byContent[contentID] {
                        replaced[tracks[holder].id] = tracks[existing].id
                    } else {
                        tracks[holder].contentID = contentID
                        byContent[contentID] = holder
                        add(file, to: holder, entry: entry)
                        continue
                    }
                }
                // The path now holds this audio, so no other track keeps it.
                for index in holders[file.path] ?? [] where tracks[index].contentID != contentID {
                    tracks[index].files.removeAll { $0.path == file.path }
                }
                holders[file.path]?.removeAll { tracks[$0].contentID != contentID }
                if let index = byContent[contentID] {
                    add(file, to: index, entry: entry)
                } else {
                    var track = Track(
                        contentID: contentID, files: [entry], title: TitleNormalizer.displayTitle(filename: entry.filename),
                        durationSec: file.durationSec, sampleRate: file.sampleRate, channels: file.channels
                    )
                    track.fadeOutSec = defaultFadeOutSec
                    append(track, path: file.path)
                }
            } else if let index = holders[file.path]?.min() {
                add(file, to: index, entry: entry)
            } else {
                var track = Track(files: [entry], title: TitleNormalizer.displayTitle(filename: entry.filename))
                track.fadeOutSec = defaultFadeOutSec
                append(track, path: file.path)
            }
        }

        tracks.removeAll { $0.contentID == nil && $0.files.isEmpty }
        return replaced
    }

    private mutating func apply(_ file: ScannedFile, to index: Int, entry: TrackFile) {
        if let fileIndex = tracks[index].files.firstIndex(where: { $0.path == file.path }) {
            tracks[index].files[fileIndex] = entry
        } else {
            tracks[index].files.append(entry)
        }
        if file.durationSec > 0 {
            tracks[index].durationSec = file.durationSec
            tracks[index].sampleRate = file.sampleRate
            tracks[index].channels = file.channels
        }
    }

    /// A cloud-only file has no content ID, so a move would otherwise leave its old track behind
    /// and make a ghost one, offered as a new file. When exactly one placeholder with a name went
    /// away and exactly one unknown placeholder with that name appeared in the same scan, the old
    /// track follows it. A rename cannot be told apart from a different file, so it is left alone.
    private mutating func followMovedPlaceholders(scan: [ScannedFile], scannedPaths: Set<String>, gaps: ScanGaps) {
        let known = Set(tracks.flatMap { $0.files.map(\.path) })
        let appeared = Dictionary(grouping: scan.filter { $0.contentID == nil && $0.locality == .cloudOnly && !known.contains($0.path) }) {
            URL(fileURLWithPath: $0.path).lastPathComponent
        }
        guard !appeared.isEmpty else { return }
        var vanished: [String: [(track: Int, file: Int)]] = [:]
        for index in tracks.indices {
            for fileIndex in tracks[index].files.indices {
                let file = tracks[index].files[fileIndex]
                guard file.locality == .cloudOnly, !scannedPaths.contains(file.path), !gaps.contains(file.path) else { continue }
                vanished[file.filename, default: []].append((index, fileIndex))
            }
        }
        for (name, arrivals) in appeared where arrivals.count == 1 {
            guard let gone = vanished[name], gone.count == 1 else { continue }
            tracks[gone[0].track].files[gone[0].file].path = arrivals[0].path
        }
    }

    /// Excludes tracks that look like stems, and all but one copy of a playback, and brings back
    /// ones that no longer do. The operator's own choices are left alone. Returns whether anything changed.
    @discardableResult
    public mutating func excludeStems(protecting protected: Set<UUID>) -> Bool {
        var reasons = StemDetector.detect(tracks: tracks, protected: protected)
        // Stems first, so a stem never stands in for the playback it was copied beside.
        reasons.merge(DuplicateDetector.detect(tracks: tracks, protected: protected, skipping: Set(reasons.keys))) { stem, _ in stem }
        var changed = false
        for index in tracks.indices where tracks[index].exclusion?.byOperator != true {
            let exclusion = reasons[tracks[index].id].map { Exclusion(reason: $0, byOperator: false) }
            if tracks[index].exclusion != exclusion {
                tracks[index].exclusion = exclusion
                changed = true
            }
        }
        return changed
    }

    /// The operator's Not a Playback.
    public mutating func exclude(id: UUID, reason: String = "You chose Not a Playback") {
        update(id: id) {
            $0.exclusion = Exclusion(reason: reason, byOperator: true)
            $0.keptByOperator = false
        }
    }

    /// The operator's This Is a Playback. Stem detection leaves the track alone from now on.
    public mutating func keep(id: UUID) {
        update(id: id) {
            $0.exclusion = nil
            $0.keptByOperator = true
        }
    }

    public var duplicateGroups: [DuplicateGroup] {
        let tracks = playbackTracks
        // Cantator's own copy in ~/Music/Cantor is a backup the operator asked for, not a duplicate.
        // Two copies there are, as are two outside it.
        let managed = ManagedFolder.path + "/"
        var groups: [DuplicateGroup] = tracks
            .filter { track in
                let inManaged = track.files.count { $0.path.hasPrefix(managed) }
                return inManaged > 1 || track.files.count - inManaged > 1
            }
            .map { DuplicateGroup(id: "same-\($0.id)", kind: .sameAudio, trackIDs: [$0.id]) }

        // Numbers are part of the key, so "Psalm 23" and "Psalm 91" are not offered as duplicates.
        let byTitle = Dictionary(grouping: tracks.filter { $0.durationSec > 0 }) {
            (TitleNormalizer.normalize($0.title) + TitleNormalizer.titleNumbers($0.title).sorted()).joined(separator: " ")
        }
        for (title, members) in byTitle where members.count > 1 && !title.isEmpty {
            let sorted = members.sorted { $0.durationSec < $1.durationSec }
            var cluster = [sorted[0]]
            for track in sorted.dropFirst() {
                if track.durationSec - cluster[cluster.count - 1].durationSec <= 1 {
                    cluster.append(track)
                } else {
                    if cluster.count > 1 {
                        groups.append(DuplicateGroup(id: "near-\(title)-\(cluster[0].id)", kind: .possible, trackIDs: cluster.map(\.id)))
                    }
                    cluster = [track]
                }
            }
            if cluster.count > 1 {
                groups.append(DuplicateGroup(id: "near-\(title)-\(cluster[0].id)", kind: .possible, trackIDs: cluster.map(\.id)))
            }
        }
        return groups
    }

    public var allTags: [String] { Array(Set(tracks.flatMap(\.tags))).sorted() }

    /// Renames a tag on every track, excluded ones too. A track that had both names keeps one.
    public mutating func renameTag(_ old: String, to new: String) {
        guard old != new, !new.isEmpty else { return }
        for index in tracks.indices where tracks[index].tags.contains(old) {
            tracks[index].tags = tracks[index].tags.reduce(into: []) { result, tag in
                let renamed = tag == old ? new : tag
                if !result.contains(renamed) { result.append(renamed) }
            }
        }
    }

    public mutating func removeTag(_ tag: String) {
        for index in tracks.indices { tracks[index].tags.removeAll { $0 == tag } }
    }
}
