import Foundation
import Testing
@testable import PeelCore
@testable import PeelUI

/// What an org page's sheet may download, what it saves a download as, and
/// how the apps on the iPhone are searched and filtered.
struct OrgPageRulesTests {
    /// A public site's sign-in lives in its own store, found again on the
    /// next open of any page there, and never another site's.
    @Test func aPublicSiteKeepsOneStoreOfItsOwn() throws {
        func store(_ address: String) throws -> UUID {
            let url = try #require(URL(string: address))
            return PublicPage(try #require(PublicAppLink(url))).storeIdentifier
        }
        let worker = try store("https://strut.stadeum1.sphinx.chat/?app=strut/worker&solo=1&public=1")
        #expect(try store("https://strut.stadeum1.sphinx.chat/?app=strut/worker&solo=1&public=1") == worker)
        #expect(try store("https://STRUT.stadeum1.sphinx.chat:443/?app=other&public=1") == worker)
        #expect(try store("https://strut.stadeum2.sphinx.chat/?app=strut/worker&solo=1&public=1") != worker)
        #expect(try store("https://strut.stadeum1.sphinx.chat:8443/?app=strut/worker&solo=1&public=1") != worker)
        // A name-based UUID, version 5, RFC 9562's variant.
        #expect(worker.uuid.6 >> 4 == 5)
        #expect(worker.uuid.8 >> 6 == 0b10)
    }

    @Test func onlyStrutsOwnMainFramePageMayDownload() {
        #expect(OrgPageRules.mayDownload(isMainFrame: true, sourceIsMainFrame: true, served: true))
        // A frame in the page holds what the org or an agent wrote.
        #expect(!OrgPageRules.mayDownload(isMainFrame: false, sourceIsMainFrame: true, served: true))
        #expect(!OrgPageRules.mayDownload(isMainFrame: true, sourceIsMainFrame: false, served: true))
        #expect(!OrgPageRules.mayDownload(isMainFrame: false, sourceIsMainFrame: false, served: true))
        // A foreign host.
        #expect(!OrgPageRules.mayDownload(isMainFrame: true, sourceIsMainFrame: true, served: false))
    }

    @Test func aDownloadServedByTheOrgsStrutIsTheOnlyOneAllowed() throws {
        let page = OrgPageRequest(url: try #require(URL(string: "https://acme.sphinx.chat/lab/?app=x&solo=1")),
                                  token: "t", peer: "acme", workspace: "Acme")
        let own = try #require(URL(string: "https://acme.sphinx.chat/lab/files/a.zip"))
        let foreign = try #require(URL(string: "https://evil.example/lab/files/a.zip"))
        #expect(OrgPageRules.mayDownload(isMainFrame: true, sourceIsMainFrame: true, served: page.serves(own)))
        #expect(!OrgPageRules.mayDownload(isMainFrame: true, sourceIsMainFrame: true, served: page.serves(foreign)))
        #expect(!OrgPageRules.mayDownload(isMainFrame: false, sourceIsMainFrame: false, served: page.serves(own)))
    }

    @Test(arguments: [
        ("report.pdf", "report.pdf"),
        ("../../etc/passwd", "passwd"),
        ("a/b/c.txt", "c.txt"),
        ("..\\..\\win.ini", "win.ini"),
        ("dir/", "dir"),
        ("..", "download"),
        (".", "download"),
        ("", "download"),
        ("/", "download"),
        ("   ", "download"),
        ("../", "download"),
        ("nul\u{0}.txt", "nul.txt"),
    ])
    func aSuggestedNameStaysInItsFolder(suggested: String, saved: String) {
        #expect(OrgPageRules.filename(suggested) == saved)
    }

    @Test func aFailingStatusSaysWhy() {
        #expect(OrgPageRules.failure(status: 200) == nil && OrgPageRules.failure(status: 304) == nil)
        #expect(OrgPageRules.failure(status: 404)?.contains("404") == true)
        #expect(OrgPageRules.failure(status: 401)?.contains("401") == true)
        #expect(OrgPageRules.failure(status: 503)?.contains("503") == true)
        #expect(OrgPageRules.failure(status: 418)?.contains("418") == true)
    }

    private let apps = [
        WorkspaceApp(peer: "globex", name: "board", title: "Board", about: "Kanban for the team"),
        WorkspaceApp(peer: nil, name: "mine", title: "Mine", about: nil),
        WorkspaceApp(peer: "acme", name: "ledger", title: "Ledger", about: "Books"),
        WorkspaceApp(peer: "acme", name: "notes", title: "Notes", about: nil),
    ]

    @Test func sourcesListYoursThenWorkspacesAToZ() throws {
        #expect(WorkspaceApp.sources(of: apps) == ["Yours", "@acme", "@globex"])
        // One strut seeds is Built-in, after Yours, and found by that word.
        let knowledge = try #require(WorkspaceApp(peer: nil, entry: Data(#"{"name":"strut/knowledge","title":"Knowledge","publisher":"strut"}"#.utf8)))
        #expect(knowledge.source == "Built-in")
        #expect(WorkspaceApp.sources(of: [knowledge] + apps) == ["Yours", "Built-in", "@acme", "@globex"])
        #expect(WorkspaceApp.sources(of: [knowledge]) == ["Built-in"])
        #expect(WorkspaceApp.filter([knowledge] + apps, query: "built", source: nil).map(\.name) == ["strut/knowledge"])
        #expect(WorkspaceApp.sources(of: apps.filter { $0.peer != nil }) == ["@acme", "@globex"])
        #expect(WorkspaceApp.sources(of: []) == [])
    }

    @Test func appsAreFilteredByQueryAndBySource() {
        #expect(WorkspaceApp.filter(apps, query: "", source: nil).map(\.name) == ["board", "mine", "ledger", "notes"])
        // Title, what it is for, and where it comes from.
        #expect(WorkspaceApp.filter(apps, query: "led", source: nil).map(\.name) == ["ledger"])
        #expect(WorkspaceApp.filter(apps, query: "kanban", source: nil).map(\.name) == ["board"])
        #expect(WorkspaceApp.filter(apps, query: "acme", source: nil).map(\.name) == ["ledger", "notes"])
        #expect(WorkspaceApp.filter(apps, query: "", source: "@acme").map(\.name) == ["ledger", "notes"])
        #expect(WorkspaceApp.filter(apps, query: "not", source: "@acme").map(\.name) == ["notes"])
        #expect(WorkspaceApp.filter(apps, query: "", source: "Yours").map(\.name) == ["mine"])
        #expect(WorkspaceApp.filter(apps, query: "board", source: "@acme").isEmpty)
        #expect(WorkspaceApp.filter(apps, query: "zzz", source: nil).isEmpty)
    }
}
