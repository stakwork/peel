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

    // MARK: Preferences sync

    @Test func syncedPublicAppsEncodeAsOfficialFixedPointsAndValidate() throws {
        let opened = SyncedPublicApp.opened(.init(
            url: "https://acme.example.com/public/?app=strut/tasks", title: "  Tasks \n", icon: "list-checks"
        ))
        let encoded = try Preference<SyncedPublicApp>.publicApp.write(opened)
        #expect(Preferences.isOfficialFixedPoint(encoded))
        let decoded = Preference<SyncedPublicApp>.publicApp.read(encoded)
        #expect(decoded == .opened(.init(
            url: "https://acme.example.com/public/?app=strut/tasks", title: "Tasks", icon: "list-checks"
        )))

        let forgotten = try Preference<SyncedPublicApp>.publicApp.write(.forgotten)
        #expect(Preferences.isOfficialFixedPoint(forgotten))
        #expect(Preference<SyncedPublicApp>.publicApp.read(forgotten) == .forgotten)

        // Official apps leave the preferences file byte-for-byte intact.
        let file = PreferencesFile().merged(with: [
            PreferenceRow(
                key: Preferences.publicAppKey,
                identifier: SyncedPublicApp.identifier(seller: "https://acme.example.com", app: "strut/tasks"),
                value: try encoded.text, updatedAt: 100
            ),
            PreferenceRow(
                key: Preferences.publicAppKey,
                identifier: SyncedPublicApp.identifier(seller: "https://acme.example.com", app: "books"),
                value: try forgotten.text, updatedAt: 101
            ),
        ]).file
        let text = try file.text
        #expect(OfficialApp.rewrite(text) == text)

        // Disallowed URLs (non-https, credentials, fragment) are refused.
        for bad in [
            "http://acme.example.com/public/?app=strut/tasks",
            "https://user:pass@acme.example.com/public/?app=strut/tasks",
            "https://acme.example.com/public/?app=strut/tasks#frag",
            "not a url",
        ] {
            let entry = SyncedPublicApp.opened(.init(url: bad))
            #expect(throws: UnwritablePreference.self) { try Preference<SyncedPublicApp>.publicApp.write(entry) }
            #expect(Preference<SyncedPublicApp>.publicApp.read(.string(#"{"url":"\#(bad)"}"#)) == nil)
        }
        // Invalid icons are dropped rather than stored.
        let oddIcon = Preference<SyncedPublicApp>.publicApp.read(
            .string(#"{"icon":"Bad.Icon","title":"Tasks","url":"https://acme.example.com/public/?app=strut/tasks"}"#)
        )
        #expect(oddIcon == .opened(.init(
            url: "https://acme.example.com/public/?app=strut/tasks", title: "Tasks", icon: nil
        )))
    }

    /// Opening an app again reorders this device's list and leaves the synced
    /// item alone, so it uploads nothing; a first opening or a new address
    /// changes the item.
    @Test func openingAgainChangesNothingSynced() throws {
        let tasks = try link("https://acme.example.com/public/?app=strut/tasks")
        #expect(try storage.rememberPublicApp(tasks, at: 1_700_000_100))
        let file = PreferencesFile().merged(with: try storage.preferenceRows()).file

        #expect(try !storage.rememberPublicApp(tasks, at: 1_700_000_500))
        #expect(!file.merged(with: try storage.preferenceRows()).changed)
        #expect(try storage.openedPublicApps().first?.openedAt == 1_700_000_500)

        let solo = try link("https://acme.example.com/public/?app=strut/tasks&solo=1")
        #expect(try storage.rememberPublicApp(solo, at: 1_700_000_600))
        #expect(file.merged(with: try storage.preferenceRows()).changed)
    }

    @Test func openedPublicAppsSyncAndRestoreAcrossDevices() throws {
        let tasks = try link("https://acme.example.com/public/?app=strut/tasks")
        let home = try link("https://other.example.com/")
        let t1 = Date(timeIntervalSince1970: 1_700_000_100)
        try storage.rememberPublicApp(tasks, at: 1_700_000_100)
        #expect(try storage.setPublicAppTitle(seller: tasks.seller.absoluteString, app: "strut/tasks", title: "Tasks", syncedAt: t1))
        #expect(try !storage.setPublicAppTitle(seller: tasks.seller.absoluteString, app: "strut/tasks", title: "Tasks", syncedAt: t1))
        #expect(try storage.setPublicAppIcon(seller: tasks.seller.absoluteString, app: "strut/tasks", icon: "list-checks", syncedAt: t1))
        #expect(try !storage.setPublicAppIcon(seller: tasks.seller.absoluteString, app: "strut/tasks", icon: "list-checks", syncedAt: t1))
        try storage.rememberPublicApp(home, at: 1_700_000_200)

        // Upload from device 1 into an encrypted preferences file.
        let uploaded = PreferencesFile().merged(with: try storage.preferenceRows())
        #expect(uploaded.changed)
        #expect(uploaded.uploads.count == 2)

        // Fresh restored database on device 2 starts empty and gets both apps
        // back, each dated by its item, so the last opened is still first.
        let restoredProfile = TempProfile()
        let restored = try restoredProfile.storage()
        #expect(try restored.openedPublicApps().isEmpty)
        let pulled = uploaded.file.merged(with: try restored.preferenceRows())
        #expect(!pulled.changed)
        #expect(try restored.applyPreferences(pulled.apply) == 2)

        let apps = try restored.openedPublicApps()
        #expect(apps.count == 2)
        #expect(apps[0].seller == home.seller.absoluteString && apps[0].app == "" && apps[0].openedAt == 1_700_000_200)
        #expect(apps[1].seller == tasks.seller.absoluteString && apps[1].app == "strut/tasks")
        #expect(apps[1].url == tasks.url.absoluteString && apps[1].openedAt < 1_700_000_200)
        #expect(apps[1].appTitle == "Tasks" && apps[1].title == "Tasks" && apps[1].icon == "list-checks")
    }

    /// An item from another device (a new title there) updates an app already
    /// here, which keeps when it was last opened here.
    @Test func anAppAlreadyHereKeepsItsOwnOrder() throws {
        let tasks = try link("https://acme.example.com/public/?app=strut/tasks")
        try storage.rememberPublicApp(tasks, at: 1_700_000_100)
        var file = PreferencesFile().merged(with: try storage.preferenceRows()).file
        try storage.rememberPublicApp(tasks, at: 1_700_000_500)

        let device2Profile = TempProfile()
        let device2 = try device2Profile.storage()
        _ = try device2.applyPreferences(file.merged(with: try device2.preferenceRows()).apply)
        try device2.setPublicAppTitle(
            seller: tasks.seller.absoluteString, app: "strut/tasks", title: "Tasks",
            syncedAt: Date(timeIntervalSince1970: 1_700_000_300)
        )
        file = file.merged(with: try device2.preferenceRows()).file

        _ = try storage.applyPreferences(file.merged(with: try storage.preferenceRows()).apply)
        let app = try #require(try storage.openedPublicApps().first)
        #expect(app.appTitle == "Tasks" && app.openedAt == 1_700_000_500)
    }

    @Test func forgettingAndReopeningPublicAppsSyncsCleanly() throws {
        let tasks = try link("https://acme.example.com/public/?app=strut/tasks")
        let seller = tasks.seller.absoluteString
        let t2 = Date(timeIntervalSince1970: 1_700_000_200)

        try storage.rememberPublicApp(tasks, at: 1_700_000_100)
        var file = PreferencesFile().merged(with: try storage.preferenceRows()).file

        let device2Profile = TempProfile()
        let device2 = try device2Profile.storage()
        _ = try device2.applyPreferences(file.merged(with: try device2.preferenceRows()).apply)
        #expect(try device2.openedPublicApps().count == 1)

        // Forget on device 1: tombstone syncs and removes it on device 2 and on a fresh restore.
        try storage.forgetPublicApp(seller: seller, app: "strut/tasks", syncedAt: t2)
        let forgetMerge = file.merged(with: try storage.preferenceRows())
        #expect(forgetMerge.changed)
        file = forgetMerge.file

        _ = try device2.applyPreferences(file.merged(with: try device2.preferenceRows()).apply)
        #expect(try device2.openedPublicApps().isEmpty)

        let restoredProfile = TempProfile()
        let restored = try restoredProfile.storage()
        _ = try restored.applyPreferences(file.merged(with: try restored.preferenceRows()).apply)
        #expect(try restored.openedPublicApps().isEmpty)

        // Re-opening later on device 2 beats the tombstone and brings it back on device 1.
        #expect(try device2.rememberPublicApp(tasks, at: 1_700_000_300))
        let reopenMerge = file.merged(with: try device2.preferenceRows())
        #expect(reopenMerge.changed)
        file = reopenMerge.file

        _ = try storage.applyPreferences(file.merged(with: try storage.preferenceRows()).apply)
        let apps = try storage.openedPublicApps()
        #expect(apps.count == 1 && apps[0].app == "strut/tasks" && apps[0].openedAt == 1_700_000_300)
    }

    @Test func disconnectingAnOriginSyncsTheRemoval() throws {
        let tasks = try link("https://acme.example.com/public/?app=strut/tasks")
        try storage.rememberPublicApp(tasks, at: 1_700_000_100)
        try storage.saveWalletConnection(connection("https://acme.example.com", title: "Tasks"))
        var file = PreferencesFile().merged(with: try storage.preferenceRows()).file

        let device2Profile = TempProfile()
        let device2 = try device2Profile.storage()
        _ = try device2.applyPreferences(file.merged(with: try device2.preferenceRows()).apply)
        #expect(try device2.openedPublicApps().count == 1)

        // Disconnecting the origin deletes the app locally and tombstones it in preferences.
        try storage.deleteWalletConnection(key: WalletScope.origin("https://acme.example.com").key)
        let disconnectMerge = file.merged(with: try storage.preferenceRows())
        #expect(disconnectMerge.changed)
        file = disconnectMerge.file

        _ = try device2.applyPreferences(file.merged(with: try device2.preferenceRows()).apply)
        #expect(try device2.openedPublicApps().isEmpty)
    }

    @Test func offlineOpensOnTwoDevicesMergeWithoutLosingEither() throws {
        let tasks = try link("https://acme.example.com/public/?app=strut/tasks")
        let books = try link("https://acme.example.com/public/?app=books")

        let device2Profile = TempProfile()
        let device2 = try device2Profile.storage()

        try storage.rememberPublicApp(tasks, at: 1_700_000_100)
        try device2.rememberPublicApp(books, at: 1_700_000_200)

        var file = PreferencesFile().merged(with: try storage.preferenceRows()).file
        let m2 = file.merged(with: try device2.preferenceRows())
        _ = try device2.applyPreferences(m2.apply)
        file = m2.file
        let m1 = file.merged(with: try storage.preferenceRows())
        _ = try storage.applyPreferences(m1.apply)

        #expect(try storage.openedPublicApps().map(\.app) == ["books", "strut/tasks"])
        #expect(try device2.openedPublicApps().map(\.app) == ["books", "strut/tasks"])
    }

    @Test func mismatchedIdentifierInPreferencesFileIsIgnored() throws {
        let encoded = try Preference<SyncedPublicApp>.publicApp.write(.opened(.init(
            url: "https://acme.example.com/public/?app=strut/tasks", title: "Tasks"
        )))
        let file = try PreferencesFile(text: """
            {"items":[{"key":"\(Preferences.publicAppKey)","identifier":"https://evil.example.com other","date":"100","value":\(try encoded.text)}]}
            """)
        let merge = file.merged(with: try storage.preferenceRows())
        _ = try storage.applyPreferences(merge.apply)
        #expect(try storage.openedPublicApps().isEmpty)
    }
}
