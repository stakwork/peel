import Foundation
import Observation
import PeelCore

/// What a device does around its Stadeum pairing beyond keeping it: the
/// Mac puts the orgs on its strut as peers and hands their tokens to its
/// bridge (`MacStadeumHost`); the iPhone, with no strut, needs none of it.
@MainActor
public protocol StadeumHost: AnyObject {
    /// `link` is about to be kept in place of `kept` (a pairing or a
    /// renewal): what the host keeps per workspace drops what no longer
    /// holds. A throw keeps nothing.
    func stadeum(willKeep link: HiveLink, replacing kept: HiveLink?) throws
    /// `link` is kept; `changed`: its orgs are not those in use before
    /// (another set, or no longer revoked).
    func stadeum(kept link: HiveLink, changed: Bool)
    /// Stadeum no longer knows this device: the orgs' tokens stop being
    /// used now (`Stadeum.live` is empty).
    func stadeumRevoked()
    /// The person disconnected: `actor`'s orgs are let go, the kept item
    /// already deleted. A throw is said as the problem.
    func stadeumDisconnected(actor: String?) throws
}

/// The person's Stadeum workspaces on this device (Hive's device flow, the
/// person knows it as Stadeum; strut's specs/DESKTOP.md §2): paired once,
/// the credential and each org's token kept with the account
/// (`Profile.hive`, the Keychain for an app profile), renewed whenever due
/// while the account is open. One for the Mac and the iPhone alike
/// (`AppModel.stadeum`): the Mac's host puts the orgs on its strut
/// (`StadeumHost`); the iPhone opens an org's pages on that org's own strut
/// (`opening`; strut's specs/DESKTOP.md, "A device with no strut of its
/// own"). Also the apps listed, the workspaces' and on the Mac the person's
/// own (`readApps`).
@MainActor @Observable
public final class Stadeum {
    public enum Status: Equatable, Sendable {
        case off
        /// A code waiting for the person's yes in Stadeum.
        case pairing(HiveClient.Pairing)
        case connected
        /// Stadeum no longer knows this device (revoked, or never collected): connect again.
        case needsPairing
    }

    public private(set) var status = Status.off
    /// What is kept: the orgs, and those Stadeum gave no record for.
    public private(set) var link: HiveLink?
    /// The last thing that went wrong, in words; nil once something works.
    public var problem: String?
    /// Stadeum answered 401 (`HiveLink.revokedAt`, kept): the orgs stay
    /// listed until paired again, but their tokens are no longer used (`live`).
    public var revoked: Bool { link?.revokedAt != nil }
    /// The apps listed, A–Z (`readApps`).
    public var apps: [WorkspaceApp] = []
    /// What the device's host does beyond keeping the pairing; none on the iPhone.
    @ObservationIgnored public weak var host: (any StadeumHost)?

    /// The orgs in use: none once revoked.
    public var live: [HivePeer] { revoked ? [] : link?.peers ?? [] }
    /// Whether a read of `apps` is under way.
    public private(set) var readingApps = false
    /// The workspaces whose apps the last read could not read, by peer id:
    /// what they listed before is kept.
    public private(set) var unreadApps: [String] = []
    /// Whether an account is open (`open`): pairing needs one.
    public var isOpen: Bool { profile != nil }

    @ObservationIgnored private var profile: Profile?
    @ObservationIgnored private var pairing: Task<Void, Never>?
    @ObservationIgnored private var renewing: Task<Void, Never>?
    @ObservationIgnored private var appsReading: Task<Void, Never>?
    /// The pairing's wait for its next poll, which `cameToFront` cuts short.
    @ObservationIgnored private var nap: Task<Void, Never>?
    /// Peel came to the front while a pairing's poll was in flight: its next wait is skipped.
    @ObservationIgnored private var pollSoon = false
    /// Counts resets: a pairing, renewal or read begun before the last one
    /// keeps nothing and says nothing (the account closed, or Disconnect).
    @ObservationIgnored private var generation = 0
    /// The Hive a profile pairs with (`HiveClient(for:)`); a test's stand-in.
    @ObservationIgnored var client: (Profile) -> HiveClient = { HiveClient(for: $0) }

    public init() {}

    // MARK: - The pairing

    /// The account opened: what it kept, renewed whenever due while it
    /// stays open, and with `renewNow` at once too (the Mac, as its agent
    /// opens, so a Mac revoked in Stadeum says so; the iPhone, which opens
    /// it at every unlock, waits until it is due).
    public func open(_ profile: Profile, renewNow: Bool = true) {
        close()
        self.profile = profile
        do {
            link = try HiveLink.read(from: profile.hive)
        } catch {
            problem = PeelError.noted(error, couldNot: "read your Stadeum connection")
        }
        guard link != nil else { return }
        status = revoked ? .needsPairing : .connected
        keepRenewed(now: renewNow)
    }

    /// The account closed (on the iPhone, locked too): everything let go,
    /// the person's own apps kept. `open` reads it again.
    public func close() {
        reset()
        profile = nil
    }

    /// Connect Stadeum: a code to approve in Stadeum, naming this device
    /// `name`, polled until the person answers there or it runs out.
    public func connect(as name: String) {
        guard let profile else { return }
        pairing?.cancel()
        problem = nil
        pollSoon = false
        let client = client(profile)
        let generation = generation
        pairing = Task {
            do {
                // When the code runs out, by this device's clock: no later than Hive's.
                let asked = Date()
                let pairing = try await client.start(name: name)
                // Cancelled while Stadeum answered: its code is never shown.
                try Task.checkCancellation()
                status = .pairing(pairing)
                let deadline = asked.addingTimeInterval(TimeInterval(pairing.expiresIn))
                switch try await client.answer(to: pairing, name: name, until: deadline,
                                               wait: { await self.napUntilNextPoll($0) }) {
                case .pending:
                    return
                case .denied:
                    settle("It was turned down in Stadeum.")
                case .expired:
                    // Approved or not, Peel collects it only once it is back in front.
                    let minutes = Formatting.count(max(1, (pairing.expiresIn + 59) / 60), "minute")
                    settle(Date() >= deadline
                        ? "The code ran out before pairing finished. Connect again, then approve it in Stadeum and come back to Peel within \(minutes)."
                        : "Stadeum no longer has this code, so pairing didn't finish. Connect again.")
                case .paired(let link):
                    // Cancelled, or the account closed, while Stadeum answered: nothing kept.
                    guard !Task.isCancelled, generation == self.generation else { return }
                    try keep(link)
                    status = .connected
                    keepRenewed(now: false)
                }
            } catch is CancellationError {
            } catch {
                settle(PeelError.noted(error, couldNot: "connect Stadeum"))
            }
        }
        /// Ends this pairing with `problem`, unless it was cancelled: a newer one may be under way.
        func settle(_ problem: String) {
            guard !Task.isCancelled, generation == self.generation else { return }
            self.pairing = nil
            status = link == nil ? .off : .needsPairing
            self.problem = problem
        }
    }

    public func cancelPairing() {
        pairing?.cancel()
        pairing = nil
        status = link == nil ? .off : .needsPairing
    }

    /// Disconnect: the credential and the tokens gone from this device, and
    /// the host lets go of the orgs. Stadeum keeps the device until it is
    /// revoked there, and its tokens age out in a week.
    public func disconnect() {
        guard let profile else { return }
        let actor = link?.actor
        reset()
        var failed: (any Error)?
        do { try profile.hive.delete() } catch { failed = error }
        do { try host?.stadeumDisconnected(actor: actor) } catch { failed = failed ?? error }
        if let failed { problem = PeelError.noted(failed, couldNot: "forget the Stadeum connection") }
    }

    /// Peel came back to the front: a pairing under way polls Hive now (the
    /// person likely just approved it there, on the iPhone in Safari), and
    /// the workspaces are renewed if due.
    public func cameToFront() {
        if case .pairing = status {
            // Waiting: woken now. Polling: the next wait is skipped.
            if let nap { nap.cancel() } else { pollSoon = true }
        }
        renewIfDue()
    }

    /// The pairing's wait between polls: none when Peel has just come to the front.
    private func napUntilNextPoll(_ duration: Duration) async {
        if pollSoon {
            pollSoon = false
            return
        }
        let nap = Task<Void, Never> { try? await Task.sleep(for: duration) }
        self.nap = nap
        await withTaskCancellationHandler { await nap.value } onCancel: { nap.cancel() }
        if self.nap == nap { self.nap = nil }
    }

    /// Renews now if due: Peel back in front (`cameToFront`), where the
    /// hourly look may have slept through its turn.
    func renewIfDue() {
        guard let link, link.revokedAt == nil, link.due() else { return }
        keepRenewed(now: true)
    }

    /// Renews whenever due, looking every hour while the account is open,
    /// and `now` too.
    private func keepRenewed(now: Bool) {
        renewing?.cancel()
        let generation = generation
        renewing = Task {
            var first = now
            while !Task.isCancelled, generation == self.generation {
                // A revoked device's credential answers nothing but 401: it waits to be paired again.
                if let link, link.revokedAt == nil, first || link.due() { await renew(link) }
                first = false
                try? await Task.sleep(for: .seconds(3600))
            }
        }
    }

    private func renew(_ link: HiveLink) async {
        let generation = generation
        do {
            let renewed = try await HiveClient(hive: link.hive).renew(link)
            // Closed, disconnected or paired again meanwhile: nothing of it is kept or said.
            guard !Task.isCancelled, generation == self.generation, self.link?.credential == link.credential else { return }
            guard let renewed else {
                // Revoked in Stadeum: its tokens may still work until they expire, so they stop
                // being used now, and after a restart or an unlock too (kept with the link).
                var revokedLink = link
                revokedLink.revokedAt = Date()
                if let profile { try? revokedLink.write(to: profile.hive) }
                self.link = revokedLink
                // A pairing under way (Connect again) keeps its code on the screen.
                if case .pairing = status {} else { status = .needsPairing }
                host?.stadeumRevoked()
                return
            }
            try keep(renewed)
        } catch is CancellationError {
        } catch {
            // Tried again within the hour; the tokens last a week.
            guard generation == self.generation, self.link?.credential == link.credential else { return }
            problem = PeelError.noted(error, couldNot: "renew your Stadeum workspaces")
        }
    }

    /// Keeps `link` (the Keychain first), and tells the host.
    private func keep(_ link: HiveLink) throws {
        guard let profile else { return }
        let kept = self.link
        try host?.stadeum(willKeep: link, replacing: kept)
        try link.write(to: profile.hive)
        let changed = revoked || kept?.peers != link.peers
        self.link = link
        problem = nil
        host?.stadeum(kept: link, changed: changed)
    }

    private func reset() {
        generation += 1
        pairing?.cancel()
        renewing?.cancel()
        appsReading?.cancel()
        pairing = nil
        renewing = nil
        appsReading = nil
        nap = nil
        pollSoon = false
        readingApps = false
        unreadApps = []
        status = .off
        link = nil
        problem = nil
        // The workspaces' go with them; the person's own are not Stadeum's.
        apps.removeAll { $0.peer != nil }
    }

    // MARK: - Calls with Jamie

    /// A call with Jamie in it for `peer`'s workspace: the link Hive makes
    /// for this device's person (`HiveClient.startCall`, docs/hive-calls.md).
    public func callLink(on peer: HivePeer) async throws -> String {
        guard let link, !revoked, live.contains(where: { $0.id == peer.id }) else {
            throw PeelError("Connect Stadeum to call with Jamie from \(peer.name).")
        }
        return try await HiveClient(hive: link.hive).startCall(link, workspace: peer.id)
    }

    // MARK: - Opening an org's page

    /// How something opens on its org's own strut, for a device with no
    /// strut of its own, or why it does not.
    public enum Opening: Equatable {
        case page(OrgPageRequest)
        /// No Stadeum on this device, or Stadeum no longer knows it.
        case connectFirst
        /// An org this device holds no token for.
        case notPaired(String)
        /// On the brain's own strut, which only the Mac reaches.
        case onMac
    }

    /// How a deliverable from the agent's DM opens: on its org's strut.
    /// `title` is what the person calls it (the artifact's), for the page's title.
    public func opening(_ handle: AgentArtifact.Handle, title: String? = nil) -> Opening {
        handle.onOrg.map { opening($0, title: title) } ?? .onMac
    }

    /// How a workspace's app opens: on its own strut.
    public func opening(_ app: WorkspaceApp) -> Opening {
        app.peer.map { opening(OrgPage.app(app.name, on: $0), title: app.title) } ?? .onMac
    }

    private func opening(_ page: OrgPage, title: String? = nil) -> Opening {
        guard let peer = live.first(where: { $0.id == page.peer }) else {
            return link == nil || revoked ? .connectFirst : .notPaired(page.peer)
        }
        guard let base = URL(string: peer.baseUrl), let url = page.url(on: base) else { return .notPaired(page.peer) }
        return .page(OrgPageRequest(url: url, token: peer.token, peer: peer.id, workspace: peer.name,
                                      title: title))
    }

    // MARK: - The apps

    /// Reads the apps again, all at once: `own`, the person's own (the
    /// Mac's strut; nil on the iPhone, which has none), and with
    /// `workspaces` each live workspace's pinned apps with `pinned` (the
    /// Mac through its strut, the iPhone on each org's own). A newer read
    /// replaces one under way, unless it would read less; what is not read,
    /// or cannot be, keeps what it last listed. `still` says, when the
    /// reads answer, whether what they read from is still in use (the Mac:
    /// the same strut). The read, for a caller that waits for it (a pull to
    /// refresh); nil when one under way reads more.
    @discardableResult
    public func readApps(
        own: (@Sendable () async throws -> [WorkspaceApp])?,
        workspaces: Bool = true,
        pinned: @escaping @Sendable (HivePeer) async throws -> [WorkspaceApp],
        still: @escaping @MainActor () -> Bool = { true }
    ) -> Task<Void, Never>? {
        // A read under way reads the workspaces too: not cut short for less.
        guard workspaces || appsReading == nil else { return nil }
        let peers = live
        appsReading?.cancel()
        let reading = workspaces ? peers : []
        readingApps = true
        appsReading = Task {
            // Done, unless a newer read took its place.
            defer {
                if !Task.isCancelled {
                    appsReading = nil
                    readingApps = false
                }
            }
            // By peer, the person's own under nil.
            let read = await withTaskGroup(of: (String?, [WorkspaceApp]?).self) { group in
                if let own { group.addTask { (nil, try? await own()) } }
                for peer in reading {
                    group.addTask { (peer.id, try? await pinned(peer)) }
                }
                var read: [String?: [WorkspaceApp]] = [:]
                for await (peer, apps) in group {
                    if let apps { read[peer] = apps }
                }
                return read
            }
            // A newer read, or the source or the workspaces changed meanwhile: theirs, not this.
            guard !Task.isCancelled, still(), live.map(\.id) == peers.map(\.id) else { return }
            if workspaces {
                let unread = reading.map(\.id).filter { read[$0] == nil }
                if unreadApps != unread { unreadApps = unread }
            }
            let sources: [String?] = (own == nil ? [] : [nil]) + peers.map(\.id)
            let listed = WorkspaceApp.byTitle(sources.flatMap { peer in read[peer] ?? apps.filter { $0.peer == peer } })
            if apps != listed { apps = listed }
        }
        return appsReading
    }

    /// Stops a read of the apps under way: what it read is not kept.
    public func stopReadingApps() {
        appsReading?.cancel()
        appsReading = nil
        readingApps = false
    }
}

/// An org's page as a device with no strut opens it (`Stadeum.opening`):
/// strut's UI there showing one thing alone, with the person's token for
/// the org. The token is handed over twice and never in an address (strut's
/// specs/DESKTOP.md, "A device with no strut of its own"): as the first
/// request's bearer, which a swarm's gate wants for the page itself, and in
/// the page's own storage before its script runs, where strut's UI keeps
/// the key it sends on every call (`handOver`). Never described with its token.
public struct OrgPageRequest: Identifiable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible,
    CustomReflectable {
    public let id = UUID()
    /// strut's UI showing it alone; no credential in it.
    public let url: URL
    /// The person's token for the org: never shown, logged or kept.
    public let token: String
    /// The org's peer id.
    public let peer: String
    /// The org as the person reads it.
    public let workspace: String
    /// The app's or artifact's own title, when it has one: what a sheet
    /// shows before the workspace. Not part of what makes two requests the same.
    public var title: String? = nil

    public var description: String { "org page on \(workspace)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["workspace": workspace]) }

    public static func == (a: Self, b: Self) -> Bool { a.id == b.id }

    /// `url`'s origin as a page reads it (`location.origin`).
    public var origin: String { Self.origin(of: url) ?? "" }

    /// `url`'s origin as a page reads it: the scheme, the host in lower
    /// case, and a port only when not the scheme's own.
    public static func origin(of url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), let host = url.host()?.lowercased() else { return nil }
        let port = url.port.flatMap { ($0 == 443 && scheme == "https") || ($0 == 80 && scheme == "http") ? nil : $0 }
        return "\(scheme)://\(host)" + (port.map { ":\($0)" } ?? "")
    }

    /// The folder strut's UI is served from (`/`, or a swarm's `/lab/`):
    /// `url`'s path, which `StrutUI.page` ends with its `/`.
    public var folder: String { url.path(percentEncoded: true) }

    /// Whether `other` is strut's: on `url`'s origin, in its UI's folder
    /// (a swarm's `/lab/` shares its host with other services).
    public func serves(_ other: URL) -> Bool {
        Self.origin(of: other) == origin && other.path(percentEncoded: true).hasPrefix(folder)
    }

    /// The request that loads it: the token as its bearer.
    public var request: URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    /// The script that hands the token to strut's UI (its `strut/apiKey`
    /// in `sessionStorage`), run before the page's own and only in its
    /// folder on the org's origin. The strings as JSON literals.
    public var handOver: String {
        let encoder = JSONEncoder()
        // No `/` escaped: the literals are a script's, never inside a tag.
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let literals = (try? encoder.encode([origin, folder, token])).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
        return """
        (() => { const [origin, folder, key] = \(literals);
          if (location.origin === origin && location.pathname.startsWith(folder)) {
            try { sessionStorage.setItem("strut/apiKey", key); } catch (e) {} } })();
        """
    }
}

extension WorkspaceApp {
    /// Where it comes from, as the person reads it: `@workspace`, or Yours.
    public var source: String { peer.map { "@\($0)" } ?? Self.yours }
    public static let yours = "Yours"

    /// Under its title and at its card's foot: `@workspace · v14`, the
    /// source when asked (several sources listed).
    public func caption(showsSource: Bool) -> String? {
        let parts = [showsSource ? source : nil, version].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Whether a search for `query` finds it: in its title, what it is for,
    /// or where it comes from (`@workspace`, Yours).
    public func matches(_ query: String) -> Bool {
        [title, about ?? "", source].contains { ChatSections.matches($0, query: query) }
    }

    /// The sources `apps` come from, as the person reads them: Yours first
    /// when any is the person's own, then each workspace's `@peer` A–Z.
    public static func sources(of apps: [WorkspaceApp]) -> [String] {
        let peers = Set(apps.compactMap(\.peer)).sorted().map { "@\($0)" }
        return (apps.contains { $0.peer == nil } ? [yours] : []) + peers
    }

    /// `apps` from `source` (all when nil) that a search for `query` finds,
    /// in their order.
    public static func filter(_ apps: [WorkspaceApp], query: String, source: String?) -> [WorkspaceApp] {
        apps.filter { (source == nil || $0.source == source) && $0.matches(query) }
    }
}
