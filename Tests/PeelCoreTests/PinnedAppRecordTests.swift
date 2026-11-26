import Foundation
import Testing
@testable import PeelCore

/// The pinned apps' kept records (`PinnedAppRecord`) and how a read of the
/// workspaces changes them, and the person's own apps listed first.
struct PinnedAppRecordTests {
    private func app(_ peer: String?, _ name: String, _ title: String? = nil, version: String? = nil) -> WorkspaceApp {
        var app = WorkspaceApp(peer: peer, name: name, title: title ?? name, about: nil)
        app.version = version
        return app
    }

    private func records(_ apps: [WorkspaceApp]) -> [PinnedAppRecord] { apps.map { PinnedAppRecord($0) } }

    @Test func theOwnAppsComeFirstThenTheWorkspacesEachAToZ() {
        let listed = WorkspaceApp.ownFirst([app("acme", "alpha"), app(nil, "zed"), app("acme", "beta"), app(nil, "mine")])
        #expect(listed.map(\.id) == ["mine", "zed", "@acme/alpha", "@acme/beta"])
    }

    @Test func aRecordKeepsOnlyWhatShowsTheRowAndComesBackRefreshing() throws {
        var board = app("acme", "board", "Board", version: "v3")
        board.icon = "flask-conical"
        let record = PinnedAppRecord(board)
        let decoded = try JSONDecoder().decode(PinnedAppRecord.self, from: JSONEncoder().encode(record))
        #expect(decoded == record)
        #expect(decoded.app.id == "@acme/board" && decoded.app.title == "Board" && decoded.app.icon == "flask-conical")
        #expect(decoded.app.version == "v3" && decoded.app.refreshing && decoded.app.about == nil)
    }

    @Test func onlyPinnedWorkspaceAppsAreRecorded() {
        let apps = [app("acme", "board"), app("acme", "other"), app(nil, "mine")]
        let kept = PinnedAppRecord.records(of: apps, pinnedIDs: ["@acme/board", "mine"])
        #expect(kept.map(\.id) == ["@acme/board"])
    }

    @Test func aWorkspaceThatAnswersReplacesItsRecords() {
        let old = records([app("acme", "board", "Board", version: "v1"), app("acme", "gone", "Gone")])
        let read: [String: Result<[WorkspaceApp], AppsReadFailure>] = [
            "acme": .success([app("acme", "board", "Boards", version: "v2"), app("acme", "new", "New")])]
        let kept = PinnedAppRecord.reconcile(old: old, read: read, pinnedIDs: ["@acme/board", "@acme/gone"], live: ["acme"])
        // Removed: dropped. Renamed, newer: updated. Not pinned: not stored.
        #expect(kept.map(\.id) == ["@acme/board"])
        #expect(kept.first?.title == "Boards" && kept.first?.version == "v2")
    }

    @Test func aRefusalDropsTheWorkspacesRecordsButATimeoutKeepsThem() {
        let old = records([app("acme", "board"), app("globex", "wiki")])
        let pins = ["@acme/board", "@globex/wiki"]
        for status in [401, 403, 404] {
            let read: [String: Result<[WorkspaceApp], AppsReadFailure>] = ["acme": .failure(AppsReadFailure(status: status))]
            #expect(PinnedAppRecord.reconcile(old: old, read: read, pinnedIDs: pins, live: ["acme", "globex"]).map(\.id)
                == ["@globex/wiki"])
        }
        for failure in [AppsReadFailure(status: nil), AppsReadFailure(status: 500), AppsReadFailure(status: 503)] {
            let read: [String: Result<[WorkspaceApp], AppsReadFailure>] = ["acme": .failure(failure)]
            #expect(PinnedAppRecord.reconcile(old: old, read: read, pinnedIDs: pins, live: ["acme", "globex"]).map(\.id) == pins)
        }
    }

    @Test func anUnpinnedAppOrAWorkspaceNoLongerLiveIsDropped() {
        let old = records([app("acme", "board"), app("globex", "wiki")])
        #expect(PinnedAppRecord.reconcile(old: old, read: [:], pinnedIDs: ["@globex/wiki"], live: ["acme", "globex"]).map(\.id)
            == ["@globex/wiki"])
        #expect(PinnedAppRecord.reconcile(old: old, read: [:], pinnedIDs: ["@acme/board", "@globex/wiki"], live: ["acme"]).map(\.id)
            == ["@acme/board"])
    }

    @Test func aPinFollowsTheListAndAnUnpinLetsGo() {
        let old = records([app("acme", "board")])
        let kept = PinnedAppRecord.following(pins: ["@acme/board", "@acme/wiki"], old: old, apps: [app("acme", "wiki", "Wiki")])
        #expect(kept.map(\.id) == ["@acme/board", "@acme/wiki"])
        #expect(PinnedAppRecord.following(pins: ["@acme/wiki"], old: kept, apps: []).map(\.id) == ["@acme/wiki"])
    }

    @Test func onlyARefusalOfAccessIsLostAccess() {
        #expect([401, 403, 404].allSatisfy { AppsReadFailure(status: $0).lostAccess })
        #expect(![nil, 408, 429, 500, 502].contains { AppsReadFailure(status: $0).lostAccess })
        #expect(AppsReadFailure(PeelError("offline")) == AppsReadFailure(status: nil))
    }
}
