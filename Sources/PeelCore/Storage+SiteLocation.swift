import Foundation
import GRDB

/// What the person decided when a web page Peel opened asked for their
/// location, by the origin Peel loaded (`PublicPage.origin`). Only the
/// decision is kept: Peel never reads or stores a position. It lives in the
/// account's database, so it goes with the profile on sign-out.
public struct SiteLocationGrant: Codable, Sendable, Equatable, Identifiable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "siteLocationGrant"

    public var origin: String
    public var allowed: Bool
    /// Whether the site may ask for the precise position, not an approximate one.
    public var precise: Bool
    /// Unix seconds.
    public var decidedAt: Int64

    public var id: String { origin }

    public init(origin: String, allowed: Bool, precise: Bool = false, decidedAt: Int64) {
        self.origin = origin
        self.allowed = allowed
        self.precise = precise
        self.decidedAt = decidedAt
    }
}

extension Storage {
    public func siteLocationGrant(origin: String) throws -> SiteLocationGrant? {
        try pool.read { db in try SiteLocationGrant.fetchOne(db, key: origin) }
    }

    /// Every decision, by origin.
    public func siteLocationGrants() throws -> [SiteLocationGrant] {
        try pool.read { db in try SiteLocationGrant.order(Column("origin")).fetchAll(db) }
    }

    /// Every decision, re-emitted whenever one changes: You › Site location.
    public func siteLocationGrantUpdates() -> some AsyncSequence<[SiteLocationGrant], any Error> {
        ValueObservation
            .tracking { db in try SiteLocationGrant.order(Column("origin")).fetchAll(db) }
            .removeDuplicates()
            .values(in: pool)
    }

    /// Writes (or replaces) the decision for its origin.
    public func putSiteLocationGrant(_ grant: SiteLocationGrant) throws {
        try pool.write { db in try grant.save(db) }
    }

    /// Forgets one site: it is asked again next time.
    public func removeSiteLocationGrant(origin: String) throws {
        _ = try pool.write { db in try SiteLocationGrant.deleteOne(db, key: origin) }
    }

    /// Forgets every site.
    public func clearSiteLocationGrants() throws {
        _ = try pool.write { db in try SiteLocationGrant.deleteAll(db) }
    }
}
