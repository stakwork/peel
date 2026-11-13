import Foundation

/// Which key signs a visitor in to a public app (strut's
/// plans/app-payments.md §4.4, plans/app-repos.md §5.2): the person's own
/// Sphinx account, or a key of that app's domain alone. Kept on the wallet
/// connection as the person chose it; a challenge says which one its app
/// takes (`visitorKey`).
public enum SignInKey: String, Codable, Sendable, CaseIterable {
    /// The account's own key: the same visitor on every app.
    case root
    /// A key of this domain alone (LUD-05's derivation): a visitor no other
    /// app can tie to this one.
    case domain
}

/// A strut visitor challenge (strut's specs/API.md §13.2):
/// `strut-visitor.<base64url JSON claims>.<base64url HMAC>`, claims
/// `{ host, visitorKey, nonce, exp }`. Read, never verified: the HMAC is
/// the seller's to check. It is the ONLY thing Peel signs for a page
/// (no general `sign_message`), and only for the host it names. A port of
/// strut's `visitorChallengeClaims` (kit/src/wallet/protocol.ts).
public struct VisitorChallenge: Sendable, Equatable {
    public static let prefix = "strut-visitor."
    /// The longest challenge read; strut's are about 200 characters.
    public static let maxLength = 2_048

    /// The whole challenge, as signed: its UTF-8 bytes.
    public let text: String
    /// The seller's host name, lower case, no port: what it was made for.
    public let host: String
    /// Which key the app takes.
    public let visitorKey: SignInKey
    public let nonce: String
    /// When it ends, unix MILLISECONDS.
    public let expiresAtMs: Int64

    /// Nil for anything that is not a strut visitor challenge.
    public init?(_ text: String) {
        guard text.utf16.count <= Self.maxLength, text.hasPrefix(Self.prefix) else { return nil }
        let parts = text.dropFirst(Self.prefix.count).split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy(Self.isBase64URL),
              let bytes = MediaToken.base64URLDecode(String(parts[0])),
              let claims = String(data: bytes, encoding: .utf8),
              case .object(let c)? = JSON.decode(JSONValue.self, from: claims),
              let host = c["host"]?.string, !host.isEmpty, let nonce = c["nonce"]?.string, !nonce.isEmpty,
              let exp = WalletProtocol.integer(c["exp"]), exp >= 1,
              let key = c["visitorKey"]?.string.flatMap(SignInKey.init) else { return nil }
        self.text = text
        self.host = host
        self.visitorKey = key
        self.nonce = nonce
        self.expiresAtMs = exp
    }

    /// One or more of base64url's letters and nothing else.
    private static func isBase64URL(_ part: Substring) -> Bool {
        !part.isEmpty && part.utf8.allSatisfy { b in
            (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) || (b >= 0x30 && b <= 0x39) || b == 0x2D || b == 0x5F
        }
    }
}

/// A strut server a page names as its seller: its base URL, `https`, or
/// `http` to this machine; no credentials, query or fragment (strut's
/// `isSellerUrl`). What a challenge names of it is its host alone.
public enum Seller {
    /// Whether `text` names a seller as strut's `isSellerUrl` reads one.
    public static func isSellerURL(_ text: String) -> Bool {
        guard let parts = URLComponents(string: text), let scheme = parts.scheme?.lowercased(), let host = parts.host,
              !host.isEmpty, parts.user == nil, parts.password == nil,
              (parts.percentEncodedQuery ?? "").isEmpty, (parts.percentEncodedFragment ?? "").isEmpty else { return false }
        if scheme == "https" { return true }
        return scheme == "http" && isLoopback(host)
    }

    /// The host name a challenge names for `url`: lower case, no port, no
    /// IPv6 brackets (strut's `sellerHost`). Nil for no URL.
    public static func host(of url: URL) -> String? {
        guard let host = URLComponents(url: url, resolvingAgainstBaseURL: false)?.host, !host.isEmpty else { return nil }
        return host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    }

    /// `localhost`, `*.localhost`, `127.x.x.x`, `::1`: this machine.
    static func isLoopback(_ host: String) -> Bool {
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host == "localhost" || host == "::1" { return true }
        if host.hasSuffix(".localhost") {
            let label = host.dropLast(".localhost".count)
            return !label.isEmpty && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        return octets.count == 4 && octets[0] == "127"
            && octets.allSatisfy { (1...3).contains($0.count) && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }
    }

    /// A server's base URL as strut names a seller (its `remoteBase`): the
    /// origin and path, no trailing `/` nor `/public`, no query or
    /// fragment. Nil for one strut's UI would not open as a seller.
    public static func base(_ text: String) -> URL? {
        guard var parts = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              parts.user == nil, parts.password == nil else { return nil }
        var path = parts.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        if path.hasSuffix("/public") || path == "/public" {
            path.removeLast("/public".count)
            while path.hasSuffix("/") { path.removeLast() }
        }
        parts.percentEncodedPath = path
        parts.percentEncodedQuery = nil
        parts.percentEncodedFragment = nil
        parts.scheme = parts.scheme?.lowercased()
        parts.host = parts.host?.lowercased()
        if (parts.scheme == "https" && parts.port == 443) || (parts.scheme == "http" && parts.port == 80) { parts.port = nil }
        guard let text = parts.string, isSellerURL(text) else { return nil }
        return parts.url
    }
}

/// A `sign_in` request (strut's specs/WALLET.md §1.2, "sign_in"): strut's
/// UI asks the native host to sign the visitor in to `seller`'s public app
/// by signing `challenge`, the seller's own. Never an app's call: the page
/// never sees the request, the challenge or a key.
public struct SignInRequest: Sendable, Equatable {
    /// The strut server the visitor signs in to, as the page names it.
    public var seller: String
    /// The public app whose page asked, as the page names it.
    public var app: App
    public var challenge: String

    public struct App: Sendable, Equatable {
        public var name: String
        public var version: String
        public var title: String
    }

    /// The fields as a message holds them; nil when one is not a string.
    public init?(_ message: [String: JSONValue]) {
        guard case .object(let app)? = message["app"], let name = app["name"]?.string,
              let version = app["version"]?.string, let title = app["title"]?.string,
              let seller = message["seller"]?.string, let challenge = message["challenge"]?.string else { return nil }
        self.seller = seller
        self.app = App(name: name, version: version, title: title)
        self.challenge = challenge
    }

    /// The longest app field read, as strut's `CREDIT_TEXT_MAX`.
    static let textMax = 1_000

    /// What is wrong with a `sign_in` message at `nowMs` (unix ms); none
    /// when the host may sign it, or ask. Above all: the challenge is a
    /// strut visitor challenge made for `host` (the seller's, unless the
    /// caller names the host it trusts instead, as the iPhone does: the
    /// origin it loaded), and it has not ended. A port of strut's
    /// `signInRequestProblems`; the vectors' `sign_in_requests` hold it.
    public static func problems(_ raw: JSONValue, nowMs: Int64, host trusted: String? = nil) -> [String] {
        guard case .object(let r) = raw else { return ["a sign-in request must be an object"] }
        var out: [String] = []
        if WalletProtocol.integer(r["v"]) != 1 || r["op"] != .string("sign_in") {
            out.append(#"a sign-in request is { v: 1, op: "sign_in", … }"#)
        }
        let seller = r["seller"]?.string
        if !(seller.map(Seller.isSellerURL) ?? false) {
            out.append("seller must be a strut server's base URL: https, or http on loopback, with no credentials, query or fragment")
        }
        if case .object(let app)? = r["app"] {
            for key in ["name", "version", "title"] {
                guard let value = app[key]?.string, !value.isEmpty else {
                    out.append("app.\(key) must be a string")
                    continue
                }
                if value.utf16.count > textMax { out.append("app.\(key) is longer than \(textMax) characters") }
            }
        } else {
            out.append("app is missing")
        }
        guard let challenge = r["challenge"]?.string.flatMap(VisitorChallenge.init) else {
            out.append("challenge must be a strut visitor challenge (strut-visitor.<claims>.<hmac>): nothing else is signed")
            return out
        }
        let host = trusted ?? seller.flatMap(URL.init(string:)).flatMap(Seller.host(of:))
        if let host, challenge.host != host {
            out.append("the challenge is for \(TextLine.clean(challenge.host, max: 80)), not \(host): never signed")
        }
        if challenge.expiresAtMs <= nowMs { out.append("the challenge has ended") }
        return out
    }
}

/// A visitor's signature over a challenge (strut's `SignInAnswer`): the key
/// that signed, compressed, and its Lightning signed message over the
/// challenge's UTF-8 bytes, `[31 + recovery id] ‖ r ‖ s`, both hex. What
/// sphinx-rs's `sign_bytes` answers, checked by strut's `ln-message`.
public struct VisitorSignature: Sendable, Equatable {
    public var key: String
    public var sig: String

    public init(key: String, sig: String) {
        self.key = key
        self.sig = sig
    }

    /// `{ key, sig }`, as the answer's `result`.
    public var result: JSONValue { .object(["key": .string(key), "sig": .string(sig)]) }
}
