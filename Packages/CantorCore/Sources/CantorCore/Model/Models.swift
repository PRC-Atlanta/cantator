import Foundation

public enum FileLocality: String, Codable, Sendable {
    case local
    case cloudOnly
    case missing
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
        return local.first { $0.path.hasPrefix(managedRoot) } ?? local.first
    }

    public var isLocal: Bool { bestFile() != nil }
    public var hasCloudOnlyCopy: Bool { files.contains { $0.locality == .cloudOnly } }
    public var isAnalyzed: Bool { integratedLUFS != nil }
    public var primaryFilename: String { (bestFile() ?? files.first)?.filename ?? title }
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
    public var songID: String?
    public var lengthSec: Double?
    public var attachmentFilenames: [String]
    public var needsPlayback: Bool
    public var candidates: [MatchCandidate]
    /// Set only by the operator. Nothing assigns this automatically.
    public var trackID: UUID?
    public var changedSinceConfirm: Bool
    public var isManual: Bool

    public init(
        id: CueID, position: Int, title: String, itemType: String = "item", notes: String = "", arrangement: String = "",
        songID: String? = nil, lengthSec: Double? = nil, attachmentFilenames: [String] = [], needsPlayback: Bool = true,
        isManual: Bool = false
    ) {
        self.id = id
        self.position = position
        self.title = title
        self.itemType = itemType
        self.notes = notes
        self.arrangement = arrangement
        self.songID = songID
        self.lengthSec = lengthSec
        self.attachmentFilenames = attachmentFilenames
        self.needsPlayback = needsPlayback
        candidates = []
        trackID = nil
        changedSinceConfirm = false
        self.isManual = isManual
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

    public var playbackCues: [ServiceCue] { cues.filter(\.needsPlayback).sorted { $0.position < $1.position } }

    public var hasOperatorWork: Bool { cues.contains { $0.trackID != nil || $0.isManual } }

    /// Applies a sync. A plan missing from the sync stays if it is loaded, or holds operator work
    /// and is under two weeks old: Planning Center stops listing a plan as future once it starts.
    public static func applySync(existing: [ServicePlan], fresh: [ServicePlan], loadedID: String?, now: Date = Date()) -> [ServicePlan] {
        let byID = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let synced = fresh.map { byID[$0.id]?.merging(fresh: $0) ?? $0 }
        let freshIDs = Set(fresh.map(\.id))
        let cutoff = now.addingTimeInterval(-14 * 24 * 3600)
        let kept = existing.filter { plan in
            guard !freshIDs.contains(plan.id) else { return false }
            return plan.id == loadedID || (plan.hasOperatorWork && (plan.sortDate ?? now) >= cutoff)
        }
        return (synced + kept).sorted { ($0.sortDate ?? .distantFuture) < ($1.sortDate ?? .distantFuture) }
    }

    /// Applies a fresh sync, keeping operator work on items that still exist.
    public func merging(fresh: ServicePlan) -> ServicePlan {
        var result = fresh
        let previous = Dictionary(cues.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        result.cues = fresh.cues.map { incoming in
            guard let old = previous[incoming.id] else { return incoming }
            var merged = incoming
            merged.trackID = old.trackID
            merged.candidates = old.candidates
            merged.needsPlayback = old.needsPlayback
            merged.changedSinceConfirm = old.changedSinceConfirm
            if old.trackID != nil, old.title != incoming.title || old.songID != incoming.songID {
                merged.changedSinceConfirm = true
            }
            return merged
        }
        result.cues += cues.filter(\.isManual)
        return result
    }
}

public struct AliasMemory: Codable, Equatable, Sendable {
    /// Keys are `song:<id>` or `title:<normalized>`, values are content IDs.
    public var confirmed: [String: String] = [:]
    /// Same keys. Operator's explicit Needed / Not Needed choices.
    public var needsOverrides: [String: Bool] = [:]

    public init() {}

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

    public var isSameDevice: Bool { houseDeviceUID != nil && houseDeviceUID == cueDeviceUID }
}

public struct AppSettings: Codable, Equatable, Sendable {
    public var routing = OutputRouting()
    public var folders: [String] = AppSettings.defaultFolders()
    public var panicFadeSec = 1.5
    public var defaultFadeOutSec = 3.0
    public var targetLUFS = -18.0
    public var normalize = true
    public var llmModel = "claude-opus-5-5"
    public var llmEnabled = true
    public var isolateSystemSound = true
    public var appearance = "dark"

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
        llmEnabled = try c.decodeIfPresent(Bool.self, forKey: .llmEnabled) ?? llmEnabled
        isolateSystemSound = try c.decodeIfPresent(Bool.self, forKey: .isolateSystemSound) ?? isolateSystemSound
        appearance = try c.decodeIfPresent(String.self, forKey: .appearance) ?? appearance
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
