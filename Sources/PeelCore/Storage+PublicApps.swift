import Foundation
import GRDB

/// A stranger's public app opened here, kept so Apps can open it again (the
/// worker's Tasks above all; docs/phases/13-worker-invite-iphone.md): one
/// per app on a seller, with the address it was last opened at. Synced
/// through the account's encrypted preferences file (`peel.public_app`, URL
/// and display metadata only — no credentials or session tokens) so an
/// account restore brings the Apps tab back.
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
    /// The title the seller's own listing gave the app (`PublicAppLink.appListing`),
    /// refreshed at each opening. Android keeps its own copy of this rule.
    public var appTitle: String?
    /// The lucide icon the seller's listing named for the app, refreshed at
    /// each opening; nil until it has, and the row then draws the fallback.
    public var icon: String?

    public var id: String { "\(seller) \(app)" }

    /// The link to open it again; nil for an address today's rules refuse.
    public var link: PublicAppLink? { URL(string: url).flatMap { PublicAppLink($0) } }

    /// What the row is called: the connection's title (unless it is only the
    /// host, an invite's placeholder), else the seller's title, else the host.
    public var title: String {
        let host = link?.host ?? origin
        if let connectionTitle, !connectionTitle.isEmpty, connectionTitle != host { return connectionTitle }
        if let appTitle, !appTitle.isEmpty { return appTitle }
        return host
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
    /// app on a seller, replaced by the later opening, and recorded in the
    /// account's synced preferences (`peel.public_app`). Returns true when
    /// the synced item changed (a first opening, or a new address): opening
    /// the same app again changes only this device's order.
    @discardableResult
    public func rememberPublicApp(_ link: PublicAppLink, at: Int64) throws -> Bool {
        let seller = link.seller.absoluteString
        let app = link.app ?? ""
        let now = Date(timeIntervalSince1970: TimeInterval(at))
        return try pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO publicApp (seller, app, url, origin, openedAt) VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(seller, app) DO UPDATE SET
                        url = excluded.url, origin = excluded.origin, openedAt = excluded.openedAt
                    """,
                arguments: [seller, app, link.url.absoluteString, link.origin, at]
            )
            return try Self.syncPublicAppPreference(seller: seller, app: app, at: now, in: db)
        }
    }

    /// Keeps the title the seller gave an opened app; none changes nothing.
    /// Returns true when the synced preference changed.
    @discardableResult
    public func setPublicAppTitle(seller: String, app: String, title: String, syncedAt now: Date = .now) throws -> Bool {
        try pool.write { db in
            try db.execute(
                sql: "UPDATE publicApp SET title = ? WHERE seller = ? AND app = ?", arguments: [title, seller, app]
            )
            return try Self.syncPublicAppPreference(seller: seller, app: app, at: now, in: db)
        }
    }

    /// Keeps the icon the seller's listing named for an opened app; none
    /// changes nothing, so an answer without one never erases a stored icon.
    /// Returns true when the synced preference changed.
    @discardableResult
    public func setPublicAppIcon(seller: String, app: String, icon: String?, syncedAt now: Date = .now) throws -> Bool {
        guard let icon else { return false }
        return try pool.write { db in
            try db.execute(
                sql: "UPDATE publicApp SET icon = ? WHERE seller = ? AND app = ?", arguments: [icon, seller, app]
            )
            return try Self.syncPublicAppPreference(seller: seller, app: app, at: now, in: db)
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
            SELECT p.seller, p.app, p.url, p.origin, p.openedAt, w.title AS connectionTitle, p.title AS appTitle, p.icon
            FROM publicApp p LEFT JOIN walletConnection w ON w.key = ? || p.origin
            ORDER BY p.openedAt DESC, p.url ASC
            """, arguments: [originKeyPrefix])
    }

    /// Takes one app off the list and records a tombstone in synced
    /// preferences so the removal follows the account. Its connection, if any,
    /// stays (You › Connected apps), so a link someone sent never sticks there
    /// for good.
    public func forgetPublicApp(seller: String, app: String, syncedAt now: Date = .now) throws {
        try pool.write { db in
            try db.execute(sql: "DELETE FROM publicApp WHERE seller = ? AND app = ?", arguments: [seller, app])
            try Self.recordForgottenPublicApp(seller: seller, app: app, deletedLocal: db.changesCount > 0, at: now, in: db)
        }
    }

    /// Writes the current `publicApp` row for `(seller, app)` into the synced
    /// `preference` table. Returns true when the preference row changed.
    static func syncPublicAppPreference(seller: String, app: String, at now: Date, in db: Database) throws -> Bool {
        guard let row = try Row.fetchOne(
            db,
            sql: "SELECT url, title, icon FROM publicApp WHERE seller = ? AND app = ?",
            arguments: [seller, app]
        ) else { return false }
        let entry = SyncedPublicApp.Entry(url: row["url"], title: row["title"], icon: row["icon"])
        let identifier = SyncedPublicApp.identifier(seller: seller, app: app)
        return try Self.setPreference(.publicApp, .opened(entry), for: identifier, at: now, in: db)
    }

    /// Writes a forgotten tombstone into `preference` when an app was removed
    /// locally or already has a synced preference row.
    static func recordForgottenPublicApp(
        seller: String, app: String, deletedLocal: Bool, at now: Date, in db: Database
    ) throws {
        let identifier = SyncedPublicApp.identifier(seller: seller, app: app)
        if !deletedLocal {
            let existing = try PreferenceRow.fetchOne(db, key: ["key": Preferences.publicAppKey, "identifier": identifier])
            guard existing != nil else { return }
        }
        _ = try Self.setPreference(.publicApp, .forgotten, for: identifier, at: now, in: db)
    }

    /// Materializes a synced `peel.public_app` preference row into the local
    /// `publicApp` table (upsert on `.opened`, delete on `.forgotten`). An app
    /// new here is dated by its item (`date`, unix seconds); one already here
    /// keeps when it was last opened here.
    static func applySyncedPublicApp(identifier: String, value: String, date: Double, in db: Database) throws {
        guard let json = JSONValue(text: value),
              let synced = Preference<SyncedPublicApp>.publicApp.read(json) else { return }
        switch synced {
        case .opened(let entry):
            guard let parsed = URL(string: entry.url), let link = PublicAppLink(parsed) else { return }
            let seller = link.seller.absoluteString
            let app = link.app ?? ""
            guard SyncedPublicApp.identifier(seller: seller, app: app) == identifier else { return }
            try db.execute(
                sql: """
                    INSERT INTO publicApp (seller, app, url, origin, openedAt, title, icon)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(seller, app) DO UPDATE SET
                        url = excluded.url,
                        origin = excluded.origin,
                        title = COALESCE(excluded.title, publicApp.title),
                        icon = COALESCE(excluded.icon, publicApp.icon)
                    """,
                arguments: [seller, app, link.url.absoluteString, link.origin, Int64(max(date, 0)), entry.title, entry.icon]
            )
        case .forgotten:
            guard let (seller, app) = SyncedPublicApp.split(identifier: identifier) else { return }
            try db.execute(sql: "DELETE FROM publicApp WHERE seller = ? AND app = ?", arguments: [seller, app])
        }
    }
}
