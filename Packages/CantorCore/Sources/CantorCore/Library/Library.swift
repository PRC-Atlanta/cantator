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
    /// left stays, with its files marked missing, because its cue points are worth keeping.
    /// Returns tracks replaced by another, so cues pointing at them can follow.
    @discardableResult
    public mutating func merge(scan: [ScannedFile], defaultFadeOutSec: Double = 3) -> [UUID: UUID] {
        var replaced: [UUID: UUID] = [:]
        let scannedPaths = Set(scan.map(\.path))
        for index in tracks.indices {
            for fileIndex in tracks[index].files.indices where !scannedPaths.contains(tracks[index].files[fileIndex].path) {
                tracks[index].files[fileIndex].locality = .missing
            }
        }

        for file in scan {
            let entry = TrackFile(path: file.path, locality: file.locality)
            if let contentID = file.contentID {
                let holder = tracks.firstIndex { $0.files.contains { $0.path == file.path } }
                if let holder, tracks[holder].contentID == nil {
                    // A placeholder finished downloading. Keep whichever record already has this audio.
                    if let existing = track(contentID: contentID) {
                        replaced[tracks[holder].id] = existing.id
                    } else {
                        tracks[holder].contentID = contentID
                        apply(file, to: holder, entry: entry)
                        continue
                    }
                }
                detach(path: file.path, exceptContentID: contentID)
                if let index = tracks.firstIndex(where: { $0.contentID == contentID }) {
                    apply(file, to: index, entry: entry)
                } else {
                    var track = Track(
                        contentID: contentID, files: [entry], title: TitleNormalizer.displayTitle(filename: entry.filename),
                        durationSec: file.durationSec, sampleRate: file.sampleRate, channels: file.channels
                    )
                    track.fadeOutSec = defaultFadeOutSec
                    tracks.append(track)
                }
            } else if let index = tracks.firstIndex(where: { $0.files.contains { $0.path == file.path } }) {
                apply(file, to: index, entry: entry)
            } else {
                var track = Track(files: [entry], title: TitleNormalizer.displayTitle(filename: entry.filename))
                track.fadeOutSec = defaultFadeOutSec
                tracks.append(track)
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

    private mutating func detach(path: String, exceptContentID contentID: String) {
        for index in tracks.indices where tracks[index].contentID != contentID {
            tracks[index].files.removeAll { $0.path == path }
        }
    }

    /// Excludes tracks that look like stems and brings back ones that no longer do. The operator's
    /// own choices are left alone. Returns whether anything changed.
    @discardableResult
    public mutating func excludeStems(protecting protected: Set<UUID>) -> Bool {
        let reasons = StemDetector.detect(tracks: tracks, protected: protected)
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
    public mutating func exclude(id: UUID) {
        update(id: id) {
            $0.exclusion = Exclusion(reason: "You chose Not a Playback", byOperator: true)
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
        var groups: [DuplicateGroup] = tracks
            .filter { $0.files.count > 1 }
            .map { DuplicateGroup(id: "same-\($0.id)", kind: .sameAudio, trackIDs: [$0.id]) }

        let byTitle = Dictionary(grouping: tracks.filter { $0.durationSec > 0 }) {
            TitleNormalizer.normalize($0.title).joined(separator: " ")
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
}
