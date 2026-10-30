import Foundation
import Testing
@testable import PeelCore

/// One of the person's own apps' versions as strut gives them (strut's
/// plans/app-releases.md, `GET /apps/:name/versions`), and the version its
/// listing says waits to be made live.
struct AppVersionsTests {
    /// Held at r3 (v7): newest first by number, not as text (v10 above
    /// v9); the releases newest first though strut lists them oldest first;
    /// what the lock left behind, one of them gone. Only newer versions wait.
    @Test func aHeldAppsVersionsAndReleasesAreReadNewestFirst() throws {
        let reply = #"""
            {"name":"bench","active":"v7","live":"r3",
             "versions":{"v9":{"createdAt":"2026-10-28T10:00:00.000Z","hash":"a"},"v10":{"createdAt":"2026-10-28T11:00:00Z","hash":"b"},
                         "v7":{"createdAt":"2026-10-26T10:00:00Z","hash":"c"}},
             "releases":[{"id":"r1","version":"v3","createdAt":"2026-10-12T10:00:00Z","lock":{}},
                         {"id":"r3","version":"v7","createdAt":"2026-10-26T10:00:00Z","by":"tom","lock":{}}],
             "behind":[{"kind":"workflow","name":"openhealth-run","locked":"v14","current":"v17"},
                       {"kind":"step","name":"score-step","locked":"v3","current":null}]}
            """#
        let versions = try #require(AppVersions(reply: Data(reply.utf8)))
        #expect(versions.active == "v7" && versions.release == "r3" && versions.held)
        #expect(versions.versions.map(\.label) == ["v10", "v9", "v7"])
        #expect(versions.versions.first?.createdAt != nil && versions.versions[1].createdAt != nil)
        #expect(versions.releases.map(\.id) == ["r3", "r1"])
        #expect(versions.behind == [AppVersions.Drift(name: "openhealth-run", locked: "v14", current: "v17"),
                                    AppVersions.Drift(name: "score-step", locked: "v3", current: nil)])
        #expect(versions.newestWaiting == "v10")
        #expect(versions.isWaiting("v9") && !versions.isWaiting("v7"))
    }

    /// Following latest (`live: "latest"`): no release, and nothing waits,
    /// since every publish goes live. A reply with no version is none.
    @Test func anAppFollowingLatestHasNothingWaiting() throws {
        let reply = #"{"active":"v12","live":"latest","versions":{"v12":{},"v11":{}},"releases":[],"behind":[]}"#
        let versions = try #require(AppVersions(reply: Data(reply.utf8)))
        #expect(versions.release == nil && !versions.held)
        #expect(versions.newestWaiting == nil && !versions.isWaiting("v12"))
        #expect(AppVersions(reply: Data(#"{"live":"latest"}"#.utf8)) == nil)
    }

    /// What `PUT /apps/:name/active` is sent for each choice.
    @Test func eachChoiceSendsStrutsBody() {
        #expect(AppLiveTarget.version("v9").body == ["version": "v9"])
        #expect(AppLiveTarget.release("r2").body == ["release": "r2"])
        #expect(AppLiveTarget.latest.body == ["version": "latest"])
    }

    /// From `GET /apps`: the person's own app held at v7 with v10 built has
    /// v10 waiting; following latest, or a workspace's, none.
    @Test(arguments: [
        (nil, #""live":"r3""#, "v10"),
        (nil, #""live":null"#, nil),
        ("acme", #""live":"r3","pinned":true"#, nil),
    ] as [(String?, String, String?)])
    func aListedAppSaysWhichVersionWaits(peer: String?, live: String, waiting: String?) throws {
        let entry = #"{"name":"bench","title":"Bench","activeVersion":"v7","versions":["v7","v10","v9"],\#(live)}"#
        let app = try #require(WorkspaceApp(peer: peer, entry: Data(entry.utf8)))
        #expect(app.newest == "v10")
        #expect(app.waiting == waiting)
    }
}
