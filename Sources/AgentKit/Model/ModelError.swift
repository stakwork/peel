import Foundation

/// Why a model call failed, in cases the UI can word plainly. Provider
/// messages are kept short and have anything that looks like a key removed.
public enum ModelError: Error, Sendable, Hashable {
    /// 401 or 403: the key was refused.
    case invalidKey(String?)
    /// 429, with how long the provider asked to wait when it said.
    case rateLimited(retryAfter: TimeInterval?)
    /// 5xx, Anthropic's 529 (overloaded) among them.
    case unavailable(status: Int, String?)
    /// The provider refused the request itself (400, 404, 413 and the other 4xx).
    case badRequest(status: Int, String)
    /// The request did not reach the provider, or its reply stopped arriving.
    case network(String)
    /// The reply could not be read.
    case malformed(String)
    /// The provider's address is not https (or http to this machine); nothing was sent.
    case invalidAddress
    case cancelled

    /// Whether trying the same request again later may work.
    public var isRetryable: Bool {
        switch self {
        case .rateLimited, .unavailable, .network: true
        case .invalidKey, .badRequest, .malformed, .invalidAddress, .cancelled: false
        }
    }

    /// The failure from an HTTP error: its status, `retry-after` header and
    /// body. `secret` (the API key) is removed from any message kept.
    init(status: Int, retryAfter: String?, body: Data, secret: String) {
        let error = (try? JSONDecoder().decode(JSONValue.self, from: body))?["error"]
        let message = (error?["message"]?.string ?? error?.string).map { Self.scrubbed($0, secret: secret) }
        switch status {
        case 401, 403: self = .invalidKey(message)
        case 408: self = .network("The provider took too long to answer.")
        case 429: self = .rateLimited(retryAfter: retryAfter.flatMap { TimeInterval($0.trimmingCharacters(in: .whitespaces)) })
        case 500...: self = .unavailable(status: status, message)
        default: self = .badRequest(status: status, message ?? HTTPURLResponse.localizedString(forStatusCode: status))
        }
    }

    /// An error the provider sent inside the stream: Anthropic's `error`
    /// event (`{"type": "overloaded_error", "message": ...}`) or an
    /// OpenAI-compatible chunk's `error` (`{"code": 429, "message": ...}`).
    init(streamError error: JSONValue, secret: String) {
        let message = Self.scrubbed(error["message"]?.string ?? "The provider reported an error.", secret: secret)
        // OpenAI names a rate limit by its code ("rate_limit_exceeded"), with
        // a type ("tokens", "requests") that says which limit.
        let status: Int =
            if error["code"]?.string == "rate_limit_exceeded" { 429 } else {
            switch error["type"]?.string {
            case "authentication_error": 401
            case "permission_error": 403
            case "rate_limit_error": 429
            case "overloaded_error": 529
            case "api_error": 500
            case "invalid_request_error": 400
            case "billing_error": 402
            case "not_found_error": 404
            case "request_too_large": 413
            case "timeout_error": 504
            default: error["code"]?.int ?? Int(error["code"]?.string ?? "") ?? 500
            }
            }
        switch status {
        case 401, 403: self = .invalidKey(message)
        case 429: self = .rateLimited(retryAfter: nil)
        case 400..<500: self = .badRequest(status: status, message)
        default: self = .unavailable(status: status, message)
        }
    }

    init(_ error: any Error) {
        switch error {
        case let error as ModelError: self = error
        case is CancellationError: self = .cancelled
        case let error as URLError where error.code == .cancelled: self = .cancelled
        case let error as URLError: self = .network(Self.words(for: error))
        default: self = .malformed(String(describing: type(of: error)))
        }
    }

    /// A provider's message, cut to a sentence or two, with the key and
    /// anything shaped like one replaced (OpenAI's 401 quotes part of the
    /// key it was given).
    static func scrubbed(_ message: String, secret: String) -> String {
        var text = message
        if !secret.isEmpty { text = text.replacingOccurrences(of: secret, with: "[key]") }
        text = text.replacingOccurrences(of: #"\b(sk|rk|pk)-[A-Za-z0-9_\-\*\.]{4,}"#, with: "[key]", options: .regularExpression)
        return text.count > 300 ? String(text.prefix(300)) + "…" : text
    }

    /// A provider's message as a sentence: "Overloaded" as "Overloaded.",
    /// "overloaded:" too (the rule `PeelError.sentence` keeps in PeelCore,
    /// which AgentKit does not import).
    static func sentence(_ words: String) -> String {
        var text = words.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = text.last, ",;:".contains(last) { text.removeLast() }
        guard let last = text.last, !".!?…".contains(last) else { return text }
        return text + "."
    }

    private static func words(for error: URLError) -> String {
        switch error.code {
        case .notConnectedToInternet, .dataNotAllowed: "Not connected to the internet."
        case .networkConnectionLost: "The connection to the provider was lost."
        case .timedOut: "The provider took too long to answer."
        case .cannotFindHost, .dnsLookupFailed, .cannotConnectToHost: "Could not reach the provider."
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
            .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot:
            "Could not make a secure connection to the provider."
        default: "The connection to the provider failed (\(error.code.rawValue))."
        }
    }
}

extension ModelError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidKey(let message):
            "The provider refused the API key." + (message.map { " (\($0))" } ?? "")
        case .rateLimited(let after):
            "Rate limited by the provider. "
                + (after.map { "Try again in \(Int($0.rounded(.up))) seconds." } ?? "Try again in a moment.")
        case .unavailable(let status, let message):
            (status == 529 ? "The provider is overloaded." : "The provider had a problem (\(status)).")
                + (message.map { " " + Self.sentence($0) } ?? "") + " Try again in a moment."
        case .badRequest(let status, let message):
            "The provider refused the request (\(status)): \(message)"
        case .network(let message):
            message
        case .malformed(let what):
            "The provider's reply could not be read (\(what))."
        case .invalidAddress:
            "The provider's address must be https (or http to this Mac)."
        case .cancelled:
            "Stopped."
        }
    }
}
