import Foundation

public enum FileLocality: String, Codable, Sendable {
    case local
    case cloudOnly
    case missing

    /// A value from a later version reads as missing, so nothing tries to play a file it cannot place.
    public init(from decoder: Decoder) throws {
        self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .missing
    }
}

public struct TrackFile: Codable, Equatable, Hashable, Sendable {
    public var path: String
    public var locality: FileLocality

    public init(path: String, locality: FileLocality) {
        self.path = path
        self.locality = locality
    }

    public var url: URL { URL(fileURLWithPath: path) }
    public var filename: String { url.lastPathComponent }
}

public struct Marker: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var seconds: Double

    public init(id: UUID = UUID(), name: String, seconds: Double) {
        self.id = id
        self.name = name
        self.seconds = seconds
    }
}

/// Why a track is left out of matching and the library lists.
public struct Exclusion: Codable, Equatable, Sendable {
    public var reason: String
    /// True when the operator chose Not a Playback, false when Cantor detected a stem.
    public var byOperator: Bool

    public init(reason: String, byOperator: Bool) {
        self.reason = reason
        self.byOperator = byOperator
    }
}

public struct Track: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var contentID: String?
    public var files: [TrackFile]
    public var title: String
    public var durationSec: Double
    public var sampleRate: Double
    public var channels: Int
    public var startSec: Double
    public var endSec: Double?
    public var suggestedEndSec: Double?
    public var fadeOutSec: Double
    public var fadeInSec: Double
    public var trimDb: Double
    public var integratedLUFS: Double?
    public var truePeakDb: Double?
    public var markers: [Marker]
    public var key: String
    public var notes: String
    public var tags: [String]
    public var pcoSongIDs: [String]
    public var playCount: Int
    public var lastPlayed: Date?
    /// Set for stems and other audio that is not a playback. Nil means the track is in use.
    public var exclusion: Exclusion?
    /// The operator said this is a playback, so stem detection leaves it alone.
    public var keptByOperator: Bool
    /// Nil until the operator opens the EQ, which plays the track unchanged.
    public var eq: TrackEQ?

    public init(
        id: UUID = UUID(), contentID: String? = nil, files: [TrackFile] = [], title: String,
        durationSec: Double = 0, sampleRate: Double = 0, channels: Int = 0
    ) {
        self.id = id
        self.contentID = contentID
        self.files = files
        self.title = title
        self.durationSec = durationSec
        self.sampleRate = sampleRate
        self.channels = channels
        startSec = 0
        endSec = nil
        suggestedEndSec = nil
        fadeOutSec = 3
        fadeInSec = 0
        trimDb = 0
        integratedLUFS = nil
        truePeakDb = nil
        markers = []
        key = ""
        notes = ""
        tags = []
        pcoSongIDs = []
        playCount = 0
        lastPlayed = nil
        exclusion = nil
        keptByOperator = false
        eq = nil
    }

    /// Puts edited points back in a playable order.
    public mutating func sanitizePoints() {
        let minimumRun = 0.1
        let limit = durationSec > 0 ? durationSec : .greatestFiniteMagnitude
        startSec = min(max(startSec, 0), max(limit - minimumRun, 0))
        if let end = endSec { endSec = min(max(end, startSec + minimumRun), limit) }
        fadeOutSec = max(fadeOutSec, 0)
        fadeInSec = max(fadeInSec, 0)
    }

    /// The file to play: managed copy first, then any local file.
    public func bestFile(managedRoot: String = ManagedFolder.path) -> TrackFile? {
        let local = files.filter { $0.locality == .local }
        return local.first { $0.path.hasPrefix(managedRoot + "/") } ?? local.first
    }

    public var isLocal: Bool { bestFile() != nil }
    public var hasCloudOnlyCopy: Bool { files.contains { $0.locality == .cloudOnly } }
    public var isAnalyzed: Bool { integratedLUFS != nil }
    public var primaryFilename: String { (bestFile() ?? files.first)?.filename ?? title }
    public var isExcluded: Bool { exclusion != nil }
}

// A field added in a later version must not make an existing library unreadable.
extension Track {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(UUID.self, forKey: .id),
            contentID: try c.decodeIfPresent(String.self, forKey: .contentID),
            files: try c.decodeIfPresent([TrackFile].self, forKey: .files) ?? [],
            title: try c.decodeIfPresent(String.self, forKey: .title) ?? "",
            durationSec: try c.decodeIfPresent(Double.self, forKey: .durationSec) ?? 0,
            sampleRate: try c.decodeIfPresent(Double.self, forKey: .sampleRate) ?? 0,
            channels: try c.decodeIfPresent(Int.self, forKey: .channels) ?? 0
        )
        startSec = try c.decodeIfPresent(Double.self, forKey: .startSec) ?? 0
        endSec = try c.decodeIfPresent(Double.self, forKey: .endSec)
        suggestedEndSec = try c.decodeIfPresent(Double.self, forKey: .suggestedEndSec)
        fadeOutSec = try c.decodeIfPresent(Double.self, forKey: .fadeOutSec) ?? 3
        fadeInSec = try c.decodeIfPresent(Double.self, forKey: .fadeInSec) ?? 0
        trimDb = try c.decodeIfPresent(Double.self, forKey: .trimDb) ?? 0
        integratedLUFS = try c.decodeIfPresent(Double.self, forKey: .integratedLUFS)
        truePeakDb = try c.decodeIfPresent(Double.self, forKey: .truePeakDb)
        markers = try c.decodeIfPresent([Marker].self, forKey: .markers) ?? []
        key = try c.decodeIfPresent(String.self, forKey: .key) ?? ""
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        pcoSongIDs = try c.decodeIfPresent([String].self, forKey: .pcoSongIDs) ?? []
        playCount = try c.decodeIfPresent(Int.self, forKey: .playCount) ?? 0
        lastPlayed = try c.decodeIfPresent(Date.self, forKey: .lastPlayed)
        exclusion = try c.decodeIfPresent(Exclusion.self, forKey: .exclusion)
        keptByOperator = try c.decodeIfPresent(Bool.self, forKey: .keptByOperator) ?? false
        eq = try c.decodeIfPresent(TrackEQ.self, forKey: .eq)
    }
}

// The same for the types saved inside a track, a plan or the settings: a missing field takes its
// default, so one addition cannot make the whole file unreadable. Encoding is unchanged.
extension TrackFile {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            path: try c.decodeIfPresent(String.self, forKey: .path) ?? "",
            locality: try c.decodeIfPresent(FileLocality.self, forKey: .locality) ?? .missing
        )
    }
}

extension Marker {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
            name: try c.decodeIfPresent(String.self, forKey: .name) ?? "",
            seconds: try c.decodeIfPresent(Double.self, forKey: .seconds) ?? 0
        )
    }
}

extension Exclusion {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            reason: try c.decodeIfPresent(String.self, forKey: .reason) ?? "",
            byOperator: try c.decodeIfPresent(Bool.self, forKey: .byOperator) ?? false
        )
    }
}

// EQ types live in Equalizer.swift. Their keys are spelled out here because synthesized
// CodingKeys are private to that file.
extension EQBand {
    private enum Keys: String, CodingKey { case shape, isOn, frequency, q, gainDb }

    /// A shape from a later version decodes as a bell that is off, so the track plays unchanged.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let shape = (try c.decodeIfPresent(String.self, forKey: .shape)).flatMap(EQShape.init(rawValue:))
        let isOn = try c.decodeIfPresent(Bool.self, forKey: .isOn) ?? true
        self.init(
            shape: shape ?? .bell,
            isOn: shape != nil && isOn,
            frequency: try c.decodeIfPresent(Double.self, forKey: .frequency) ?? 1000,
            q: try c.decodeIfPresent(Double.self, forKey: .q) ?? 0.71,
            gainDb: try c.decodeIfPresent(Double.self, forKey: .gainDb) ?? 0
        )
    }
}

extension TrackEQ {
    private enum Keys: String, CodingKey { case isOn, bands, outputDb }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        self.init(
            isOn: try c.decodeIfPresent(Bool.self, forKey: .isOn) ?? true,
            bands: try c.decodeIfPresent([EQBand].self, forKey: .bands) ?? TrackEQ.defaultBands,
            outputDb: try c.decodeIfPresent(Double.self, forKey: .outputDb) ?? 0
        )
    }
}

public enum ManagedFolder {
    public static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Music/Cantor", isDirectory: true)
    }
    public static var path: String { url.path }
}

public enum MatchSource: String, Codable, Sendable {
    case remembered, attachment, string, llm

    public init(from decoder: Decoder) throws {
        self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .string
    }
}

public struct MatchCandidate: Codable, Equatable, Identifiable, Sendable {
    public var trackID: UUID
    public var score: Double
    public var source: MatchSource
    public var reason: String
    public var durationMismatch: Bool

    public var id: UUID { trackID }

    public init(trackID: UUID, score: Double, source: MatchSource, reason: String, durationMismatch: Bool = false) {
        self.trackID = trackID
        self.score = score
        self.source = source
        self.reason = reason
        self.durationMismatch = durationMismatch
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            trackID: try c.decode(UUID.self, forKey: .trackID),
            score: try c.decodeIfPresent(Double.self, forKey: .score) ?? 0,
            source: try c.decodeIfPresent(MatchSource.self, forKey: .source) ?? .string,
            reason: try c.decodeIfPresent(String.self, forKey: .reason) ?? "",
            durationMismatch: try c.decodeIfPresent(Bool.self, forKey: .durationMismatch) ?? false
        )
    }
}

public enum MatchBand: String, Sendable {
    case proposed, likely, none

    public init(candidates: [MatchCandidate]) {
        guard let top = candidates.first else {
            self = .none
            return
        }
        let margin = candidates.count > 1 ? top.score - candidates[1].score : 1
        if top.score >= 0.85, margin >= 0.08 {
            self = .proposed
        } else if top.score >= 0.60 {
            self = .likely
        } else {
            self = .none
        }
    }
}

public struct ServiceCue: Codable, Equatable, Identifiable, Sendable {
    public var id: CueID
    public var position: Int
    public var title: String
    public var itemType: String
    public var notes: String
    public var arrangement: String
    /// The item's key in Planning Center. Nil when it was saved before Cantor read keys.
    public var keyName: String?
    public var songID: String?
    public var lengthSec: Double?
    public var attachmentFilenames: [String]
    public var needsPlayback: Bool
    public var candidates: [MatchCandidate]
    /// Set only by the operator. Nothing assigns this automatically.
    public var trackID: UUID?
    public var changedSinceConfirm: Bool
    public var isManual: Bool
    /// A confirmed item that is no longer in Planning Center. Kept so the operator sees it go.
    public var removedInPCO: Bool
    /// Set by a sync whose attachment request failed, so merging keeps the saved filenames. Not saved.
    public var attachmentsUnavailable = false
    /// The file was put on the item by Cantor, from a strong match, not by the operator.
    public var autoConfirmed = false
    /// The operator cleared a match, so Cantor never confirms one on this item by itself again.
    public var matchCleared = false
    /// Needs as the operator set it on this item. Nil until they do. Notes and remembered choices
    /// never override it, so Not Needed stays off however the notes are worded.
    public var operatorNeeds: Bool?

    public init(
        id: CueID, position: Int, title: String, itemType: String = "item", notes: String = "", arrangement: String = "",
        keyName: String? = nil, songID: String? = nil, lengthSec: Double? = nil, attachmentFilenames: [String] = [],
        needsPlayback: Bool = true, isManual: Bool = false
    ) {
        self.id = id
        self.position = position
        self.title = title
        self.itemType = itemType
        self.notes = notes
        self.arrangement = arrangement
        self.keyName = keyName
        self.songID = songID
        self.lengthSec = lengthSec
        self.attachmentFilenames = attachmentFilenames
        self.needsPlayback = needsPlayback
        candidates = []
        trackID = nil
        changedSinceConfirm = false
        self.isManual = isManual
        removedInPCO = false
    }

    enum CodingKeys: String, CodingKey {
        case id, position, title, itemType, notes, arrangement, keyName, songID, lengthSec, attachmentFilenames
        case needsPlayback, candidates, trackID, changedSinceConfirm, isManual, removedInPCO
        case autoConfirmed, matchCleared, operatorNeeds
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(CueID.self, forKey: .id),
            position: try c.decodeIfPresent(Int.self, forKey: .position) ?? 0,
            title: try c.decodeIfPresent(String.self, forKey: .title) ?? "",
            itemType: try c.decodeIfPresent(String.self, forKey: .itemType) ?? "item",
            notes: try c.decodeIfPresent(String.self, forKey: .notes) ?? "",
            arrangement: try c.decodeIfPresent(String.self, forKey: .arrangement) ?? "",
            keyName: try c.decodeIfPresent(String.self, forKey: .keyName),
            songID: try c.decodeIfPresent(String.self, forKey: .songID),
            lengthSec: try c.decodeIfPresent(Double.self, forKey: .lengthSec),
            attachmentFilenames: try c.decodeIfPresent([String].self, forKey: .attachmentFilenames) ?? [],
            needsPlayback: try c.decodeIfPresent(Bool.self, forKey: .needsPlayback) ?? true,
            isManual: try c.decodeIfPresent(Bool.self, forKey: .isManual) ?? false
        )
        candidates = try c.decodeIfPresent([MatchCandidate].self, forKey: .candidates) ?? []
        trackID = try c.decodeIfPresent(UUID.self, forKey: .trackID)
        changedSinceConfirm = try c.decodeIfPresent(Bool.self, forKey: .changedSinceConfirm) ?? false
        removedInPCO = try c.decodeIfPresent(Bool.self, forKey: .removedInPCO) ?? false
        autoConfirmed = try c.decodeIfPresent(Bool.self, forKey: .autoConfirmed) ?? false
        matchCleared = try c.decodeIfPresent(Bool.self, forKey: .matchCleared) ?? false
        operatorNeeds = try c.decodeIfPresent(Bool.self, forKey: .operatorNeeds)
    }

    /// Something the operator chose the track for has changed. A key saved before Cantor read keys
    /// is unknown, not changed.
    func differsForPlayback(from fresh: ServiceCue) -> Bool {
        title != fresh.title || songID != fresh.songID || arrangement != fresh.arrangement
            || (keyName != nil && keyName != fresh.keyName)
    }

    /// The same song added back as a new item: same song, or the same title once case and punctuation are ignored.
    func isSameSong(as other: ServiceCue) -> Bool {
        if let song = songID, song == other.songID { return true }
        let simple = { (text: String) in
            text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
        }
        let mine = simple(title)
        return !mine.isEmpty && mine == simple(other.title)
    }
}

public struct ServicePlan: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var serviceTypeID: String
    public var serviceTypeName: String
    public var title: String
    public var dates: String
    public var sortDate: Date?
    public var serviceTimes: [Date]
    public var syncedAt: Date
    public var cues: [ServiceCue]
    /// Chosen in the service picker, so a sync keeps it while it is inside the picker's window.
    public var picked = false
    /// Set by a sync whose plan_times request failed, so merging keeps the saved times. Not saved.
    public var serviceTimesUnavailable = false
    /// Set by a sync that could not fetch this plan, so the saved copy is kept as it was. Not saved.
    public var syncFailed = false

    public init(
        id: String, serviceTypeID: String, serviceTypeName: String, title: String, dates: String, sortDate: Date?,
        serviceTimes: [Date] = [], syncedAt: Date = Date(), cues: [ServiceCue] = []
    ) {
        self.id = id
        self.serviceTypeID = serviceTypeID
        self.serviceTypeName = serviceTypeName
        self.title = title
        self.dates = dates
        self.sortDate = sortDate
        self.serviceTimes = serviceTimes
        self.syncedAt = syncedAt
        self.cues = cues
    }

    enum CodingKeys: String, CodingKey {
        case id, serviceTypeID, serviceTypeName, title, dates, sortDate, serviceTimes, syncedAt, cues, picked
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(String.self, forKey: .id),
            serviceTypeID: try c.decodeIfPresent(String.self, forKey: .serviceTypeID) ?? "",
            serviceTypeName: try c.decodeIfPresent(String.self, forKey: .serviceTypeName) ?? "",
            title: try c.decodeIfPresent(String.self, forKey: .title) ?? "",
            dates: try c.decodeIfPresent(String.self, forKey: .dates) ?? "",
            sortDate: try c.decodeIfPresent(Date.self, forKey: .sortDate),
            serviceTimes: try c.decodeIfPresent([Date].self, forKey: .serviceTimes) ?? [],
            // Unknown sync time reads as long ago, so Check asks for a refresh.
            syncedAt: try c.decodeIfPresent(Date.self, forKey: .syncedAt) ?? .distantPast,
            cues: try c.decodeIfPresent([ServiceCue].self, forKey: .cues) ?? []
        )
        picked = try c.decodeIfPresent(Bool.self, forKey: .picked) ?? false
    }

    public var playbackCues: [ServiceCue] { cues.filter(\.needsPlayback).sorted { $0.position < $1.position } }

    /// Enough of the plan to read it again on its own. The item count is unknown, so a short read
    /// isn't caught; the connector's own page tokens still have to run out.
    public var summary: PlanSummary {
        PlanSummary(
            id: id, serviceTypeID: serviceTypeID, serviceTypeName: serviceTypeName, title: title, dates: dates,
            sortDate: sortDate, serviceTimes: serviceTimes
        )
    }

    /// Sets Needs on each Planning Center item from its notes and the operator's remembered choices,
    /// as a sync would. An item with a file keeps Needs on unless the notes say nothing and the
    /// operator turned it off, so a confirmed line never drops out by itself.
    public mutating func redetect(memory: AliasMemory) {
        for index in cues.indices where !cues[index].isManual && cues[index].itemType != "header" {
            if let choice = cues[index].operatorNeeds {
                cues[index].needsPlayback = choice
                continue
            }
            let detected = PlaybackDetector.needsPlayback(cues[index], memory: memory)
            if cues[index].trackID == nil {
                cues[index].needsPlayback = detected
            } else if detected {
                cues[index].needsPlayback = true
            }
        }
    }

    /// Puts the top file on each playback item whose match is strong (Proposed), unless the operator
    /// has cleared a match there. Returns how many it confirmed.
    @discardableResult
    public mutating func autoConfirmStrongMatches() -> Int {
        var count = 0
        for index in cues.indices {
            let cue = cues[index]
            // A name match whose length is far from the item's is likely another setting or
            // arrangement of the same title, so it waits for the operator. A file the operator chose
            // for this song before still goes on: Planning Center lengths are often placeholders.
            guard cue.needsPlayback, cue.trackID == nil, !cue.matchCleared, !cue.removedInPCO,
                  MatchBand(candidates: cue.candidates) == .proposed, let top = cue.candidates.first,
                  !top.durationMismatch || top.source == .remembered
            else { continue }
            cues[index].trackID = top.trackID
            cues[index].autoConfirmed = true
            cues[index].changedSinceConfirm = false
            count += 1
        }
        return count
    }

    /// Every cue in service order.
    public var orderedCues: [ServiceCue] { cues.sorted { $0.position < $1.position } }

    public enum InsertPoint: Equatable, Sendable {
        case start, end
        case after(CueID)
    }

    /// Adds cues at a point in the service. An item that is gone counts as the end.
    public mutating func insert(_ added: [ServiceCue], at point: InsertPoint) {
        var ordered = orderedCues
        let index: Int
        switch point {
        case .start: index = 0
        case .end: index = ordered.count
        case .after(let id): index = ordered.firstIndex { $0.id == id }.map { $0 + 1 } ?? ordered.count
        }
        ordered.insert(contentsOf: added, at: index)
        cues = Self.numbered(ordered)
    }

    /// Numbers cues in the order given. Positions only order the cues, so renumbering is safe.
    static func numbered(_ ordered: [ServiceCue]) -> [ServiceCue] {
        ordered.enumerated().map { index, cue in
            var cue = cue
            cue.position = index
            return cue
        }
    }

    public var hasOperatorWork: Bool { cues.contains { $0.trackID != nil || $0.isManual } }

    /// Applies a sync. A plan missing from the sync stays if it is loaded, holds operator work and is
    /// under two weeks old (Planning Center stops listing a plan as future once it starts), or was
    /// chosen in the service picker and is still inside its window.
    public static func applySync(existing: [ServicePlan], fresh: [ServicePlan], loadedID: String?, now: Date = Date()) -> [ServicePlan] {
        let byID = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let synced = fresh.compactMap { plan in
            plan.syncFailed ? byID[plan.id] : byID[plan.id]?.merging(fresh: plan) ?? plan
        }
        let freshIDs = Set(fresh.map(\.id))
        let cutoff = now.addingTimeInterval(-14 * 24 * 3600)
        let pickerStart = PlanSummary.window(now: now).lowerBound
        let kept = existing.filter { plan in
            guard !freshIDs.contains(plan.id) else { return false }
            if plan.id == loadedID { return true }
            if plan.picked { return (plan.sortDate ?? now) >= pickerStart }
            return plan.hasOperatorWork && (plan.sortDate ?? now) >= cutoff
        }
        return (synced + kept).sorted { ($0.sortDate ?? .distantFuture) < ($1.sortDate ?? .distantFuture) }
    }

    /// Adds or refreshes the one plan read for the service picker, leaving every other plan as it was.
    public static func applyPicked(existing: [ServicePlan], fresh: ServicePlan) -> [ServicePlan] {
        var picked = existing.first { $0.id == fresh.id }?.merging(fresh: fresh) ?? fresh
        picked.picked = true
        let others = existing.filter { $0.id != fresh.id }
        return (others + [picked]).sorted { ($0.sortDate ?? .distantFuture) < ($1.sortDate ?? .distantFuture) }
    }

    /// Applies a fresh sync, keeping operator work. A confirmed item that is gone moves to a new item
    /// for the same song when exactly one matches; otherwise it stays, marked removed in Planning Center.
    public func merging(fresh: ServicePlan) -> ServicePlan {
        var result = fresh
        result.picked = picked || fresh.picked
        if fresh.serviceTimesUnavailable { result.serviceTimes = serviceTimes }
        let previous = Dictionary(cues.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let freshIDs = Set(fresh.cues.map(\.id))
        let orphans = cues.filter { !$0.isManual && $0.trackID != nil && !freshIDs.contains($0.id) }
        let newcomers = fresh.cues.filter { previous[$0.id] == nil }
        var adopted: [CueID: ServiceCue] = [:]
        for orphan in orphans {
            let claims = newcomers.filter { $0.isSameSong(as: orphan) }
            guard claims.count == 1, let claim = claims.first,
                  orphans.filter({ claim.isSameSong(as: $0) }).count == 1
            else { continue }
            adopted[claim.id] = orphan
        }

        result.cues = fresh.cues.map { incoming in
            guard let old = previous[incoming.id] ?? adopted[incoming.id] else { return incoming }
            var merged = incoming
            merged.trackID = old.trackID
            merged.candidates = old.candidates
            // The notes can change between syncs. A confirmed cue keeps its row, and the operator's
            // own choices already came in through the remembered override.
            if old.trackID != nil { merged.needsPlayback = old.needsPlayback }
            merged.changedSinceConfirm = old.changedSinceConfirm
            merged.autoConfirmed = old.autoConfirmed
            merged.matchCleared = old.matchCleared
            merged.operatorNeeds = old.operatorNeeds
            if let choice = old.operatorNeeds { merged.needsPlayback = choice }
            if incoming.attachmentsUnavailable { merged.attachmentFilenames = old.attachmentFilenames }
            if old.trackID != nil, old.differsForPlayback(from: incoming) {
                merged.changedSinceConfirm = true
            }
            return merged
        }
        let adoptedIDs = Set(adopted.values.map(\.id))
        let removed = orphans.filter { !adoptedIDs.contains($0.id) }.map { orphan in
            var removed = orphan
            removed.removedInPCO = true
            return removed
        }
        // Removed and added items go back after the item they followed, so a cue added by hand keeps
        // its place. An adopted item is followed under its new id.
        let kept = Dictionary((removed + cues.filter(\.isManual)).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let renamed = Dictionary(adopted.map { ($0.value.id, $0.key) }, uniquingKeysWith: { a, _ in a })
        let oldOrder = orderedCues
        var ordered = result.cues.sorted { $0.position < $1.position }
        for (index, old) in oldOrder.enumerated() {
            guard let cue = kept[old.id] else { continue }
            let at = oldOrder[..<index].reversed().lazy
                .compactMap { earlier in ordered.firstIndex { $0.id == (renamed[earlier.id] ?? earlier.id) } }
                .first.map { $0 + 1 } ?? 0
            ordered.insert(cue, at: at)
        }
        result.cues = Self.numbered(ordered)
        return result
    }
}

/// One service in the service picker's list: enough to show and choose it, without its items.
public struct PlanSummary: Equatable, Identifiable, Sendable {
    public var id: String
    public var serviceTypeID: String
    public var serviceTypeName: String
    public var title: String
    public var dates: String
    public var sortDate: Date?
    public var serviceTimes: [Date]
    /// How many items Planning Center lists, so a read that comes back short is caught.
    public var itemsCount: Int?

    public init(
        id: String, serviceTypeID: String, serviceTypeName: String, title: String, dates: String, sortDate: Date?,
        serviceTimes: [Date] = [], itemsCount: Int? = nil
    ) {
        self.id = id
        self.serviceTypeID = serviceTypeID
        self.serviceTypeName = serviceTypeName
        self.title = title
        self.dates = dates
        self.sortDate = sortDate
        self.serviceTimes = serviceTimes
        self.itemsCount = itemsCount
    }

    public static let weeksBack = 6
    public static let weeksAhead = 3

    /// From the start of the day six weeks ago to the end of the day three weeks ahead.
    public static func window(now: Date = Date(), calendar: Calendar = .current) -> ClosedRange<Date> {
        let today = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -7 * weeksBack, to: today) ?? today
        let end = calendar.date(byAdding: .day, value: 7 * weeksAhead + 1, to: today) ?? today
        return start...end.addingTimeInterval(-1)
    }

    /// The plan with no items yet, as the picker starts reading it.
    public func emptyPlan(now: Date = Date()) -> ServicePlan {
        ServicePlan(
            id: id, serviceTypeID: serviceTypeID, serviceTypeName: serviceTypeName, title: title, dates: dates,
            sortDate: sortDate, serviceTimes: serviceTimes, syncedAt: now
        )
    }

    /// Plans inside the window, one per id, by date.
    public static func inWindow(_ summaries: [PlanSummary], now: Date = Date()) -> [PlanSummary] {
        let window = window(now: now)
        var seen = Set<String>()
        return summaries
            .filter { $0.sortDate.map(window.contains) ?? false }
            .filter { seen.insert($0.id).inserted }
            .sorted { ($0.sortDate ?? .distantFuture) < ($1.sortDate ?? .distantFuture) }
    }
}

public struct AliasMemory: Codable, Equatable, Sendable {
    /// Keys are `song:<id>` or `title:<normalized>`, values are content IDs.
    public var confirmed: [String: String] = [:]
    /// Same keys. Operator's explicit Needed / Not Needed choices.
    public var needsOverrides: [String: Bool] = [:]

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        confirmed = try c.decodeIfPresent([String: String].self, forKey: .confirmed) ?? [:]
        needsOverrides = try c.decodeIfPresent([String: Bool].self, forKey: .needsOverrides) ?? [:]
    }

    public static func keys(for cue: ServiceCue) -> [String] {
        var keys: [String] = []
        if let song = cue.songID { keys.append("song:\(song)") }
        keys.append("title:\(TitleNormalizer.normalize(cue.title).joined(separator: " "))")
        return keys
    }

    public func contentID(for cue: ServiceCue) -> String? {
        Self.keys(for: cue).lazy.compactMap { confirmed[$0] }.first
    }

    public func needsOverride(for cue: ServiceCue) -> Bool? {
        Self.keys(for: cue).lazy.compactMap { needsOverrides[$0] }.first
    }

    public mutating func remember(_ cue: ServiceCue, contentID: String) {
        for key in Self.keys(for: cue) { confirmed[key] = contentID }
    }

    public mutating func rememberNeeds(_ cue: ServiceCue, needed: Bool) {
        for key in Self.keys(for: cue) { needsOverrides[key] = needed }
    }
}

public struct OutputRouting: Codable, Equatable, Sendable {
    public var houseDeviceUID: String?
    /// Zero-based first channel of the stereo pair.
    public var houseFirstChannel: Int
    public var cueDeviceUID: String?
    public var cueFirstChannel: Int

    public init(houseDeviceUID: String? = nil, houseFirstChannel: Int = 0, cueDeviceUID: String? = nil, cueFirstChannel: Int = 0) {
        self.houseDeviceUID = houseDeviceUID
        self.houseFirstChannel = houseFirstChannel
        self.cueDeviceUID = cueDeviceUID
        self.cueFirstChannel = cueFirstChannel
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            houseDeviceUID: try c.decodeIfPresent(String.self, forKey: .houseDeviceUID),
            houseFirstChannel: try c.decodeIfPresent(Int.self, forKey: .houseFirstChannel) ?? 0,
            cueDeviceUID: try c.decodeIfPresent(String.self, forKey: .cueDeviceUID),
            cueFirstChannel: try c.decodeIfPresent(Int.self, forKey: .cueFirstChannel) ?? 0
        )
    }

    public var isSameDevice: Bool { houseDeviceUID != nil && houseDeviceUID == cueDeviceUID }
}

public enum PlanningCenterSource: String, Codable, CaseIterable, Sendable {
    /// The Planning Center connector on the operator's Claude account, through Claude Code.
    case connector
    /// A Planning Center Personal Access Token, read directly.
    case token
}

public struct AppSettings: Codable, Equatable, Sendable {
    public var routing = OutputRouting()
    public var folders: [String] = AppSettings.defaultFolders()
    public var panicFadeSec = 1.5
    public var defaultFadeOutSec = 3.0
    public var targetLUFS = -18.0
    public var normalize = true
    /// Empty uses the Claude account's default model.
    public var llmModel = ""
    /// Empty looks in the usual install locations.
    public var claudePath = ""
    public var llmEnabled = true
    /// How Planning Center is read. The token is used whenever the connector can't be.
    public var planningCenterSource = PlanningCenterSource.connector
    public var isolateSystemSound = true
    public var appearance = "dark"
    /// When Cantor started watching each folder. Only files that arrive later count as new.
    public var watchedSince: [String: Date] = [:]
    /// Every service type seen in Planning Center, name by id, so Settings can list them all.
    public var serviceTypes: [String: String] = [:]
    /// Off, Sync Now and the sidebar leave out `hiddenServiceTypeIDs`. On, every type is imported
    /// and the unchecked list is kept for when it is turned off again.
    public var importAllServiceTypes = true
    /// Service types left unchecked. The service picker still lists them.
    public var hiddenServiceTypeIDs: Set<String> = []

    /// The service types Sync Now skips.
    public var skippedServiceTypeIDs: Set<String> { importAllServiceTypes ? [] : hiddenServiceTypeIDs }

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        routing = try c.decodeIfPresent(OutputRouting.self, forKey: .routing) ?? routing
        folders = try c.decodeIfPresent([String].self, forKey: .folders) ?? folders
        panicFadeSec = try c.decodeIfPresent(Double.self, forKey: .panicFadeSec) ?? panicFadeSec
        defaultFadeOutSec = try c.decodeIfPresent(Double.self, forKey: .defaultFadeOutSec) ?? defaultFadeOutSec
        targetLUFS = try c.decodeIfPresent(Double.self, forKey: .targetLUFS) ?? targetLUFS
        normalize = try c.decodeIfPresent(Bool.self, forKey: .normalize) ?? normalize
        llmModel = try c.decodeIfPresent(String.self, forKey: .llmModel) ?? llmModel
        claudePath = try c.decodeIfPresent(String.self, forKey: .claudePath) ?? claudePath
        llmEnabled = try c.decodeIfPresent(Bool.self, forKey: .llmEnabled) ?? llmEnabled
        planningCenterSource = (try? c.decodeIfPresent(PlanningCenterSource.self, forKey: .planningCenterSource)) ?? planningCenterSource
        isolateSystemSound = try c.decodeIfPresent(Bool.self, forKey: .isolateSystemSound) ?? isolateSystemSound
        appearance = try c.decodeIfPresent(String.self, forKey: .appearance) ?? appearance
        watchedSince = try c.decodeIfPresent([String: Date].self, forKey: .watchedSince) ?? watchedSince
        serviceTypes = try c.decodeIfPresent([String: String].self, forKey: .serviceTypes) ?? serviceTypes
        importAllServiceTypes = try c.decodeIfPresent(Bool.self, forKey: .importAllServiceTypes) ?? importAllServiceTypes
        hiddenServiceTypeIDs = try c.decodeIfPresent(Set<String>.self, forKey: .hiddenServiceTypeIDs) ?? hiddenServiceTypeIDs
    }

    /// A service of a hidden type stays in the sidebar when it was picked by hand.
    public func hides(_ plan: ServicePlan) -> Bool {
        skippedServiceTypeIDs.contains(plan.serviceTypeID) && !plan.picked
    }

    /// Remembers the names of the service types in a sync or a picker list. Types are never
    /// forgotten, since a hidden type stops coming back from syncs.
    public mutating func noteServiceTypes(_ types: [(id: String, name: String)]) {
        for type in types where !type.id.isEmpty { serviceTypes[type.id] = type.name }
    }

    /// Starts the clock for folders not yet watched, and forgets removed ones so adding a folder
    /// back does not count everything in it as new.
    public mutating func stampWatchedFolders(now: Date = Date()) {
        for folder in folders where watchedSince[folder] == nil { watchedSince[folder] = now }
        for folder in watchedSince.keys where !folders.contains(folder) { watchedSince[folder] = nil }
    }

    public static func defaultFolders() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var roots = ["Downloads", "Desktop"].map { home.appendingPathComponent($0).path }
        let cloud = home.appendingPathComponent("Library/CloudStorage")
        if let items = try? FileManager.default.contentsOfDirectory(atPath: cloud.path) {
            roots += items.filter { $0.hasPrefix("GoogleDrive-") }.map { cloud.appendingPathComponent($0).path }
        }
        return roots
    }
}
