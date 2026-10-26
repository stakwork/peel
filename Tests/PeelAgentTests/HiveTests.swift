import AgentKit
import Foundation
import Synchronization
import Testing
@testable import PeelAgent
@testable import PeelCore
@testable import PeelTestSupport

/// Hive's device flow for a strut desktop app (stakwork/hive#5602), against a
/// stand-in Hive answering as that PR documents and its integration test
/// records: start, poll until approved, collect once, renew daily, revoked.
struct HiveTests {
    /// A peer record as Hive gives one: strut's `PUT /peers/:id` body and its id.
    static func peer(_ id: String, _ label: String) -> String {
        #"{"id":"\#(id)","baseUrl":"https://\#(id).sphinx.chat:3355/lab","token":"jwt-\#(id)","label":"\#(label)","description":"\#(label) on Hive. Workspaces: \#(id).","repos":["https://github.com/acme/\#(id)"]}"#
    }

    static func pairing(_ port: UInt16, page: String? = nil) -> String {
        let page = page ?? "http://127.0.0.1:\(port)/pair?code=BCDF-GHJK"
        return #"{"deviceCode":"dc-secret","userCode":"BCDF-GHJK","verificationUri":"http://127.0.0.1:\#(port)/pair","verificationUriComplete":"\#(page)","expiresIn":600,"interval":5}"#
    }

    static let paired = #"""
        {"credential":"hivedev_abc","device":{"id":"dev-1","name":"Tom's Mac"},"actor":"tom-cm1","peers":[\#(peer("acme-hive", "Acme"))],
         "expiresAt":"2026-10-29T10:00:00.000Z","errors":[{"org":"globex","error":"swarm unreachable"}]}
        """#

    private func path(_ request: String) -> String {
        String(request.split(separator: " ").dropFirst().first ?? "")
    }

    private func body(_ request: String) -> String {
        String(request[(request.range(of: "\r\n\r\n")?.upperBound ?? request.endIndex)...])
    }

    @Test func aPairingIsApprovedInHiveAndCollectedOnce() async throws {
        let polls = Mutex(0)
        let hive = try await HTTPStub { port, request in
            switch path(request) {
            case "/api/strut-devices/pair": return (200, Self.pairing(port))
            case "/api/strut-devices/pair/token":
                return polls.withLock { $0 += 1; return $0 } == 1 ? (400, #"{"error":"authorization_pending"}"#) : (200, Self.paired)
            default: return (404, "{}")
            }
        }
        defer { hive.stop() }
        let client = HiveClient(hive: URL(string: "http://127.0.0.1:\(hive.port)")!)
        let pairing = try await client.start(name: "Tom's Mac")
        #expect(pairing.userCode == "BCDF-GHJK" && pairing.interval == 5)
        #expect(body(hive.requests[0]) == #"{"name":"Tom's Mac"}"# && hive.requests[0].hasPrefix("POST "))

        #expect(try await client.poll(pairing, name: "Tom's Mac") == .pending)
        let now = Date(timeIntervalSince1970: 1_792_800_000)
        guard case .paired(let link) = try await client.poll(pairing, name: "Tom's Mac", now: now) else {
            Issue.record("not paired")
            return
        }
        #expect(body(hive.requests[1]) == #"{"deviceCode":"dc-secret"}"#)
        #expect(link.credential == "hivedev_abc" && link.actor == "tom-cm1" && link.deviceID == "dev-1" && link.renewedAt == now)
        #expect(link.peers.map(\.id) == ["acme-hive"] && link.peers.first?.name == "Acme" && link.peers.first?.token == "jwt-acme-hive")
        #expect(link.errors.map { "\($0.name): \($0.reason)" } == ["globex: swarm unreachable"])
        #expect(link.expiresAt == ISO8601DateFormatter().date(from: "2026-10-29T10:00:00Z"))
    }

    @Test(arguments: [("access_denied", HiveClient.Poll.denied), ("expired_token", .expired)])
    func aDenialOrAnExpiryEndsThePairing(error: String, poll: HiveClient.Poll) async throws {
        let hive = try await HTTPStub { _, _ in (400, #"{"error":"\#(error)"}"#) }
        defer { hive.stop() }
        let client = HiveClient(hive: URL(string: "http://127.0.0.1:\(hive.port)")!)
        let pairing = try JSONDecoder().decode(HiveClient.Pairing.self, from: Data(Self.pairing(hive.port).utf8))
        #expect(try await client.poll(pairing, name: "Mac") == poll)
    }

    /// Only Hive's own page is shown or opened, and only an account Peel can name is kept.
    @Test(arguments: [
        (pairing: "https://evil.example/pair?code=X", paired: nil),
        (pairing: nil, paired: Self.paired.replacingOccurrences(of: "\"tom-cm1\"", with: "\"tom/evil\"")),
        (pairing: nil, paired: Self.paired.replacingOccurrences(of: "hivedev_abc", with: "not-a-device")),
    ] as [(pairing: String?, paired: String?)])
    func whatHiveCannotStandBehindIsRefused(pairing page: String?, paired: String?) async throws {
        let hive = try await HTTPStub { port, request in
            path(request) == "/api/strut-devices/pair" ? (200, Self.pairing(port, page: page)) : (200, paired ?? Self.paired)
        }
        defer { hive.stop() }
        let client = HiveClient(hive: URL(string: "http://127.0.0.1:\(hive.port)")!)
        if page != nil {
            await #expect(throws: PeelError.self) { try await client.start(name: "Mac") }
        } else {
            let pairing = try await client.start(name: "Mac")
            await #expect(throws: PeelError.self) { try await client.poll(pairing, name: "Mac") }
        }
    }

    @Test func renewalReplacesTheOrgsAndARevokedDeviceIsToldToPairAgain() async throws {
        let revoked = Mutex(false)
        let hive = try await HTTPStub { _, request in
            guard path(request) == "/api/strut-devices/peers", request.contains("Authorization: Bearer hivedev_abc") else { return (404, "{}") }
            return !revoked.withLock { $0 }
                ? (200, #"{"actor":"tom-cm2","peers":[\#(Self.peer("acme-hive", "Acme")),\#(Self.peer("globex", "Globex"))],"expiresAt":"2026-11-05T10:00:00Z","errors":[]}"#)
                : (401, #"{"error":"unauthorized"}"#)
        }
        defer { hive.stop() }
        let link = try Self.link(hive: URL(string: "http://127.0.0.1:\(hive.port)")!)
        let now = Date(timeIntervalSince1970: 1_792_900_000)
        let renewed = try #require(try await HiveClient(hive: link.hive).renew(link, now: now))
        #expect(renewed.peers.map(\.id) == ["acme-hive", "globex"] && renewed.actor == "tom-cm2" && renewed.errors.isEmpty)
        #expect(renewed.credential == link.credential && renewed.renewedAt == now)
        revoked.withLock { $0 = true }
        #expect(try await HiveClient(hive: link.hive).renew(link) == nil)
    }

    @Test func theLinkIsKeptWholeAndRenewedDaily() throws {
        let file = FileItem(file: FileManager.default.temporaryDirectory.appending(path: "peel-hive-\(UUID().uuidString)"))
        defer { try? file.delete() }
        #expect(try HiveLink.read(from: file) == nil)
        let link = try Self.link(hive: HiveClient.production)
        try link.write(to: file)
        #expect(try HiveLink.read(from: file) == link)
        let renewed = link.renewedAt
        #expect(!link.due(at: renewed.addingTimeInterval(3600)) && link.due(at: renewed.addingTimeInterval(HiveClient.renewEvery)))
        var expiring = link
        expiring.expiresAt = renewed.addingTimeInterval(7200)
        #expect(expiring.due(at: renewed.addingTimeInterval(60)))
    }

    /// The card for a call to an org: worded from strut's record and showing
    /// all it sends; another workflow there gets no "Always allow"; one that
    /// cannot be read, or holds more than the card shows, is refused with no
    /// card; another step's proposal is asked as before.
    @Test func aCallToAnOrgIsWordedFromStrutsRecordOrRefused() async throws {
        let profile = TempProfile()
        let storage = try registeredStorage(profile, contact: keyG, Storage.Commit())
        let rules = ApprovalRules(store: try SQLiteAgentStore.inMemory(device: "mac"))
        let cards = DeviceActionsTests.Cards()
        try await withTestEngine(storage, on: Transport(publishing: { _, _ in })) { engine in
            let actions = DeviceActions(engine: engine, rules: rules, peerRequest: { id in
                switch id {
                case "triage": return PeerRequest(peer: "acme", name: "Acme", workflow: "triage", prompt: "Look at bug 12")
                case "more": return PeerRequest(peer: "acme", name: "Acme", workflow: "orchestrator", prompt: "Hi", more: true)
                case "gone": throw PeelError("strut's proposal is no longer waiting.")
                default: return nil
                }
            }) { _, approval in await cards.ask(approval) }
            func approve(_ id: String) async -> DeviceAnswer? {
                await actions.answer(DeviceRequest(agent: "02a", id: id, kind: "approve",
                                                   args: .object(["intent": .object(["action": .string("Run strut/run-workflow")])]),
                                                   deadline: Date().addingTimeInterval(3600)))
            }
            cards.reply = .some(.deny)
            #expect(await approve("proposal:triage")?.status == .denied)
            let card = try #require(cards.asked.first)
            #expect(card.action == "Send this to Acme?" && card.content == "Look at bug 12" && !card.mayBeAlwaysAllowed)
            #expect(card.details.last == "Runs its workflow \u{201C}triage\u{201D}")
            let kept = try rules.all()
            #expect(kept.isEmpty)
            // Unreadable, or more than it can show: refused, no card.
            for id in ["proposal:gone", "proposal:more"] {
                #expect(await approve(id)?.status == .failed, "\(id)")
            }
            #expect(cards.asked.count == 1)
            // Another step's proposal: the bridge's words, as before.
            cards.reply = .some(.allowOnce)
            #expect(await approve("proposal:other")?.status == .done)
            #expect(cards.asked.last?.action == "Run strut/run-workflow" && cards.asked.last?.target == nil)
        }
    }

    /// A peer's token goes only to https off this Mac: any other address
    /// becomes that org's error, never a record on strut.
    @Test func aPeerAtAnAddressPeelWouldNotSendATokenToIsRefused() {
        let peers = ["https://acme.sphinx.chat/lab", "http://acme.sphinx.chat/lab", "https://127.0.0.1:3355/lab", "https://u:p@acme.example/lab"]
            .enumerated().map { HivePeer(id: "p\($0.offset)", baseUrl: $0.element, token: "t") }
        let (kept, refused) = HiveClient(hive: HiveClient.production).reachable(peers)
        #expect(kept.map(\.id) == ["p0"] && refused.map(\.org) == ["p1", "p2", "p3"])
        // A test Hive on this Mac may name a test strut on this Mac.
        #expect(HiveClient(hive: URL(string: "http://127.0.0.1:9")!).reachable([HivePeer(id: "l", baseUrl: "http://127.0.0.1:4000", token: "t")]).peers.count == 1)
        // An id that is not one path segment, or one given twice, is refused too, so the rest still sync.
        let odd = ["acme", "../x", "acme"].map { HivePeer(id: $0, baseUrl: "https://acme.sphinx.chat/lab", token: "t") }
        let (once, twice) = HiveClient(hive: HiveClient.production).reachable(odd)
        #expect(once.map(\.id) == ["acme"] && twice.map(\.org) == ["../x", "acme"])
    }

    /// The card shows the message only, so a call that also carries a
    /// version, params or a job there, or input beyond the message and its
    /// thread, is marked as holding more (and refused by `DeviceActions`).
    @Test(arguments: [
        (#"{"peer":"acme","workflow":"orchestrator","input":{"prompt":"Hi","session":"tom-cm1/peel/agent-1/dm"},"room":true,"wait":true}"#, false),
        (#"{"peer":"acme","workflow":"orchestrator","input":{"prompt":"Hi"},"version":"v1"}"#, true),
        (#"{"peer":"acme","workflow":"orchestrator","input":{"prompt":"Hi"},"params":{"system":"x"}}"#, true),
        (#"{"peer":"acme","workflow":"orchestrator","input":{"prompt":"Hi"},"job":"j-1"}"#, true),
        (#"{"peer":"acme","workflow":"orchestrator","input":{"prompt":"Hi","files":["/etc"]}}"#, true),
    ])
    func aCallHoldingMoreThanItsMessageIsMarked(input: String, more: Bool) async throws {
        let strut = try await HTTPStub { _, request in
            path(request).hasPrefix("/proposals/")
                ? (200, #"{"id":"p1","status":"pending","step":"strut/run-workflow","input":\#(input)}"#)
                : (200, #"{"peers":[{"id":"acme","label":"Acme"}]}"#)
        }
        defer { strut.stop() }
        let client = AutomationsClient(server: try #require(MemoryServer(base: URL(string: "http://127.0.0.1:\(strut.port)")!, key: "k")))
        let asked = try #require(try await client.peerRequest(proposal: "p1"))
        #expect(asked.name == "Acme" && asked.prompt == "Hi" && asked.more == more)
    }

    /// A workspace's apps come through Peel's own strut's read-through,
    /// with its key: only those pinned as tabs, under names strut gives,
    /// with their icon, version, held release and warnings when strut gives
    /// them as text (and a count), none otherwise. One opens as strut's UI showing that page
    /// alone, with the key, the app and `solo` encoded so strut's UI reads
    /// them back exactly; a home server opens none.
    @Test func aWorkspacesPinnedAppsAreListedAndOpenAloneOnPeelsOwnStrut() async throws {
        let strut = try await HTTPStub { _, request in
            guard path(request) == "/peers/acme/apps", request.contains("Authorization: Bearer k+1") else { return (404, "{}") }
            return (200, #"""
                {"apps":[{"name":"hive/board","title":"Board\n","pinned":true,"description":"The team's board",
                          "icon":"flask-conical","activeVersion":"v14","live":"r3","warnings":2},
                         {"name":"scratch","title":"Scratch"},
                         {"name":"x@v2","title":"Pinned to a version","pinned":true},
                         {"name":"plain","title":"","pinned":true,"icon":3,"activeVersion":" \n","live":null,"warnings":-1}]}
                """#)
        }
        defer { strut.stop() }
        let server = try #require(MemoryServer(base: URL(string: "http://127.0.0.1:\(strut.port)")!, key: "k+1"))
        let apps = try await AutomationsClient(server: server).pinnedApps(of: "acme")
        #expect(apps == [WorkspaceApp(peer: "acme", name: "hive/board", title: "Board", about: "The team's board",
                                      icon: "flask-conical", version: "v14", release: "r3", problems: 2),
                         WorkspaceApp(peer: "acme", name: "plain", title: "plain", about: nil)])
        let page = try #require(server.page(of: apps[0]))
        #expect(page.path == "/" && server.serves(page))
        // Encoded as strut's UI decodes it (`URLSearchParams`, where a bare `+` is a space).
        #expect(URLComponents(url: page, resolvingAgainstBaseURL: false)?.percentEncodedQuery
                == "key=k%2B1&app=%40acme%2Fhive%2Fboard&solo=1")
        let home = try #require(MemoryServer(base: URL(string: "http://127.0.0.1:\(strut.port)")!, key: "k", home: true))
        #expect(home.page(of: apps[0]) == nil)
    }

    /// The person's own apps come from Peel's strut itself, every one of
    /// them, pinned or not, but not the ones strut seeds for other apps to
    /// import; one opens by its name alone, with no workspace.
    @Test func yourOwnAppsAreAllListedAndOpenByName() async throws {
        let strut = try await HTTPStub { _, request in
            guard path(request) == "/apps", request.contains("Authorization: Bearer k") else { return (404, "{}") }
            return (200, #"""
                {"apps":[{"name":"meal-planner","title":"Meal planner","publisher":"ai"},{"name":"tools/board","title":"Board","pinned":true},
                         {"name":"strut/views","title":"strut views","publisher":"strut","pinned":true}]}
                """#)
        }
        defer { strut.stop() }
        let server = try #require(MemoryServer(base: URL(string: "http://127.0.0.1:\(strut.port)")!, key: "k"))
        let apps = try await AutomationsClient(server: server).ownApps()
        #expect(apps == [WorkspaceApp(peer: nil, name: "meal-planner", title: "Meal planner", about: nil),
                         WorkspaceApp(peer: nil, name: "tools/board", title: "Board", about: nil)])
        let page = try #require(server.page(of: apps[1]))
        #expect(URLComponents(url: page, resolvingAgainstBaseURL: false)?.percentEncodedQuery
                == "key=k&app=tools%2Fboard&solo=1")
    }

    /// A deliverable from the agent's DM opens as an app does, strut's UI
    /// showing it alone: a file's path as `artifact`, an escape in it kept
    /// an escape once strut's UI decodes it, an app's as `app`; a home
    /// server opens none.
    @Test func aDeliverableOpensAloneOnPeelsOwnStrut() throws {
        let server = try #require(MemoryServer(base: URL(string: "http://127.0.0.1:4100")!, key: "k+1"))
        let file = try #require(AgentArtifact.Handle(path: "/peers/acme/jobs/peer%2Fj-1/files/Lisbon%20plan.md"))
        let page = try #require(server.page(showing: file))
        #expect(page.path == "/" && server.serves(page))
        #expect(URLComponents(url: page, resolvingAgainstBaseURL: false)?.percentEncodedQuery
                == "key=k%2B1&artifact=%2Fpeers%2Facme%2Fjobs%2Fpeer%252Fj-1%2Ffiles%2FLisbon%2520plan.md&solo=1")
        let board = try #require(AgentArtifact.Handle(app: "@acme/hive/board"))
        let app = try #require(server.page(showing: board))
        #expect(URLComponents(url: app, resolvingAgainstBaseURL: false)?.percentEncodedQuery == "key=k%2B1&app=%40acme%2Fhive%2Fboard&solo=1")
        let home = try #require(MemoryServer(base: URL(string: "http://127.0.0.1:4100")!, key: "k", home: true))
        #expect(home.page(showing: file) == nil)
    }

    static func link(hive: URL) throws -> HiveLink {
        let peers = try JSONDecoder().decode([HivePeer].self, from: Data("[\(peer("acme-hive", "Acme"))]".utf8))
        return HiveLink(hive: hive, credential: "hivedev_abc", deviceID: "dev-1", deviceName: "Mac", actor: "tom-cm1",
                        peers: peers, errors: [], expiresAt: Date(timeIntervalSince1970: 1_793_000_000),
                        renewedAt: Date(timeIntervalSince1970: 1_792_800_000))
    }
}
