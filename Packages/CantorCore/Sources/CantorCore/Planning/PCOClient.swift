import Foundation

public enum PCOError: LocalizedError, Equatable {
    case unauthorized
    case rateLimited
    case http(Int)
    case malformed

    public var errorDescription: String? {
        switch self {
        case .unauthorized: "Planning Center rejected the token. Check the App ID and Secret in Settings."
        case .rateLimited: "Planning Center rate limit reached. Try again in a minute."
        case .http(let code): "Planning Center returned HTTP \(code)."
        case .malformed: "Planning Center returned an unexpected response."
        }
    }
}

/// Read-only Planning Center Services client. Everything it returns is snapshotted to disk; the
/// Show view never calls it.
public actor PCOClient {
    static let base = "https://api.planningcenteronline.com/services/v2"
    static let maxRetries = 3

    private let authorization: String
    private let session: URLSession
    private let spacing: Duration
    private var lastRequest: ContinuousClock.Instant?

    public init(appID: String, secret: String, session: URLSession = .shared, spacing: Duration = .milliseconds(150)) {
        authorization = "Basic " + Data("\(appID):\(secret)".utf8).base64EncodedString()
        self.session = session
        self.spacing = spacing
    }

    public func fetchUpcomingPlans(plansPerType: Int = 6, memory: AliasMemory, now: Date = Date()) async throws -> [ServicePlan] {
        var plans: [ServicePlan] = []
        for type in try await getAll("\(Self.base)/service_types?per_page=100") {
            guard let typeID = type["id"] as? String else { continue }
            let typeName = attributes(type)["name"] as? String ?? "Service"
            let url = "\(Self.base)/service_types/\(typeID)/plans?filter=future&order=sort_date&per_page=\(plansPerType)"
            let (planData, _) = try await getPage(url)
            for plan in planData.prefix(plansPerType) {
                plans.append(try await fetchPlan(plan, serviceTypeID: typeID, serviceTypeName: typeName, memory: memory, now: now))
            }
        }
        return plans.sorted { ($0.sortDate ?? .distantFuture) < ($1.sortDate ?? .distantFuture) }
    }

    private func fetchPlan(
        _ plan: [String: Any], serviceTypeID: String, serviceTypeName: String, memory: AliasMemory, now: Date
    ) async throws -> ServicePlan {
        guard let planID = plan["id"] as? String else { throw PCOError.malformed }
        let attrs = attributes(plan)
        var result = ServicePlan(
            id: planID, serviceTypeID: serviceTypeID, serviceTypeName: serviceTypeName,
            title: attrs["title"] as? String ?? "", dates: attrs["dates"] as? String ?? "",
            sortDate: Self.date(attrs["sort_date"]), syncedAt: now
        )

        let root = "\(Self.base)/service_types/\(serviceTypeID)/plans/\(planID)"
        let times = (try? await getAll("\(root)/plan_times?per_page=25")) ?? []
        result.serviceTimes = times
            .filter { attributes($0)["time_type"] as? String == "service" }
            .compactMap { Self.date(attributes($0)["starts_at"]) }
            .sorted()

        var included: [String: [String: Any]] = [:]
        var items: [[String: Any]] = []
        var next: String? = "\(root)/items?include=song,arrangement&per_page=100"
        while let url = next {
            let document = try await getDocument(url)
            items += document["data"] as? [[String: Any]] ?? []
            for entry in document["included"] as? [[String: Any]] ?? [] {
                if let type = entry["type"] as? String, let id = entry["id"] as? String { included["\(type):\(id)"] = entry }
            }
            next = (document["links"] as? [String: Any])?["next"] as? String
        }

        for (index, item) in items.enumerated() {
            guard var cue = cue(from: item, position: index, included: included) else { continue }
            cue.needsPlayback = memory.needsOverride(for: cue) ?? PlaybackDetector.needsPlayback(cue)
            if cue.needsPlayback {
                let attachments = (try? await getAll("\(root)/items/\(cue.id)/attachments?per_page=25")) ?? []
                cue.attachmentFilenames = attachments.compactMap { attributes($0)["filename"] as? String }
            }
            result.cues.append(cue)
        }
        return result
    }

    private func cue(from item: [String: Any], position: Int, included: [String: [String: Any]]) -> ServiceCue? {
        guard let id = item["id"] as? String else { return nil }
        let attrs = attributes(item)
        let relationships = item["relationships"] as? [String: Any] ?? [:]
        let related = { (name: String) -> [String: Any]? in
            guard let link = (relationships[name] as? [String: Any])?["data"] as? [String: Any],
                  let type = link["type"] as? String, let relatedID = link["id"] as? String
            else { return nil }
            return included["\(type):\(relatedID)"]
        }
        let song = related("song")
        let arrangement = related("arrangement")
        let notes = [attrs["description"] as? String, (attrs["html_details"] as? String).map(Self.stripHTML)]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
        let length = (attrs["length"] as? Double) ?? (attrs["length"] as? Int).map(Double.init)
        return ServiceCue(
            id: id, position: attrs["sequence"] as? Int ?? position, title: attrs["title"] as? String ?? "",
            itemType: attrs["item_type"] as? String ?? "item", notes: notes,
            arrangement: arrangement.flatMap { attributes($0)["name"] as? String } ?? "",
            songID: song?["id"] as? String, lengthSec: (length ?? 0) > 0 ? length : nil
        )
    }

    private nonisolated func attributes(_ resource: [String: Any]) -> [String: Any] {
        resource["attributes"] as? [String: Any] ?? [:]
    }

    private func getAll(_ url: String) async throws -> [[String: Any]] {
        var all: [[String: Any]] = []
        var next: String? = url
        while let current = next {
            let (data, following) = try await getPage(current)
            all += data
            next = following
        }
        return all
    }

    private func getPage(_ url: String) async throws -> ([[String: Any]], String?) {
        let document = try await getDocument(url)
        return (document["data"] as? [[String: Any]] ?? [], (document["links"] as? [String: Any])?["next"] as? String)
    }

    private func getDocument(_ url: String) async throws -> [String: Any] {
        guard let requestURL = URL(string: url) else { throw PCOError.malformed }
        var request = URLRequest(url: requestURL)
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 20

        for attempt in 0...Self.maxRetries {
            if let lastRequest {
                let wait = spacing - lastRequest.duration(to: .now)
                if wait > .zero { try await Task.sleep(for: wait) }
            }
            lastRequest = .now
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch status {
            case 200:
                guard let document = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw PCOError.malformed }
                return document
            case 401, 403:
                throw PCOError.unauthorized
            case 429:
                guard attempt < Self.maxRetries else { throw PCOError.rateLimited }
                let header = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After")
                try await Task.sleep(for: .seconds(Double(header ?? "") ?? 5))
            default:
                throw PCOError.http(status)
            }
        }
        throw PCOError.rateLimited
    }

    private static func date(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
    }

    private static func stripHTML(_ html: String) -> String {
        html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum PlaybackDetector {
    static let playbackKeywords = [
        "choir", "special", "anthem", "track", "soloist", "solo", "offertory", "accompaniment", "satb", "playback", "duet", "trio", "quartet",
    ]
    static let excludedKeywords = [
        "welcome", "sermon", "message", "prayer", "announcement", "benediction", "scripture", "offering prayer", "greeting", "dismissal",
    ]

    /// Errs towards including an item: an extra row costs one click, a missed cue costs the moment.
    public static func needsPlayback(_ cue: ServiceCue) -> Bool {
        if cue.itemType == "header" { return false }
        let text = [cue.title, cue.arrangement, cue.notes].joined(separator: " ").lowercased()
        if playbackKeywords.contains(where: { text.contains($0) }) { return true }
        if cue.itemType == "media" || cue.itemType == "song" { return true }
        if excludedKeywords.contains(where: { cue.title.lowercased().contains($0) }) { return false }
        return false
    }
}
