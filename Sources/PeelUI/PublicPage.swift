import CryptoKit
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

    /// The website data store this origin's pages keep their cookies and
    /// storage in (strut keeps a visitor signed in for 30 days there): the
    /// same every time Peel opens this origin, and no other origin's, so a
    /// site reads only what it wrote itself. A name-based UUID (RFC 9562,
    /// version 5) over the origin.
    public var storeIdentifier: UUID { Self.storeIdentifier(origin: origin) }

    static func storeIdentifier(origin: String) -> UUID {
        // RFC 9562's URL namespace, 6ba7b811-9dad-11d1-80b4-00c04fd430c8.
        let namespace: [UInt8] = [0x6b, 0xa7, 0xb8, 0x11, 0x9d, 0xad, 0x11, 0xd1, 0x80, 0xb4, 0x00, 0xc0, 0x4f, 0xd4, 0x30, 0xc8]
        var bytes = Array(Insecure.SHA1.hash(data: namespace + Array(origin.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
