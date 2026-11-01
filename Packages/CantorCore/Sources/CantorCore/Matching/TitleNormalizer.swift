import Foundation

public enum TitleNormalizer {
    static let noiseTokens: Set<String> = [
        "final", "copy", "mix", "master", "mastered", "track", "tracks", "accompaniment", "instrumental", "backing",
        "perf", "performance", "demo", "new", "old", "edit", "edited", "mp3", "wav", "audio", "playback", "stereo",
    ]
    static let hintTokens: Set<String> = ["choir", "special", "solo", "soloist", "duet", "trio", "quartet", "satb", "anthem"]
    static let stopwords: Set<String> = ["the", "a", "an", "of", "and", "to", "in", "o", "oh"]

    /// Filename or title into comparable tokens. Hints like "choir" are removed here, see `hints`.
    public static func normalize(_ text: String) -> [String] {
        tokens(text).filter { token in
            !noiseTokens.contains(token) && !hintTokens.contains(token) && !stopwords.contains(token)
                && !isVersionOrNumber(token)
        }
    }

    public static func hints(_ text: String) -> Set<String> {
        Set(tokens(text)).intersection(hintTokens)
    }

    static func tokens(_ text: String) -> [String] {
        var value = text
        if let dot = value.lastIndex(of: "."), FolderScanner.audioExtensions.contains(value[value.index(after: dot)...].lowercased()) {
            value = String(value[..<dot])
        }
        // BeStill and GreatIsThyFaithfulness keep their word breaks.
        value = value.replacingOccurrences(of: #"(\p{Ll})(\p{Lu})"#, with: "$1 $2", options: .regularExpression)
        value = value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US"))
        value = value.replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "\u{2019}", with: "")
        let separators = CharacterSet.alphanumerics.inverted
        return value.lowercased().components(separatedBy: separators).filter { !$0.isEmpty }
    }

    private static func isVersionOrNumber(_ token: String) -> Bool {
        if token.allSatisfy(\.isNumber) { return true }
        if token.hasPrefix("v"), token.count > 1, token.dropFirst().allSatisfy(\.isNumber) { return true }
        // Bitrates, as in 128k or 320kbps.
        return token.range(of: #"^\d+(k|kbps)$"#, options: .regularExpression) != nil
    }

    /// The whole title plus the part after a colon or dash, as in "Offertory Special: Be Still".
    public static func titleVariants(_ title: String) -> [[String]] {
        var variants = [normalize(title)]
        for separator in [":", " - ", " \u{2013} "] {
            if let range = title.range(of: separator, options: .backwards) {
                variants.append(normalize(String(title[range.upperBound...])))
            }
        }
        return variants.filter { !$0.isEmpty }
    }

    /// A readable title from a filename, for the library list.
    public static func displayTitle(filename: String) -> String {
        var value = filename
        if let dot = value.lastIndex(of: ".") { value = String(value[..<dot]) }
        value = value.replacingOccurrences(of: "_", with: " ")
        value = value.replacingOccurrences(of: #"\s*\(\d+\)\s*$"#, with: "", options: .regularExpression)
        value = value.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return value.trimmingCharacters(in: .whitespaces)
    }
}
