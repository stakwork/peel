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
        guard let c = StrutClaims.read(text, prefix: Self.prefix, maxLength: Self.maxLength),
              let host = c["host"]?.string, !host.isEmpty, let nonce = c["nonce"]?.string, !nonce.isEmpty,
              let exp = WalletProtocol.integer(c["exp"]), exp >= 1,
              let key = c["visitorKey"]?.string.flatMap(SignInKey.init) else { return nil }
        self.text = text
        self.host = host
        self.visitorKey = key
        self.nonce = nonce
        self.expiresAtMs = exp
    }
}

/// The claims of something strut signed, as a client reads them:
/// `<prefix><base64url JSON>.<base64url HMAC>`. Read, never verified: the
/// HMAC is strut's to check. A visitor challenge and a box's link challenge
/// (`BoxChallenge`) are read through here.
enum StrutClaims {
    /// The JSON object, or nil for anything else or past `maxLength` (UTF-16).
    static func read(_ text: String, prefix: String, maxLength: Int) -> [String: JSONValue]? {
        guard text.utf16.count <= maxLength, text.hasPrefix(prefix) else { return nil }
        let parts = text.dropFirst(prefix.count).split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy(isBase64URL),
              let bytes = MediaToken.base64URLDecode(String(parts[0])),
              let claims = String(data: bytes, encoding: .utf8),
              case .object(let c)? = JSON.decode(JSONValue.self, from: claims) else { return nil }
        return c
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

    /// The port a repo2graph (stakgraph) box serves on: its strut is mounted
    /// under `/lab` there, and the root paths answer a plain-text 401.
    public static let repo2graphPort = 3355

    /// `base` with the `/lab` mount path when it is a repo2graph box's bare
    /// origin (port 3355, no path). An address that already has a path, and every other port, is kept as it is: a strut served at the root elsewhere is not touched. (Peel cannot tell a box's kind from its address except by this port.)
    public static func mounted(_ base: URL) -> URL {
        guard var parts = URLComponents(url: base, resolvingAgainstBaseURL: false),
              parts.port == repo2graphPort, parts.percentEncodedPath.isEmpty || parts.percentEncodedPath == "/" else { return base }
        parts.percentEncodedPath = "/lab"
        return parts.url ?? base
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
/// sphinx-rs's `sign_bytes` answers, checked by strut's `ln-message`. With
/// the account's own key, the account's Sphinx address beside it, which the
/// seller keeps to pay the person (strut's plans/human-steps.md §8.2).
public struct VisitorSignature: Sendable, Equatable {
    public var key: String
    public var sig: String
    /// The account's own Sphinx address, `<pubkey>_<lsp_pubkey>_<scid>`,
    /// whose pubkey is `key`: only with the root key, never a domain's.
    public var address: String?

    public init(key: String, sig: String, address: String? = nil) {
        self.key = key
        self.sig = sig
        self.address = address
    }

    /// `{ key, sig, address? }`, as the answer's `result`.
    public var result: JSONValue {
        var r: [String: JSONValue] = ["key": .string(key), "sig": .string(sig)]
        if let address { r["address"] = .string(address) }
        return .object(r)
    }

    /// `contactInfo` as the `address` of a sign-in with `key`: a Sphinx
    /// address (`<pubkey>_<lsp_pubkey>_<scid>`, lower case) whose pubkey IS
    /// `key`, as strut's `readSignInReply` and the seller keep it. Nil for
    /// anything else, so a payout never goes to another key's address.
    public static func address(_ contactInfo: String?, for key: String) -> String? {
        guard let info = contactInfo.flatMap(ContactCode.contactInfo),
              info.split(separator: "_").first.map(String.init) == key.lowercased() else { return nil }
        return info
    }
}
