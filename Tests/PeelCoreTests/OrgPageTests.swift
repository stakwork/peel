import Foundation
import Testing
@testable import PeelCore
@testable import PeelTestSupport

/// A deliverable from the agent's DM as the iPhone opens it (strut's
/// specs/DESKTOP.md, "A device with no strut of its own"): on its org's own
/// strut, the brain's `/peers/<org>` hop taken off, through that strut's UI
/// showing it alone.
struct OrgPageTests {
    private func query(_ url: URL?) -> String? {
        url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.percentEncodedQuery }
    }

    @Test(arguments: [
        // An org's own job file.
        ("/peers/acme/jobs/j-1/files/plan.md", "acme", "/jobs/j-1/files/plan.md"),
        // A job the org keeps for a peer, its `/` escaped, and an escaped space.
        ("/peers/acme/jobs/peer%2Fj-1/files/Lisbon%20plan.md", "acme", "/jobs/peer%2Fj-1/files/Lisbon%20plan.md"),
        // A spoke's, read through the org: the second hop stays.
        ("/peers/acme/peers/billing/jobs/j-2/files/r.md", "acme", "/peers/billing/jobs/j-2/files/r.md"),
        // A run's artifact.
        ("/peers/acme.io/artifacts/1793/shot.png", "acme.io", "/artifacts/1793/shot.png"),
    ])
    func anOrgsFileOpensOnTheOrgsOwnStrut(path: String, peer: String, onOrg: String) throws {
        let page = try #require(AgentArtifact.Handle(path: path)?.onOrg)
        #expect(page == OrgPage(peer: peer, query: "artifact", value: onOrg))
    }

    @Test func anOrgsAppOpensByItsNameThere() throws {
        let page = try #require(AgentArtifact.Handle(app: "@acme/hive/board")?.onOrg)
        #expect(page == OrgPage(peer: "acme", query: "app", value: "hive/board"))
        #expect(query(page.url(on: URL(string: "https://acme.sphinx.chat/lab")!)) == "app=hive%2Fboard&solo=1")
    }

    @Test func oneOfTheBrainsOwnHasNoPageOnAnOrg() throws {
        #expect(try #require(AgentArtifact.Handle(path: "/jobs/j-1/files/plan.md")).onOrg == nil)
        #expect(try #require(AgentArtifact.Handle(path: "/artifacts/1793/shot.png")).onOrg == nil)
        #expect(try #require(AgentArtifact.Handle(app: "reports")).onOrg == nil)
    }

    @Test(arguments: [
        // A swarm's strut is mcp's `/lab`: the UI is its folder, with its `/`.
        ("https://acme.sphinx.chat/lab", "https://acme.sphinx.chat/lab/"),
        ("https://acme.sphinx.chat/lab/", "https://acme.sphinx.chat/lab/"),
        ("https://strut.acme.io:8443", "https://strut.acme.io:8443/"),
    ])
    func thePageIsTheOrgsUiAloneWithNoCredentialInIt(base: String, folder: String) throws {
        let page = try #require(AgentArtifact.Handle(path: "/peers/acme/jobs/peer%2Fj-1/files/Lisbon%20plan.md")?.onOrg)
        let url = try #require(page.url(on: URL(string: base)!))
        #expect(url.absoluteString.hasPrefix(folder + "?"))
        // The path's `%` escaped again, so strut's UI reads back exactly the path.
        #expect(query(url) == "artifact=%2Fjobs%2Fpeer%252Fj-1%2Ffiles%2FLisbon%2520plan.md&solo=1")
        #expect(!url.absoluteString.contains("key="))
    }
}

/// A workspace's apps as the iPhone reads them: on the workspace's own
/// strut, its `/lab` included, with the person's token as the bearer; only
/// those pinned as tabs, under names strut gives.
struct WorkspaceAppTests {
    @Test func aWorkspacesPinnedAppsAreReadOnItsOwnStrut() async throws {
        let strut = try await HTTPStub { _, request in
            guard request.hasPrefix("GET /lab/apps "), request.contains("Authorization: Bearer jwt-acme") else { return (404, "{}") }
            return (200, #"{"apps":[{"name":"hive/board","title":"Board","pinned":true,"activeVersion":"v3"},{"name":"scratch","title":"Scratch"}]}"#)
        }
        defer { strut.stop() }
        let peer = HivePeer(id: "acme", baseUrl: "http://127.0.0.1:\(strut.port)/lab", token: "jwt-acme", label: "Acme")
        let apps = try await WorkspaceApp.pinned(on: peer)
        #expect(apps == [WorkspaceApp(peer: "acme", name: "hive/board", title: "Board", about: nil, version: "v3")])
        #expect(apps.first?.id == "@acme/hive/board")
    }

    @Test func aWorkspaceThatRefusesSaysSo() async throws {
        let strut = try await HTTPStub { _, _ in (401, #"{"error":"Unauthorized"}"#) }
        defer { strut.stop() }
        let peer = HivePeer(id: "acme", baseUrl: "http://127.0.0.1:\(strut.port)/lab", token: "old", label: "Acme")
        await #expect(throws: PeelError.self) { try await WorkspaceApp.pinned(on: peer) }
    }
}

/// A link to an app as a page in strut's UI hands one to its host (strut's
/// plans/apps.md §7.1, "Deep links"; the kit's `appLink`), read back as
/// strut's UI reads its own address, and the view it names carried into the
/// page Peel opens.
struct StrutAppLinkTests {
    private let ui = URL(string: "http://127.0.0.1:4100/")!

    private func query(_ url: URL?) -> String? {
        url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.percentEncodedQuery }
    }

    /// What `appLink("bench", { view: "/runs", run: 12 })` makes, resolved
    /// against strut's page, then opened: strut's UI reads back the same input.
    @Test func aLinkOpensTheAppAtTheViewItNames() throws {
        let url = try #require(URL(string: "?app=bench&input=view%3D%252Fruns%26run%3D12", relativeTo: ui)?.absoluteURL)
        let link = try #require(StrutAppLink(url, folder: "/", from: .own))
        #expect(link == StrutAppLink(app: .app("bench"), input: "view=%2Fruns&run=12"))
        let page = StrutUI.page(on: ui, key: "k", "app", "bench", input: link.input)
        #expect(query(page) == "key=k&app=bench&input=view%3D%252Fruns%26run%3D12&solo=1")
    }

    @Test(arguments: [
        // A page names apps where it lives: a bare name from a workspace's page is that workspace's.
        ("?app=board&input=v%3D1", .peer("acme"), "@acme/board", "v=1"),
        ("?app=board%40v3", .peer("acme"), "@acme/board@v3", nil),
        // From a page of Peel's own strut, as written.
        ("?app=%40acme%2Fboard", .own, "@acme/board", nil),
        ("?app=tools%2Fboard&input=", .own, "tools/board", nil),
        // On the org's own strut (the iPhone), one of its own.
        ("?app=board", .org, "board", nil),
        // `URLSearchParams`: a bare `+` is a space.
        ("?app=bench&input=q%3Da+b", .own, "bench", "q=a b"),
    ] as [(String, StrutAppLink.Source, String, String?)])
    func aLinkIsReadAsStrutsUiReadsIt(link: String, from source: StrutAppLink.Source, app: String, input: String?) throws {
        let url = try #require(URL(string: link, relativeTo: ui)?.absoluteURL)
        #expect(StrutAppLink(url, folder: "/", from: source) == StrutAppLink(app: .app(app), input: input))
    }

    @Test(arguments: [
        // An org's page linking to its own peer's app: the org's to open.
        ("http://127.0.0.1:4100/?app=%40globex%2Fx", .peer("acme")),
        ("http://127.0.0.1:4100/?app=%40globex%2Fx", .org),
        // A run, a job: no app.
        ("http://127.0.0.1:4100/?wf=clip&run=1", .own),
        ("http://127.0.0.1:4100/?app=&input=v%3D1", .own),
        // Not a name strut gives an app.
        ("http://127.0.0.1:4100/?app=..%2Fx", .own),
        // Not strut's UI: an app's own document on the same strut.
        ("http://127.0.0.1:4100/apps/board/v1/files/dist/index.html?app=board", .own),
        // Given twice, or not decoding: strut would read it its own way.
        ("http://127.0.0.1:4100/?app=bench&app=other", .own),
        ("http://127.0.0.1:4100/?app=&app=board", .own),
        ("http://127.0.0.1:4100/?app=b&input=&input=v%3D1", .own),
        ("http://127.0.0.1:4100/?app=b&%61pp=c", .own),
        ("http://127.0.0.1:4100/?app=b&input=%FF", .own),
    ] as [(String, StrutAppLink.Source)])
    func anythingElseIsNoAppLink(url: String, from source: StrutAppLink.Source) throws {
        #expect(StrutAppLink(try #require(URL(string: url)), folder: "/", from: source) == nil)
    }

    /// Counted in bytes: 1,025 two-byte characters are past it.
    @Test func anInputPastAViewsAddressIsNoLink() throws {
        let long = String(repeating: "%C3%A9", count: StrutAppLink.longestInput / 2 + 1)
        #expect(StrutAppLink(try #require(URL(string: "http://127.0.0.1:4100/?app=x&input=\(long)")), folder: "/", from: .own) == nil)
    }

    /// Loading a page again at the view it moved to keeps the rest of its
    /// address exactly, the key's escapes included.
    @Test func thePageMovesToAnotherViewWithItsAddressKept() throws {
        let opened = try #require(URL(string: "http://127.0.0.1:4100/?key=k%2B1&app=%40acme%2Fboard&input=v%3D1&solo=1"))
        #expect(query(StrutUI.page(opened, input: "view=/x")) == "key=k%2B1&app=%40acme%2Fboard&input=view%3D%2Fx&solo=1")
        #expect(query(StrutUI.page(opened, input: nil)) == "key=k%2B1&app=%40acme%2Fboard&solo=1")
        let first = try #require(URL(string: "http://127.0.0.1:4100/?key=k%2B1&app=board&solo=1"))
        #expect(query(StrutUI.page(first, input: "v=2")) == "key=k%2B1&app=board&input=v%3D2&solo=1")
    }
}
