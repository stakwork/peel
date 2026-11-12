import Foundation

/// A stranger's public app as Peel opens it (strut's plans/app-payments.md
/// §5.3, R7; docs/app-wallet.md, "Signing in"): a box Peel is not paired
/// with, serving one app at its domain, or a strut's public view of one.
/// On the Mac, Peel's own strut UI hosts it (strut's remote mode,
/// `StrutUI.page(…, from:)`); on the iPhone, Peel loads `url` itself and
/// trusts only its `origin`. Reached by a `peel://open?url=<address>` link.
public struct PublicAppLink: Sendable, Equatable {
    /// The address as given: what the iPhone loads.
    public let url: URL
    /// The server's base URL (`Seller.base`): the origin, and the path of a
    /// strut mounted under one.
    public let seller: URL
    /// The app the address names (`?app=`, a public view's link); nil for a
    /// served box's own address, whose app the box names (`appName`).
    public let app: String?

    /// `peel://open?url=<address>`, and nothing else: no path, user,
    /// fragment or other value. Any page can open one, so the address is
    /// held to `init(_:)`.
    public init?(peelLink link: URL) {
        guard link.scheme?.lowercased() == "peel", link.host?.lowercased() == "open",
              link.path.isEmpty || link.path == "/", link.user == nil, link.fragment == nil,
              let items = URLComponents(url: link, resolvingAgainstBaseURL: false)?.queryItems,
              items.count == 1, items[0].name == "url", let text = items[0].value, let url = URL(string: text) else { return nil }
        self.init(url)
    }

    /// An address of a public app: https, or http to this machine (a
    /// development box); no credentials or fragment, and an `app` given
    /// once at most, a name strut takes.
    public init?(_ url: URL) {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false), parts.fragment == nil,
              let host = parts.host, !host.isEmpty else { return nil }
        let names = (parts.queryItems ?? []).filter { $0.name == "app" }
        guard names.count <= 1 else { return nil }
        let app = names.first?.value
        if let app, !AgentArtifact.Handle.isAppName(app) { return nil }
        parts.query = nil
        guard let base = parts.string.flatMap(Seller.base) else { return nil }
        self.url = url
        self.seller = base
        self.app = app
    }

    /// `url`'s origin as a page reads it (`location.origin`): what the
    /// iPhone keys its connection by (`WalletScope.origin`).
    public var origin: String {
        let scheme = url.scheme?.lowercased() ?? "https", host = url.host()?.lowercased() ?? ""
        let port = url.port.flatMap { ($0 == 443 && scheme == "https") || ($0 == 80 && scheme == "http") ? nil : $0 }
        return "\(scheme)://\(host)" + (port.map { ":\($0)" } ?? "")
    }

    /// The host as the person reads it, and as a challenge names it.
    public var host: String { Seller.host(of: seller) ?? "" }

    /// The app it opens: the one the address names, else the one the box
    /// serves at its root (its `strut-serve` meta, strut's serve mode),
    /// else its public view's only app. Throws when none can be told.
    public func appName() async throws -> String {
        if let app { return app }
        if let root = URL(string: seller.absoluteString + "/"),
           let page = try? await Web.get(root, limit: 1_000_000, what: "the app's page"),
           let name = Self.served(in: String(decoding: page, as: UTF8.self)) {
            return name
        }
        let listed = try await Web.get(seller.appending(path: "public/apps"), limit: 1_000_000, what: "the server's apps")
        guard case .array(let apps)? = JSON.decode(JSONValue.self, from: String(decoding: listed, as: UTF8.self)),
              apps.count == 1, let name = apps[0].objectValue["name"]?.string, AgentArtifact.Handle.isAppName(name) else {
            throw PeelError("\(host) does not say which app to open.")
        }
        return name
    }

    /// The app a served box's page names in `<meta name="strut-serve"
    /// content="…">`; nil without one, or one strut would not take.
    static func served(in page: String) -> String? {
        let pattern = #"<meta\s+name="strut-serve"\s+content="([^"<>]{1,120})"\s*/?>"#
        guard let match = page.firstMatch(of: try! Regex(pattern)), let found = match.output[1].substring else { return nil }
        let name = String(found)
        return AgentArtifact.Handle.isAppName(name) ? name : nil
    }
}
