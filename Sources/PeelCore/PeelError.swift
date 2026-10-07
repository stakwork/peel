import Foundation

/// A failure with a message meant for the person using Peel.
public struct PeelError: Error, CustomStringConvertible, Sendable {
    public let description: String

    public init(_ description: String) {
        self.description = description
    }

    /// An error in words for the person using Peel. Peel's own errors already
    /// read that way; network and file errors from the system would print as
    /// an NSError dump, so they give their short sentence instead.
    public static func readable(_ error: any Error) -> String {
        switch error {
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
