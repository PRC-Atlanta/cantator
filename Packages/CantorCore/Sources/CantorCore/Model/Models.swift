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
    /// Bytes on the drive, from the last scan. A file not downloaded yet has a size but no length,
    /// so this is how its copies are told apart from other files with its name.
    public var sizeBytes: Int64?

    public init(path: String, locality: FileLocality, sizeBytes: Int64? = nil) {
        self.path = path
        self.locality = locality
        self.sizeBytes = sizeBytes
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

    /// Silence at least this long at the end of a file is worth an end point. A file with sound in
    /// its last two seconds ends with the music, so playing to the end is fine.
    public static let trailingSilenceForEndSec = 2.0

    /// No end point is set and the file ends in silence, so it would play dead air. A file not
    /// analyzed yet counts, since its ending is not known, and so does one with no sound at all.
    /// Sound past the file's reported length doesn't: the length is an estimate, an end can't be set
    /// past it, and playing the whole file, as it does without one, keeps the music.
    public var needsEndPoint: Bool {
        guard endSec == nil else { return false }
        guard isAnalyzed, durationSec > 0, let lastSound = suggestedEndSec else { return true }
        return durationSec - lastSound >= Self.trailingSilenceForEndSec
    }
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
            locality: try c.decodeIfPresent(FileLocality.self, forKey: .locality) ?? .missing,
            sizeBytes: try c.decodeIfPresent(Int64.self, forKey: .sizeBytes)
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
    /// The operator confirmed this file for the same Planning Center song.
    case remembered
    /// The operator confirmed this file for an item with the same title but no song to compare.
    /// Offered, never confirmed by Cantor itself: items such as "Special Music" recur weekly with
    /// a different song each time.
    case rememberedTitle
    case attachment, string, llm

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
    /// Kept at the top of the sidebar whatever its date, for practice days that only load songs. A
    /// pinned service is never filtered out, folded into the past or removed by a sync or by age.
    public var pinned = false
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
        case id, serviceTypeID, serviceTypeName, title, dates, sortDate, serviceTimes, syncedAt, cues, picked, pinned
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
        pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
    }

    public var playbackCues: [ServiceCue] { cues.filter(\.needsPlayback).sorted { $0.position < $1.position } }

    // MARK: Services built in Cantator

    /// The service type of every service built in Cantator. Planning Center ids are numbers, so this can't collide.
    public static let manualServiceTypeID = "cantator"

    /// Built in Cantator, not read from Planning Center. Every cue in it is manual.
    public var isManual: Bool { serviceTypeID == Self.manualServiceTypeID }

    /// What a pinned service is called in the sidebar: its title, or for a Planning Center service
    /// with no title, its service type.
    public var sidebarName: String {
        let name = title.isEmpty ? serviceTypeName : title
        return name.isEmpty ? dates : name
    }

    /// A new, empty service for a date. `title` is what the operator calls it, such as "Sunday Morning".
    public static func manual(title: String, date: Date, cues: [ServiceCue] = [], now: Date = Date()) -> ServicePlan {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        var plan = ServicePlan(
            id: "manual-\(UUID().uuidString)", serviceTypeID: manualServiceTypeID, serviceTypeName: name.isEmpty ? "Service" : name,
            title: name.isEmpty ? "Service" : name, dates: dateLabel(date), sortDate: date, serviceTimes: [date], syncedAt: now
        )
        plan.cues = numbered(cues)
        return plan
    }

    /// "Sun, Nov 8, 2026", so a hand-built service reads like a synced one in the sidebar.
    public static func dateLabel(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().year())
    }

    /// An item or section added by hand. Items run on a track until the operator says otherwise.
    public static func manualCue(title: String, header: Bool = false, notes: String = "", needsPlayback: Bool = true) -> ServiceCue {
        var cue = ServiceCue(
            id: "\(header ? "header" : "manual")-\(UUID().uuidString)", position: 0, title: title,
            itemType: header ? "header" : "item", notes: notes, needsPlayback: header ? false : needsPlayback, isManual: true
        )
        cue.operatorNeeds = header ? nil : needsPlayback
        return cue
    }

    /// This service's order for another date: sections and items with new ids and no tracks, so
    /// last week's song can't play by mistake.
    public func copyingOrder(title: String, date: Date, now: Date = Date()) -> ServicePlan {
        Self.manual(title: title, date: date, cues: orderedCues.map { cue in
            Self.manualCue(title: cue.title, header: cue.itemType == "header", notes: cue.notes, needsPlayback: cue.needsPlayback)
        }, now: now)
    }

    /// A template's order as fresh cues.
    public static func cues(from template: ServiceTemplate) -> [ServiceCue] {
        numbered(template.items.map { manualCue(title: $0.title, header: $0.isHeader, notes: $0.notes, needsPlayback: $0.needsPlayback) })
    }

    /// Moves a cue one place up (-1) or down (+1). Returns false at either end.
    @discardableResult
    public mutating func move(_ id: CueID, by offset: Int) -> Bool {
        var ordered = orderedCues
        guard let index = ordered.firstIndex(where: { $0.id == id }), ordered.indices.contains(index + offset) else { return false }
        ordered.swapAt(index, index + offset)
        cues = Self.numbered(ordered)
        return true
    }

    /// Moves a cue to a point in the service, as a drag does. Dropping a cue on itself changes nothing.
    public mutating func move(_ id: CueID, to point: InsertPoint) {
        if case .after(let target) = point, target == id { return }
        guard let moved = cues.first(where: { $0.id == id }) else { return }
        cues.removeAll { $0.id == id }
        insert([moved], at: point)
    }

    public mutating func remove(_ id: CueID) {
        cues.removeAll { $0.id == id }
        cues = Self.numbered(orderedCues)
    }

    /// Services built in Cantator leave the sidebar `keepWeeks` after their date, except the loaded
    /// one. 0 keeps them forever. Synced services are kept or dropped by the sync.
    public static func pruningPastManual(_ plans: [ServicePlan], keepWeeks: Int, loadedID: String?, now: Date = Date()) -> [ServicePlan] {
        guard keepWeeks > 0 else { return plans }
        let cutoff = now.addingTimeInterval(-Double(keepWeeks) * 7 * 24 * 3600)
        return plans.filter { plan in
            guard plan.isManual, !plan.pinned, plan.id != loadedID, let date = plan.sortDate else { return true }
            return date >= cutoff
        }
    }

    /// The end of a window `weeks` weeks ahead of today: the start of the day after the same weekday
    /// that many weeks out, so a service on that day still counts. Nil for 0, which ends nowhere.
    public static func upcomingWindowEnd(weeks: Int, now: Date = Date(), calendar: Calendar = .current) -> Date? {
        guard weeks > 0 else { return nil }
        return calendar.date(byAdding: .day, value: 7 * weeks + 1, to: calendar.startOfDay(for: now))
    }

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
            // for this same song before still goes on: Planning Center lengths are often placeholders.
            // A file remembered only by title always waits.
            // An item typed by hand waits for the operator too: they are choosing its track, not confirming a plan's.
            guard cue.needsPlayback, cue.trackID == nil, !cue.matchCleared, !cue.removedInPCO, !cue.isManual,
                  MatchBand(candidates: cue.candidates) == .proposed, let top = cue.candidates.first,
                  top.source != .rememberedTitle, !top.durationMismatch || top.source == .remembered
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

    /// Applies a sync. A plan missing from the sync stays if it was built in Cantator, is loaded,
    /// holds operator work and is under two weeks old (Planning Center stops listing a plan as future
    /// once it starts), is pinned, or was chosen in the service picker and is still inside its window.
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
            if plan.isManual || plan.pinned || plan.id == loadedID { return true }
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
        result.pinned = pinned
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

    /// Where a choice is saved: the item's song, and its title. A title keeps its numbers, so
    /// "Psalm 23" and "Psalm 91" differ, and a title with nothing left once words such as "choir"
    /// and "special" are dropped has no key at all.
    public static func keys(for cue: ServiceCue) -> [String] {
        var keys: [String] = []
        if let song = cue.songID { keys.append("song:\(song)") }
        if let title = titleKey(cue.title) { keys.append(title) }
        return keys
    }

    static func titleKey(_ title: String) -> String? {
        let words = TitleNormalizer.normalize(title)
        guard !words.isEmpty else { return nil }
        return "title:" + (words + TitleNormalizer.titleNumbers(title).sorted()).joined(separator: " ")
    }

    /// Where a choice is looked up. An item with a song is only ever matched by that song, so
    /// another song with a similar title never inherits its file or its Needs.
    static func lookupKey(for cue: ServiceCue) -> (key: String, bySong: Bool)? {
        if let song = cue.songID { return ("song:\(song)", true) }
        return titleKey(cue.title).map { ($0, false) }
    }

    public func contentID(for cue: ServiceCue) -> String? {
        remembered(for: cue)?.contentID
    }

    /// The file confirmed before, and whether it was found by the item's song.
    public func remembered(for cue: ServiceCue) -> (contentID: String, bySong: Bool)? {
        guard let lookup = Self.lookupKey(for: cue), let id = confirmed[lookup.key] else { return nil }
        return (id, lookup.bySong)
    }

    public func needsOverride(for cue: ServiceCue) -> Bool? {
        Self.lookupKey(for: cue).flatMap { needsOverrides[$0.key] }
    }

    public mutating func remember(_ cue: ServiceCue, contentID: String) {
        for key in Self.keys(for: cue) { confirmed[key] = contentID }
    }

    public mutating func rememberNeeds(_ cue: ServiceCue, needed: Bool) {
        for key in Self.keys(for: cue) { needsOverrides[key] = needed }
    }
}

public struct OutputRouting: Codable, Equatable, Sendable {
    /// Whether a stereo pair starting at `firstChannel` exists. A device with two outputs or fewer
    /// only has the pair 1-2.
    public static func pairFits(firstChannel: Int, deviceChannels: Int) -> Bool {
        deviceChannels <= 2 ? firstChannel == 0 : firstChannel >= 0 && firstChannel + 1 < deviceChannels
    }

    /// After a device is chosen: a pair it doesn't have goes back to 1-2, which every device has,
    /// so a pair saved for a larger interface can't leave Arm refused with no picker to fix it.
    /// Only connected devices count: one briefly unplugged keeps its pair.
    public mutating func fitPairs(deviceChannels: [String: Int]) {
        if let uid = houseDeviceUID, let channels = deviceChannels[uid], !Self.pairFits(firstChannel: houseFirstChannel, deviceChannels: channels) {
            houseFirstChannel = 0
        }
        if let uid = cueDeviceUID, let channels = deviceChannels[uid], !Self.pairFits(firstChannel: cueFirstChannel, deviceChannels: channels) {
            cueFirstChannel = 0
        }
    }

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

    /// House and cue on the same outputs. One device is allowed when each has its own pair, as on a
    /// Dante or other multichannel interface: each engine's channel map sends silence to every
    /// output but its own pair, so the cue still never reaches the house pair. A device with two
    /// outputs or fewer has only the pair 1-2, so house and cue on it always overlap.
    public var sharesOutputs: Bool {
        houseDeviceUID != nil && houseDeviceUID == cueDeviceUID && abs(houseFirstChannel - cueFirstChannel) < 2
    }
}

public enum PlanningCenterSource: String, Codable, CaseIterable, Sendable {
    /// The Planning Center connector on the operator's Claude account, through Claude Code.
    case connector
    /// A Planning Center Personal Access Token, read directly.
    case token
}

/// Where services come from. Standalone needs no account: services are built in Cantator.
public enum ServiceSource: String, Codable, CaseIterable, Sendable {
    case standalone
    case planningCenter
}

/// How much of the transport the Show view puts in front of the operator. Both modes drive the
/// same `ShowController`; Simple only shows less and answers fewer keys.
public enum OperatorMode: String, Codable, CaseIterable, Sendable {
    /// The cue list with a pointer, the waveform, EQ, meters and every transport key.
    case full
    /// A plain list with Arm on each row and four buttons: Arm, Disarm, GO and Fade.
    case simple

    /// Whether this mode answers a transport key. Simple keeps Arm, GO, Fade, Disarm, Esc and the
    /// fault acknowledgement. Hold, markers, end nudges and audition stay keys for Full, so a stray
    /// press in Simple cannot silence a track or move its ending. The arrow keys are the Full view's
    /// pointer; in Simple they belong to the song list, which selects and never plays.
    public func answers(_ key: TransportKey) -> Bool {
        switch self {
        case .full: return true
        case .simple:
            switch key {
            case .arm, .disarm, .go, .fade, .panic, .acknowledge: return true
            case .hold, .marker, .nudgeEnd, .audition, .pointer: return false
            }
        }
    }
}

/// The transport actions a key can ask for.
public enum TransportKey: CaseIterable, Sendable {
    case arm, disarm, go, fade, hold, panic, marker, nudgeEnd, audition, pointer, acknowledge
}

/// What happens when a new audio file arrives in a watched folder.
public enum NewFileHandling: String, Codable, CaseIterable, Sendable {
    /// The New File pop-up, once nothing is loaded or playing.
    case ask
    /// Files wait under New Files in the sidebar for a week, then are just library tracks.
    case quiet
}

/// A service order saved to start new services from: sections and item titles, never tracks.
public struct ServiceTemplate: Codable, Equatable, Identifiable, Sendable {
    public struct Item: Codable, Equatable, Sendable {
        public var title: String
        public var isHeader: Bool
        public var needsPlayback: Bool
        public var notes: String

        public init(title: String, isHeader: Bool = false, needsPlayback: Bool = true, notes: String = "") {
            self.title = title
            self.isHeader = isHeader
            self.needsPlayback = needsPlayback
            self.notes = notes
        }
    }

    public var id: UUID
    public var name: String
    public var items: [Item]
    public var savedAt: Date

    public init(id: UUID = UUID(), name: String, items: [Item], savedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.items = items
        self.savedAt = savedAt
    }

    /// The plan's order without its tracks.
    public init(plan: ServicePlan, name: String, now: Date = Date()) {
        self.init(
            name: name,
            items: plan.orderedCues.map { cue in
                Item(title: cue.title, isHeader: cue.itemType == "header", needsPlayback: cue.needsPlayback, notes: cue.notes)
            },
            savedAt: now
        )
    }

    /// "3 sections, 6 items"
    public var summary: String {
        let headers = items.filter(\.isHeader).count
        let count = items.count - headers
        return "\(headers) \(headers == 1 ? "section" : "sections"), \(count) \(count == 1 ? "item" : "items")"
    }
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
    /// Off for a fresh install. Settings saved before this choice existed read as on, since Claude was always on then.
    public var llmEnabled = false
    /// Standalone for a fresh install. Settings saved before the choice existed read as Planning Center.
    public var serviceSource = ServiceSource.standalone
    /// False until the operator has answered the first-launch question. Older settings read as answered.
    public var hasChosenServiceSource = false
    public var newFileHandling = NewFileHandling.ask
    /// How long services built in Cantator stay in the sidebar once they are over. 0 keeps them forever.
    public var keepPastServicesWeeks = 8
    /// How many weeks ahead the sidebar lists services, counted from today so the window moves with
    /// the date. 0 lists them all.
    public var upcomingServicesWeeks = 0
    public var templates: [ServiceTemplate] = []
    public var isolateSystemSound = true
    public var appearance = "dark"
    /// Advanced (Full) for a fresh install and for settings saved before the choice existed.
    public var operatorMode = OperatorMode.full
    /// When Cantor started watching each folder. Only files that arrive later count as new.
    public var watchedSince: [String: Date] = [:]
    /// Every service type seen in Planning Center, name by id, so Settings can list them all.
    public var serviceTypes: [String: String] = [:]
    /// Off, Sync Now and the sidebar leave out `hiddenServiceTypeIDs`. On, every type is imported
    /// and the unchecked list is kept for when it is turned off again.
    public var importAllServiceTypes = true
    /// Service types left unchecked. The service picker still lists them.
    public var hiddenServiceTypeIDs: Set<String> = []
    /// The tags offered for tracks, in order. A tag a track still has is offered too.
    public var tags: [String] = PlaybackCategory.defaults
    /// Applying New Files copies each playback into ~/Music/Cantor, downloading it from Drive if
    /// needed, so it plays even if the original moves or is deleted.
    public var copyPlaybacksToCantor = true

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
        llmEnabled = try c.decodeIfPresent(Bool.self, forKey: .llmEnabled) ?? true
        serviceSource = (try? c.decodeIfPresent(ServiceSource.self, forKey: .serviceSource)) ?? .planningCenter
        hasChosenServiceSource = try c.decodeIfPresent(Bool.self, forKey: .hasChosenServiceSource) ?? true
        newFileHandling = (try? c.decodeIfPresent(NewFileHandling.self, forKey: .newFileHandling)) ?? newFileHandling
        keepPastServicesWeeks = try c.decodeIfPresent(Int.self, forKey: .keepPastServicesWeeks) ?? keepPastServicesWeeks
        upcomingServicesWeeks = try c.decodeIfPresent(Int.self, forKey: .upcomingServicesWeeks) ?? upcomingServicesWeeks
        templates = try c.decodeIfPresent([ServiceTemplate].self, forKey: .templates) ?? templates
        isolateSystemSound = try c.decodeIfPresent(Bool.self, forKey: .isolateSystemSound) ?? isolateSystemSound
        appearance = try c.decodeIfPresent(String.self, forKey: .appearance) ?? appearance
        operatorMode = (try? c.decodeIfPresent(OperatorMode.self, forKey: .operatorMode)) ?? operatorMode
        watchedSince = try c.decodeIfPresent([String: Date].self, forKey: .watchedSince) ?? watchedSince
        serviceTypes = try c.decodeIfPresent([String: String].self, forKey: .serviceTypes) ?? serviceTypes
        importAllServiceTypes = try c.decodeIfPresent(Bool.self, forKey: .importAllServiceTypes) ?? importAllServiceTypes
        hiddenServiceTypeIDs = try c.decodeIfPresent(Set<String>.self, forKey: .hiddenServiceTypeIDs) ?? hiddenServiceTypeIDs
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? tags
        copyPlaybacksToCantor = try c.decodeIfPresent(Bool.self, forKey: .copyPlaybacksToCantor) ?? copyPlaybacksToCantor
    }

    /// Adds a tag to the list and returns its cleaned name, or nil when nothing is left of it.
    @discardableResult
    public mutating func addTag(_ name: String) -> String? {
        let tag = FileClassifier.cleanCategory(name)
        guard !tag.isEmpty else { return nil }
        if !tags.contains(tag) { tags.append(tag) }
        return tag
    }

    /// Renames in place, keeping the tag's position. Renaming onto a tag already listed merges them.
    public mutating func renameTag(_ old: String, to new: String) {
        guard old != new, !new.isEmpty else { return }
        if let index = tags.firstIndex(of: old), !tags.contains(new) {
            tags[index] = new
        } else {
            tags.removeAll { $0 == old }
            if !tags.contains(new) { tags.append(new) }
        }
    }

    /// A service of a hidden type stays in the sidebar when it was picked by hand or pinned.
    public func hides(_ plan: ServicePlan) -> Bool {
        skippedServiceTypeIDs.contains(plan.serviceTypeID) && !plan.picked && !plan.pinned
    }

    public var usesPlanningCenter: Bool { serviceSource == .planningCenter }

    /// The first-launch answer. Picking Planning Center turns Claude on, as it always was; building
    /// services here leaves it off until the operator wants it.
    public mutating func chooseServiceSource(_ source: ServiceSource) {
        serviceSource = source
        hasChosenServiceSource = true
        llmEnabled = source == .planningCenter
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
