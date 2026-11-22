import Foundation
import GRDB

/// A stranger's public app opened here, kept so Apps can open it again (the
/// worker's Tasks above all; docs/phases/13-worker-invite-iphone.md): one
/// per app on a seller, with the address it was last opened at. Not synced
/// and not backed up with the account's words: a restore starts with none,
/// and they come back as apps are opened.
public struct OpenedPublicApp: Decodable, Sendable, Equatable, Identifiable, FetchableRecord {
    public var seller: String
    /// The app's name (`?app=`); empty for the seller's own page.
    public var app: String
    public var url: String
    public var origin: String
    /// Unix seconds, when it was last opened.
    public var openedAt: Int64
    /// The title the origin's wallet connection holds, once the app's first
    /// sign-in named it (the app's own claim, cleaned when it was saved).
    public var connectionTitle: String?

    public var id: String { "\(seller) \(app)" }

    /// The link to open it again; nil for an address today's rules refuse.
    public var link: PublicAppLink? { URL(string: url).flatMap { PublicAppLink($0) } }

    /// What the row is called: the connection's title, else the host.
    public var title: String {
        if let connectionTitle, !connectionTitle.isEmpty { return connectionTitle }
        return link?.host ?? origin
    }

    /// Under the title: where it is and which app, "acme.example.com · strut/worker".
    public var caption: String {
        [link?.host ?? origin, app.isEmpty ? nil : app].compactMap { $0 }.joined(separator: " · ")
    }

    /// Whether Apps' search finds it, by its title, host or app name; any
    /// app for an empty search.
    public func matches(_ query: String) -> Bool {
        let words = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return words.isEmpty || [title, caption].contains { $0.lowercased().contains(words) }
    }
}

extension Storage {
    /// What an `origin:<origin>` wallet connection's key starts with
    /// (`WalletScope.origin`).
    static let originKeyPrefix = "origin:"

    /// Remembers a public app as opened at `at` (unix seconds): one row per
    /// app on a seller, replaced by the later opening.
    public func rememberPublicApp(_ link: PublicAppLink, at: Int64) throws {
        try pool.write { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO publicApp (seller, app, url, origin, openedAt) VALUES (?, ?, ?, ?, ?)",
                arguments: [link.seller.absoluteString, link.app ?? "", link.url.absoluteString, link.origin, at]
            )
        }
    }

    /// The public apps opened here, last opened first.
    public func openedPublicApps() throws -> [OpenedPublicApp] {
        try pool.read { db in try Self.openedPublicApps(db) }
    }

    /// The same, re-emitted whenever one is opened, forgotten or retitled:
    /// Apps and the Chats row that leads there.
    public func openedPublicAppUpdates() -> some AsyncSequence<[OpenedPublicApp], any Error> {
        ValueObservation
            .tracking { db in try Self.openedPublicApps(db) }
            .removeDuplicates()
            .values(in: pool)
    }

    private static func openedPublicApps(_ db: Database) throws -> [OpenedPublicApp] {
        try OpenedPublicApp.fetchAll(db, sql: """
            SELECT p.seller, p.app, p.url, p.origin, p.openedAt, w.title AS connectionTitle
            FROM publicApp p LEFT JOIN walletConnection w ON w.key = ? || p.origin
            ORDER BY p.openedAt DESC, p.url ASC
            """, arguments: [originKeyPrefix])
    }

    /// Takes one app off the list. Its connection, if any, stays (You ›
    /// Connected apps), so a link someone sent never sticks there for good.
    public func forgetPublicApp(seller: String, app: String) throws {
        try pool.write { db in
            try db.execute(sql: "DELETE FROM publicApp WHERE seller = ? AND app = ?", arguments: [seller, app])
        }
    }
}
