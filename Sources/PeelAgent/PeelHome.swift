import AgentKit
import Foundation
import os
import PeelCore
import Synchronization

/// The link a home server's `strut move serve` shows (docs/always-on.md,
/// "How a move works"): `peel://home-setup?host=<host[:port]>&code=<code>`,
/// for a move there or, once it holds Peel Home, back here. Which one is
/// the box's to say (`HomeMover.check`). Nil for any other link, a name given
/// twice, anything else in it, or a host or code that is not plainly one.
public struct HomeLink: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// The box's address on the home network, as the link gives it.
    public let host: String
    /// The link as it came, which strut parses again; its code moves Peel Home once.
    let url: URL

    /// Only the host: the code is never printed.
    public var description: String { "Peel Home link for \(host)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["host": host], displayStyle: .struct) }

    public init?(_ link: URL) {
        guard let values = peelLink(link, host: "home-setup", names: ["host", "code"]),
              let host = values["host"], let code = values["code"] else { return nil }
        // A name or address with an optional port, in ASCII; nothing that could reach past it.
        let ascii = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        let hostCharacters = ascii.union(CharacterSet(charactersIn: ".-:[]"))
        let codeCharacters = ascii.union(CharacterSet(charactersIn: "-"))
        guard (1...255).contains(host.count), host.unicodeScalars.allSatisfy(hostCharacters.contains),
              (8...64).contains(code.count), code.unicodeScalars.allSatisfy(codeCharacters.contains) else { return nil }
        self.host = host
        self.url = link
    }

    /// The link's code, only to keep it out of strut's words.
    var code: String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "code" }?.value
    }

    /// Whether `host` is on a home network: a private, link-local or
    /// loopback address, a `.local` name or a bare name. A move carries the
    /// agent's key, so anything else is said plainly before it goes.
    public var isHomeNetwork: Bool {
        var name = host.lowercased()
        if name.hasPrefix("["), let end = name.firstIndex(of: "]") {
            name = String(name[name.index(after: name.startIndex)..<end])
        } else if name.filter({ $0 == ":" }).count == 1, let colon = name.firstIndex(of: ":") {
            name = String(name[..<colon])
        }
        let parts = name.split(separator: ".").compactMap { UInt8($0) }
        if parts.count == 4, name.split(separator: ".").count == 4 {
            return parts[0] == 10 || parts[0] == 127 || parts[0] == 192 && parts[1] == 168
                || parts[0] == 172 && (16...31).contains(parts[1]) || parts[0] == 169 && parts[1] == 254
        }
        if name.contains(":") { return name == "::1" || name.hasPrefix("fe80:") || name.hasPrefix("fc") || name.hasPrefix("fd") }
        return name == "localhost" || name.hasSuffix(".local") || !name.contains(".")
    }

    /// What the box is ready for, as it says.
    public enum Mode: Sendable, Equatable {
        /// Empty, waiting for a move.
        case receive
        /// Holding Peel Home, packed to send it back.
        case sendBack
    }
}

/// The values of a `peel://<host>?…` link that names exactly `names`, each
/// once, and nothing else: no path, user or fragment. Nil for any other
/// link. Any page can open one, so it is read only through here.
func peelLink(_ link: URL, host: String, names: Set<String>) -> [String: String]? {
    guard link.scheme?.lowercased() == "peel", link.host?.lowercased() == host,
          link.path.isEmpty || link.path == "/", link.user == nil, link.fragment == nil,
          let items = URLComponents(url: link, resolvingAgainstBaseURL: false)?.queryItems,
          items.count == names.count, Set(items.map(\.name)) == names else { return nil }
    var values: [String: String] = [:]
    for item in items {
        guard let value = item.value else { return nil }
        values[item.name] = value
    }
    return values
}

/// What a move carries from this Mac (docs/always-on.md, "What moves"):
/// strut's folder, the bridge's as the sidecar `bridge`, strut's secret key
/// and the bridge's identity.
public struct HomeParts: Sendable {
    /// Peel's strut folder: `workspace/` (strut's data) and `host-config.json`.
    public var strut: URL
    /// The bridge's folder: the agent's account and its inbox.
    public var bridge: URL
    /// strut's secret key (`Profile.strutKey`): its secret store is encrypted with it.
    public var secretKey: any SecretItem
    /// The bridge's settings that make it this agent (`BundledBridge.identity`).
    public var identity: [String: String]
    /// Who the person is to the box's strut, for the peer record a move out
    /// asks for (`--peer-actor`); none asks for none.
    public var peerActor: String?
    /// Where the box's peer record is kept (`Profile.homePeer`).
    public var homePeer: (any SecretItem)?
    /// The Mac's strut while Peel Home is on the box (`HomeClient`).
    public var client: URL { HomeClient.folder(for: strut) }

    public init(strut: URL, bridge: URL, secretKey: any SecretItem, identity: [String: String] = [:],
                peerActor: String? = nil, homePeer: (any SecretItem)? = nil) {
        self.strut = strut
        self.bridge = bridge
        self.secretKey = secretKey
        self.identity = identity
        self.peerActor = peerActor
        self.homePeer = homePeer
    }
}

/// strut's word that the box answered and took nothing: a wrong code,
/// another version, a box not empty, an upload it refused. Only this lets a
/// failed send start this Mac's strut and bridge again; a send that failed
/// any other way may have arrived.
public struct HomeMoveRefused: Error, CustomStringConvertible {
    public let description: String
}

/// strut's `move` (strut's AGENTS.md, "Moving strut to another host"): the
/// one seam Peel moves Peel Home through. It packs, seals with the link's
/// code, sends and receives; Peel has no tar or crypto of its own.
/// `StrutMove` runs the bundled strut's; the tests use a fake.
public protocol HomeMover: Sendable {
    /// What the box is ready for, once its strut's version matches this
    /// one's and it takes the link's code. Throws in words otherwise.
    func check(_ link: HomeLink, _ parts: HomeParts) async throws -> HomeLink.Mode
    /// Packs this Mac's stopped folders and sends them; `callbacks`, the
    /// bridge just stopped, which strut's callbacks point at until the box
    /// points them at its own. Returns the box as a peer for the Mac's
    /// strut (`HomePeer`); nil from a strut that gives none.
    func send(_ link: HomeLink, _ parts: HomeParts, callbacks: BundledBridge.Server?) async throws -> HomePeer?
    /// Downloads the box's move into this Mac's folders and tells the box,
    /// which then sets its copy aside. Returns strut's env values that came with it.
    func fetch(_ link: HomeLink, _ parts: HomeParts) async throws -> [String: String]
}

/// The bundled strut's `move` (strut branch `strut-move`, e92fbe7), run as
/// `node desktop.js move …` over its stopped folders, beside the server and
/// never inside it, with the environment the server gets
/// (`BundledStrut.environment`): one JSON line on stdout per result,
/// `{"event":"error","error":…}` and exit 1 on a refusal, exit 2 for usage.
/// Its env values go in a 0600 file in a folder of its own, deleted after;
/// its words on stderr are dropped. A fetch names no bridge: Peel's starts
/// after strut and points strut at itself then (`AutomationsClient.useBridge`).
public struct StrutMove: HomeMover {
    private static let log = Logger(subsystem: "dev.peel.mac", category: "peel-home")
    let node: URL
    let desktop: URL

    /// How the desktop package is asked for a move: the one line to change
    /// if strut runs it otherwise.
    nonisolated static func arguments(desktop: URL, _ command: [String]) -> [String] {
        [desktop.path, "move"] + command
    }

    /// The folders a command names, the same for `send` and `fetch`.
    nonisolated static func folders(_ parts: HomeParts, envFile: URL) -> [String] {
        ["--data", parts.strut.appending(path: "workspace").path,
         "--host-config", parts.strut.appending(path: "host-config.json").path,
         "--sidecar", "bridge=\(parts.bridge.path)",
         "--env", envFile.path]
    }

    /// The env file a send carries: strut's secret key, and the bridge's identity as `bridge.<KEY>`.
    nonisolated static func envFile(secretKey: String, identity: [String: String]) -> String {
        let quoted = { (value: String) in "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let lines = ["STRUT_SECRET_KEY=\(quoted(secretKey))"]
            + identity.sorted { $0.key < $1.key }.map { "bridge.\($0.key)=\(quoted($0.value))" }
        return lines.joined(separator: "\n") + "\n"
    }

    /// `KEY='value'` lines as strut writes them, unquoted.
    nonisolated static func readEnv(_ text: String) -> [String: String] {
        var values: [String: String] = [:]
        for line in text.split(separator: "\n") where !line.hasPrefix("#") {
            guard let equals = line.firstIndex(of: "=") else { continue }
            var value = String(line[line.index(after: equals)...])
            if value.count >= 2, value.hasPrefix("'"), value.hasSuffix("'") {
                value = String(value.dropFirst().dropLast()).replacingOccurrences(of: "'\\''", with: "'")
            }
            values[String(line[..<equals])] = value
        }
        return values
    }

    public func check(_ link: HomeLink, _ parts: HomeParts) async throws -> HomeLink.Mode {
        let result = try await run(["check", link.url.absoluteString], parts, link: link, within: .seconds(30))
        guard result["event"] as? String == "checked" else { throw PeelError("Peel's strut didn't say what your home server is ready for.") }
        switch result["mode"] as? String {
        case "receive": return .receive
        case "send-back" where result["ready"] as? Bool == true: return .sendBack
        case "send-back": throw PeelError("Your home server hasn't packed Peel Home yet. Try again in a moment.")
        default: throw PeelError("Your home server is ready for something Peel doesn't know.")
        }
    }

    public func send(_ link: HomeLink, _ parts: HomeParts, callbacks: BundledBridge.Server?) async throws -> HomePeer? {
        try await withEnvFile { file in
            let secretKey = try BundledStrut.secretKey(in: parts.secretKey)
            try Self.write(Self.envFile(secretKey: secretKey, identity: parts.identity), to: file)
            var command = ["send", link.url.absoluteString] + Self.folders(parts, envFile: file)
            if let callbacks { command += ["--bridge", callbacks.base.absoluteString] }
            if let actor = parts.peerActor { command += ["--peer-actor", actor] }
            let result = try await run(command, parts, link: link, secretKey: secretKey, bridgeToken: callbacks?.token)
            guard result["event"] as? String == "sent" else { throw PeelError("Peel's strut didn't say Peel Home was sent.") }
            // A box given no peer address says why; dictation then keeps this Mac's last copy.
            if let refusal = HomePeer.refusal(result["peer"]) { Self.log.notice("no peer record: \(refusal, privacy: .public)") }
            return HomePeer(result["peer"])
        }
    }

    public func fetch(_ link: HomeLink, _ parts: HomeParts) async throws -> [String: String] {
        try await withEnvFile { file in
            let result = try await run(["fetch", link.url.absoluteString] + Self.folders(parts, envFile: file), parts, link: link)
            guard result["event"] as? String == "fetched" else { throw PeelError("Peel's strut didn't say Peel Home arrived.") }
            return (try? String(contentsOf: file, encoding: .utf8)).map(Self.readEnv) ?? [:]
        }
    }

    /// A folder only this user reads, for the env file, removed however the command ends.
    private func withEnvFile<T>(_ body: (URL) async throws -> T) async throws -> T {
        let folder = FileManager.default.temporaryDirectory.appending(path: "peel-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        return try await body(folder.appending(path: "move.env"))
    }

    private static func write(_ text: String, to file: URL) throws {
        guard FileManager.default.createFile(atPath: file.path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600]) else {
            throw PeelError("Peel couldn't write the move's settings.")
        }
    }

    /// strut's refusal, in words the person can act on: a version mismatch
    /// names no side, since either may be the older; never the link's code.
    nonisolated static func words(_ error: String, code: String?) -> String {
        let line = error.split(whereSeparator: \.isNewline).first.map(String.init) ?? error
        if line.hasPrefix("versions differ") {
            return "Peel and Peel Home on your home server run different versions. Update the older one, then open the link again."
        }
        if let code, line.contains(code) { return "Your home server refused the move." }
        return line
    }

    /// strut's refusals, where the box answered and took nothing (its
    /// `move/client.ts`): before an upload, or the upload itself refused,
    /// which since strut#335 leaves nothing in place.
    nonisolated static let refusals = ["the move was refused", "the code was refused", "the other end", "versions differ"]

    /// Runs one command over `parts`' strut folder with the environment its
    /// server gets, and reads its last result line; strut's own refusal as
    /// the error. Ended (`endProcess`) when the task is cancelled or
    /// `within` runs out. `secretKey`: strut's key when already read.
    private func run(_ command: [String], _ parts: HomeParts, link: HomeLink, secretKey: String? = nil, bridgeToken: String? = nil,
                     within timeout: Duration? = nil) async throws -> [String: Any] {
        let process = Process()
        process.executableURL = node
        process.arguments = Self.arguments(desktop: desktop, command)
        process.currentDirectoryURL = desktop.deletingLastPathComponent()
        var environment = BundledStrut.environment(
            ProcessInfo.processInfo.environment, key: try BundledStrut.newKey(),
            secretKey: try secretKey ?? BundledStrut.secretKey(in: parts.secretKey),
            data: parts.strut, hostConfig: parts.strut.appending(path: "host-config.json"))
        if let bridgeToken { environment["STRUT_MOVE_BRIDGE_TOKEN"] = bridgeToken }
        process.environment = environment
        let output = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw PeelError("Peel couldn't run its strut to move Peel Home.") }
        let running = Running(process)
        let timer = DispatchWorkItem { running.end(timedOut: true) }
        if let timeout { DispatchQueue.global().asyncAfter(deadline: .now() + Double(timeout.components.seconds), execute: timer) }
        // On a queue of its own, not the concurrency pool: a send can take minutes.
        let text = await withTaskCancellationHandler {
            await withCheckedContinuation { (done: CheckedContinuation<String, Never>) in
                DispatchQueue.global().async {
                    let data = output.fileHandleForReading.readDataToEndOfFile()
                    running.process.waitUntilExit()
                    done.resume(returning: String(decoding: data, as: UTF8.self))
                }
            }
        } onCancel: {
            DispatchQueue.global().async { running.end() }
        }
        timer.cancel()
        let status = process.terminationStatus
        try Task.checkCancellation()
        let last = text.split(whereSeparator: \.isNewline).reversed().lazy.compactMap { line in
            (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
        }.first
        if let timeout, running.timedOut {
            throw PeelError("Your home server didn't answer in \(timeout.components.seconds) seconds.")
        }
        if status == 2 { throw PeelError("This copy of Peel's strut can't move Peel Home. Update Peel.") }
        if let error = last?["error"] as? String {
            let words = Self.words(error, code: link.code)
            if Self.refusals.contains(where: error.hasPrefix) { throw HomeMoveRefused(description: words) }
            throw PeelError(words)
        }
        guard status == 0, let last else { throw PeelError("Peel's strut stopped before it finished (status \(status)).") }
        return last
    }
}

/// A move command's process, ended from a timer or a cancel on any queue.
private final class Running: @unchecked Sendable {
    let process: Process
    private let ended = Mutex(false)
    init(_ process: Process) { self.process = process }
    /// Ended by the timer, not by itself or a cancel.
    var timedOut: Bool { ended.withLock { $0 } }
    func end(timedOut: Bool = false) {
        if timedOut, process.isRunning { ended.withLock { $0 = true } }
        endProcess(process.processIdentifier, isRunning: { process.isRunning })
    }
}

extension BundledStrut {
    /// Its `move`, for Peel Home (`PeelHomeMove`), run over its folders while it is stopped.
    public var mover: StrutMove { StrutMove(node: folder.appending(path: "native/node"), desktop: folder.appending(path: "desktop.js")) }
}

/// What a move asks of the app: its own strut and bridge, the agent's DM,
/// and where the account keeps Peel Home's place.
@MainActor
public protocol PeelHomeLocal: AnyObject {
    /// Keeps `brain` as the account's (`Profile.brain`), nothing else: a
    /// moved Peel Home is never started here, whatever happens next.
    func keep(_ brain: Brain) throws
    /// Stops this Mac's strut and bridge, and returns once both are gone:
    /// the bridge's address and token, if it was running.
    func stopHome() async -> BundledBridge.Server?
    /// Starts them again; a failure to start is the app's to say.
    func startHome()
    /// Whether this Mac's strut, just started, is running: false once its start failed.
    func homeStarted() async -> Bool
    /// Pings the agent in its DM: true once it answers.
    func pingAgent() async -> Bool
    /// Starts the Mac's strut on `HomeParts.client`, for dictation only:
    /// scheduler off, no bridge, no agent. A failure is quiet.
    func startClient()
    /// Lets a sync under way end, then tries once more, if it is running.
    func syncClient() async
    /// What dictation learned or undid in its memory from `since` (its last
    /// push that landed; nil: everything), as `dictation/changes-since`
    /// gives it; nil when it isn't running or couldn't say.
    func clientChanges(since: AgentKit.JSONValue?) async -> AgentKit.JSONValue?
    /// Replays `changes` into this Mac's own strut, just started, with
    /// `dictation/apply-changes`: true once they are in.
    func applyChanges(_ changes: AgentKit.JSONValue) async -> Bool
    /// Stops it (its own folder; Peel Home's is never its).
    func stopClient()
}

/// Peel Home moving between this Mac and a home server (docs/always-on.md,
/// "How a move works"), by stopping this Mac's strut and bridge and running
/// strut's `move` over their folders. Two bridges with the agent's key must
/// never run at once, so the mark that Peel Home has gone (`Brain.moved`)
/// is kept before anything stops, and taken off only once nothing can have
/// arrived on the box (it still waits for a move) or the box's copy is back here.
@MainActor
public struct PeelHomeMove {
    public enum Step: Sendable, Equatable {
        /// `sending`: out to the box, or back from it.
        case checking, sending, waiting
    }

    public enum Outcome: Sendable, Equatable {
        /// On the box, and the agent answered from there.
        case movedOut(MovedHome)
        /// Refused before anything stopped, or put back as it was: Peel Home is on this Mac.
        case unchanged(String)
        /// Sent, or it may have arrived: this Mac's strut and bridge stay
        /// stopped until the agent answers from the box or the person chooses.
        case unanswered(MovedHome, String)
        /// Back here and started; whether the agent answered yet.
        case movedBack(answered: Bool)
        /// Still on the box, this Mac's stopped: why.
        case stillAway(String)
    }

    let mover: any HomeMover
    let local: any PeelHomeLocal
    let parts: HomeParts
    let now: () -> Date

    public init(mover: any HomeMover, local: any PeelHomeLocal, parts: HomeParts, now: @escaping () -> Date = Date.init) {
        self.mover = mover
        self.local = local
        self.parts = parts
        self.now = now
    }

    /// Moves Peel Home to the box `link` names: checked first (the box
    /// empty, its strut this one's version, the code taken), then marked
    /// moved and stopped here, sent, and the agent pinged. A failed send that
    /// left the box still waiting changed nothing: started again here.
    public func out(_ link: HomeLink, progress: (Step) -> Void = { _ in }) async -> Outcome {
        // Without it the box's bridge could never start, and this Mac's would be stopped for nothing.
        guard !parts.identity.isEmpty else {
            return .unchanged("Peel couldn't read your assistant's account, which moves with Peel Home. " + Self.stillHere)
        }
        progress(.checking)
        do {
            guard try await mover.check(link, parts) == .receive else {
                return .unchanged("That home server already holds a Peel Home, so it can't take this one. " + Self.stillHere)
            }
        } catch {
            return .unchanged(PeelError.noted(error, couldNot: "move Peel Home") + " " + Self.stillHere)
        }
        let home = MovedHome(host: link.host, date: now())
        do {
            try local.keep(.moved(home))
        } catch {
            return .unchanged(PeelError.noted(error, couldNot: "move Peel Home") + " " + Self.stillHere)
        }
        progress(.sending)
        let callbacks = await local.stopHome()
        let peer: HomePeer?
        do {
            peer = try await mover.send(link, parts, callbacks: callbacks)
        } catch {
            let why = PeelError.noted(error, couldNot: "send Peel Home")
            // Only a box that refused it, and still waits, has none of it: one
            // still saying "receive" may be unpacking an upload whose answer was lost.
            guard error is HomeMoveRefused, (try? await mover.check(link, parts)) == .receive,
                  (try? local.keep(.thisMac)) != nil else {
                startClient(peer: nil)
                return .unanswered(home, why + " " + Self.mayHaveArrived)
            }
            local.startHome()
            return .unchanged(why + " " + Self.stillHere)
        }
        startClient(peer: peer)
        return await answered(home, progress: progress)
    }

    /// Why `link` can't bring Peel Home back from `home`: it names another box.
    public static func refusal(_ link: HomeLink, from home: MovedHome) -> String? {
        link.host.lowercased() == home.host.lowercased() ? nil
            : "That link is from \(link.host), but Peel Home moved to \(home.host). Open the link on that home server's page."
    }

    /// Pings the agent again after a move it had not answered.
    public func pingAgain(_ home: MovedHome, progress: (Step) -> Void = { _ in }) async -> Outcome {
        await answered(home, progress: progress)
    }

    /// Brings Peel Home back from the box `link` names, which has stopped
    /// it and packed it: fetched into this Mac's folders (strut sets aside
    /// anything there), then unmarked, started and pinged. A failed fetch
    /// leaves it on the box and this Mac's stopped.
    public func back(_ link: HomeLink, from moved: MovedHome, progress: (Step) -> Void = { _ in }) async -> Outcome {
        var home = moved
        // Only the box it went to: any page can open a link, and another box's would bring in its strut and agent.
        if let refusal = Self.refusal(link, from: moved) { return .stillAway(refusal) }
        progress(.checking)
        let env: [String: String]
        var unpushed: AgentKit.JSONValue?
        do {
            guard try await mover.check(link, parts) == .sendBack else {
                return .stillAway("Your home server is waiting for a move, not sending one back. Peel Home is still there.")
            }
            progress(.sending)
            // Any sync under way ends first, so nothing writes beside the fetch. Its own try rarely lands: Send back
            // stopped the box's strut. So what dictation changed here since the last push that landed is read now,
            // and replayed into Peel Home's own strut once it is back.
            await local.syncClient()
            unpushed = await local.clientChanges(since: HomeClient.pushedUntil(in: parts.client))
            local.stopClient()
            // This Mac's copy from the move, kept to fall back on, if the agent never answered from the box.
            home = setAside(home)
            env = try await mover.fetch(link, parts)
        } catch {
            local.startClient()
            return .stillAway(PeelError.noted(error, couldNot: "bring Peel Home back") + " It's still on your home server.")
        }
        // The key strut's secrets are encrypted with now; the same one unless the box made its own.
        // This Mac's is put back if Peel Home can't start here, for this Mac's copy to read.
        let previousKey = try? parts.secretKey.read()
        let restoreKey = { if let previousKey { try? parts.secretKey.write(previousKey) } }
        if let key = env["STRUT_SECRET_KEY"], key.count == 64, (try? BundledStrut.secretKey(in: parts.secretKey)) != key {
            do { try parts.secretKey.write(Data(key.utf8)) } catch {
                return .stillAway(PeelError.noted(error, couldNot: "keep Peel Home's key")
                    + " Its folders are on this Mac, but Peel won't start them until it can.")
            }
        }
        // Account › Connections' grants stayed in this Mac's copy.
        if let copy = home.strutCopy.map({ parts.strut.deletingLastPathComponent().appending(path: $0) }),
           FileManager.default.fileExists(atPath: copy.appending(path: MCPGrants.file).path) {
            try? MCPGrants.read(in: copy).write(in: parts.strut)
        }
        do {
            try local.keep(.thisMac)
        } catch {
            restoreKey()
            return .stillAway(PeelError.noted(error, couldNot: "finish bringing Peel Home back")
                + " Its folders are on this Mac, but Peel won't start them until it can record that.")
        }
        local.startHome()
        // Folders strut can't open leave the agent nowhere: marked moved again, so this Mac's copy is offered.
        guard await local.homeStarted() else {
            try? local.keep(.moved(home))
            restoreKey()
            local.startClient()
            return .stillAway("Peel Home came back, but Peel's strut couldn't start with it. Your home server kept what it sent "
                + "in its data folder. To carry on here as of the move, turn off Peel Home.")
        }
        // The client's folder goes only once what it learned is in Peel Home's memory; else it stays, and its next
        // push (a move out again) replays it.
        if let changes = unpushed, changes.array?.isEmpty == false, await !local.applyChanges(changes) {
            try? parts.homePeer?.delete()
        } else {
            removeClient()
        }
        progress(.waiting)
        return .movedBack(answered: await local.pingAgent())
    }

    /// Puts this Mac's copy from the move back in place, for a box that is
    /// gone: what happened there since is lost. Anything at the folders'
    /// own names (a move back cut short) is set aside first. Then started.
    public func useThisMacCopy(_ home: MovedHome) throws {
        let stamp = Self.stamp(now())
        for (folder, copy) in [(parts.strut, home.strutCopy), (parts.bridge, home.bridgeCopy)] {
            guard let copy else { continue }
            let kept = folder.deletingLastPathComponent().appending(path: copy)
            guard FileManager.default.fileExists(atPath: kept.path) else { continue }
            if FileManager.default.fileExists(atPath: folder.path) {
                try FileManager.default.moveItem(at: folder, to: Self.free(folder.appendingPathExtension("old-\(stamp)")))
            }
            try FileManager.default.moveItem(at: kept, to: folder)
        }
        try local.keep(.thisMac)
        // Only now: until the copy is back in place, dictation keeps the client's strut.
        local.stopClient()
        removeClient()
        local.startHome()
    }

    /// The Mac's strut for dictation while Peel Home is on the box, on a
    /// folder made now from Peel Home's, still in place (`HomeClient`), and
    /// the box's peer record kept for it.
    private func startClient(peer: HomePeer?) {
        if let peer, let item = parts.homePeer { try? peer.keep(in: item) }
        try? HomeClient.prepare(parts.client, from: parts.strut)
        local.startClient()
    }

    /// The Mac's strut for dictation, gone with the box's peer record.
    private func removeClient() {
        try? HomeClient.remove(parts.client)
        try? parts.homePeer?.delete()
    }

    /// The agent pinged; once it answers, the move is kept as done and this
    /// Mac's folders set aside under `<name>.moved-<date>`, marked first so a
    /// crash between leaves them where `useThisMacCopy` finds them.
    private func answered(_ home: MovedHome, progress: (Step) -> Void) async -> Outcome {
        progress(.waiting)
        guard await local.pingAgent() else {
            return .unanswered(home, "Peel Home was sent, but your assistant hasn't answered from your home server yet. "
                + "This Mac keeps its own stopped, so two never run at once.")
        }
        var done = home
        done.answered = true
        return .movedOut(setAside(done))
    }

    /// This Mac's folders set aside under `<name>.moved-<date>`, kept in the
    /// mark first so a crash between leaves them where `useThisMacCopy` finds
    /// them; once only (a move back may come before the agent answered).
    private func setAside(_ home: MovedHome) -> MovedHome {
        guard home.strutCopy == nil else { return home }
        var kept = home
        let date = Self.day(home.date)
        let strutCopy = Self.free(parts.strut.appendingPathExtension("moved-\(date)"))
        let bridgeCopy = Self.free(parts.bridge.appendingPathExtension("moved-\(date)"))
        kept.strutCopy = strutCopy.lastPathComponent
        kept.bridgeCopy = bridgeCopy.lastPathComponent
        // Marked moved already: a failure here only leaves the folders under their own names.
        try? local.keep(.moved(kept))
        try? FileManager.default.moveItem(at: parts.strut, to: strutCopy)
        try? FileManager.default.moveItem(at: parts.bridge, to: bridgeCopy)
        return kept
    }

    /// Removes the folders set aside beside `folder` (`<name>.moved-…`,
    /// `<name>.old-…`) and the client's (`<name>.client`): with the account,
    /// since they hold the agent's key, strut's secrets and the box's token.
    public nonisolated static func eraseCopies(of folder: URL) throws {
        let parent = folder.deletingLastPathComponent(), name = folder.lastPathComponent
        let names = (try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? []
        for other in names where other.hasPrefix(name + ".moved-") || other.hasPrefix(name + ".old-") || other == HomeClient.folder(for: folder).lastPathComponent {
            try FileManager.default.removeItem(at: parent.appending(path: other))
        }
    }

    static let stillHere = "Nothing changed; Peel Home is still on this Mac."
    static let mayHaveArrived = "It may have reached your home server, so this Mac keeps its own stopped: two must never run at once."

    /// `url`, or `url-2`, `url-3`… if something already has that name.
    static func free(_ url: URL) -> URL {
        var candidate = url, n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = url.deletingLastPathComponent().appending(path: "\(url.lastPathComponent)-\(n)")
            n += 1
        }
        return candidate
    }

    static func day(_ date: Date) -> String {
        date.formatted(.iso8601.year().month().day().dateSeparator(.dash))
    }

    static func stamp(_ date: Date) -> String {
        date.formatted(.iso8601.year().month().day().dateSeparator(.dash).time(includingFractionalSeconds: false).timeSeparator(.omitted))
    }
}
