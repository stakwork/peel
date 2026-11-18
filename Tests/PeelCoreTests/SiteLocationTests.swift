import Foundation
import Testing
@testable import PeelCore
@testable import PeelTestSupport

/// What the person decided about a site asking for their location.
struct SiteLocationTests {
    @Test func putReplacesAndRemoveForgets() throws {
        let profile = TempProfile()
        let storage = try profile.storage()
        #expect(try storage.siteLocationGrant(origin: "https://a.example") == nil)
        try storage.putSiteLocationGrant(.init(origin: "https://a.example", allowed: true, precise: true, decidedAt: 1))
        try storage.putSiteLocationGrant(.init(origin: "https://b.example", allowed: false, decidedAt: 2))
        try storage.putSiteLocationGrant(.init(origin: "https://a.example", allowed: true, precise: false, decidedAt: 3))
        let all = try storage.siteLocationGrants()
        #expect(all.map(\.origin) == ["https://a.example", "https://b.example"])
        #expect(all[0].precise == false && all[0].decidedAt == 3)
        try storage.removeSiteLocationGrant(origin: "https://a.example")
        #expect(try storage.siteLocationGrants().map(\.origin) == ["https://b.example"])
    }

    @Test func clearAllForgetsEverySite() throws {
        let storage = try TempProfile().storage()
        try storage.putSiteLocationGrant(.init(origin: "https://a.example", allowed: true, decidedAt: 1))
        try storage.putSiteLocationGrant(.init(origin: "https://b.example", allowed: false, decidedAt: 1))
        try storage.clearSiteLocationGrants()
        #expect(try storage.siteLocationGrants().isEmpty)
    }

    @Test func decisionsAreKeptOnlyInTheProfileDirectory() throws {
        let profile = TempProfile()
        do {
            let storage = try profile.storage()
            try storage.putSiteLocationGrant(.init(origin: "https://a.example", allowed: true, decidedAt: 1))
        }
        // Reopened: kept; the profile directory removed (as sign-out does): gone.
        #expect(try profile.storage().siteLocationGrants().count == 1)
        try FileManager.default.removeItem(at: profile.url)
        #expect(try profile.storage().siteLocationGrants().isEmpty)
    }
}
