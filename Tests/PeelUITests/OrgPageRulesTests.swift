import Foundation
import Testing
@testable import PeelCore
@testable import PeelUI

/// What an org page's sheet may download, what it saves a download as, and
/// how the apps on the iPhone are searched and filtered.
struct OrgPageRulesTests {
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

    @Test func sourcesListYoursThenWorkspacesAToZ() {
        #expect(WorkspaceApp.sources(of: apps) == ["Yours", "@acme", "@globex"])
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
