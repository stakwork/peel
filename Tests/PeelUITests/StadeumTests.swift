import Foundation
import Synchronization
import Testing
@testable import PeelCore
@testable import PeelTestSupport
@testable import PeelUI

/// The Stadeum pairing the Mac and the iPhone share (`Stadeum`): kept with
/// the account, paired against a stand-in Hive, revoked, let go with the
/// account, the apps it lists, and how something opens on an org's own
/// strut for the iPhone.
@MainActor
struct StadeumTests {
    /// A peer record as Hive gives one.
    nonisolated static func peer(_ id: String, _ label: String) -> String {
        #"{"id":"\#(id)","baseUrl":"https://\#(id).sphinx.chat:3355/lab","token":"jwt-\#(id)","label":"\#(label)"}"#
    }

    /// A development profile in a folder of its own.
    private func profile() throws -> Profile {
        let folder = FileManager.default.temporaryDirectory.appending(path: "stadeum-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return Profile(developmentAt: folder)
    }

    private func link(hive: URL, peers: [String], renewedAt: Date = Date()) throws -> HiveLink {
        let peers = try JSONDecoder().decode([HivePeer].self, from: Data("[\(peers.joined(separator: ","))]".utf8))
        return HiveLink(hive: hive, credential: "hivedev_abc", deviceID: "dev-1", deviceName: "iPhone", actor: "tom-cm1",
                        peers: peers, errors: [], expiresAt: nil, renewedAt: renewedAt)
    }

    /// Waits for `done`, a few seconds at most.
    private func until(_ done: () -> Bool) async {
        for _ in 0..<100 where !done() { try? await Task.sleep(for: .milliseconds(50)) }
    }

    @MainActor final class Recorder: StadeumHost {
        var calls: [String] = []
        func stadeum(willKeep link: HiveLink, replacing kept: HiveLink?) throws { calls.append("willKeep \(link.actor)") }
        func stadeum(kept link: HiveLink, changed: Bool) { calls.append("kept changed=\(changed)") }
        func stadeumRevoked() { calls.append("revoked") }
        func stadeumDisconnected(actor: String?) throws { calls.append("disconnected \(actor ?? "nil")") }
    }

    @Test func aPairingIsKeptWithTheAccountAndTheHostIsTold() async throws {
        let hive = try await hive(interval: 1) {
            (200, #"{"credential":"hivedev_abc","device":{"id":"dev-1"},"actor":"tom-cm1","peers":[\#(Self.peer("acme", "Acme"))]}"#)
        }
        defer { hive.stop() }
        let profile = try profile()
        let host = Recorder()
        let stadeum = Stadeum()
        stadeum.client = { _ in HiveClient(hive: URL(string: "http://127.0.0.1:\(hive.port)")!) }
        stadeum.host = host
        stadeum.open(profile)
        #expect(stadeum.status == .off)
        stadeum.connect(as: "iPhone")
        await until { stadeum.status == .connected }
        #expect(stadeum.status == .connected && stadeum.live.map(\.id) == ["acme"])
        #expect(host.calls == ["willKeep tom-cm1", "kept changed=true"])
        // Kept with the account: opened again, it is there.
        let again = Stadeum()
        again.open(profile)
        #expect(again.link?.credential == "hivedev_abc" && again.status == .connected)
        again.close()
        stadeum.close()
    }

    /// A stand-in Hive whose code lasts `expiresIn` and is polled every
    /// `interval`, answering each poll with `token`.
    private func hive(interval: Int, expiresIn: Int = 600, token: @escaping @Sendable () -> (Int, String)) async throws -> HTTPStub {
        try await HTTPStub { port, request in
            if request.hasPrefix("POST /api/strut-devices/pair/token") { return token() }
            if request.hasPrefix("POST /api/strut-devices/pair") {
                return (200, #"{"deviceCode":"dc","userCode":"BCDF-GHJK","verificationUri":"http://127.0.0.1:\#(port)/pair","verificationUriComplete":"http://127.0.0.1:\#(port)/pair?code=BCDF-GHJK","expiresIn":\#(expiresIn),"interval":\#(interval)}"#)
            }
            return (404, "{}")
        }
    }

    /// Back in front (from Safari, where the person approved it), a pairing
    /// polls Hive at once rather than at its next interval.
    @Test func comingBackToTheFrontPollsHiveAtOnce() async throws {
        let hive = try await hive(interval: 600) {
            (200, #"{"credential":"hivedev_abc","device":{"id":"dev-1"},"actor":"tom-cm1","peers":[\#(Self.peer("acme", "Acme"))]}"#)
        }
        defer { hive.stop() }
        let stadeum = Stadeum()
        stadeum.client = { _ in HiveClient(hive: URL(string: "http://127.0.0.1:\(hive.port)")!) }
        stadeum.open(try profile())
        stadeum.connect(as: "iPhone")
        await until { if case .pairing = stadeum.status { true } else { false } }
        stadeum.cameToFront()
        await until { stadeum.status == .connected }
        #expect(stadeum.live.map(\.id) == ["acme"] && hive.requests.count == 2)
        stadeum.close()
    }

    /// A code Hive no longer has is said for what it is: run out (approved
    /// or not, Peel was not back in time to collect it), or gone sooner.
    @Test(arguments: [
        // Polled after its one second: run out.
        (1, false, "The code ran out before pairing finished. Connect again, then approve it in Stadeum and come back to Peel within 1 minute."),
        // Polled at once, back in front, with ten minutes left: gone sooner.
        (600, true, "Stadeum no longer has this code, so pairing didn't finish. Connect again."),
    ])
    func aCodeHiveNoLongerHasIsSaidForWhatItIs(expiresIn: Int, front: Bool, said: String) async throws {
        let hive = try await hive(interval: 1, expiresIn: expiresIn) { (400, #"{"error":"expired_token"}"#) }
        defer { hive.stop() }
        let stadeum = Stadeum()
        stadeum.client = { _ in HiveClient(hive: URL(string: "http://127.0.0.1:\(hive.port)")!) }
        stadeum.open(try profile())
        stadeum.connect(as: "iPhone")
        await until { if case .pairing = stadeum.status { true } else { false } }
        if front { stadeum.cameToFront() }
        await until { stadeum.problem != nil }
        #expect(stadeum.status == .off && stadeum.problem == said)
        stadeum.close()
    }

    @Test func aRevokedDeviceKeepsItsOrgsListedButUsesNone() async throws {
        let asked = Mutex(0)
        let hive = try await HTTPStub { _, _ in
            asked.withLock { $0 += 1 }
            return (401, #"{"error":"Unauthorized"}"#)
        }
        defer { hive.stop() }
        let profile = try profile()
        // Due: a day since it was last renewed.
        try link(hive: URL(string: "http://127.0.0.1:\(hive.port)")!, peers: [Self.peer("acme", "Acme")],
                 renewedAt: Date(timeIntervalSinceNow: -2 * 24 * 3600)).write(to: profile.hive)
        let host = Recorder()
        let stadeum = Stadeum()
        stadeum.host = host
        stadeum.open(profile)
        await until { stadeum.revoked }
        #expect(stadeum.status == .needsPairing && stadeum.live.isEmpty && stadeum.link?.peers.count == 1)
        #expect(host.calls == ["revoked"])
        let file = try #require(AgentArtifact.Handle(path: "/peers/acme/jobs/j-1/files/plan.md"))
        #expect(stadeum.opening(file) == .connectFirst)
        // Kept with the link: opened again (an unlock, a restart), still revoked, and Hive not asked again.
        stadeum.close()
        let again = Stadeum()
        again.open(profile)
        #expect(again.revoked && again.status == .needsPairing && again.live.isEmpty)
        again.renewIfDue()
        try await Task.sleep(for: .milliseconds(200))
        #expect(asked.withLock { $0 } == 1)
        again.close()
    }

    @Test func closingTheAccountLetsGoOfEverythingButThePersonsOwnApps() async throws {
        let profile = try profile()
        try link(hive: URL(string: "http://127.0.0.1:9")!, peers: [Self.peer("acme", "Acme")]).write(to: profile.hive)
        let stadeum = Stadeum()
        stadeum.open(profile)
        stadeum.apps = [WorkspaceApp(peer: nil, name: "mine", title: "Mine", about: nil),
                        WorkspaceApp(peer: "acme", name: "board", title: "Board", about: nil)]
        stadeum.close()
        #expect(stadeum.status == .off && stadeum.link == nil && stadeum.live.isEmpty)
        #expect(stadeum.apps.map(\.name) == ["mine"])
    }

    @Test func somethingOpensOnItsOrgsOwnStrutOrSaysWhyNot() async throws {
        let profile = try profile()
        let stadeum = Stadeum()
        let file = try #require(AgentArtifact.Handle(path: "/peers/acme/jobs/peer%2Fj-1/files/plan.md"))
        #expect(stadeum.opening(file) == .connectFirst)
        try link(hive: URL(string: "http://127.0.0.1:9")!, peers: [Self.peer("acme", "Acme")]).write(to: profile.hive)
        stadeum.open(profile)
        guard case .page(let page) = stadeum.opening(file) else {
            Issue.record("no page")
            return
        }
        #expect(page.url.absoluteString == "https://acme.sphinx.chat:3355/lab/?artifact=%2Fjobs%2Fpeer%252Fj-1%2Ffiles%2Fplan.md&solo=1")
        #expect(page.token == "jwt-acme" && page.peer == "acme" && page.workspace == "Acme")
        // Never described with its token.
        #expect(!"\(page)".contains("jwt") && !String(reflecting: page).contains("jwt") && !"\(Mirror(reflecting: page).children.map(\.value))".contains("jwt"))
        let app = WorkspaceApp(peer: "acme", name: "hive/board", title: "Board", about: nil)
        guard case .page(let appPage) = stadeum.opening(app) else {
            Issue.record("no app page")
            return
        }
        #expect(appPage.url.absoluteString == "https://acme.sphinx.chat:3355/lab/?app=hive%2Fboard&solo=1")
        // Titled by the app's own, or the artifact's the caller names; the token still hidden.
        #expect(appPage.title == "Board" && page.title == nil)
        guard case .page(let titled) = stadeum.opening(file, title: "Plan") else {
            Issue.record("no titled page")
            return
        }
        #expect(titled.title == "Plan" && titled.workspace == "Acme")
        #expect(!"\(titled)".contains("jwt") && !"\(titled)".contains("Plan") && !String(reflecting: titled).contains("jwt"))
        #expect(stadeum.opening(try #require(AgentArtifact.Handle(path: "/peers/globex/jobs/j/files/a.md"))) == .notPaired("globex"))
        #expect(stadeum.opening(try #require(AgentArtifact.Handle(path: "/jobs/j/files/a.md"))) == .onMac)
        #expect(stadeum.opening(WorkspaceApp(peer: nil, name: "mine", title: "Mine", about: nil)) == .onMac)
        stadeum.close()
    }

    @Test func theWorkspacesAppsAreReadAtOnceAndOneThatCannotBeKeepsItsLast() async throws {
        let profile = try profile()
        try link(hive: URL(string: "http://127.0.0.1:9")!, peers: [Self.peer("acme", "Acme"), Self.peer("globex", "Globex")])
            .write(to: profile.hive)
        let stadeum = Stadeum()
        stadeum.open(profile)
        stadeum.apps = [WorkspaceApp(peer: "globex", name: "old", title: "Old", about: nil)]
        await stadeum.readApps(own: nil, pinned: { peer in
            guard peer.id == "acme" else { throw PeelError("unreachable") }
            return [WorkspaceApp(peer: "acme", name: "zeta", title: "Zeta", about: nil),
                    WorkspaceApp(peer: "acme", name: "alpha", title: "Alpha", about: nil)]
        })?.value
        #expect(stadeum.apps.map(\.id) == ["@acme/alpha", "@globex/old", "@acme/zeta"])
        #expect(!stadeum.readingApps && stadeum.unreadApps == ["globex"])
        #expect(stadeum.apps.first?.caption(showsSource: true) == "@acme" && stadeum.apps.first?.matches("acme") == true)
        stadeum.close()
    }

    @Test(arguments: [
        ("https://acme.sphinx.chat/lab/?app=x&solo=1", "https://acme.sphinx.chat", "/lab/"),
        ("https://ACME.sphinx.chat:443/lab/?app=x&solo=1", "https://acme.sphinx.chat", "/lab/"),
        ("http://127.0.0.1:3417/?app=x&solo=1", "http://127.0.0.1:3417", "/"),
    ])
    func aPageKeepsToItsStrutsFolder(page: String, origin: String, folder: String) {
        let request = OrgPageRequest(url: URL(string: page)!, token: "t\"</script>", peer: "acme", workspace: "Acme")
        #expect(request.origin == origin && request.folder == folder)
        #expect(request.serves(URL(string: origin + folder + "jobs/j/files/a.md?t=1")!))
        #expect(!request.serves(URL(string: "https://evil.example" + folder)!))
        if folder != "/" { #expect(!request.serves(URL(string: origin + "/other/")!)) }
        #expect(request.request.value(forHTTPHeaderField: "Authorization") == "Bearer t\"</script>")
        #expect(request.request.url == request.url && !request.url.absoluteString.contains("script"))
        // The token rides as a JSON literal, checked against the origin and the folder before it is set.
        #expect(request.handOver.contains(#"["\#(origin)","\#(folder)","t\"</script>"]"#))
        #expect(request.handOver.contains("location.origin === origin && location.pathname.startsWith(folder)"))
    }
}
