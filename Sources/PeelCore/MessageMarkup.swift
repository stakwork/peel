import Foundation

/// What a message's text marks up: blocks (paragraphs, list items, headings,
/// quotes, fenced code) and, inside the text of a block, inline spans (code,
/// https links, `[text](https://…)` links, mentions) and emphasis (bold,
/// italic, strikethrough). Parsing only; how each looks is the client's.
public enum MessageMarkup {
    public enum Block: Equatable, Sendable {
        case paragraph(String)
        /// A line starting with "- ", "• " or "* ", without its marker.
        case item(String)
        /// A line starting with "1. " or "1) ": its number and the rest.
        case numbered(Int, String)
        /// A line starting with one to six "#" and a space: how many, and the rest.
        case heading(Int, String)
        /// Lines in a row starting with ">", without it.
        case quote(String)
        /// The lines between ``` fences, as typed.
        case code(String)
    }

    public struct Span: Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            case code
            case link(URL)
            /// `[text](https://…)`: the text shows, the link opens.
            case namedLink(URL)
            case mention
        }

        public let kind: Kind
        /// Where it sits in the text, backticks and brackets included.
        public let range: Range<String.Index>
        /// What shows: the text between the backticks for code, between the
        /// brackets for a named link, else the span itself.
        public let text: String
    }

    public struct Emphasis: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let bold = Emphasis(rawValue: 1)
        public static let italic = Emphasis(rawValue: 2)
        public static let strikethrough = Emphasis(rawValue: 4)
    }

    /// A piece of a block's text as it shows: plain text or a span, with the
    /// emphasis around it and the marks that made it taken out.
    public struct Inline: Equatable, Sendable {
        public let text: String
        /// Nil for plain text.
        public let kind: Span.Kind?
        public let emphasis: Emphasis
    }

    private static let fence = "```"
    private static let itemMarkers = ["- ", "• ", "* "]

    /// The text as paragraphs, list items, headings, quotes and code blocks.
    /// A fence nothing closes stays text, as an unmatched backtick does.
    public static func blocks(_ text: String) -> [Block] {
        // "\r\n" is one Character, so it would never split on "\n".
        let lines = (text.contains("\r\n") ? text.replacingOccurrences(of: "\r\n", with: "\n") : text)
            .split(separator: "\n", omittingEmptySubsequences: false)
        let closers = closers(lines, in: text)
        var blocks: [Block] = []
        var paragraph: [Substring] = []
        var quote: [Substring] = []
        func joined(_ lines: inout [Substring]) -> String? {
            // Blank lines beside a block are the gap the blocks already have.
            defer { lines = [] }
            // Found from both ends, not removed one at a time: removeFirst on
            // thousands of blank lines is quadratic.
            let blank = { (line: Substring) in line.allSatisfy(\.isWhitespace) }
            guard let start = lines.firstIndex(where: { !blank($0) }),
                  let end = lines.lastIndex(where: { !blank($0) }) else { return nil }
            return lines[start...end].joined(separator: "\n")
        }
        func flush() {
            if let text = joined(&quote) { blocks.append(.quote(text)) }
            if let text = joined(&paragraph) { blocks.append(.paragraph(text)) }
        }
        var index = 0
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(fence), let (code, end) = fencedCode(lines, from: index, closer: closers[index + 1]) {
                flush()
                blocks.append(.code(code))
                index = end + 1
                continue
            }
            index += 1
            if trimmed.hasPrefix(">") {
                if quote.isEmpty { flush() }
                let rest = trimmed.dropFirst()
                quote.append(rest.first == " " ? rest.dropFirst() : rest)
                continue
            }
            if !quote.isEmpty { flush() }
            if let marker = itemMarkers.first(where: { trimmed.hasPrefix($0) }) {
                flush()
                blocks.append(.item(String(trimmed.dropFirst(marker.count))))
            } else if let (level, rest) = marked(trimmed, by: heading) {
                flush()
                blocks.append(.heading(level, rest))
            } else if let (number, rest) = marked(trimmed, by: numbered) {
                flush()
                blocks.append(.numbered(number, rest))
            } else {
                paragraph.append(line)
            }
        }
        flush()
        return blocks
    }

    /// For each line, the first from it on that could close a fence, found
    /// once, so a message of many unclosed fences is not searched again
    /// from every one of them.
    private static func closers(_ lines: [Substring], in text: String) -> [Int?] {
        var closers = [Int?](repeating: nil, count: lines.count + 1)
        if text.contains(fence) {
            for index in lines.indices.reversed() {
                closers[index] = lines[index].trimmingCharacters(in: .whitespaces).hasSuffix(fence) ? index : closers[index + 1]
            }
        }
        return closers
    }

    /// Where `text` is code as `blocks` and `spans` read it: each fenced
    /// block, its fences included, and each inline code span. For text
    /// with no "\r\n" (`blocks` reads those as "\n").
    static func codeRanges(_ text: String) -> [Range<String.Index>] {
        guard text.contains("`") else { return [] }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let closers = closers(lines, in: text)
        var ranges: [Range<String.Index>] = []
        var index = 0
        while index < lines.count {
            if lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(fence),
               let (_, end) = fencedCode(lines, from: index, closer: closers[index + 1]) {
                ranges.append(lines[index].startIndex..<lines[end].endIndex)
                index = end + 1
            } else {
                index += 1
            }
        }
        return ranges + spans(in: text).filter { $0.kind == .code }.map(\.range)
    }

    /// "## Notes": one to six "#", a space, then text.
    private static let heading = try? NSRegularExpression(pattern: #"^(#{1,6}) +(\S.*)$"#)
    /// "12. Ship it" or "12) Ship it".
    private static let numbered = try? NSRegularExpression(pattern: #"^([0-9]{1,9})[.)] +(\S.*)$"#)

    /// The number a line's marker holds (a heading's "#" counted) and the
    /// text after it, when `pattern` matches the whole line.
    private static func marked(_ line: String, by pattern: NSRegularExpression?) -> (Int, String)? {
        guard let first = line.first, first == "#" || first.isASCIIDigit,
              let match = pattern?.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let marker = Range(match.range(at: 1), in: line), let rest = Range(match.range(at: 2), in: line)
        else { return nil }
        let number = first == "#" ? line[marker].count : Int(line[marker]) ?? 0
        return (number, String(line[rest]))
    }

    /// The text on one line without its markup, for previews: inline code as
    /// its text, a named link as its text, emphasis and block marks dropped
    /// (a numbered item keeps its number), a code block's lines joined, every
    /// line break a space.
    public static func plainText(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        // Previews are drawn often, and most text has no markup to parse.
        if !text.contains(where: { $0.isNewline || "`*_~[".contains($0) }), !itemMarkers.contains(where: trimmed.hasPrefix),
           trimmed.first.map({ "#>".contains($0) || $0.isASCIIDigit }) != true {
            return trimmed
        }
        return blocks(text).map { block in
            switch block {
            case .paragraph(let text), .item(let text), .heading(_, let text), .quote(let text): plain(text)
            case .numbered(let number, let text): "\(number). " + plain(text)
            case .code(let code): code
            }
        }
        .flatMap { $0.split(whereSeparator: \.isNewline) }
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
        .joined(separator: " ")
    }

    private static func plain(_ text: String) -> String {
        inlines(text).map(\.text).joined()
    }

    /// The code of a block opened on `lines[start]` and the index of the
    /// line that closes it: the same line for ```code```, else `closer`, the
    /// next line ending in ```. Nil when nothing closes it or it holds nothing.
    private static func fencedCode(_ lines: [Substring], from start: Int, closer: Int?) -> (String, Int)? {
        let opening = lines[start].trimmingCharacters(in: .whitespaces).dropFirst(fence.count)
        var code: [Substring] = []
        let end: Int
        if opening.count > fence.count, opening.hasSuffix(fence) {
            code = [opening.dropLast(fence.count)]
            end = start
        } else {
            guard let close = closer else { return nil }
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
    /// `[text](address)`: text on one line with no brackets, an address with
    /// no space or parentheses.
    static let namedLink = try? NSRegularExpression(pattern: #"\[([^\[\]\n]++)\]\(([^\s()]++)\)"#)
    /// What marks emphasis: **bold**, __bold__, *italic*, _italic_, ~~struck~~.
    private static let emphasisMarks: Set<Character> = ["*", "_", "~"]

    /// Inline code, https links (anything else stays text), `[text](https://…)`
    /// links and mentions, in order and never overlapping. A backtick inside
    /// a link is part of the link; a link or mention inside code is code.
    public static func spans(in text: String) -> [Span] {
        let whole = NSRange(text.startIndex..., in: text)
        // The detector is the costly part; only https links are kept.
        let mayLink = text.range(of: "https", options: .caseInsensitive) != nil
        var links = (mayLink ? detector?.matches(in: text, range: whole) ?? [] : []).compactMap { link($0, in: text) }
        // A named link opens only an address the detector read as an https
        // link, the whole of it, so it follows the same rules as one typed out.
        if !links.isEmpty, text.contains("](") {
            var next = links.startIndex
            let named: [Span] = (namedLink?.matches(in: text, range: whole) ?? []).compactMap { match in
                guard let range = Range(match.range, in: text), let label = Range(match.range(at: 1), in: text),
                      let address = Range(match.range(at: 2), in: text) else { return nil }
                while next < links.endIndex, links[next].range.lowerBound < address.lowerBound { next += 1 }
                guard next < links.endIndex, links[next].range == address, case .link(let url) = links[next].kind else { return nil }
                return Span(kind: .namedLink(url), range: range, text: String(text[label]))
            }
            links = (named + links.filter(outside(named))).sorted(by: inOrder)
        }
        // Links, codes and mentions each come in order and never overlap
        // their own kind, so every check below walks forward once: a long
        // message of many spans costs no more than its length.
        var codes: [Span] = []
        var from = text.startIndex
        var nextLink = links.startIndex
        while text[from...].contains("`"),
              let match = code?.firstMatch(in: text, options: .withTransparentBounds, range: NSRange(from..., in: text)),
              let range = Range(match.range, in: text), let inner = Range(match.range(at: 2), in: text) {
            // Opening inside a link: the backtick is the link's, and the
            // search goes on after it, so a later pair is still found.
            while nextLink < links.endIndex, links[nextLink].range.upperBound <= range.lowerBound { nextLink += 1 }
            if nextLink < links.endIndex, links[nextLink].range.lowerBound < range.lowerBound {
                from = links[nextLink].range.upperBound
                continue
            }
            codes.append(Span(kind: .code, range: range, text: String(text[inner])))
            from = range.upperBound
        }
        var spans = (codes + links.filter(outside(codes))).sorted(by: inOrder)
        if text.contains("@") {
            let mentions = (mention?.matches(in: text, range: whole) ?? []).compactMap { match -> Span? in
                guard let range = Range(match.range, in: text).map({ withoutClosingMarks(text, $0) }),
                      text[range].count > 1 else { return nil }
                return Span(kind: .mention, range: range, text: String(text[range]))
            }
            spans = (spans + mentions.filter(outside(spans))).sorted(by: inOrder)
        }
        return spans
    }

    /// `range` without the emphasis marks at its end, which close what is
    /// around a link or mention rather than belong to it: the detector reads
    /// "**https://a.co**" as "https://a.co**".
    private static func withoutClosingMarks(_ text: String, _ range: Range<String.Index>) -> Range<String.Index> {
        var end = range.upperBound
        while end > range.lowerBound, emphasisMarks.contains(text[text.index(before: end)]) { end = text.index(before: end) }
        return range.lowerBound..<end
    }

    /// An https link the detector found, without closing marks (read again
    /// without them). No `user@host`: the name before the @ is not where it goes.
    private static func link(_ match: NSTextCheckingResult, in text: String) -> Span? {
        guard var range = Range(match.range, in: text), var url = match.url else { return nil }
        let trimmed = withoutClosingMarks(text, range)
        if trimmed != range {
            range = trimmed
            let address = String(text[range])
            let all = NSRange(address.startIndex..., in: address)
            guard let again = detector?.firstMatch(in: address, range: all), again.range == all, let read = again.url
            else { return nil }
            url = read
        }
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil, url.host?.isEmpty == false
        else { return nil }
        return Span(kind: .link(url), range: range, text: String(text[range]))
    }

    private static func inOrder(_ a: Span, _ b: Span) -> Bool { a.range.lowerBound < b.range.lowerBound }

    /// A run of one emphasis mark between spans, and whether it can open or
    /// close (CommonMark's flanking rules: "a * b" and "snake_case" do neither).
    private struct Marks {
        let mark: Character
        /// The marks not yet matched, which still show.
        var shown: Range<String.Index>
        let opens: Bool
        let closes: Bool
    }

    private enum Piece {
        case text(Range<String.Index>)
        case span(Span)
        case marks(Marks)
    }

    /// The text as it shows: `spans` with plain text between, and emphasis
    /// marks that pair up taken out, what they hold emphasised. Marks are
    /// never read inside a span, so code shows as typed; a mark nothing
    /// closes shows as typed. Each kind of mark pairs on its own, so every
    /// mark is looked at once however the text nests.
    public static func inlines(_ text: String) -> [Inline] {
        var pieces: [Piece] = []
        var from = text.startIndex
        /// The text from `from` up to `end`, as plain text and runs of marks.
        func read(upTo end: String.Index) {
            var plainFrom = from
            while from < end {
                let mark = text[from]
                var runEnd = text.index(after: from)
                guard emphasisMarks.contains(mark) else {
                    from = runEnd
                    continue
                }
                while runEnd < end, text[runEnd] == mark { runEnd = text.index(after: runEnd) }
                if let marks = marks(mark, from..<runEnd, in: text) {
                    if plainFrom < from { pieces.append(.text(plainFrom..<from)) }
                    pieces.append(.marks(marks))
                    plainFrom = runEnd
                }
                from = runEnd
            }
            if plainFrom < end { pieces.append(.text(plainFrom..<end)) }
        }
        for span in spans(in: text) {
            read(upTo: span.range.lowerBound)
            pieces.append(.span(span))
            from = span.range.upperBound
        }
        read(upTo: text.endIndex)

        // Each pair adds its emphasis to the pieces between, counted at the
        // first piece and taken away after the last.
        let kinds: [Emphasis] = [.bold, .italic, .strikethrough]
        var change = kinds.map { _ in [Int](repeating: 0, count: pieces.count + 1) }
        var open: [Character: [Int]] = [:]
        for closer in pieces.indices {
            guard case .marks(var marks) = pieces[closer] else { continue }
            while marks.closes, !marks.shown.isEmpty, let opener = open[marks.mark]?.last,
                  case .marks(var opening) = pieces[opener] {
                let used = min(text[opening.shown].count, text[marks.shown].count) >= 2 ? 2 : 1
                opening.shown = opening.shown.lowerBound..<text.index(opening.shown.upperBound, offsetBy: -used)
                marks.shown = text.index(marks.shown.lowerBound, offsetBy: used)..<marks.shown.upperBound
                pieces[opener] = .marks(opening)
                if opening.shown.isEmpty { open[marks.mark]?.removeLast() }
                let kind = kinds.firstIndex(of: marks.mark == "~" ? .strikethrough : used == 2 ? .bold : .italic)!
                change[kind][opener + 1] += 1
                change[kind][closer] -= 1
            }
            if marks.opens, !marks.shown.isEmpty { open[marks.mark, default: []].append(closer) }
            pieces[closer] = .marks(marks)
        }

        var inlines: [Inline] = []
        // Plain text runs on until its emphasis changes or a span comes.
        var plain = ""
        var plainEmphasis: Emphasis = []
        func endPlain() {
            if !plain.isEmpty { inlines.append(Inline(text: plain, kind: nil, emphasis: plainEmphasis)) }
            plain = ""
        }
        var depth = kinds.map { _ in 0 }
        for (index, piece) in pieces.enumerated() {
            var emphasis: Emphasis = []
            for kind in kinds.indices {
                depth[kind] += change[kind][index]
                if depth[kind] > 0 { emphasis.insert(kinds[kind]) }
            }
            let shown: Substring
            switch piece {
            case .span(let span):
                endPlain()
                inlines.append(Inline(text: span.text, kind: span.kind, emphasis: emphasis))
                continue
            case .text(let range): shown = text[range]
            case .marks(let marks): shown = text[marks.shown]
            }
            guard !shown.isEmpty else { continue }
            if emphasis != plainEmphasis {
                endPlain()
                plainEmphasis = emphasis
            }
            plain += shown
        }
        endPlain()
        return inlines
    }

    /// A run of marks that can emphasise: one to three "*" or "_", or "~~".
    private static func marks(_ mark: Character, _ run: Range<String.Index>, in text: String) -> Marks? {
        let count = text[run].count
        guard mark == "~" ? count == 2 : count <= 3 else { return nil }
        let before = run.lowerBound > text.startIndex ? text[text.index(before: run.lowerBound)] : nil
        let after = run.upperBound < text.endIndex ? text[run.upperBound] : nil
        func blank(_ character: Character?) -> Bool { character?.isWhitespace ?? true }
        func punctuation(_ character: Character?) -> Bool { character.map { $0.isPunctuation || $0.isSymbol } ?? false }
        let left = !blank(after) && (!punctuation(after) || blank(before) || punctuation(before))
        let right = !blank(before) && (!punctuation(before) || blank(after) || punctuation(after))
        // "_" inside a word is the word's.
        let opens = mark == "_" ? left && (!right || punctuation(before)) : left
        let closes = mark == "_" ? right && (!left || punctuation(after)) : right
        return opens || closes ? Marks(mark: mark, shown: run, opens: opens, closes: closes) : nil
    }

    /// A link's host as the address names it, with its port: an
    /// international name in its `xn--` form, as the web pane's toolbar shows
    /// it, so a look-alike in another script cannot pass for the real one.
    public static func host(of url: URL) -> String? {
        url.host.map { name in
            let bracketed = name.contains(":") ? "[\(name)]" : name
            return url.port.map { "\(bracketed):\($0)" } ?? bracketed
        }
    }

    /// How a link reads in a message, "github.com/stakwork/sphinx-broker/…/0.9.3-reconnect-backoff.md":
    /// no scheme; the host always whole (`host(of:)`); only what follows the
    /// host shortened in the middle when the whole is longer than `limit`, so
    /// a long link cannot hide where it goes.
    public static func linkLabel(_ text: String, url: URL, limit: Int = 56) -> String {
        var rest = Substring(text)
        if let scheme = rest.range(of: "://") { rest = rest[scheme.upperBound...] }
        let hostEnd = rest.firstIndex { "/?#".contains($0) } ?? rest.endIndex
        let host = host(of: url) ?? String(rest[..<hostEnd])
        rest = rest[hostEnd...]
        let budget = max(limit - host.count, 16)
        guard rest.count > budget else { return host + rest }
        return host + rest.prefix(budget * 3 / 5) + "…" + rest.suffix(budget * 2 / 5 - 1)
    }

    /// Whether a span misses every one of `taken` (in order, none
    /// overlapping), for spans asked about in order.
    private static func outside(_ taken: [Span]) -> (Span) -> Bool {
        var next = taken.startIndex
        return { span in
            while next < taken.endIndex, taken[next].range.upperBound <= span.range.lowerBound { next += 1 }
            return next == taken.endIndex || !taken[next].range.overlaps(span.range)
        }
    }
}
