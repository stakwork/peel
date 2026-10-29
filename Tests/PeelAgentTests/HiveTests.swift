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

    static func pairing(_ port: UInt16, page: String? = nil, code: String = "dc-secret") -> String {
        let page = page ?? "http://127.0.0.1:\(port)/pair?code=BCDF-GHJK"
        return #"{"deviceCode":"\#(code)","userCode":"BCDF-GHJK","verificationUri":"http://127.0.0.1:\#(port)/pair","verificationUriComplete":"\#(page)","expiresIn":600,"interval":5}"#
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

    /// A poll Hive does not answer (a 5xx) is tried again until the code runs
    /// out, then said in Hive's words; a refusal ends it at once.
    @Test func aPollHiveDoesNotAnswerIsTriedAgainUntilTheCodeRunsOut() async throws {
        let polls = Mutex(0)
        let hive = try await HTTPStub { _, request in
            if request.contains("dc-refused") { return (404, #"{"error":"Not found"}"#) }
            if request.contains("dc-down") { return (503, #"{"error":"Failed to complete pairing"}"#) }
            return polls.withLock { $0 += 1; return $0 } < 3 ? (500, #"{"error":"Failed to complete pairing"}"#) : (200, Self.paired)
        }
        defer { hive.stop() }
        let client = HiveClient(hive: URL(string: "http://127.0.0.1:\(hive.port)")!)
        let pairing = try JSONDecoder().decode(HiveClient.Pairing.self, from: Data(Self.pairing(hive.port).utf8))
        let later = Date(timeIntervalSinceNow: 600)
        guard case .paired(let link) = try await client.answer(to: pairing, name: "iPhone", until: later, wait: { _ in }) else {
            Issue.record("not paired")
            return
        }
        #expect(link.credential == "hivedev_abc" && polls.withLock { $0 } == 3)

        // Each polled once: past its end, a 5xx is said; a refusal ends it however long is left.
        for (code, deadline, said) in [("dc-down", Date(), "Stadeum could not pair: Failed to complete pairing."),
                                       ("dc-refused", later, "Stadeum could not pair: Not found.")] {
            let waits = Mutex(0)
            let pairing = try JSONDecoder().decode(HiveClient.Pairing.self, from: Data(Self.pairing(hive.port, code: code).utf8))
            let error = try await #require(throws: PeelError.self) {
                try await client.answer(to: pairing, name: "iPhone", until: deadline, wait: { _ in waits.withLock { $0 += 1 } })
            }
            #expect(PeelError.problem(error) == said && waits.withLock { $0 } == 1)
        }
    }

    /// A poll that reaches no one (on the iPhone, a connection the system
    /// dropped while Peel was away in Safari) is tried again until the code
    /// runs out.
    @Test func aPollThatReachesNoOneIsTriedAgainUntilTheCodeRunsOut() async throws {
        // A privileged port no test can listen on: refused.
        let client = HiveClient(hive: URL(string: "http://127.0.0.1:1")!)
        let pairing = try JSONDecoder().decode(HiveClient.Pairing.self, from: Data(Self.pairing(1).utf8))
        // Time left: asked again and again, in a task of its own the third wait cancels.
        let waits = Mutex(0)
        let asking = Task {
            try await client.answer(to: pairing, name: "iPhone", until: Date(timeIntervalSinceNow: 600)) { _ in
                if waits.withLock({ $0 += 1; return $0 }) == 3 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        await #expect(throws: CancellationError.self) { try await asking.value }
        #expect(waits.withLock { $0 } == 3)
        // None left: said after the one try.
        let once = Mutex(0)
        await #expect(throws: URLError.self) {
            try await client.answer(to: pairing, name: "iPhone", until: Date()) { _ in once.withLock { $0 += 1 } }
        }
        #expect(once.withLock { $0 } == 1)
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

    /// A call with Jamie in it: asked of Hive with the device credential
    /// for one workspace, its link answered (docs/hive-calls.md).
    @Test func aCallWithJamieIsAskedOfHiveForOneWorkspace() async throws {
        let room = "https://chat.sphinx.chat/rooms/sphinx.call.-acme-hive.sphinx.chat-.1792900000"
        let hive = try await HTTPStub { _, request in
            guard path(request) == "/api/strut-devices/calls", request.contains("Authorization: Bearer hivedev_abc") else {
                return (404, "{}")
            }
            return (200, #"{"url":"\#(room)"}"#)
        }
        defer { hive.stop() }
        let link = try Self.link(hive: URL(string: "http://127.0.0.1:\(hive.port)")!)
        #expect(try await HiveClient(hive: link.hive).startCall(link, workspace: "acme-hive") == room)
        #expect(hive.requests[0].hasPrefix("POST ") && body(hive.requests[0]) == #"{"workspace":"acme-hive"}"#)
    }

    /// What Hive answers instead of a link, in words. A Hive from before the
    /// route answers its middleware's 401, as for a revoked device.
    @Test(arguments: [
        (404, #"{"error":"Workspace not found"}"#, "Stadeum could not start a call with Jamie: Workspace not found."),
        (403, #"{"error":"Access denied"}"#, "Stadeum could not start a call with Jamie: Access denied."),
        (502, #"{"error":"Could not start Jamie for the call"}"#,
         "Stadeum could not start a call with Jamie: Could not start Jamie for the call."),
        (401, #"{"error":"Unauthorized"}"#,
         "Stadeum didn't accept this device for a call. If it was disconnected in Stadeum, connect it again."),
        (200, #"{"link":"x"}"#, "Stadeum's call link could not be read."),
    ])
    func aCallHiveCannotMakeIsSaid(status: Int, answer: String, said: String) async throws {
        let hive = try await HTTPStub { _, _ in (status, answer) }
        defer { hive.stop() }
        let link = try Self.link(hive: URL(string: "http://127.0.0.1:\(hive.port)")!)
        await #expect {
            try await HiveClient(hive: link.hive).startCall(link, workspace: "acme-hive")
        } throws: { error in
            "\(error)" == said
        }
    }

    // MARK: Jamie in tribes (docs/hive-tribes.md)

    static let tribeKey = String(repeating: "ab", count: 33)
    static let jamieKey = String(repeating: "0c", count: 33)

    /// A tribe linked, listed and unlinked with the device credential, in
    /// the shapes stakwork/hive#5667 takes and answers. A link Peel could
    /// not use is left out of the list; one already gone is unlinked.
    @Test func aTribeIsLinkedListedAndUnlinkedWithTheDeviceCredential() async throws {
        let jamie = #"{"pubkey":"\#(Self.jamieKey.uppercased())","alias":"Jamie"}"#
        let linked = #"{"pubkey":"\#(Self.tribeKey)","host":"tribes.v2.sphinx.chat","name":"Builders","workspace":"acme-hive","org":"acme","createdAt":"2026-10-29T18:00:00.000Z"}"#
        let listed = linked.replacingOccurrences(of: Self.tribeKey, with: Self.tribeKey.uppercased())
        let hive = try await HTTPStub { _, request in
            guard request.contains("Authorization: Bearer hivedev_abc") else { return (401, #"{"error":"Unauthorized"}"#) }
            switch (request.split(separator: " ").first.map(String.init) ?? "", path(request)) {
            case ("GET", "/api/strut-devices/tribes"):
                let unusable = #"{"pubkey":"02","host":"x","workspace":"acme-hive"},{"pubkey":"\#(Self.jamieKey)","host":"x","workspace":"a/b"}"#
                return (200, #"{"jamie":\#(jamie),"tribes":[\#(listed),\#(unusable)]}"#)
            case ("POST", "/api/strut-devices/tribes"): return (200, #"{"jamie":\#(jamie),"tribe":\#(linked)}"#)
            case ("DELETE", "/api/strut-devices/tribes/\(Self.tribeKey)"): return (200, #"{"unlinked":true}"#)
            case ("DELETE", _): return (404, #"{"error":"Tribe not linked"}"#)
            default: return (404, "{}")
            }
        }
        defer { hive.stop() }
        let link = try Self.link(hive: URL(string: "http://127.0.0.1:\(hive.port)")!)
        let client = HiveClient(hive: link.hive)

        let links = try await client.jamieLinks(link)
        #expect(links.jamie == JamieAccount(pubkey: Self.jamieKey, alias: "Jamie"))
        #expect(links.tribes == [JamieLink(pubkey: Self.tribeKey, host: "tribes.v2.sphinx.chat", name: "Builders",
                                           workspace: "acme-hive", org: "acme")])

        let (answered, tribe) = try await client.linkTribe(link, workspace: "acme-hive", tribe: Self.tribeKey,
                                                           host: "tribes.v2.sphinx.chat", name: "Builders")
        #expect(answered.pubkey == Self.jamieKey && tribe.workspace == "acme-hive")
        #expect(hive.requests[1].hasPrefix("POST ") && body(hive.requests[1])
            == #"{"tribe":{"host":"tribes.v2.sphinx.chat","name":"Builders","pubkey":"\#(Self.tribeKey)"},"workspace":"acme-hive"}"#)

        try await client.unlinkTribe(link, tribe: Self.tribeKey.uppercased())
        #expect(hive.requests[2].hasPrefix("DELETE /api/strut-devices/tribes/\(Self.tribeKey) "))
        // Unlinked from the person's other device already: done.
        try await client.unlinkTribe(link, tribe: Self.jamieKey)
        // Never a path built from something that is not a tribe's key.
        await #expect(throws: PeelError.self) { try await client.unlinkTribe(link, tribe: "../peers") }
        #expect(hive.requests.count == 4)
    }

    /// What Hive answers instead of a link, in words the owner can act on;
    /// an answer naming a key that is not one, or another tribe, is refused.
    @Test(arguments: [
        (503, #"{"error":"Jamie in tribes is not configured"}"#, "Jamie isn't switched on in Stadeum yet."),
        (409, #"{"error":"This tribe is linked to an org by someone else."}"#, "Someone else already linked this tribe to an org."),
        (403, #"{"error":"Access denied"}"#, "Stadeum could not add Jamie: Access denied."),
        (401, #"{"error":"Unauthorized"}"#,
         "Stadeum didn't accept this device for Jamie. If it was disconnected in Stadeum, connect it again."),
        (200, #"{"jamie":{"pubkey":"02ab","alias":"Jamie"},"tribe":{"pubkey":"\#(HiveTests.tribeKey)","host":"h","workspace":"acme-hive"}}"#,
         "Stadeum's answer about Jamie could not be read."),
        (200, #"{"jamie":{"pubkey":"\#(HiveTests.jamieKey)","alias":"Jamie"},"tribe":{"pubkey":"\#(HiveTests.jamieKey)","host":"h","workspace":"acme-hive"}}"#,
         "Stadeum's answer about Jamie could not be read."),
    ])
    func aLinkHiveRefusesIsSaid(status: Int, answer: String, said: String) async throws {
        let hive = try await HTTPStub { _, _ in (status, answer) }
        defer { hive.stop() }
        let link = try Self.link(hive: URL(string: "http://127.0.0.1:\(hive.port)")!)
        await #expect {
            try await HiveClient(hive: link.hive).linkTribe(link, workspace: "acme-hive", tribe: Self.tribeKey, host: "h", name: nil)
        } throws: { error in
            "\(error)" == said
        }
    }

    /// Who a call brings Jamie from: the pick in that chat while the org is
    /// paired, else the tribe's own swarm, else none.
    @Test func aCallBringsJamieFromThePickElseTheTribesSwarm() throws {
        let peers = try ["acme-hive", "globex"].map {
            try JSONDecoder.hive.decode(HivePeer.self, from: Data(Self.peer($0, $0.capitalized).utf8))
        }
        let tribe = "https://globex.sphinx.chat/app"
        #expect(HivePeer.jamie(picked: "acme-hive", pages: [tribe], in: peers)?.id == "acme-hive")
        #expect(HivePeer.jamie(picked: "", pages: [tribe], in: peers) == nil)
        #expect(HivePeer.jamie(picked: "initech", pages: [tribe], in: peers) == nil)
        #expect(HivePeer.jamie(picked: nil, pages: [tribe, nil], in: peers)?.id == "globex")
        #expect(HivePeer.jamie(picked: nil, pages: [nil, "https://ACME-HIVE.sphinx.chat"], in: peers)?.id == "acme-hive")
        #expect(HivePeer.jamie(picked: nil, pages: ["https://initech.sphinx.chat", "https://localhost/x", "x"], in: peers) == nil)
        #expect(HivePeer.jamie(picked: nil, pages: [], in: []) == nil)
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
        // Another version, previewed: `name@vN`, as strut's UI reads it.
        let preview = try #require(server.page(of: apps[1], version: "v9"))
        #expect(URLComponents(url: preview, resolvingAgainstBaseURL: false)?.percentEncodedQuery
                == "key=k&app=tools%2Fboard%40v9&solo=1")
    }

    /// An app's versions are read, and what is live changed, on Peel's own
    /// strut with its key, the app's `/` escaped so it stays one segment.
    @Test func yourOwnAppsVersionsAreReadAndMadeLiveByName() async throws {
        let strut = try await HTTPStub { _, request in
            guard request.contains("Authorization: Bearer k") else { return (401, "{}") }
            switch (request.split(separator: " ").first.map(String.init), path(request)) {
            case ("GET", "/apps/tools%2Fboard/versions"):
                return (200, #"{"active":"v7","live":"r3","versions":{"v7":{},"v9":{}},"releases":[],"behind":[]}"#)
            case ("PUT", "/apps/tools%2Fboard/active"):
                return (200, #"{"ok":true,"name":"tools/board","active":"v9","live":"r4"}"#)
            default:
                return (404, #"{"error":"no such route"}"#)
            }
        }
        defer { strut.stop() }
        let client = AutomationsClient(server: try #require(MemoryServer(base: URL(string: "http://127.0.0.1:\(strut.port)")!, key: "k")))
        let versions = try await client.versions(of: "tools/board")
        #expect(versions.newestWaiting == "v9")
        try await client.makeLive("tools/board", .version("v9"))
        let sent = try #require(strut.requests.last)
        #expect(sent.hasPrefix("PUT ") && sent.hasSuffix(#"{"version":"v9"}"#))
    }

    /// A deliverable from the agent's DM opens as an app does, strut's UI
    /// showing it alone: a file's path as `artifact`, an escape in it kept
    /// an escape once strut's UI decodes it, an app's as `app`.
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
    }

    /// A page's link to another app (strut's page alone hands one to its
    /// host) is read on Peel's own strut only, a workspace's bare name as
    /// that workspace's, and opens alone there at the view it names.
    @Test func aPagesLinkToAnotherAppOpensAloneOnPeelsOwnStrut() throws {
        let server = try #require(MemoryServer(base: URL(string: "http://127.0.0.1:4100")!, key: "k+1"))
        let link = try #require(server.appLink(URL(string: "http://127.0.0.1:4100/?app=board&input=view%3D%252Fruns")!, from: "acme"))
        #expect(link == StrutAppLink(app: .app("@acme/board"), input: "view=%2Fruns"))
        let page = try #require(server.page(showing: link.app, input: link.input))
        #expect(URLComponents(url: page, resolvingAgainstBaseURL: false)?.percentEncodedQuery
                == "key=k%2B1&app=%40acme%2Fboard&input=view%3D%252Fruns&solo=1")
        // Another strut's address is not this one's link.
        #expect(server.appLink(URL(string: "http://127.0.0.1:4101/?app=board")!, from: nil) == nil)
        // A file's page shows no app, so a link in it (an org's words) opens none.
        let report = try #require(AgentArtifact.Handle(path: "/peers/acme/jobs/j-1/files/r.md"))
        let file = try #require(server.page(showing: report))
        #expect(server.appLink(file, from: nil) == nil)
        // strut's UI (a run's link, which opens nowhere) is not a file it serves (which a click saves).
        #expect(server.servesPage(URL(string: "http://127.0.0.1:4100/?wf=clip&run=1")!))
        #expect(!server.servesPage(URL(string: "http://127.0.0.1:4100/jobs/j-1/files/a.pdf?t=1")!))
    }

    static func link(hive: URL) throws -> HiveLink {
        let peers = try JSONDecoder().decode([HivePeer].self, from: Data("[\(peer("acme-hive", "Acme"))]".utf8))
        return HiveLink(hive: hive, credential: "hivedev_abc", deviceID: "dev-1", deviceName: "Mac", actor: "tom-cm1",
                        peers: peers, errors: [], expiresAt: Date(timeIntervalSince1970: 1_793_000_000),
                        renewedAt: Date(timeIntervalSince1970: 1_792_800_000))
    }
}
