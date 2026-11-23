import Foundation
import Testing
@testable import PeelCore
@testable import PeelUI

/// The iPhone's Apps list: workspace apps and opened public apps as one.
struct AppsListingTests {
    private let workspace = [
        WorkspaceApp(peer: "acme", name: "ledger", title: "Ledger", about: "Books"),
        WorkspaceApp(peer: "acme", name: "notes", title: "Notes", about: nil),
    ]

    private func opened(_ host: String, app: String, openedAt: Int64) -> OpenedPublicApp {
        OpenedPublicApp(seller: "https://\(host)", app: app, url: "https://\(host)/public?app=\(app)",
                        origin: "https://\(host)", openedAt: openedAt, connectionTitle: nil)
    }

    private var openedApps: [OpenedPublicApp] {
        [opened("tasks.example.com", app: "strut/worker", openedAt: 20),
         opened("other.example.org", app: "strut/board", openedAt: 10)]
    }

    @Test func workspaceAppsComeFirstThenOpenedLastOpenedFirst() {
        let rows = AppsListRow.merged(workspace: workspace, opened: openedApps, query: "", source: nil)
        #expect(rows.count == 4)
        #expect(rows.prefix(2).map(\.title) == ["Ledger", "Notes"])
        #expect(rows.suffix(2).map(\.source) == ["tasks.example.com", "other.example.org"])
        #expect(Set(rows.map(\.id)).count == 4)
        if case .opened(let first) = rows[2] { #expect(first.openedAt == 20) } else { Issue.record("not opened") }
    }

    @Test func sourcesAddEachOpenedHostOnce() {
        let more = openedApps + [opened("tasks.example.com", app: "strut/other", openedAt: 5)]
        let sources = AppsListRow.sources(workspace: workspace, opened: more)
        #expect(sources == ["@acme", "tasks.example.com", "other.example.org"])
        #expect(AppsListRow.sources(workspace: [], opened: []) == [])
    }

    @Test func aHostShowsOnlyThatServersOpenedApps() {
        let rows = AppsListRow.merged(workspace: workspace, opened: openedApps, query: "", source: "other.example.org")
        #expect(rows.count == 1)
        #expect(rows.first?.source == "other.example.org")
        #expect(AppsListRow.merged(workspace: workspace, opened: openedApps, query: "", source: "@acme").count == 2)
    }

    @Test func aSearchFindsBothKinds() {
        #expect(AppsListRow.merged(workspace: workspace, opened: openedApps, query: "ledger", source: nil).count == 1)
        #expect(AppsListRow.merged(workspace: workspace, opened: openedApps, query: "worker", source: nil).count == 1)
        #expect(AppsListRow.merged(workspace: workspace, opened: openedApps, query: "zzz", source: nil).isEmpty)
    }
}
