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

    public var duplicateGroups: [DuplicateGroup] {
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
