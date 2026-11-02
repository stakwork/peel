import Foundation

/// An agent reply (markdown) made into something sensible to read aloud
/// (docs/voice-mode.md, "Long replies, markdown, code and links"): code,
/// tables and links become a short phrase, markup goes, and a long reply is
/// cut to a short version with the rest kept for "read it all". Pure.
public struct SpokenText: Equatable, Sendable {
    /// Sentence-sized pieces to speak now, so speech can be stopped and
    /// queued quickly. Ends with `shortVersionNote` when `isShortened`.
    public var chunks: [String]
    /// Every sentence of the cleaned reply, for "read it all".
    public var full: [String]
    public var isShortened: Bool

    /// Said after a short version.
    public static let shortVersionNote = "That is the short version. Say read it all for the rest."

    /// How much is read before the short version ends: characters, and
    /// sentences (a list item is one).
    public struct Budget: Sendable, Equatable {
        public var characters: Int
        public var sentences: Int
        public init(characters: Int = 600, sentences: Int = 8) {
            self.characters = characters
            self.sentences = sentences
        }
    }

    public init(markdown: String, budget: Budget = Budget()) {
        let paragraphs = Self.paragraphs(markdown)
        full = paragraphs.flatMap { $0 }
        var taken: [String] = []
        var characters = 0
        var boundary = 0
        var cut = false
        outer: for paragraph in paragraphs {
            for sentence in paragraph {
                if !taken.isEmpty, characters + sentence.count > budget.characters || taken.count >= budget.sentences {
                    cut = true
                    break outer
                }
                taken.append(sentence)
                characters += sentence.count + 1
            }
            boundary = taken.count
        }
        if cut, boundary > 0 { taken = Array(taken.prefix(boundary)) }
        isShortened = cut
        chunks = cut ? taken + [Self.shortVersionNote] : taken
    }

    // MARK: Paragraphs of sentences

    /// The reply as paragraphs, each a list of cleaned sentences.
    static func paragraphs(_ markdown: String) -> [[String]] {
        var result: [[String]] = []
        var current: [String] = []
        var plain: [String] = []
        func flushPlain() {
            guard !plain.isEmpty else { return }
            current += sentences(in: plain.joined(separator: " "))
            plain = []
        }
        func endParagraph() {
            flushPlain()
            if !current.isEmpty { result.append(current) }
            current = []
        }

        var fence: String?
        var codeLines = 0
        var inTable = false
        for raw in markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let marker = fence {
                if line.hasPrefix(marker) {
                    fence = nil
                    current.append(codeBlockPhrase(lines: codeLines))
                } else {
                    codeLines += 1
                }
                continue
            }
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                flushPlain()
                fence = String(line.prefix(3))
                codeLines = 0
                continue
            }
            if isTableLine(line) {
                if !inTable {
                    flushPlain()
                    current.append("A table, skipped.")
                    inTable = true
                }
                continue
            }
            inTable = false
            if line.isEmpty {
                endParagraph()
                continue
            }
            if line.range(of: #"^([-*_])(\s*\1){2,}$"#, options: .regularExpression) != nil { continue }
            if let heading = line.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
                flushPlain()
                let text = clean(String(line[heading.upperBound...]))
                if !text.isEmpty { current.append(terminated(text)) }
                continue
            }
            var body = line
            let isQuote = body.hasPrefix(">")
            while let quote = body.range(of: #"^>\s?"#, options: .regularExpression) { body.removeSubrange(quote) }
            if let marker = body.range(of: #"^([-*+•]|\d{1,3}[.)])\s+"#, options: .regularExpression) {
                flushPlain()
                let text = clean(String(body[marker.upperBound...]))
                if !text.isEmpty { current.append(terminated(text)) }
                continue
            }
            let text = clean(body)
            // A quoted line stands alone: the sentence splitter would not
            // break before a lowercase word that follows a full stop.
            if isQuote { flushPlain() }
            if !text.isEmpty { plain.append(text) }
            if isQuote { flushPlain() }
        }
        if fence != nil { current.append(codeBlockPhrase(lines: codeLines)) }
        endParagraph()
        return result
    }

    private static func codeBlockPhrase(lines: Int) -> String {
        switch lines {
        case ...0: "A code block, skipped."
        case 1: "A code block of one line, skipped."
        default: "A code block of \(lines) lines, skipped."
        }
    }

    private static func isTableLine(_ line: String) -> Bool {
        guard line.contains("|") else { return false }
        return line.hasPrefix("|") || line.range(of: #"^[\s|:\-]+$"#, options: .regularExpression) != nil
    }

    private static func terminated(_ text: String) -> String {
        guard let last = text.last else { return text }
        return ".!?…:;".contains(last) ? text : text + "."
    }

    private static func sentences(in text: String) -> [String] {
        var found: [String] = []
        text.enumerateSubstrings(in: text.startIndex..., options: [.bySentences, .substringNotRequired]) { _, range, _, _ in
            let sentence = text[range].trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty { found.append(sentence) }
        }
        return found.isEmpty && !text.isEmpty ? [text] : found
    }

    // MARK: Inline markup

    /// One line's inline markup removed: links, URLs, identifiers, code
    /// ticks, emphasis, HTML and emoji.
    static func clean(_ text: String) -> String {
        var s = text
        s = replace(#"!\[[^\]]*\]\([^)]*\)"#, in: s, with: "an image")
        s = replace(#"\[([^\]]*)\]\([^)]*\)"#, in: s, with: "$1")
        s = replace(#"<(https?://[^>\s]+)>"#, in: s, with: "$1")
        s = s.replacingOccurrences(of: "`", with: "")
        s = replaceURLs(in: s)
        s = replace(#"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b"#, in: s, with: "an identifier")
        s = replaceMatches(#"\b[0-9a-fA-F]{12,}\b"#, in: s) { $0.contains(where: \.isNumber) ? "an identifier" : $0 }
        s = replace(#"(?<![\w/])(?:~|\.{1,2})?/[\w.\-]+(?:/[\w.\-]+)+"#, in: s, with: "an identifier")
        s = replace(#"[A-Za-z0-9_\-]+(?:/[A-Za-z0-9_.\-]+)+\.[A-Za-z0-9]{1,6}\b"#, in: s, with: "an identifier")
        s = replaceMatches(#"\S{24,}"#, in: s) { _ in "an identifier" }
        s = replace(#"\*\*(.+?)\*\*"#, in: s, with: "$1")
        s = replace(#"__(.+?)__"#, in: s, with: "$1")
        s = replace(#"~~(.+?)~~"#, in: s, with: "$1")
        s = replace(#"\*(.+?)\*"#, in: s, with: "$1")
        s = replace(#"(?<![\w])_(.+?)_(?![\w])"#, in: s, with: "$1")
        s = replace(#"</?[A-Za-z][^>]*>"#, in: s, with: "")
        s = String(String.UnicodeScalarView(s.unicodeScalars.filter { !isEmoji($0) }))
        s = replace(#"\s+"#, in: s, with: " ")
        return s.trimmingCharacters(in: .whitespaces)
    }

    private static func isEmoji(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x200D, 0xFE0F, 0x20E3, 0x1F000...0x1FAFF, 0x2600...0x27BF, 0x2B50, 0x2B55: true
        default: scalar.properties.isEmojiPresentation
        }
    }

    /// A bare URL is "a link to host"; punctuation after it stays outside.
    private static func replaceURLs(in text: String) -> String {
        replaceMatches(#"https?://[^\s<>"]+"#, in: text) { url in
            var link = url
            var tail = ""
            while let last = link.last, ".,;:!?)]}'".contains(last) {
                tail = String(last) + tail
                link.removeLast()
            }
            var host = URL(string: link)?.host ?? ""
            if host.hasPrefix("www.") { host.removeFirst(4) }
            return (host.isEmpty ? "a link" : "a link to \(host)") + tail
        }
    }

    private static func replace(_ pattern: String, in text: String, with template: String) -> String {
        text.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
    }

    /// Replaces each match of `pattern` with what `transform` makes of it.
    private static func replaceMatches(_ pattern: String, in text: String, _ transform: (String) -> String) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return text }
        var result = ""
        var last = text.startIndex
        let whole = NSRange(text.startIndex..., in: text)
        for match in expression.matches(in: text, range: whole) {
            guard let range = Range(match.range, in: text) else { continue }
            result += text[last..<range.lowerBound] + transform(String(text[range]))
            last = range.upperBound
        }
        return result + text[last...]
    }
}
