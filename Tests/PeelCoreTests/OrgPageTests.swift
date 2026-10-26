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
        #expect(apps.first?.id == "@acme/hive/board" && apps.first?.caption(showsSource: true) == "@acme · v3")
    }

    @Test func aWorkspaceThatRefusesSaysSo() async throws {
        let strut = try await HTTPStub { _, _ in (401, #"{"error":"Unauthorized"}"#) }
        defer { strut.stop() }
        let peer = HivePeer(id: "acme", baseUrl: "http://127.0.0.1:\(strut.port)/lab", token: "old", label: "Acme")
        await #expect(throws: PeelError.self) { try await WorkspaceApp.pinned(on: peer) }
    }
}
