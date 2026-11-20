import Foundation
import GRDB
import MQTTNIO
import Network
import NIOCore
import Sphinxrs

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
        return sentence.isEmpty
            ? String(localized: "Could not \(action).", table: "Shared")
            : String(localized: "Could not \(action). \(sentence)", table: "Shared")
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
    /// read that way, and the core's keep their own words. The system's and
    /// the libraries' would print as an NSError dump (its userInfo, a failing
    /// URL), as SQL or as a decoder's coding path, so the common ones give a
    /// short sentence and the rest their localized description, never one
    /// that names an address. They are the middle of a sentence, lowercase
    /// and with no full stop: the app shows them through `problem`.
    public static func readable(_ error: any Error) -> String {
        switch error {
        case let error as DatabaseError:
            switch error.resultCode {
            case .SQLITE_FULL: return String(localized: "the disk is full", table: "Shared")
            case .SQLITE_BUSY, .SQLITE_LOCKED: return String(localized: "the local database is busy; try again", table: "Shared")
            case .SQLITE_CORRUPT, .SQLITE_NOTADB: return String(localized: "the local database is damaged", table: "Shared")
            case .SQLITE_CANTOPEN, .SQLITE_PERM, .SQLITE_READONLY, .SQLITE_IOERR:
                return String(localized: "the local database could not be opened or written", table: "Shared")
            default: return String(localized: "the local database failed (SQLite error \(Int(error.resultCode.rawValue)))", table: "Shared")
            }
        case is RowDecodingError, is PersistenceError: return String(localized: "the local database failed", table: "Shared")
        case let error as URLError:
            switch error.code {
            case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff:
                return String(localized: "not connected to the internet", table: "Shared")
            case .cannotFindHost, .dnsLookupFailed: return String(localized: "the server's address could not be found", table: "Shared")
            case .cannotConnectToHost: return String(localized: "the server could not be reached", table: "Shared")
            case .networkConnectionLost: return String(localized: "the connection was lost", table: "Shared")
            case .timedOut: return String(localized: "the server took too long to answer", table: "Shared")
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
                 .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
                 .clientCertificateRejected, .clientCertificateRequired:
                return String(localized: "a secure connection to the server could not be made", table: "Shared")
            case .badServerResponse, .cannotParseResponse, .cannotDecodeRawData, .cannotDecodeContentData,
                 .zeroByteResource:
                return String(localized: "the server's answer could not be read", table: "Shared")
            case .badURL, .unsupportedURL, .appTransportSecurityRequiresSecureConnection:
                return String(localized: "the address is not one Peel can open", table: "Shared")
            case .cancelled: return String(localized: "it was cancelled", table: "Shared")
            default: return described(error)
            }
        case let error as CocoaError:
            switch error.code {
            case .fileNoSuchFile, .fileReadNoSuchFile: return String(localized: "the file was not found", table: "Shared")
            case .fileReadNoPermission, .fileWriteNoPermission: return String(localized: "Peel is not allowed to use the file", table: "Shared")
            case .fileWriteOutOfSpace: return String(localized: "the disk is full", table: "Shared")
            case .fileWriteVolumeReadOnly: return String(localized: "the disk is read-only", table: "Shared")
            case .fileWriteFileExists: return String(localized: "a file with that name is already there", table: "Shared")
            case .fileReadCorruptFile: return String(localized: "the file could not be read", table: "Shared")
            case .userCancelled: return String(localized: "it was cancelled", table: "Shared")
            default: return described(error)
            }
        case let error as POSIXError: return words(error.code)
        case let error as NWError:
            switch error {
            case .posix(let code): return words(code)
            case .dns: return String(localized: "the server's address could not be found", table: "Shared")
            case .tls: return String(localized: "a secure connection to the server could not be made", table: "Shared")
            default: return String(localized: "the connection to the server failed", table: "Shared")
            }
        case let error as MQTTError:
            switch error {
            case .timeout: return String(localized: "the server took too long to answer", table: "Shared")
            case .connectionError(.serverUnavailable): return String(localized: "the server is not available", table: "Shared")
            case .connectionError: return String(localized: "the server refused the connection", table: "Shared")
            case .noConnection, .serverClosedConnection, .serverDisconnection: return String(localized: "the connection was lost", table: "Shared")
            default: return String(localized: "the connection to the server failed", table: "Shared")
            }
        case let error as ChannelError:
            if case .connectTimeout = error { return String(localized: "the server took too long to answer", table: "Shared") }
            return String(localized: "the connection to the server failed", table: "Shared")
        case is DecodingError: return String(localized: "the data could not be read", table: "Shared")
        case is CancellationError: return String(localized: "it was cancelled", table: "Shared")
        // The core's own words, as they have always been shown.
        case is SphinxError: return "\(error)"
        default:
            // Peel's own errors are Swift types that describe themselves; an
            // NSError's description is the dump.
            if !(type(of: error) is NSError.Type), let own = error as? CustomStringConvertible {
                return own.description
            }
            return described(error)
        }
    }

    /// A system error's localized description, unless it names the address
    /// that failed (a link someone sent, a server): then only its code.
    static func described(_ error: any Error) -> String {
        let nsError = error as NSError
        let text = nsError.localizedDescription
        let failing = [
            (nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL)?.absoluteString,
            nsError.userInfo[NSURLErrorFailingURLStringErrorKey] as? String,
        ].compactMap { $0 }.filter { !$0.isEmpty }
        let hosts = failing.compactMap { URL(string: $0)?.host() }.filter { !$0.isEmpty }
        let namesAddress = text.contains("://") || (failing + hosts).contains { text.contains($0) }
        return namesAddress || text.isEmpty
            ? String(localized: "something went wrong (\(nsError.domain) error \(nsError.code))", table: "Shared") : text
    }

    /// A POSIX error code in words.
    static func words(_ code: POSIXErrorCode) -> String {
        switch code {
        case .ENOENT: return String(localized: "the file was not found", table: "Shared")
        case .EACCES: return String(localized: "Peel is not allowed to use the file", table: "Shared")
        case .ENOSPC: return String(localized: "the disk is full", table: "Shared")
        case .ECONNREFUSED, .EHOSTUNREACH, .ENETUNREACH, .EHOSTDOWN, .ENETDOWN:
            return String(localized: "the server could not be reached", table: "Shared")
        case .ETIMEDOUT: return String(localized: "the server took too long to answer", table: "Shared")
        case .ECONNRESET, .ECONNABORTED, .EPIPE, .ENOTCONN: return String(localized: "the connection was lost", table: "Shared")
        default: return String(cString: strerror(code.rawValue))
        }
    }
}

/// Its own words wherever an error is read as `localizedDescription` (the
/// agent's tool loop among them), rather than Foundation's "The operation
/// couldn't be completed. (PeelCore.PeelError error 1.)".
extension PeelError: LocalizedError {
    public var errorDescription: String? { description }
}
