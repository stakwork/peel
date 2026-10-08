import Foundation

/// What a message's text marks up: blocks (paragraphs, list items, fenced
/// code) and, inside a paragraph or item, inline spans (code, https links,
/// mentions). Parsing only; how each looks is the client's.
public enum MessageMarkup {
    public enum Block: Equatable, Sendable {
        case paragraph(String)
        /// A line starting with "- ", "• " or "* ", without its marker.
        case item(String)
        /// The lines between ``` fences, as typed.
        case code(String)
    }

    public struct Span: Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            case code
            case link(URL)
            case mention
        }

        public let kind: Kind
        /// Where it sits in the text, backticks included.
        public let range: Range<String.Index>
        /// What shows: the text between the backticks for code, else the span itself.
        public let text: String
    }

    private static let fence = "```"
    private static let itemMarkers = ["- ", "• ", "* "]

    /// The text as paragraphs, list items and code blocks. A fence nothing
    /// closes stays text, as an unmatched backtick does.
    public static func blocks(_ text: String) -> [Block] {
        // "\r\n" is one Character, so it would never split on "\n".
        let lines = (text.contains("\r\n") ? text.replacingOccurrences(of: "\r\n", with: "\n") : text)
            .split(separator: "\n", omittingEmptySubsequences: false)
        var blocks: [Block] = []
        var paragraph: [Substring] = []
        func flush() {
            // Blank lines beside a block are the gap the blocks already have.
            while paragraph.last?.allSatisfy(\.isWhitespace) == true { paragraph.removeLast() }
            while paragraph.first?.allSatisfy(\.isWhitespace) == true { paragraph.removeFirst() }
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))) }
            paragraph = []
        }
        var index = 0
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(fence), let (code, end) = fencedCode(lines, from: index) {
                flush()
                blocks.append(.code(code))
                index = end + 1
                continue
            }
            if let marker = itemMarkers.first(where: { trimmed.hasPrefix($0) }) {
                flush()
                blocks.append(.item(String(trimmed.dropFirst(marker.count))))
            } else {
                paragraph.append(line)
            }
            index += 1
        }
        flush()
        return blocks
    }

    /// The text on one line without its markup, for previews: inline code as
    /// its text, a code block's lines joined, every line break a space.
    public static func plainText(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        // Previews are drawn often, and most text has no markup to parse.
        if !text.contains("`"), !text.contains(where: \.isNewline), !itemMarkers.contains(where: trimmed.hasPrefix) {
            return trimmed
        }
        return blocks(text).map { block in
            switch block {
            case .paragraph(let text), .item(let text): withoutCodeMarks(text)
            case .code(let code): code
            }
        }
        .flatMap { $0.split(whereSeparator: \.isNewline) }
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
        .joined(separator: " ")
    }

    private static func withoutCodeMarks(_ text: String) -> String {
        guard text.contains("`") else { return text }
        var plain = ""
        var from = text.startIndex
        for span in spans(in: text) where span.kind == .code {
            plain += text[from..<span.range.lowerBound] + span.text
            from = span.range.upperBound
        }
        return plain + text[from...]
    }

    /// The code of a block opened on `lines[start]` and the index of the
    /// line that closes it: the same line for ```code```, else the next
    /// line ending in ```. Nil when nothing closes it or it holds nothing.
    private static func fencedCode(_ lines: [Substring], from start: Int) -> (String, Int)? {
        let opening = lines[start].trimmingCharacters(in: .whitespaces).dropFirst(fence.count)
        var code: [Substring] = []
        let end: Int
        if opening.count > fence.count, opening.hasSuffix(fence) {
            code = [opening.dropLast(fence.count)]
            end = start
        } else {
            guard let close = lines.indices.dropFirst(start + 1).first(where: {
                lines[$0].trimmingCharacters(in: .whitespaces).hasSuffix(fence)
            }) else { return nil }
            end = close
            // A language name after the fence is dropped, as the official
            // apps do; other text there is the first line of code.
            let first = opening.trimmingCharacters(in: .whitespaces)
            if !first.isEmpty, !isLanguageName(first) { code.append(Substring(first)) }
            code += lines[(start + 1)..<close]
            var closing = lines[close]
            while closing.last?.isWhitespace == true { closing.removeLast() }
            closing.removeLast(fence.count)
            if !closing.allSatisfy(\.isWhitespace) { code.append(closing) }
        }
        let joined = code.joined(separator: "\n").trimmingCharacters(in: .newlines)
        return joined.allSatisfy(\.isWhitespace) ? nil : (joined, end)
    }

    /// "swift", "ts", "c++", "objective-c".
    private static func isLanguageName(_ word: String) -> Bool {
        word.count <= 20 && word.allSatisfy { $0.isLetter || $0.isNumber || "+-#._".contains($0) }
    }

    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    /// The Mac app's mention pattern: `@` at the start of a word, up to the next space.
    private static let mention = try? NSRegularExpression(pattern: #"\B@[^\s]+"#)
    /// A run of backticks, text on one line with none in it, then the same
    /// run again: `code`, ``code``, ```code``` inside a line.
    private static let code = try? NSRegularExpression(pattern: #"(?<!`)(`+)([^`\n]+)\1(?!`)"#)

    /// Inline code, https links (anything else stays text) and mentions,
    /// in order and never overlapping. A backtick inside a link is part of
    /// the link; a link or mention inside code is code.
    public static func spans(in text: String) -> [Span] {
        let whole = NSRange(text.startIndex..., in: text)
        // The detector is the costly part; only https links are kept.
        let mayLink = text.range(of: "https", options: .caseInsensitive) != nil
        let links: [Span] = (mayLink ? detector?.matches(in: text, range: whole) ?? [] : []).compactMap { match in
            guard let url = match.url, url.scheme?.lowercased() == "https",
                  let range = Range(match.range, in: text) else { return nil }
            return Span(kind: .link(url), range: range, text: String(text[range]))
        }
        var codes: [Span] = []
        var from = text.startIndex
        while text[from...].contains("`"),
              let match = code?.firstMatch(in: text, options: .withTransparentBounds, range: NSRange(from..., in: text)),
              let range = Range(match.range, in: text), let inner = Range(match.range(at: 2), in: text) {
            // Opening inside a link: the backtick is the link's, and the
            // search goes on after it, so a later pair is still found.
            if let link = links.first(where: { $0.range.lowerBound < range.lowerBound && range.lowerBound < $0.range.upperBound }) {
                from = link.range.upperBound
                continue
            }
            codes.append(Span(kind: .code, range: range, text: String(text[inner])))
            from = range.upperBound
        }
        var spans = codes + links.filter { link in !codes.contains { $0.range.overlaps(link.range) } }
        if text.contains("@") {
            for match in mention?.matches(in: text, range: whole) ?? [] {
                guard let range = Range(match.range, in: text),
                      !spans.contains(where: { $0.range.overlaps(range) }) else { continue }
                spans.append(Span(kind: .mention, range: range, text: String(text[range])))
            }
        }
        return spans.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }
}
