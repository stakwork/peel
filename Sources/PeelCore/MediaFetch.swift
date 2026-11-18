import Foundation

/// What an automatic attachment fetch may do, decided from what is known
/// before any request: the kind it declares, its declared size and the
/// Auto download media setting. Pure, so every case is tested.
public enum AutoDownloadPolicy: Equatable, Sendable {
    /// Fetch it now, at most `upTo` bytes (the engine holds a larger one).
    case fetchNow(upTo: Int)
    /// Only what the cache already has; anything else waits for a tap.
    case cachedOnly
    /// Too large to fetch unasked: it waits for a tap, with its size shown.
    case hold

    /// The most an automatic fetch of `kind` takes: images up to
    /// `Engine.autoDownloadImageLimit`, videos and recordings up to
    /// `Engine.autoDownloadLimit`. Files and the rest are never automatic.
    public static func limit(for kind: AttachmentKind?) -> Int? {
        switch kind {
        case .image: Engine.autoDownloadImageLimit
        case .video, .audio: Engine.autoDownloadLimit
        case .pdf, .text, .file, nil: nil
        }
    }

    public static func decide(kind: AttachmentKind?, size: Int64?, setting: Bool) -> AutoDownloadPolicy {
        guard setting, let limit = limit(for: kind) else { return .cachedOnly }
        if let size, size > Int64(limit) { return .hold }
        return .fetchNow(upTo: limit)
    }
}

/// How a failed download is told apart and retried.
public enum MediaFetch {
    /// Whether trying again later may work: the network, a timeout, a
    /// cancelled transfer (the app was backgrounded), a server hiccup (5xx),
    /// a file not there yet (404, 408, 429) or a sign-in that failed. False
    /// for what no retry mends: an untrusted host, a paid or malformed
    /// attachment, bytes that do not decrypt, a refusal (other 4xx).
    public static func isTransient(_ error: Error) -> Bool {
        switch error {
        case let failure as MemesServer.Failure:
            switch failure {
            case .refused(let what, let status):
                return isTransient(status: status) || (isSignIn(what) && (status == 401 || status == 403))
            case .unreadableReply: return true
            case .unreadableHost, .tooLarge, .shortChallenge: return false
            }
        case let failure as Web.Failure:
            switch failure {
            case .refused(_, let status): return isTransient(status: status)
            case .unreadableReply: return true
            }
        case let error as URLError:
            switch error.code {
            case .badURL, .unsupportedURL, .appTransportSecurityRequiresSecureConnection: return false
            default: return true
            }
        case is CancellationError:
            return true
        default:
            return false
        }
    }

    static func isTransient(status: Int) -> Bool {
        status >= 500 || status == 404 || status == 408 || status == 429
    }

    private static func isSignIn(_ what: String) -> Bool {
        what == "sign-in" || what == "the signed challenge"
    }

    /// Seconds to wait before automatic retry number `attempt` (1-based), or
    /// nil once the budget is spent: three tries, then a tap, the app
    /// coming back to the foreground or the connection returning.
    public static func retryDelay(attempt: Int) -> TimeInterval? {
        let delays: [TimeInterval] = [2, 10, 30]
        return delays.indices.contains(attempt - 1) ? delays[attempt - 1] : nil
    }
}
