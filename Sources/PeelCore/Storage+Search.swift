import Foundation
import GRDB

/// A message search as typed: words and "quoted phrases" that must all
/// appear, in any order, and `from:name` for who sent it. Never handed to
/// SQLite as typed: `ftsMatch` builds the only query syntax there is.
public struct MessageQuery: Sendable, Equatable {
    /// The fewest characters a word or phrase takes, as the official app
    /// asks: the index matches runs of three (`trigram`), so a shorter
    /// one is left out of the search.
    public static let minimum = 3

    /// Words and phrases, each at least `minimum` characters.
    public private(set) var terms: [String] = []
    /// Part of the sender's name (`from:ann`, `from:"ann lee"`).
    public private(set) var from: String?
    /// A word or phrase was left out as too short.
    public private(set) var hasShortTerms = false

    public init(_ text: String) {
        // NUL ends a query string for FTS5; nothing typed needs one.
        var rest = Substring(String(String.UnicodeScalarView(text.unicodeScalars.filter { $0 != "\0" })))
        while let first = rest.first {
            if first.isWhitespace {
                rest = rest.dropFirst()
                continue
            }
            var isFrom = false
            if rest.prefix(5).lowercased() == "from:" {
                isFrom = true
                rest = rest.dropFirst(5)
            }
            let piece: Substring
            if rest.first == "\"" {
                // A phrase, to the next quote or the end.
                let body = rest.dropFirst()
                let end = body.firstIndex(of: "\"") ?? body.endIndex
                piece = body[..<end]
                rest = end < body.endIndex ? body[body.index(after: end)...] : ""
            } else {
                let end = rest.firstIndex(where: \.isWhitespace) ?? rest.endIndex
                piece = rest[..<end]
                rest = rest[end...]
            }
            let term = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            if isFrom {
                if !term.isEmpty { from = term }
            } else if term.unicodeScalars.count >= Self.minimum {
                terms.append(term)
            } else if !term.isEmpty {
                hasShortTerms = true
            }
        }
    }

    /// Nothing to search for.
    public var isEmpty: Bool { terms.isEmpty && from == nil }

    /// How `String.range(of:)` finds a term, as the index does.
    public static let compareOptions: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

    /// One line of `text` (a `Message.preview`) for a results list: from a
    /// word's start a little before the first term found, "…" where cut.
    public func snippet(of text: String, lead: Int = 40) -> String {
        let first = terms.compactMap { text.range(of: $0, options: Self.compareOptions)?.lowerBound }.min()
        guard let first, let start = text.index(first, offsetBy: -lead, limitedBy: text.startIndex),
              start > text.startIndex else { return text }
        // Not mid-word: from the next word, unless that passes the match.
        let word = text[start..<first].firstIndex(where: \.isWhitespace).map(text.index(after:)) ?? start
        return "…" + text[word...]
    }

    /// The FTS5 query: each term one string (in double quotes, a quote
    /// inside doubled, so nothing in it is syntax), all of them required.
    var ftsMatch: String? {
        terms.isEmpty ? nil : terms.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
            .joined(separator: " AND ")
    }
}

/// Message search over the `messageText` index (v19): text and attachment
/// captions as stored here, never anything from a server.
extension Storage {
    /// Messages matching `query`, newest first, at most `limit`: text and
    /// attachment captions with words, not deleted. Words match anywhere in
    /// the text as typed (Markdown marks included), ignoring case and, with
    /// SQLite 3.45 or later when the index was made, accents. In `chat`, or
    /// with nil in every chat.
    public func searchMessages(_ query: MessageQuery, in chat: String?, limit: Int) async throws -> [Message] {
        guard !query.isEmpty else { return [] }
        var conditions = [
            "m.type IN (\(MessageType.contentSQL))", "m.deleted = 0", "m.noWords = 0",
        ]
        var arguments: StatementArguments = []
        if let match = query.ftsMatch {
            conditions.append("m.id IN (SELECT rowid FROM messageText WHERE messageText MATCH ?)")
            arguments += [match]
        }
        if let chat {
            conditions.append("m.chat = ?")
            arguments += [chat]
        }
        if let from = query.from {
            // The sender's own name, as it came with the message.
            conditions.append(
                #"(CASE WHEN json_valid(m.sender) THEN json_extract(m.sender, '$.alias') END) LIKE ? ESCAPE '\'"#
            )
            arguments += ["%" + Self.likeEscaped(from) + "%"]
        }
        arguments += [limit]
        let sql = """
            SELECT m.* FROM message m WHERE \(conditions.joined(separator: " AND "))
            ORDER BY m.timestamp DESC, m.id DESC LIMIT ?
            """
        let bound = arguments
        return try await pool.read { db in try Message.fetchAll(db, sql: sql, arguments: bound) }
    }

    /// `text` with LIKE's wildcards and its escape character taken literally.
    static func likeEscaped(_ text: String) -> String {
        text.replacingOccurrences(of: #"\"#, with: #"\\"#)
            .replacingOccurrences(of: "%", with: #"\%"#)
            .replacingOccurrences(of: "_", with: #"\_"#)
    }

    /// The SQLite library's version as one number (3.45.0 is 3_045_000),
    /// for the index options newer versions bring (v19).
    static func sqliteVersion(_ db: Database) throws -> Int {
        let parts = (try String.fetchOne(db, sql: "SELECT sqlite_version()") ?? "").split(separator: ".")
        return zip(parts, [1_000_000, 1_000, 1]).reduce(0) { $0 + (Int($1.0) ?? 0) * $1.1 }
    }
}
