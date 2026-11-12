import Foundation
import PeelCore

/// A stranger's public app as the iPhone opens it (strut's
/// plans/app-payments.md §5.3, R7, "direct open"; docs/app-wallet.md,
/// "Signing in"): Peel loads the box's own address itself, with no
/// credential, and keeps to that origin. The box's own code is the main
/// frame and may claim anything, so the app wallet trusts only the origin
/// Peel loaded (`WalletScope.origin`), keying the connection and naming
/// every sheet by it. The org page's twin (`OrgPageRequest`), with no token.
public struct PublicPage: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public let link: PublicAppLink

    public init(_ link: PublicAppLink) {
        self.link = link
    }

    public static func == (a: Self, b: Self) -> Bool { a.id == b.id }

    /// The address Peel loads.
    public var url: URL { link.url }

    /// The origin Peel loaded, as a page reads it (`location.origin`).
    public var origin: String { link.origin }

    /// The host, as the person reads it and the sheets name it.
    public var host: String { link.host }

    /// Whether `other` is on the origin Peel loaded.
    public func serves(_ other: URL) -> Bool { OrgPageRequest.origin(of: other) == origin }

    /// The request that loads it: no credential of anyone's.
    public var request: URLRequest { URLRequest(url: url) }

    /// The request that loads it again where the page went, while that is
    /// still on its origin.
    public func request(at current: URL?) -> URLRequest? {
        guard let current, serves(current) else { return nil }
        return URLRequest(url: current)
    }

    /// Who the app wallet's messages are from, as Peel itself knows it.
    public var walletScope: WalletScope { .origin(origin) }
}
