import Foundation

public enum LLMError: LocalizedError, Equatable {
    case unauthorized
    case rateLimited
    case refused
    case http(Int)
    case malformed

    public var errorDescription: String? {
        switch self {
        case .unauthorized: "The Claude API key was rejected."
        case .rateLimited: "Claude API rate limit reached. Try again shortly."
        case .refused: "Claude declined this request."
        case .http(let code): "Claude API returned HTTP \(code)."
        case .malformed: "Claude returned an unexpected response."
        }
    }
}

/// Reorders ambiguous candidates. Sends only item titles, arrangement names, candidate filenames
/// and durations, which can contain a soloist's name, but no paths, notes or audio. It can never
/// confirm a match.
public struct LLMTiebreaker: Sendable {
    public static let stringWeight = 0.6
    public static let llmWeight = 0.4
    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    struct Verdict: Equatable {
        var cueID: CueID
        var chosenIndex: Int?
        var confidence: Double
        var reason: String
    }

    public var apiKey: String
    public var model: String
    public var session: URLSession

    public init(apiKey: String, model: String, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.model = model
        self.session = session
    }

    /// Returns reordered candidates per cue ID. Cues without a verdict are left out.
    public func resolve(cues: [ServiceCue], tracks: [UUID: Track]) async throws -> [CueID: [MatchCandidate]] {
        guard !cues.isEmpty else { return [:] }
        let body = try Self.requestBody(model: model, cues: cues, tracks: tracks)
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            switch http.statusCode {
            case 401, 403: throw LLMError.unauthorized
            case 429: throw LLMError.rateLimited
            default: throw LLMError.http(http.statusCode)
            }
        }
        let verdicts = try Self.parse(data)
        var result: [CueID: [MatchCandidate]] = [:]
        for cue in cues {
            guard let verdict = verdicts.first(where: { $0.cueID == cue.id }) else { continue }
            result[cue.id] = Self.blend(candidates: cue.candidates, verdict: verdict)
        }
        return result
    }

    static func requestBody(model: String, cues: [ServiceCue], tracks: [UUID: Track]) throws -> Data {
        let items: [[String: Any]] = cues.map { cue in
            var item: [String: Any] = ["item_id": cue.id, "title": cue.title]
            if !cue.arrangement.isEmpty { item["arrangement"] = cue.arrangement }
            if let length = cue.lengthSec { item["length_seconds"] = Int(length) }
            item["candidates"] = cue.candidates.enumerated().map { index, candidate -> [String: Any] in
                let track = tracks[candidate.trackID]
                var entry: [String: Any] = ["index": index, "filename": track?.primaryFilename ?? ""]
                if let duration = track?.durationSec, duration > 0 { entry["duration_seconds"] = Int(duration) }
                return entry
            }
            return item
        }
        let itemsJSON = try JSONSerialization.data(withJSONObject: items, options: [.sortedKeys])

        let schema: [String: Any] = [
            "type": "object",
            "additionalProperties": false,
            "required": ["results"],
            "properties": [
                "results": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "additionalProperties": false,
                        "required": ["item_id", "chosen_index", "confidence", "reason"],
                        "properties": [
                            "item_id": ["type": "string"],
                            "chosen_index": ["anyOf": [["type": "integer"], ["type": "null"]]],
                            "confidence": ["type": "number"],
                            "reason": ["type": "string"],
                        ],
                    ] as [String: Any],
                ] as [String: Any],
            ],
        ]

        let system = """
        You match items from a church service plan to audio playback files. For each item, choose the \
        candidate file that is the same song as the item, or null if none is. Filenames are often messy. \
        A file for a different song with similar words is not a match, and neither is a different arrangement \
        when the arrangement name rules it out. Give confidence from 0 to 1 and a reason of at most 12 words.
        """

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 8000,
            "fallbacks": "default",
            "output_config": [
                "effort": "low",
                "format": ["type": "json_schema", "schema": schema],
            ] as [String: Any],
            "system": system,
            "messages": [["role": "user", "content": String(decoding: itemsJSON, as: UTF8.self)]],
        ]
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    static func parse(_ data: Data) throws -> [Verdict] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw LLMError.malformed }
        if root["stop_reason"] as? String == "refusal" { throw LLMError.refused }
        guard let content = root["content"] as? [[String: Any]],
              let text = content.first(where: { $0["type"] as? String == "text" })?["text"] as? String,
              let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let results = json["results"] as? [[String: Any]]
        else { throw LLMError.malformed }
        return results.compactMap { entry in
            guard let id = entry["item_id"] as? String else { return nil }
            return Verdict(
                cueID: id, chosenIndex: entry["chosen_index"] as? Int, confidence: entry["confidence"] as? Double ?? 0,
                reason: entry["reason"] as? String ?? ""
            )
        }
    }

    /// 0.6 string score, 0.4 model score. The model can move a candidate, not confirm it.
    static func blend(candidates: [MatchCandidate], verdict: Verdict) -> [MatchCandidate] {
        var updated = candidates
        for index in updated.indices {
            let chosen = verdict.chosenIndex == index
            let llmScore = chosen ? verdict.confidence : (verdict.chosenIndex == nil ? 0 : (1 - verdict.confidence) * 0.5)
            updated[index].score = min(max(stringWeight * updated[index].score + llmWeight * llmScore, 0), 0.97)
            if chosen {
                updated[index].source = .llm
                updated[index].reason = verdict.reason
            }
        }
        return updated.sorted { $0.score > $1.score }
    }
}
