import Foundation

/// A service item a new file may be for.
public struct ServiceItemRef: Codable, Equatable, Hashable, Sendable {
    public var planID: String
    public var cueID: CueID

    public init(planID: String, cueID: CueID) {
        self.planID = planID
        self.cueID = cueID
    }
}

/// Where a new file should be filed. The operator sees it in the new-file pop-up and nothing is
/// applied until they accept it.
public struct FileSuggestion: Codable, Equatable, Sendable {
    public var title: String
    /// One library tag, such as "choir". Empty means uncategorized.
    public var category: String
    public var isPlayback: Bool
    public var serviceItem: ServiceItemRef?
    public var confidence: Double
    public var reason: String
    public var byClaude: Bool
    /// Why Claude was not used, when it was not.
    public var note: String?

    public init(
        title: String, category: String, isPlayback: Bool = true, serviceItem: ServiceItemRef? = nil, confidence: Double = 0,
        reason: String = "", byClaude: Bool = false, note: String? = nil
    ) {
        self.title = title
        self.category = category
        self.isPlayback = isPlayback
        self.serviceItem = serviceItem
        self.confidence = confidence
        self.reason = reason
        self.byClaude = byClaude
        self.note = note
    }
}

/// The operator's answer for one file in the New Files list. It starts as the suggestion.
public struct NewFileAnswer: Equatable, Sendable {
    public var trackID: UUID
    public var isPlayback: Bool
    public var title: String
    public var category: String
    public var serviceItem: ServiceItemRef?

    public init(trackID: UUID, isPlayback: Bool, title: String, category: String, serviceItem: ServiceItemRef? = nil) {
        self.trackID = trackID
        self.isPlayback = isPlayback
        self.title = title
        self.category = category
        self.serviceItem = serviceItem
    }

    /// `openItem` says whether a service item is still offered and needs a file, so an answer never
    /// carries one that was filled, or has passed, since Claude suggested it. A title the operator
    /// set (`titleWasSet`) is kept over the suggestion.
    public init(item: NewFileItem, currentTitle: String, titleWasSet: Bool = false, openItem: (ServiceItemRef) -> Bool) {
        let suggestion = item.suggestion
        self.init(
            trackID: item.trackID, isPlayback: suggestion?.isPlayback ?? true,
            title: titleWasSet ? currentTitle : suggestion.map(\.title).flatMap { $0.isEmpty ? nil : $0 } ?? currentTitle,
            category: suggestion?.category ?? "", serviceItem: suggestion?.serviceItem.flatMap { openItem($0) ? $0 : nil }
        )
    }
}

public struct NewFileItem: Codable, Equatable, Identifiable, Sendable {
    public var trackID: UUID
    public var detectedAt: Date
    public var suggestion: FileSuggestion?

    public var id: UUID { trackID }

    public init(trackID: UUID, detectedAt: Date = Date(), suggestion: FileSuggestion? = nil) {
        self.trackID = trackID
        self.detectedAt = detectedAt
        self.suggestion = suggestion
    }
}

/// New files waiting for the operator. Saved, so files found while the app was closed, or
/// during a service, are still waiting later.
public struct NewFileInbox: Codable, Equatable, Sendable {
    public var items: [NewFileItem] = []

    public init(items: [NewFileItem] = []) {
        self.items = items
    }

    public var awaitingSuggestion: [NewFileItem] { items.filter { $0.suggestion == nil } }
    public var ready: [NewFileItem] { items.filter { $0.suggestion != nil } }

    public mutating func add(_ ids: [UUID], at date: Date = Date()) {
        for id in ids where !items.contains(where: { $0.trackID == id }) {
            items.append(NewFileItem(trackID: id, detectedAt: date))
        }
    }

    public mutating func remove(_ id: UUID) {
        items.removeAll { $0.trackID == id }
    }

    public mutating func setSuggestion(_ suggestion: FileSuggestion, for id: UUID) {
        guard let index = items.firstIndex(where: { $0.trackID == id }) else { return }
        items[index].suggestion = suggestion
    }

    /// Follows tracks a placeholder was folded into. A file that turned out to be audio the
    /// library already had is no longer new, so it leaves.
    public mutating func reconcile(replaced: [UUID: UUID], existing: Set<UUID>) {
        items.removeAll { replaced[$0.trackID] != nil || !existing.contains($0.trackID) }
    }

    /// How long a file waits under New Files when the operator chose not to be asked about each one.
    public static let quietWaitDays = 7

    /// Files found more than a week ago stop waiting. They stay in the library as they are.
    @discardableResult
    public mutating func dropStale(now: Date = Date()) -> Int {
        let cutoff = now.addingTimeInterval(-Double(Self.quietWaitDays) * 24 * 3600)
        let before = items.count
        items.removeAll { $0.detectedAt < cutoff }
        return before - items.count
    }
}

public enum NewFileDetector {
    /// Tracks created by this scan from a file that arrived in a watched folder after Cantor
    /// started watching it. Files already there when a folder was added are not new.
    public static func newTrackIDs(
        previousIDs: Set<UUID>, tracks: [Track], scan: [ScannedFile], watchedSince: [String: Date]
    ) -> [UUID] {
        let added = Dictionary(scan.compactMap { file in file.addedDate.map { (file.path, $0) } }, uniquingKeysWith: { a, _ in a })
        return tracks.filter { track in
            guard !previousIDs.contains(track.id) else { return false }
            return track.files.contains { file in
                guard let date = added[file.path], let since = watchStart(path: file.path, watchedSince: watchedSince) else { return false }
                return date >= since
            }
        }
        .map(\.id)
    }

    static func watchStart(path: String, watchedSince: [String: Date]) -> Date? {
        watchedSince
            .filter { path.hasPrefix($0.key.hasSuffix("/") ? $0.key : $0.key + "/") }
            .max { $0.key.count < $1.key.count }?
            .value
    }
}

public enum InboxGate {
    /// The pop-up may only appear with no service loaded and nothing playing on either output.
    public static func canPresent(serviceLoaded: Bool, showState: ShowState, showMode: Bool, auditioning: Bool, loadingService: Bool) -> Bool {
        !serviceLoaded && showState == .idle && !showMode && !auditioning && !loadingService
    }

    /// Asking Claude runs another process, so it waits while a cue is armed or playing.
    public static func canClassify(showState: ShowState, showMode: Bool) -> Bool {
        !showState.holdsHouseEngine && !showMode
    }
}

public enum PlaybackCategory {
    public static let defaults = ["choir", "special", "offertory", "prelude", "postlude", "children", "walk-in"]

    /// Most specific first: "Offertory Special" is an offertory.
    static let keywords: [(category: String, words: [String])] = [
        ("offertory", ["offertory", "offering"]),
        ("prelude", ["prelude"]),
        ("postlude", ["postlude"]),
        ("children", ["kids", "children", "childrens", "vbs"]),
        ("choir", ["choir", "choral", "anthem", "chorus"]),
        ("special", ["special", "solo", "duet", "trio", "quartet", "ensemble"]),
        ("walk-in", ["walk in", "walkin", "countdown"]),
    ]

    /// Every category worth offering: the operator's tag list plus what the library already uses.
    public static func all(saved: [String] = defaults, libraryTags: [String]) -> [String] {
        var result = saved
        for tag in libraryTags where !result.contains(tag) { result.append(tag) }
        return result
    }

    /// A guess from the filename, folder and tags, used when Claude is not available.
    public static func guess(filename: String, folder: String, tags: [String: String]) -> String {
        let text = [filename, folder, tags["genre"] ?? "", tags["album"] ?? "", tags["comments"] ?? ""].joined(separator: " ")
        let spaced = text.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
        let words = " " + spaced.lowercased().map { $0.isLetter || $0.isNumber ? $0 : " " }.reduce(into: "") { $0.append($1) } + " "
        let collapsed = words.replacingOccurrences(of: " +", with: " ", options: .regularExpression)
        for entry in keywords where entry.words.contains(where: { collapsed.contains(" \($0) ") }) {
            return entry.category
        }
        return ""
    }

    public static func display(_ category: String) -> String {
        category.isEmpty ? "Uncategorized" : category.capitalized
    }
}
