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

        func send(_ link: HomeLink, _ parts: HomeParts, callbacks: BundledBridge.Server?) async throws {
            if fails == .refused { throw HomeMoveRefused(description: "the move was refused: not a move") }
            if fails == .beforeArrival { throw PeelError("could not reach 192.168.1.20:8090") }
            if fails == .whileInstalling {
                box.state = .installing
                throw PeelError("the connection was lost")
            }
            box.state = .holding
            if fails == .afterArrival { throw PeelError("the connection was lost") }
        }

        func fetch(_ link: HomeLink, _ parts: HomeParts) async throws -> [String: String] {
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
        }
    }

    /// Removed after each test.
    let temp = TempProfile()

    /// This Mac's folders for a move, in the test's own folder.
    func folders() throws -> HomeParts {
        let root = temp.url
        let parts = HomeParts(strut: root.appending(path: "Strut"), bridge: root.appending(path: "Bridge"),
                              secretKey: FileItem(file: root.appending(path: "strut-key")),
                              identity: ["BROKER_URL": "127.0.0.1:1883", "BRIDGE_DEVICE": "mac-3f2a"])
        try FileManager.default.createDirectory(at: parts.strut.appending(path: "workspace"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: parts.bridge, withIntermediateDirectories: true)
        try Data("this Mac".utf8).write(to: parts.strut.appending(path: "workspace/graph.lbug"))
        try Data(#"{"assistant":["notes"],"jobs":[]}"#.utf8).write(to: parts.strut.appending(path: MCPGrants.file))
        return parts
    }

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
        case .unchanged(let why): #expect(unchanged && why.hasSuffix("Nothing changed; Peel Home is still on this Mac."))
        case .unanswered(let home, _): #expect(!unchanged && !home.answered && local.kept == .moved(home))
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
        let outcome = await PeelHomeMove(mover: FakeMover(box: box, fails: failure), local: local, parts: try folders())
            .back(Self.link, from: home)
        guard case .stillAway = outcome else { Issue.record("\(failure): \(outcome)"); return }
        // Still marked moved (with this Mac's copy, once set aside for the fetch), nothing running.
        #expect(local.kept.moved?.host == home.host && !local.running)
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
        for name in ["Bridge.moved-2026-10-26", "Bridge.old-2026-10-26T101010", "Bridgework"] {
            try FileManager.default.createDirectory(at: root.appending(path: name), withIntermediateDirectories: true)
        }
        try PeelHomeMove.eraseCopies(of: parts.bridge)
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)).isSuperset(of: ["Bridge", "Bridgework", "Strut"]))
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
        try await mover.send(Self.link, parts, callbacks: BundledBridge.Server(base: URL(string: "http://127.0.0.1:5555")!, token: "tok"))

        let args = try String(contentsOf: seen.appending(path: "args"), encoding: .utf8).split(separator: "\n").map(String.init)
        let envFile = try String(contentsOf: seen.appending(path: "path"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(Array(args.prefix(4)) == [args[0], "move", "send", Self.link.url.absoluteString] && args[0].hasSuffix("desktop.js"))
        #expect(Array(args.dropFirst(4)) == ["--data", parts.strut.appending(path: "workspace").path,
                                             "--host-config", parts.strut.appending(path: "host-config.json").path,
                                             "--sidecar", "bridge=\(parts.bridge.path)", "--env", envFile,
                                             "--bridge", "http://127.0.0.1:5555"])
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
}
