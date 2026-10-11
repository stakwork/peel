import Foundation
import GRDB

/// A failure with a message meant for the person using Peel.
public struct PeelError: Error, CustomStringConvertible, Sendable {
    public let description: String

    public init(_ description: String) {
        self.description = description
    }

    /// A problem line, the one way the app shows a failure: the error's words
    /// as a sentence, after "Could not <action>." when the words alone would
    /// not say what failed. "Could not leave the tribe. The server could not
    /// be reached." `readable` gives the words.
    public static func problem(_ error: any Error, couldNot action: String? = nil) -> String {
        problem(readable(error), couldNot: action)
    }

    /// The same for words already in hand: a reason a view was given, or a
    /// message the engine sent. A sentence stays as it is.
    public static func problem(_ words: String, couldNot action: String? = nil) -> String {
        let sentence = sentence(words)
        guard let action else { return sentence }
        return sentence.isEmpty ? "Could not \(action)." : "Could not \(action). \(sentence)"
    }

    /// Words as a sentence: a capital first letter, unless the first word is
    /// a name ("photo.jpg", "SQLite", "iCloud"), and a full stop unless one
    /// is there (in place of a trailing comma, colon or semicolon).
    static func sentence(_ words: String) -> String {
        var text = words.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = text.last, ",;:".contains(last) { text.removeLast() }
        guard !text.isEmpty else { return "" }
        let first = text.prefix { !$0.isWhitespace }.trimmingCharacters(in: .punctuationCharacters)
        if !first.isEmpty, first.allSatisfy({ $0.isLowercase || "'’-".contains($0) }) {
            text = text.prefix(1).uppercased() + text.dropFirst()
        }
        let ends = text.last.map { ".!?…".contains($0) } ?? false
            || [".)", "!)", "?)", ".\"", ".”"].contains { text.hasSuffix($0) }
        return ends ? text : text + "."
    }

    /// An error in words for the person using Peel. Peel's own errors already
    /// read that way; network and file errors from the system would print as
    /// an NSError dump, and database errors as SQL, so they give a short
    /// sentence instead. They are the middle of a sentence, lowercase and
    /// with no full stop: the app shows them through `problem`.
    public static func readable(_ error: any Error) -> String {
        switch error {
        case let error as DatabaseError:
            switch error.resultCode {
            case .SQLITE_FULL: return "the disk is full"
            case .SQLITE_BUSY, .SQLITE_LOCKED: return "the local database is busy; try again"
            case .SQLITE_CORRUPT, .SQLITE_NOTADB: return "the local database is damaged"
            case .SQLITE_CANTOPEN, .SQLITE_PERM, .SQLITE_READONLY, .SQLITE_IOERR:
                return "the local database could not be opened or written"
            default: return "the local database failed (SQLite error \(error.resultCode.rawValue))"
            }
        case let error as URLError:
            switch error.code {
            case .cannotConnectToHost, .cannotFindHost, .notConnectedToInternet, .networkConnectionLost,
                 .dnsLookupFailed:
                return "the server could not be reached"
            case .timedOut: return "the server took too long to answer"
            default: return error.localizedDescription
            }
        case let error as CocoaError: return error.localizedDescription
        default:
            let nsError = error as NSError
            return nsError.domain == NSURLErrorDomain || nsError.domain == NSCocoaErrorDomain
                ? nsError.localizedDescription : "\(error)"
        }
    }
}
