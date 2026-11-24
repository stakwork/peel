import Foundation
import Testing
@testable import PeelCore
@testable import PeelTestSupport

/// The public apps opened here stay in Apps (docs/phases/13-worker-invite-iphone.md):
/// one row per app on a seller, the later opening replacing the earlier,
/// titled by the origin's connection, and gone with it on Disconnect.
struct OpenedPublicAppsTests {
    let profile = TempProfile()
    let storage: Storage

    init() throws { storage = try profile.storage() }

    func link(_ address: String) throws -> PublicAppLink {
        let url = try #require(URL(string: address))
        return try #require(PublicAppLink(url))
    }

    func connection(_ origin: String, title: String) -> WalletConnection {
        WalletConnection(
            key: WalletScope.origin(origin).key, app: "/worker", title: title, place: "acme.example.com", methods: [],
            notificationTypes: [], maxAmountMsat: nil, renewal: .never, expiresAt: nil, overBudget: .ask, createdAt: 1
        )
    }

    @Test func oneRowPerAppOnASellerTheLastOpenedFirst() throws {
        let tasks = try link("https://acme.example.com/public/?app=strut/worker")
        let other = try link("https://acme.example.com/public/?app=books")
        try storage.rememberPublicApp(tasks, at: 100)
        try storage.rememberPublicApp(other, at: 200)
        #expect(try storage.openedPublicApps().map(\.app) == ["books", "strut/worker"])

        // Opened again, at another address: replaced, not added, and first.
        let again = try link("https://acme.example.com/public/?app=strut/worker&solo=1")
        try storage.rememberPublicApp(again, at: 300)
        let apps = try storage.openedPublicApps()
        #expect(apps.map(\.app) == ["strut/worker", "books"])
        #expect(apps.first?.url == again.url.absoluteString && apps.first?.openedAt == 300)
        #expect(apps.first?.link == again)
        #expect(apps.first?.origin == "https://acme.example.com")
    }

    /// An app with no `?app=` is the seller's own page: one row, named ''.
    @Test func aSellersOwnPageIsOneRow() throws {
        try storage.rememberPublicApp(try link("https://acme.example.com/"), at: 1)
        try storage.rememberPublicApp(try link("https://acme.example.com/public/"), at: 2)
        let apps = try storage.openedPublicApps()
        #expect(apps.count == 1 && apps[0].app == "")
    }

    @Test func aRowIsTitledByItsOriginsConnectionElseItsHost() throws {
        let tasks = try link("https://acme.example.com/public/?app=worker")
        try storage.rememberPublicApp(tasks, at: 1)
        #expect(try storage.openedPublicApps().first?.title == "acme.example.com")
        try storage.saveWalletConnection(connection("https://acme.example.com", title: "Acme Tasks"))
        #expect(try storage.openedPublicApps().first?.title == "Acme Tasks")
    }

    /// Disconnect forgets that origin's apps with its connection, and no other's.
    @Test func disconnectingAnOriginForgetsItsApps() throws {
        try storage.rememberPublicApp(try link("https://acme.example.com/public/?app=worker"), at: 1)
        try storage.rememberPublicApp(try link("https://acme.example.com/public/?app=books"), at: 2)
        try storage.rememberPublicApp(try link("https://other.example.com/public/?app=worker"), at: 3)
        try storage.saveWalletConnection(connection("https://acme.example.com", title: "Acme"))
        try storage.deleteWalletConnection(key: WalletScope.origin("https://acme.example.com").key)
        #expect(try storage.openedPublicApps().map(\.origin) == ["https://other.example.com"])
        // A connection of another kind forgets no app.
        try storage.deleteWalletConnection(key: WalletScope.org(peer: "acme").key)
        #expect(try storage.openedPublicApps().count == 1)
    }

    @Test func takingOneOffTheListLeavesItsConnection() throws {
        let tasks = try link("https://acme.example.com/public/?app=worker")
        try storage.rememberPublicApp(tasks, at: 1)
        try storage.saveWalletConnection(connection("https://acme.example.com", title: "Acme"))
        try storage.forgetPublicApp(seller: tasks.seller.absoluteString, app: "worker")
        #expect(try storage.openedPublicApps().isEmpty)
        #expect(try storage.walletConnections().count == 1)
    }

    @Test func theCaptionAndTheSearchRead() throws {
        try storage.rememberPublicApp(try link("https://acme.example.com/public/?app=strut/worker"), at: 1)
        let app = try #require(try storage.openedPublicApps().first)
        #expect(app.caption == "acme.example.com · strut/worker")
        #expect(app.matches("") && app.matches("ACME") && app.matches(" worker ") && !app.matches("books"))
        try storage.saveWalletConnection(connection("https://acme.example.com", title: "Tasks"))
        let titled = try #require(try storage.openedPublicApps().first)
        #expect(titled.matches("tasks"))
    }

    @Test func titlePrefersAConnectionsNameThenTheSellersThenTheHost() throws {
        let tasks = try link("https://acme.example.com/public/?app=worker")
        try storage.rememberPublicApp(tasks, at: 1)
        let seller = tasks.seller.absoluteString
        try storage.setPublicAppTitle(seller: seller, app: "worker", title: "Tasks")
        #expect(try storage.openedPublicApps().first?.title == "Tasks")
        // A connection titled by the host is the invite's placeholder.
        try storage.saveWalletConnection(connection("https://acme.example.com", title: "acme.example.com"))
        #expect(try storage.openedPublicApps().first?.title == "Tasks")
        try storage.saveWalletConnection(connection("https://acme.example.com", title: "Acme Tasks"))
        #expect(try storage.openedPublicApps().first?.title == "Acme Tasks")
    }

    @Test func openingAgainKeepsTheSavedTitleAndTheColumnExists() throws {
        let tasks = try link("https://acme.example.com/public/?app=worker")
        try storage.rememberPublicApp(tasks, at: 1)
        try storage.setPublicAppTitle(seller: tasks.seller.absoluteString, app: "worker", title: "Tasks")
        try storage.rememberPublicApp(tasks, at: 2)
        let row = try #require(try storage.openedPublicApps().first)
        #expect(row.appTitle == "Tasks" && row.openedAt == 2)
    }

    @Test func theListingsTitleIsRead() {
        #expect(PublicAppLink.title(in: Data(#"{"name":"strut/worker","title":"  Tasks \n"}"#.utf8)) == "Tasks")
        #expect(PublicAppLink.title(in: Data(#"{"title":"  "}"#.utf8)) == nil)
        #expect(PublicAppLink.title(in: Data(#"{"name":"x"}"#.utf8)) == nil)
        #expect(PublicAppLink.title(in: Data("[]".utf8)) == nil)
    }

    @Test func theListingsIconIsReadAndOddOnesRefused() {
        let tasks = Data(#"{"name":"strut/worker","title":"Tasks","icon":"list-checks"}"#.utf8)
        #expect(PublicAppLink.icon(in: tasks) == "list-checks")
        let both = PublicAppLink.listing(in: tasks)
        #expect(both.title == "Tasks")
        #expect(both.icon == "list-checks")
        #expect(PublicAppLink.icon(in: Data(#"{"icon":" square "}"#.utf8)) == "square")
        #expect(PublicAppLink.icon(in: Data(#"{"icon":"square.grid.2x2"}"#.utf8)) == nil)
        #expect(PublicAppLink.icon(in: Data(#"{"icon":"  "}"#.utf8)) == nil)
        #expect(PublicAppLink.icon(in: Data(#"{"icon":"List-Checks"}"#.utf8)) == nil)
        #expect(PublicAppLink.icon(in: Data(#"{"icon":"\#(String(repeating: "a", count: 65))"}"#.utf8)) == nil)
        #expect(PublicAppLink.icon(in: Data(#"{"icon":3,"title":"Tasks"}"#.utf8)) == nil)
        #expect(PublicAppLink.title(in: Data(#"{"icon":3,"title":"Tasks"}"#.utf8)) == "Tasks")
    }

    @Test func theIconIsStoredReadBackAndNeverErasedByNone() throws {
        let tasks = try link("https://acme.example.com/public/?app=worker")
        try storage.rememberPublicApp(tasks, at: 1)
        let seller = tasks.seller.absoluteString
        #expect(try storage.openedPublicApps().first?.icon == nil)
        try storage.setPublicAppIcon(seller: seller, app: "worker", icon: "list-checks")
        try storage.setPublicAppIcon(seller: seller, app: "worker", icon: nil)
        try storage.rememberPublicApp(tasks, at: 2)
        #expect(try storage.openedPublicApps().first?.icon == "list-checks")
    }
}
