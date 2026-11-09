import Foundation

/// The user's vocabulary ("lingo", `LingoLexicon`, the same one dictation
/// uses) put to work in voice mode: as the recogniser's `contextualStrings`
/// and as a rewrite of the dictation text. Strut judges and learns the
/// entries; this only reads them, the way `/audio/transcribe` applies them:
/// an entry the user turned off (`dictationOff`, "leave alone") is never used.
public enum VoiceVocabulary {
    /// What the recogniser should expect: `base` (the wake word and the
    /// command phrases) first, then the user's own terms (written values of
    /// entries with mishearings first, then entity names), without repeats
    /// (case aside), at most `limit` in all.
    public static func contextualStrings(from lexicon: LingoLexicon?, base: [String], limit: Int = 100) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        func add(_ string: String) {
            let term = string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty, result.count < limit, seen.insert(term.lowercased()).inserted else { return }
            result.append(term)
        }
        base.forEach(add)
        let enabled = (lexicon?.entries ?? []).filter { !$0.dictationOff }
        for entry in enabled where !entry.heard.isEmpty {
            entry.heard.forEach { add($0.value) }
            add(entry.name)
        }
        for entry in enabled where entry.heard.isEmpty { add(entry.name) }
        return result
    }
}

/// Replaces what the recogniser misheard with what the user writes, by the
/// lexicon's `Heard` forms. Apply it only to dictation text (what the parser
/// split off before a command), never to the transcript the commands are
/// parsed from.
public enum LexiconRewriter {
    /// Each enabled mishearing form, as a whole word (or words), case aside,
    /// becomes its written value; the longest form wins where they overlap;
    /// the replaced text is not rewritten again; punctuation around stays.
    public static func apply(_ text: String, lexicon: LingoLexicon?) -> String {
        guard let lexicon, !text.isEmpty else { return text }
        // The first entry to claim a form keeps it.
        var values: [String: String] = [:]
        var forms: [[String]] = []
        for entry in lexicon.entries where !entry.dictationOff {
            for heard in entry.heard {
                let formWords = words(of: heard.form ?? entry.name)
                guard !formWords.isEmpty, !heard.value.isEmpty else { continue }
                let key = formWords.joined(separator: " ").lowercased()
                guard values[key] == nil else { continue }
                values[key] = heard.value
                forms.append(formWords)
            }
        }
        guard !forms.isEmpty else { return text }
        let alternatives = forms
            .sorted { $0.joined(separator: " ").count > $1.joined(separator: " ").count }
            .map { $0.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "\\s+") }
        let edge = "[\\p{L}\\p{N}_]"
        let pattern = "(?<!\(edge))(?:" + alternatives.joined(separator: "|") + ")(?!\(edge))"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return text }
        let source = text as NSString
        let result = NSMutableString(string: text)
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: source.length))
        for match in matches.reversed() {
            let key = words(of: source.substring(with: match.range)).joined(separator: " ").lowercased()
            if let value = values[key] { result.replaceCharacters(in: match.range, with: value) }
        }
        return result as String
    }

    private static func words(of form: String) -> [String] {
        form.split(whereSeparator: \.isWhitespace).map(String.init)
    }
}
