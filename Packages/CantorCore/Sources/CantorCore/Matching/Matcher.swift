import Foundation

public enum StringSimilarity {
    public static func jaccard(_ a: [String], _ b: [String]) -> Double {
        let left = Set(a), right = Set(b)
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        return Double(left.intersection(right).count) / Double(left.union(right).count)
    }

    public static func levenshteinRatio(_ a: String, _ b: String) -> Double {
        let s = Array(a), t = Array(b)
        guard !s.isEmpty, !t.isEmpty else { return s.isEmpty && t.isEmpty ? 1 : 0 }
        var previous = Array(0...t.count)
        var current = [Int](repeating: 0, count: t.count + 1)
        for i in 1...s.count {
            current[0] = i
            for j in 1...t.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (s[i - 1] == t[j - 1] ? 0 : 1))
            }
            swap(&previous, &current)
        }
        return 1 - Double(previous[t.count]) / Double(max(s.count, t.count))
    }

    public static func jaroWinkler(_ a: String, _ b: String) -> Double {
        let s = Array(a), t = Array(b)
        guard !s.isEmpty, !t.isEmpty else { return 0 }
        let window = max(max(s.count, t.count) / 2 - 1, 0)
        var sMatched = [Bool](repeating: false, count: s.count)
        var tMatched = [Bool](repeating: false, count: t.count)
        var matches = 0
        for i in s.indices {
            let low = max(0, i - window), high = min(t.count - 1, i + window)
            guard low <= high else { continue }
            for j in low...high where !tMatched[j] && s[i] == t[j] {
                sMatched[i] = true
                tMatched[j] = true
                matches += 1
                break
            }
        }
        guard matches > 0 else { return 0 }
        var transpositions = 0
        var k = 0
        for i in s.indices where sMatched[i] {
            while !tMatched[k] { k += 1 }
            if s[i] != t[k] { transpositions += 1 }
            k += 1
        }
        let m = Double(matches)
        let jaro = (m / Double(s.count) + m / Double(t.count) + (m - Double(transpositions) / 2) / m) / 3
        var prefix = 0
        while prefix < min(4, min(s.count, t.count)), s[prefix] == t[prefix] { prefix += 1 }
        return jaro + Double(prefix) * 0.1 * (1 - jaro)
    }

    /// 0 to 1 over normalized tokens. Containment counts, since filenames often add words.
    public static func score(_ a: [String], _ b: [String]) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        let left = a.joined(separator: " "), right = b.joined(separator: " ")
        if left == right { return 1 }
        // Words run together in one name but not the other.
        if a.joined() == b.joined() { return 0.95 }
        let tokenOverlap = Double(Set(a).intersection(Set(b)).count) / Double(min(Set(a).count, Set(b).count))
        let token = max(jaccard(a, b), tokenOverlap * 0.9)
        return 0.5 * token + 0.3 * jaroWinkler(left, right) + 0.2 * levenshteinRatio(left, right)
    }
}

public enum Matcher {
    public static let maxCandidates = 8
    public static let rememberedScore = 0.98
    public static let attachmentScore = 0.95
    public static let floorScore = 0.30

    /// Ranks library tracks for one cue. Never assigns a track: that is the operator's job.
    public static func rank(cue: ServiceCue, tracks: [Track], memory: AliasMemory) -> [MatchCandidate] {
        var best: [UUID: MatchCandidate] = [:]
        let keep = { (candidate: MatchCandidate) in
            if (best[candidate.trackID]?.score ?? -1) < candidate.score { best[candidate.trackID] = candidate }
        }

        if let contentID = memory.contentID(for: cue), let track = tracks.first(where: { $0.contentID == contentID }) {
            keep(MatchCandidate(
                trackID: track.id, score: rememberedScore, source: .remembered, reason: "Confirmed for this song before",
                durationMismatch: durationMismatch(cue: cue, track: track)
            ))
        }

        let attachments = Set(cue.attachmentFilenames.map { $0.lowercased() })
        let cueVariants = TitleNormalizer.titleVariants(cue.title)
        let arrangementTokens = TitleNormalizer.normalize(cue.arrangement)
        let cueHints = TitleNormalizer.hints([cue.title, cue.arrangement, cue.notes].joined(separator: " "))

        for track in tracks {
            let names = track.files.map(\.filename)
            if names.contains(where: { attachments.contains($0.lowercased()) }) {
                keep(MatchCandidate(
                    trackID: track.id, score: attachmentScore, source: .attachment, reason: "Attached to this item in Planning Center",
                    durationMismatch: durationMismatch(cue: cue, track: track)
                ))
            }

            let haystacks = names + [track.title]
            var score = 0.0
            var matched = track.primaryFilename
            for name in haystacks {
                let tokens = TitleNormalizer.normalize(name)
                let value = cueVariants.map { StringSimilarity.score($0, tokens) }.max() ?? 0
                if value > score {
                    score = value
                    matched = name
                }
            }

            let hints = haystacks.reduce(into: Set<String>()) { $0.formUnion(TitleNormalizer.hints($1)) }
            if !cueHints.isDisjoint(with: hints) || !cueHints.isDisjoint(with: Set(track.tags.map { $0.lowercased() })) {
                score += 0.05
            }
            if !arrangementTokens.isEmpty, haystacks.contains(where: { StringSimilarity.jaccard(arrangementTokens, TitleNormalizer.normalize($0)) > 0.3 }) {
                score += 0.05
            }

            let mismatch = durationMismatch(cue: cue, track: track)
            if mismatch { score -= 0.1 }
            score = min(max(score, 0), 0.97)
            guard score >= floorScore else { continue }
            keep(MatchCandidate(
                trackID: track.id, score: score, source: .string, reason: "Name similar to \(matched)", durationMismatch: mismatch
            ))
        }

        return best.values
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.trackID.uuidString < $1.trackID.uuidString }
            .prefix(maxCandidates)
            .map { $0 }
    }

    /// Off by more than 25% from the length in Planning Center.
    public static func durationMismatch(cue: ServiceCue, track: Track) -> Bool {
        guard let length = cue.lengthSec, length > 0, track.durationSec > 0 else { return false }
        return abs(track.durationSec - length) / length > 0.25
    }

    public static func needsTiebreak(_ candidates: [MatchCandidate]) -> Bool {
        guard let top = candidates.first, top.source == .string else { return false }
        let closeRunnerUp = candidates.count > 1 && top.score - candidates[1].score < 0.08
        return (top.score >= 0.45 && top.score < 0.85) || closeRunnerUp
    }
}
