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
            case .SQLITE_FULL: return "the disk is full"
            case .SQLITE_BUSY, .SQLITE_LOCKED: return "the local database is busy; try again"
            case .SQLITE_CORRUPT, .SQLITE_NOTADB: return "the local database is damaged"
            case .SQLITE_CANTOPEN, .SQLITE_PERM, .SQLITE_READONLY, .SQLITE_IOERR:
                return "the local database could not be opened or written"
            default: return "the local database failed (SQLite error \(error.resultCode.rawValue))"
            }
        case is RowDecodingError, is PersistenceError: return "the local database failed"
        case let error as URLError:
            switch error.code {
            case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff:
                return "not connected to the internet"
            case .cannotFindHost, .dnsLookupFailed: return "the server's address could not be found"
            case .cannotConnectToHost: return "the server could not be reached"
            case .networkConnectionLost: return "the connection was lost"
            case .timedOut: return "the server took too long to answer"
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
                 .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
                 .clientCertificateRejected, .clientCertificateRequired:
                return "a secure connection to the server could not be made"
            case .badServerResponse, .cannotParseResponse, .cannotDecodeRawData, .cannotDecodeContentData,
                 .zeroByteResource:
                return "the server's answer could not be read"
            case .badURL, .unsupportedURL, .appTransportSecurityRequiresSecureConnection:
                return "the address is not one Peel can open"
            case .cancelled: return "it was cancelled"
            default: return described(error)
            }
        case let error as CocoaError:
            switch error.code {
            case .fileNoSuchFile, .fileReadNoSuchFile: return "the file was not found"
            case .fileReadNoPermission, .fileWriteNoPermission: return "Peel is not allowed to use the file"
            case .fileWriteOutOfSpace: return "the disk is full"
            case .fileWriteVolumeReadOnly: return "the disk is read-only"
            case .fileWriteFileExists: return "a file with that name is already there"
            case .fileReadCorruptFile: return "the file could not be read"
            case .userCancelled: return "it was cancelled"
            default: return described(error)
            }
        case let error as POSIXError: return words(error.code)
        case let error as NWError:
            switch error {
            case .posix(let code): return words(code)
            case .dns: return "the server's address could not be found"
            case .tls: return "a secure connection to the server could not be made"
            default: return "the connection to the server failed"
            }
        case let error as MQTTError:
            switch error {
            case .timeout: return "the server took too long to answer"
            case .connectionError(.serverUnavailable): return "the server is not available"
            case .connectionError: return "the server refused the connection"
            case .noConnection, .serverClosedConnection, .serverDisconnection: return "the connection was lost"
            default: return "the connection to the server failed"
            }
        case let error as ChannelError:
            if case .connectTimeout = error { return "the server took too long to answer" }
            return "the connection to the server failed"
        case is DecodingError: return "the data could not be read"
        case is CancellationError: return "it was cancelled"
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
            ? "something went wrong (\(nsError.domain) error \(nsError.code))" : text
    }

    /// A POSIX error code in words.
    static func words(_ code: POSIXErrorCode) -> String {
        switch code {
        case .ENOENT: return "the file was not found"
        case .EACCES: return "Peel is not allowed to use the file"
        case .ENOSPC: return "the disk is full"
        case .ECONNREFUSED, .EHOSTUNREACH, .ENETUNREACH, .EHOSTDOWN, .ENETDOWN:
            return "the server could not be reached"
        case .ETIMEDOUT: return "the server took too long to answer"
        case .ECONNRESET, .ECONNABORTED, .EPIPE, .ENOTCONN: return "the connection was lost"
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
