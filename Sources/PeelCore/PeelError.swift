import Foundation
import GRDB

/// A failure with a message meant for the person using Peel.
public struct PeelError: Error, CustomStringConvertible, Sendable {
    public let description: String

    public init(_ description: String) {
        self.description = description
    }

    /// An error in words for the person using Peel. Peel's own errors already
    /// read that way; network and file errors from the system would print as
    /// an NSError dump, and database errors as SQL, so they give a short
    /// sentence instead.
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
