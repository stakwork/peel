import AgentKit
import Foundation
import Synchronization
import Testing
import PeelCore
@testable import PeelAgent
@testable import PeelTestSupport

/// Peel Home moving between this Mac and a home server (`PeelHomeMove`):
/// at every point a move can fail, at most one bridge with the agent's key
/// can run, and this Mac's runs again only when nothing can have reached the
/// box. Then the link the box shows, and the seam to strut's `move` run on a
/// stand-in for the bundled strut.
@MainActor
struct PeelHomeTests {
    static let link = HomeLink(URL(string: "peel://home-setup?host=192.168.1.20%3A8090&code=7KQ2M9XWBC4HD8RNTVFE")!)!

    // MARK: The box and this Mac, as the move sees them

    /// The home server: empty and waiting, or holding Peel Home (its bridge
    /// running) until it packs it to send back. `installing`: holding an
    /// upload while still saying "receive", as strut's serve does until its
    /// install ends (its bridge about to start).
    final class Box: @unchecked Sendable {
        enum State { case waiting, installing, holding, sendingBack, gone }
        var state = State.waiting
        var bridgeRuns: Bool { state == .holding || state == .installing }
        /// What happened, in order, on both sides: `sync`, `stop client`, `fetch`.
        var events: [String] = []
    }

    /// Where a fake move fails.
    enum Failure: Sendable { case none, check, refused, beforeArrival, whileInstalling, afterArrival, refusedAfterArrival }

    struct FakeMover: HomeMover {
        let box: Box
        var fails = Failure.none

        func check(_ link: HomeLink, _ parts: HomeParts) async throws -> HomeLink.Mode {
            switch box.state {
            case .waiting, .installing: return .receive
            case .sendingBack: return .sendBack
            // A box that took a move stops serving.
            case .holding, .gone: throw PeelError("could not reach 192.168.1.20:8090")
            }
        }

        func send(_ link: HomeLink, _ parts: HomeParts, callbacks: BundledBridge.Server?) async throws -> HomePeer? {
            if fails == .refused { throw HomeMoveRefused(description: "the move was refused: not a move") }
            if fails == .beforeArrival { throw PeelError("could not reach 192.168.1.20:8090") }
            if fails == .whileInstalling {
                box.state = .installing
                throw PeelError("the connection was lost")
            }
            box.state = .holding
            if fails == .afterArrival { throw PeelError("the connection was lost") }
            return PeelHomeTests.peer
        }

        func fetch(_ link: HomeLink, _ parts: HomeParts) async throws -> [String: String] {
            box.events.append("fetch")
            if fails == .beforeArrival { throw PeelError("the move could not be downloaded") }
            try FileManager.default.createDirectory(at: parts.strut.appending(path: "workspace"), withIntermediateDirectories: true)
            try Data("from the box".utf8).write(to: parts.strut.appending(path: "workspace/graph.lbug"))
            try FileManager.default.createDirectory(at: parts.bridge, withIntermediateDirectories: true)
            if fails == .refusedAfterArrival { throw PeelError("the other end did not take the confirmation") }
            box.state = .gone
            return ["STRUT_SECRET_KEY": String(repeating: "c", count: 64)]
        }
    }

    /// This Mac: its strut and bridge, and the brain kept in `Profile.brain`,
    /// which is what the next launch starts from.
    final class FakeLocal: PeelHomeLocal {
        let box: Box
        var kept = Brain.thisMac
        var running = true
        var failKeep = false
        var answers = true

        init(box: Box) { self.box = box }

        func keep(_ brain: Brain) throws {
            if failKeep { throw PeelError("the Keychain is locked") }
            kept = brain
        }

        func stopHome() async -> BundledBridge.Server? {
            running = false
            return nil
        }

        /// As the app does: nothing starts under a moved brain.
        func startHome() { running = kept == .thisMac }

        func pingAgent() async -> Bool { answers && (running || box.bridgeRuns) }

        /// The Mac's strut for dictation: no bridge, and as the app does, only under a moved brain.
        var clientRunning = false
        func startClient() { clientRunning = kept.moved != nil }
        func syncClient() async { if clientRunning { box.events.append("sync") } }
        /// What dictation changed in the client's strut that no push landed with,
        /// the `since` it was asked from, and what this Mac's own strut took in.
        var unpushed: AgentKit.JSONValue?
        var askedSince: AgentKit.JSONValue?
        var applied: [AgentKit.JSONValue] = []
        var applyFails = false
        func clientChanges(since: AgentKit.JSONValue?) async -> AgentKit.JSONValue? {
            guard clientRunning else { return nil }
            box.events.append("read changes")
            askedSince = since
            return unpushed
        }
        func applyChanges(_ changes: AgentKit.JSONValue) async -> Bool {
            box.events.append("apply")
            guard running, !applyFails else { return false }
            applied.append(changes)
            return true
        }
        func stopClient() {
            if clientRunning { box.events.append("stop client") }
            clientRunning = false
        }

        /// Whether strut opens what came back.
        var strutOpens = true
        func homeStarted() async -> Bool {
            if !strutOpens { running = false }
            return running
        }

        /// Never both; and what runs now is what the next launch would start.
        func expectOneBridge(_ comment: Comment? = nil) {
            #expect(!(running && box.bridgeRuns), comment)
            #expect(running == (kept == .thisMac), comment)
            // The client's strut, never beside Peel Home's own here.
            #expect(!(running && clientRunning), comment)
        }
    }

    /// Removed after each test.
    let temp = TempProfile()

    /// This Mac's folders for a move, in the test's own folder.
    func folders() throws -> HomeParts {
        let root = temp.url
        let parts = HomeParts(strut: root.appending(path: "Strut"), bridge: root.appending(path: "Bridge"),
                              secretKey: FileItem(file: root.appending(path: "strut-key")),
                              identity: ["BROKER_URL": "127.0.0.1:1883", "BRIDGE_DEVICE": "mac-3f2a"],
                              peerActor: "tom", homePeer: FileItem(file: root.appending(path: "home-peer")))
        try FileManager.default.createDirectory(at: parts.strut.appending(path: "workspace"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: parts.bridge, withIntermediateDirectories: true)
        try Data("this Mac".utf8).write(to: parts.strut.appending(path: "workspace/graph.lbug"))
        try Data(#"{"assistant":["notes"],"jobs":[]}"#.utf8).write(to: parts.strut.appending(path: MCPGrants.file))
        try FileManager.default.createDirectory(at: parts.strut.appending(path: "workspace/audio"), withIntermediateDirectories: true)
        try Data(#"{"fixer":"qwen3-1.7b-q4"}"#.utf8).write(to: parts.strut.appending(path: "workspace/audio/dictation.json"))
        return parts
    }

    nonisolated static let ca = "-----BEGIN CERTIFICATE-----\nMIIBfake\n-----END CERTIFICATE-----\n"
    /// When the peer's token runs out: a year after the move.
    nonisolated static let expires = Date(timeIntervalSince1970: 1_824_536_000)
    /// The box as strut's `move send` gives it (strut S1).
    nonisolated static let peer = HomePeer(baseUrl: URL(string: "https://192.168.1.20:8443")!, token: "person-token", actor: "tom",
                                           expires: expires, ca: ca, servername: "peel-home")!

    static let moveDay = Date(timeIntervalSince1970: 1_793_000_000)

    // MARK: Out

    @Test func outWhenNothingFails() async throws {
        let box = Box(), local = FakeLocal(box: box), parts = try folders()
        let move = PeelHomeMove(mover: FakeMover(box: box), local: local, parts: parts, now: { Self.moveDay })
        guard case .movedOut(let home) = await move.out(Self.link) else { Issue.record("not moved"); return }
        local.expectOneBridge()
        #expect(box.bridgeRuns && home.answered && home.host == "192.168.1.20:8090" && local.kept == .moved(home))
        // Set aside under the move's day, never started here again.
        let root = parts.strut.deletingLastPathComponent()
        #expect(home.strutCopy == "Strut.moved-2026-10-26" && home.bridgeCopy == "Bridge.moved-2026-10-26")
        #expect(!FileManager.default.fileExists(atPath: parts.strut.path) && !FileManager.default.fileExists(atPath: parts.bridge.path))
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "Strut.moved-2026-10-26/workspace/graph.lbug").path))
    }

    /// After a move, the Mac's strut for dictation runs on a fresh folder of
    /// its own, never the one set aside: dictation's model picks copied
    /// across, and the box's peer record kept for it (in the Keychain in the app).
    @Test func outStartsTheClient() async throws {
        let box = Box(), local = FakeLocal(box: box), parts = try folders()
        let move = PeelHomeMove(mover: FakeMover(box: box), local: local, parts: parts, now: { Self.moveDay })
        guard case .movedOut = await move.out(Self.link) else { Issue.record("not moved"); return }
        local.expectOneBridge()
        #expect(local.clientRunning && parts.client.lastPathComponent == "Strut.client")
        #expect(try String(contentsOf: parts.client.appending(path: "workspace/audio/dictation.json"), encoding: .utf8)
            == #"{"fixer":"qwen3-1.7b-q4"}"#)
        // Nothing of the agent's: its graph and grants stayed in the copy set aside.
        #expect(!FileManager.default.fileExists(atPath: parts.client.appending(path: "workspace/graph.lbug").path))
        #expect(!FileManager.default.fileExists(atPath: parts.client.appending(path: MCPGrants.file).path))
        #expect(HomePeer.read(try #require(parts.homePeer)) == Self.peer)
        // Nothing of the peer's in the folder: its token is in the Keychain only.
        #expect(try FileManager.default.subpathsOfDirectory(atPath: parts.client.path).allSatisfy { !$0.contains("peer") })
    }

    /// Each way out can fail, and what the person is told: nothing moved
    /// (this Mac's started again), or it may have (this Mac's stays stopped).
    /// Only strut's refusal says nothing arrived: a box still saying
    /// "receive" may be unpacking an upload whose answer was lost.
    @Test(arguments: [
        (Failure.check, false, true),          // the box refused the code or its version: nothing stopped
        (.refused, false, true),               // the box refused the upload and still waits: started again
        (.beforeArrival, false, false),        // lost on the way: it may have arrived, stays stopped
        (.whileInstalling, true, false),       // arrived, the box still says "receive": stays stopped
        (.afterArrival, true, false),          // it arrived, the answer was lost: stays stopped
        (.none, true, false),                  // sent, the agent never answered: stays stopped
    ])
    func outThatFails(at failure: Failure, arrived: Bool, unchanged: Bool) async throws {
        let box = Box(), local = FakeLocal(box: box), parts = try folders()
        if failure == .check { box.state = .gone }
        local.answers = false
        let move = PeelHomeMove(mover: FakeMover(box: box, fails: failure), local: local, parts: parts)
        let outcome = await move.out(Self.link)
        local.expectOneBridge("\(failure)")
        #expect(box.bridgeRuns == arrived)
        switch outcome {
        case .unchanged(let why):
            #expect(unchanged && why.hasSuffix("Nothing changed; Peel Home is still on this Mac."))
            #expect(!local.clientRunning && !FileManager.default.fileExists(atPath: parts.client.path))
        case .unanswered(let home, _):
            #expect(!unchanged && !home.answered && local.kept == .moved(home))
            // Dictation keeps a strut while this Mac's stays stopped.
            #expect(local.clientRunning)
        default: Issue.record("\(failure): \(outcome)")
        }
        // This Mac's folders are where they were either way.
        #expect(FileManager.default.fileExists(atPath: parts.strut.appending(path: "workspace/graph.lbug").path))
    }

    /// Without the bridge's identity the box could never run it: nothing stops.
    @Test func noIdentityNoMove() async throws {
        let box = Box(), local = FakeLocal(box: box)
        var parts = try folders()
        parts.identity = [:]
        guard case .unchanged = await PeelHomeMove(mover: FakeMover(box: box), local: local, parts: parts).out(Self.link) else {
            Issue.record("moved"); return
        }
        #expect(local.running && local.kept == .thisMac && box.state == .waiting)
    }

    /// The mark is kept before anything stops: one that cannot be kept stops nothing.
    @Test func aMarkThatCannotBeKeptStopsNothing() async throws {
        let box = Box(), local = FakeLocal(box: box)
        local.failKeep = true
        guard case .unchanged = await PeelHomeMove(mover: FakeMover(box: box), local: local, parts: try folders()).out(Self.link) else {
            Issue.record("moved"); return
        }
        #expect(local.running && box.state == .waiting)
    }

    @Test func pingAgainOnceTheBoxAnswers() async throws {
        let box = Box(), local = FakeLocal(box: box)
        local.answers = false
        let move = PeelHomeMove(mover: FakeMover(box: box), local: local, parts: try folders())
        guard case .unanswered(let home, _) = await move.out(Self.link) else { Issue.record("answered"); return }
        local.answers = true
        guard case .movedOut(let done) = await move.pingAgain(home) else { Issue.record("not answered"); return }
        #expect(done.answered && local.kept == .moved(done))
        local.expectOneBridge()
    }

    // MARK: Back

    /// Out, then back: the box's copy in this Mac's folders, the grants from
    /// this Mac's copy, the box's strut key kept, started and answered.
    @Test func backWhenNothingFails() async throws {
        let box = Box(), local = FakeLocal(box: box), parts = try folders()
        let move = PeelHomeMove(mover: FakeMover(box: box), local: local, parts: parts, now: { Self.moveDay })
        guard case .movedOut(let home) = await move.out(Self.link) else { Issue.record("not moved"); return }
        box.state = .sendingBack
        #expect(await move.back(Self.link, from: home) == .movedBack(answered: true))
        local.expectOneBridge()
        #expect(local.kept == .thisMac && box.state == .gone)
        #expect(try String(contentsOf: parts.strut.appending(path: "workspace/graph.lbug"), encoding: .utf8) == "from the box")
        #expect(MCPGrants.read(in: parts.strut).assistant == ["notes"])
        #expect(try parts.secretKey.read() == Data(String(repeating: "c", count: 64).utf8))
        // Synced once more and stopped before the fetch; its folder gone once Peel Home is back.
        #expect(box.events == ["sync", "read changes", "stop client", "fetch"])
        #expect(!local.clientRunning && !FileManager.default.fileExists(atPath: parts.client.path))
        #expect(HomePeer.read(try #require(parts.homePeer)) == nil)
    }

    /// Back after a correction no push landed with (Send back stopped the
    /// box's strut first): read from the client's strut from its last push,
    /// replayed into Peel Home's own once it is back, and only then the
    /// client's folder gone. When the replay fails, the folder stays.
    @Test(arguments: [true, false])
    func backHandsOverWhatThePushesMissed(applies: Bool) async throws {
        let box = Box(), local = FakeLocal(box: box), parts = try folders()
        let move = PeelHomeMove(mover: FakeMover(box: box), local: local, parts: parts, now: { Self.moveDay })
        guard case .movedOut(let home) = await move.out(Self.link) else { Issue.record("not moved"); return }
        let state = parts.client.appending(path: "workspace/home-sync.json")
        try FileManager.default.createDirectory(at: state.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"since": "2026-10-27T10:51:41.000Z", "hash": "h"}"#.utf8).write(to: state)
        let changes: AgentKit.JSONValue = [["op": "learn", "heard": "hollow mere", "written": "Hollowmere", "at": "2026-10-27T11:30:00.000Z"]]
        local.unpushed = changes
        local.applyFails = !applies
        box.state = .sendingBack
        #expect(await move.back(Self.link, from: home) == .movedBack(answered: true))
        #expect(local.askedSince == "2026-10-27T10:51:41.000Z")
        #expect(box.events == ["sync", "read changes", "stop client", "fetch", "apply"])
        #expect(local.applied == (applies ? [changes] : []))
        #expect(FileManager.default.fileExists(atPath: parts.client.path) == !applies)
        #expect(HomePeer.read(try #require(parts.homePeer)) == nil)
        local.expectOneBridge()
    }

    /// Back, but strut can't open what came (a graph naming the box's paths): marked moved
    /// again, nothing running, and this Mac's copy from the move still there to use.
    /// Whether or not the agent had answered from the box before (when it
    /// had not, this Mac's folders were never set aside: the move back does it).
    @Test(arguments: [true, false])
    func backThatStrutCannotOpen(answered: Bool) async throws {
        let box = Box(), local = FakeLocal(box: box), parts = try folders()
        local.answers = answered
        let move = PeelHomeMove(mover: FakeMover(box: box), local: local, parts: parts, now: { Self.moveDay })
        _ = await move.out(Self.link)
        guard case .moved(let sent) = local.kept else { Issue.record("not moved"); return }
        box.state = .sendingBack
        local.strutOpens = false
        let macKey = Data(String(repeating: "a", count: 64).utf8)
        try parts.secretKey.write(macKey)
        guard case .stillAway = await move.back(Self.link, from: sent) else { Issue.record("moved back"); return }
        // The box's key taken back out, so this Mac's copy can read its own secrets.
        #expect(try parts.secretKey.read() == macKey)
        guard case .moved(let home) = local.kept, home.strutCopy != nil else { Issue.record("no copy kept"); return }
        #expect(!local.running && !box.bridgeRuns)
        try move.useThisMacCopy(home)
        #expect(local.kept == .thisMac && local.running)
        #expect(try String(contentsOf: parts.strut.appending(path: "workspace/graph.lbug"), encoding: .utf8) == "this Mac")
    }

    /// A move back that fails leaves Peel Home on the box and this Mac's stopped.
    @Test(arguments: [Failure.check, .beforeArrival, .refusedAfterArrival])
    func backThatFails(at failure: Failure) async throws {
        let box = Box(), local = FakeLocal(box: box)
        let home = MovedHome(host: "192.168.1.20:8090", date: Self.moveDay, answered: true)
        local.kept = .moved(home)
        local.running = false
        box.state = failure == .check ? .holding : .sendingBack
        local.clientRunning = true
        let outcome = await PeelHomeMove(mover: FakeMover(box: box, fails: failure), local: local, parts: try folders())
            .back(Self.link, from: home)
        guard case .stillAway = outcome else { Issue.record("\(failure): \(outcome)"); return }
        // Still marked moved (with this Mac's copy, once set aside for the fetch), nothing running
        // but the strut for dictation, started again.
        #expect(local.kept.moved?.host == home.host && !local.running && local.clientRunning)
        local.expectOneBridge()
    }

    /// Only the box Peel Home went to: another's link (any page can open
    /// one) brings nothing in, and the box isn't asked.
    @Test func backOnlyFromTheBoxItWentTo() async throws {
        let box = Box(), local = FakeLocal(box: box)
        let home = MovedHome(host: "192.168.1.21:8090", date: Self.moveDay, answered: true)
        local.kept = .moved(home)
        local.running = false
        box.state = .sendingBack
        let outcome = await PeelHomeMove(mover: FakeMover(box: box), local: local, parts: try folders()).back(Self.link, from: home)
        guard case .stillAway = outcome else { Issue.record("\(outcome)"); return }
        #expect(box.state == .sendingBack && local.kept == .moved(home) && !local.running)
    }

    /// For a box that is gone: this Mac's copy put back (anything a move back
    /// cut short left in its place set aside) and started.
    @Test func thisMacsCopy() async throws {
        let box = Box(), local = FakeLocal(box: box), parts = try folders()
        let move = PeelHomeMove(mover: FakeMover(box: box), local: local, parts: parts, now: { Self.moveDay })
        guard case .movedOut(let home) = await move.out(Self.link) else { Issue.record("not moved"); return }
        box.state = .gone
        try FileManager.default.createDirectory(at: parts.bridge, withIntermediateDirectories: true)
        try move.useThisMacCopy(home)
        #expect(local.kept == .thisMac && local.running)
        #expect(try String(contentsOf: parts.strut.appending(path: "workspace/graph.lbug"), encoding: .utf8) == "this Mac")
        let left = try FileManager.default.contentsOfDirectory(atPath: parts.bridge.deletingLastPathComponent().path)
        #expect(left.contains { $0.hasPrefix("Bridge.old-") } && !left.contains("Bridge.moved-2026-10-26"))
        // The box is gone: the strut for dictation with it, and its peer record.
        let peerItem = try #require(parts.homePeer)
        #expect(!local.clientRunning && !left.contains("Strut.client") && HomePeer.read(peerItem) == nil)
        local.expectOneBridge()
    }

    // MARK: The link and the seam

    @Test(arguments: [
        "peel://other-setup?host=192.168.1.20&code=7KQ2M9XWBC4HD8RN",
        "https://home-setup?host=192.168.1.20&code=7KQ2M9XWBC4HD8RN",
        "peel://home-setup?host=192.168.1.20",
        "peel://home-setup?host=192.168.1.20&code=short",
        "peel://home-setup?host=192.168.1.20&code=7KQ2M9XWBC4HD8RN&code=7KQ2M9XWBC4HD8RN",
        "peel://home-setup?host=192.168.1.20&code=7KQ2M9XWBC4HD8RN&next=x",
        "peel://home-setup?host=evil.example%2Fx%40y&code=7KQ2M9XWBC4HD8RN",
        "peel://home-setup/x?host=192.168.1.20&code=7KQ2M9XWBC4HD8RN",
        "peel://home-setup?host=b%C3%B6x.local&code=7KQ2M9XWBC4HD8RN",          // a look-alike host: ASCII only
    ])
    func aLinkPeelCannotUse(link: String) throws {
        #expect(HomeLink(try #require(URL(string: link))) == nil)
    }

    @Test(arguments: [
        ("192.168.1.20%3A8090", true), ("10.0.0.5", true), ("172.20.1.1", true), ("169.254.3.4", true),
        ("umbrel.local", true), ("umbrel", true), ("%5Bfe80%3A%3A1%5D%3A8090", true), ("127.0.0.1%3A8090", true),
        ("box.example.com", false), ("203.0.113.9%3A8090", false), ("172.32.0.1", false),
    ])
    func whetherTheBoxIsOnTheHomeNetwork(host: String, home: Bool) throws {
        let url = try #require(URL(string: "peel://home-setup?host=\(host)&code=7KQ2M9XWBC4HD8RN"))
        let link = try #require(HomeLink(url))
        #expect(link.isHomeNetwork == home)
    }

    @Test func strutsWordsNeverCarryTheCode() {
        #expect(StrutMove.words("not a move link: peel://home-setup?code=7KQ2M9XWBC4HD8RN", code: "7KQ2M9XWBC4HD8RN")
            == "Your home server refused the move.")
    }

    /// Forgetting the account takes the copies a move set aside, which hold the agent's key.
    @Test func forgettingTakesTheCopies() throws {
        let parts = try folders(), root = parts.strut.deletingLastPathComponent()
        for name in ["Bridge.moved-2026-10-26", "Bridge.old-2026-10-26T101010", "Bridgework", "Strut.client"] {
            try FileManager.default.createDirectory(at: root.appending(path: name), withIntermediateDirectories: true)
        }
        try PeelHomeMove.eraseCopies(of: parts.bridge)
        try PeelHomeMove.eraseCopies(of: parts.strut)
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)).isSuperset(of: ["Bridge", "Bridgework", "Strut"]))
        // The client's, with the box's token.
        #expect(!FileManager.default.fileExists(atPath: parts.client.path))
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "Bridge.moved-2026-10-26").path))
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "Bridge.old-2026-10-26T101010").path))
    }

    @Test func theLinkNeverPrintsItsCode() {
        #expect("\(Self.link)" == "Peel Home link for 192.168.1.20:8090")
        #expect(!String(reflecting: Self.link).contains("7KQ2"))
    }

    /// strut's `move` as Peel runs it, on a stand-in for its Node that
    /// records what it was given and answers as strut's `move/cli.ts` does.
    func fakeStrut(_ answer: String) throws -> (StrutMove, URL) {
        let seen = temp.url.appending(path: "seen")
        try FileManager.default.createDirectory(at: seen, withIntermediateDirectories: true)
        let script = """
            printf '%s\\n' "$@" > '\(seen.path)/args'
            env > '\(seen.path)/env'
            while [ $# -gt 0 ]; do
              if [ "$1" = --env ]; then
                [ -f "$2" ] && cp "$2" '\(seen.path)/move.env' && stat -f %Lp "$2" > '\(seen.path)/mode'
                echo "$2" > '\(seen.path)/path'
                envfile="$2"
                printf "STRUT_SECRET_KEY='%s'\\n" "$(printf 'd%.0s' $(seq 64))" > "$2.fetched"
              fi
              shift
            done
            \(answer)
            """
        let (strut, _) = try BundledStrutTests().fake(script)
        return (strut.mover, seen)
    }

    @Test func sendNamesTheFoldersAndCarriesTheKeysInAFileDeletedAfter() async throws {
        let (mover, seen) = try fakeStrut(#"echo '{"event":"sent","from":"/x","sidecars":["bridge"]}'"#)
        var parts = try folders()
        parts.identity = ["BROKER_URL": "broker.example:8883", "RUNNER_ALIAS": "Ada's agent"]
        try parts.secretKey.write(Data(String(repeating: "a", count: 64).utf8))
        // A strut from before it returned the box as a peer: none.
        #expect(try await mover.send(Self.link, parts, callbacks: BundledBridge.Server(base: URL(string: "http://127.0.0.1:5555")!, token: "tok")) == nil)

        let args = try String(contentsOf: seen.appending(path: "args"), encoding: .utf8).split(separator: "\n").map(String.init)
        let envFile = try String(contentsOf: seen.appending(path: "path"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(Array(args.prefix(4)) == [args[0], "move", "send", Self.link.url.absoluteString] && args[0].hasSuffix("desktop.js"))
        #expect(Array(args.dropFirst(4)) == ["--data", parts.strut.appending(path: "workspace").path,
                                             "--host-config", parts.strut.appending(path: "host-config.json").path,
                                             "--sidecar", "bridge=\(parts.bridge.path)", "--env", envFile,
                                             "--bridge", "http://127.0.0.1:5555", "--peer-actor", "tom"])
        #expect(try String(contentsOf: seen.appending(path: "move.env"), encoding: .utf8) == """
            STRUT_SECRET_KEY='\(String(repeating: "a", count: 64))'
            bridge.BROKER_URL='broker.example:8883'
            bridge.RUNNER_ALIAS='Ada'\\''s agent'

            """)
        #expect(try String(contentsOf: seen.appending(path: "mode"), encoding: .utf8).hasPrefix("600"))
        #expect(!FileManager.default.fileExists(atPath: URL(filePath: envFile).deletingLastPathComponent().path))
        // The bridge's token by env, never an argument; nothing of Peel's own.
        let env = try String(contentsOf: seen.appending(path: "env"), encoding: .utf8)
        #expect(env.contains("STRUT_MOVE_BRIDGE_TOKEN=tok") && !args.contains("tok") && !env.contains("PEEL_"))
        // The server's own environment: its workspace and secret key.
        #expect(env.contains("STRUT_WORKSPACE=") && env.contains("STRUT_SECRET_KEY="))
    }

    /// A version mismatch says what to do, since either side may be the older.
    @Test func aVersionMismatchSaysUpdate() async throws {
        let (mover, _) = try fakeStrut(#"echo '{"event":"error","error":"versions differ: the other end runs strut 2.1"}'; exit 1"#)
        // A refusal: the box took nothing, so a send that met it may start this Mac's again.
        let error = await #expect(throws: HomeMoveRefused.self) { try await mover.check(Self.link, folders()) }
        #expect(error?.description.hasPrefix("Peel and Peel Home on your home server run different versions.") == true)
    }

    @Test(arguments: [
        (#"echo '{"event":"checked","mode":"receive","format":1}'"#, HomeLink.Mode.receive),
        (#"echo '{"event":"checked","mode":"send-back","format":1,"ready":true}'"#, .sendBack),
    ])
    func checkSaysWhatTheBoxIsReadyFor(answer: String, mode: HomeLink.Mode) async throws {
        #expect(try await fakeStrut(answer).0.check(Self.link, folders()) == mode)
    }

    @Test func aStrutWithoutMoveSaysUpdatePeel() async throws {
        let (mover, _) = try fakeStrut("echo 'strut move: unknown command' >&2; exit 2")
        let error = await #expect(throws: PeelError.self) { try await mover.check(Self.link, folders()) }
        #expect(error?.description.contains("Update Peel") == true)
    }

    /// strut writes the env file on a fetch; Peel reads strut's key back from it.
    @Test func fetchReadsStrutsKeyBack() async throws {
        let (mover, _) = try fakeStrut("""
            mv "$envfile.fetched" "$envfile"
            echo '{"event":"fetched","from":"/data/strut/workspace","sidecars":["bridge"]}'
            """)
        let env = try await mover.fetch(Self.link, try folders())
        #expect(env == ["STRUT_SECRET_KEY": String(repeating: "d", count: 64)])
    }

    /// The box as the Mac's strut's peer, from `move send`'s result (strut
    /// S1, `exp` in milliseconds): only https, a plain token and actor, and a
    /// PEM CA if any; never printed with its token. A box given no peer
    /// address answers `{ error }`: none.
    @Test(arguments: [
        (#"{"baseUrl":"https://192.168.1.20:8443","token":"person-token","actor":"tom","exp":1824536000000,"ca":"-----BEGIN CERTIFICATE-----\nMIIBfake\n-----END CERTIFICATE-----\n","servername":"peel-home"}"#, true),
        (#"{"error":"this host hands out no peer record (serve --peer-url)"}"#, false),
    ])
    func sendReturnsTheBoxAsAPeer(peer: String, given: Bool) async throws {
        let answer = #"{"event":"sent","from":"/x","sidecars":["bridge"],"peer":"# + peer + "}"
        let (mover, seen) = try fakeStrut("printf '%s\\n' '\(answer)'")
        let parts = try folders()
        try parts.secretKey.write(Data(String(repeating: "a", count: 64).utf8))
        #expect(try await mover.send(Self.link, parts, callbacks: nil) == (given ? Self.peer : nil))
        let args = try String(contentsOf: seen.appending(path: "args"), encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(Array(args.suffix(2)) == ["--peer-actor", "tom"])
    }

    @Test func aPeerRecordPeelCanTake() throws {
        #expect(!"\(Self.peer)".contains("person-token") && !String(reflecting: Self.peer).contains("person-token"))
        let url = URL(string: "https://192.168.1.20:8443")!
        #expect(HomePeer(baseUrl: URL(string: "http://192.168.1.20:8443")!, token: "t", actor: "tom", expires: Self.expires, ca: nil) == nil)
        #expect(HomePeer(baseUrl: url, token: "t t", actor: "tom", expires: Self.expires, ca: nil) == nil)
        #expect(HomePeer(baseUrl: url, token: "t", actor: "to\nm", expires: Self.expires, ca: nil) == nil)
        #expect(HomePeer(baseUrl: url, token: "t", actor: "tom", expires: Self.expires, ca: "not a certificate") == nil)
        // A server name only names the certificate its CA issued, and is a host name.
        #expect(HomePeer(baseUrl: url, token: "t", actor: "tom", expires: Self.expires, ca: nil, servername: "peel-home") == nil)
        #expect(HomePeer(baseUrl: url, token: "t", actor: "tom", expires: Self.expires, ca: Self.ca, servername: "peel home") == nil)
        // No CA: a certificate the Mac already trusts. Put on file as strut's `checkPeer` takes it.
        let plain = try #require(HomePeer(baseUrl: url, token: "t", actor: "tom", expires: Self.expires, ca: nil))
        #expect(StrutHomeSync.record(plain) == ["baseUrl": "https://192.168.1.20:8443", "token": "t", "label": "Peel Home"])
        #expect(StrutHomeSync.record(Self.peer)["ca"]?.string == Self.ca)
        #expect(StrutHomeSync.record(Self.peer)["servername"]?.string == "peel-home")
        // Kept and read back as it was.
        let item = FileItem(file: temp.url.appending(path: "home-peer"))
        try FileManager.default.createDirectory(at: temp.url, withIntermediateDirectories: true)
        try Self.peer.keep(in: item)
        #expect(HomePeer.read(item) == Self.peer)
    }

    // MARK: The Mac's strut while Peel Home is on the box

    /// A stand-in for strut's peers and `home-sync` (strut S1 and S2).
    final class FakeSync: HomeSyncing, @unchecked Sendable {
        var peers: [HomePeer] = []
        var syncs = 0
        /// Every sync asked for, landed or not.
        var tries = 0
        /// The next syncs that fail (the box out of reach; `.max` for all),
        /// then land. The Mac's own strut takes the peer all the same.
        var failNext = 0
        var pulls = false
        func addPeer(_ peer: HomePeer, on server: MemoryServer) async throws {
            peers.append(peer)
        }
        func sync(on server: MemoryServer) async throws -> Bool {
            tries += 1
            if failNext > 0 { failNext -= 1; throw PeelError("could not reach 192.168.1.20:8443") }
            syncs += 1
            return pulls
        }
    }

    /// The box put on file as the peer each time the client's strut starts,
    /// then synced; each sync's time kept for the next launch; a failure
    /// said, the last sync's time with it. No peer record, or one run out:
    /// nothing tried.
    @Test func theSyncerPutsThePeerAndKeepsTheLastSync() async throws {
        let client = temp.url.appending(path: "Strut.client"), item = FileItem(file: temp.url.appending(path: "home-peer"))
        try HomeClient.prepare(client, from: try folders().strut)
        var now = Date(timeIntervalSince1970: 1_793_000_000)
        let fake = FakeSync(), syncer = HomeSyncer(syncing: fake, client: client, peer: item, retries: [], now: { now })
        let server = MemoryServer(base: URL(string: "http://127.0.0.1:4100")!, key: "k")!
        syncer.use(server)
        await syncer.finish()
        #expect(fake.peers.isEmpty && fake.syncs == 0 && syncer.status == .noPeer)
        try Self.peer.keep(in: item)
        fake.failNext = .max
        await syncer.finish()
        #expect(syncer.lastSync == nil && syncer.status == .failed(now))
        fake.failNext = 0
        var pulled = 0
        syncer.onPull = { pulled += 1 }
        await syncer.finish()
        #expect(fake.peers == [Self.peer] && fake.syncs == 1 && syncer.status == .synced(now) && pulled == 0)
        // Asked twice before it began: one sync; then the move back's one more. The peer put once per start.
        now = now.addingTimeInterval(60)
        fake.pulls = true
        syncer.sync()
        syncer.sync()
        await syncer.finish()
        #expect(fake.peers == [Self.peer] && fake.syncs == 3 && pulled == 2)
        #expect(HomeSyncer(syncing: fake, client: client, peer: item).lastSync == now)
        // The box gone again: said, with when it last landed.
        let landed = now
        now = now.addingTimeInterval(60)
        fake.failNext = .max
        await syncer.finish()
        #expect(syncer.status == .failed(now) && syncer.lastSync == landed)
        fake.failNext = 0
        // A strut started again (a new port and key): put again.
        syncer.use(MemoryServer(base: URL(string: "http://127.0.0.1:4101")!, key: "k2")!)
        await syncer.finish()
        #expect(fake.peers.count == 2)
        // The token ran out: nothing tried.
        now = Self.expires.addingTimeInterval(1)
        await syncer.finish()
        #expect(fake.syncs == 5 && syncer.status == .expired(Self.expires))
        // Stopped: nothing runs.
        now = Self.moveDay
        syncer.use(nil)
        syncer.sync()
        await syncer.finish()
        #expect(fake.syncs == 5)
    }

    /// A failure (the box's strut still starting after a move) is tried
    /// again on its own, as many times as there are waits, then left to
    /// the next trigger; one that lands ends the tries.
    @Test func theSyncerTriesAgainAfterAFailure() async throws {
        let client = temp.url.appending(path: "Strut.client"), item = FileItem(file: temp.url.appending(path: "home-peer"))
        try HomeClient.prepare(client, from: try folders().strut)
        try Self.peer.keep(in: item)
        let fake = FakeSync()
        fake.failNext = .max
        let syncer = HomeSyncer(syncing: fake, client: client, peer: item, retries: [.milliseconds(1), .milliseconds(1)])
        let server = MemoryServer(base: URL(string: "http://127.0.0.1:4100")!, key: "k")!
        func settle(until done: () -> Bool) async throws {
            for _ in 0..<600 where !done() { try await Task.sleep(for: .milliseconds(5)) }
            try await Task.sleep(for: .milliseconds(50))
        }
        // The start's sync, then two more, and no further.
        syncer.use(server)
        try await settle { fake.tries >= 3 }
        #expect(fake.tries == 3 && fake.syncs == 0)
        if case .failed = syncer.status {} else { Issue.record("not failed: \(syncer.status)") }
        // A start again: tries again, and the first that lands ends them.
        fake.failNext = 1
        syncer.use(MemoryServer(base: URL(string: "http://127.0.0.1:4101")!, key: "k2")!)
        try await settle { fake.syncs >= 1 }
        #expect(fake.tries == 5 && fake.syncs == 1)
        if case .synced = syncer.status {} else { Issue.record("not synced: \(syncer.status)") }
    }

    /// The client's strut runs no automations and has `home-sync`; Peel Home's own neither.
    @Test func theClientRunsNoSchedulerAndSyncs() throws {
        let data = temp.url.appending(path: "Strut.client"), config = data.appending(path: "host-config.json")
        let env = BundledStrut.environment([:], key: "k", secretKey: "s", data: data, hostConfig: config, homeClient: true)
        #expect(env["STRUT_SCHEDULER"] == "0" && env["STRUT_HOME_SYNC"] == "copy")
        let home = BundledStrut.environment([:], key: "k", secretKey: "s", data: data, hostConfig: config)
        #expect(home["STRUT_SCHEDULER"] == nil && home["STRUT_HOME_SYNC"] == nil)
    }
}
