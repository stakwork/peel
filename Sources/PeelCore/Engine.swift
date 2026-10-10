import Foundation
import Network
import Sphinxrs

/// Drives one account against the Sphinx core.
///
/// The core is a library of pure functions: each call takes the seed, a unique
/// time and the whole state, and returns a `RunReturn` describing what the client
/// must now do. `Engine` is that client. It commits the state the core hands back,
/// records what arrived, and performs the subscribes and publishes it asked for.
public actor Engine {
    public nonisolated let events: AsyncStream<Event>
    public nonisolated let storage: Storage
    let emit: AsyncStream<Event>.Continuation

    let seed: String
    let network: String
    private let deviceID: String
    var alias: String
    var photoURL: String
    var server: ServerAddress?
    private var allowUntrustedCertificate = false

    private(set) var state: [String: Data]
    var clock: UniqueClock
    public private(set) var connection: ConnectionState = .offline(retryIn: nil)
    private(set) var transport: Transport?
    private var listener: Task<Void, Never>?
    private var keepConnected = false
    private var reconnectTask: Task<Void, Never>?
    /// Set by `close()`; nothing connects or refreshes after it.
    private(set) var closed = false
    /// `cameOnline` has run on this connection; see `waitUntilRegistered`.
    private var cameOnlineHere = false
    /// This connection's pings (`keepAlive`), and the system's network
    /// changes while the engine keeps connected (`watchNetwork`).
    private var keepAliveTask: Task<Void, Never>?
    private var networkWatch: Task<Void, Never>?
    /// The sends a reconnect makes again by itself (`resendRecent`).
    private var resendTask: Task<Void, Never>?
    /// The tags of the reconnect's candidates that `checkPendingSends` asked
    /// the server about on this connection, and the tags its records named
    /// (any status), nil until they come; see `resendRecent`.
    private(set) var resendGate: ResendGate?
    /// When this connection came up, and how many in a row went within
    /// `shortLived` of coming up: such a drop backs off rather than
    /// reconnecting at once (`connectionAnswers`).
    private var connectedAt: ContinuousClock.Instant?
    private var shortLivedDrops = 0
    static let shortLived: Duration = .seconds(60)

    /// Payments waiting for us while we were offline: payment hash and tag → the
    /// ping time to acknowledge once the payment lands.
    private var pingsByHash: [String: UInt64] = [:]
    private var pingsByTag: [String: UInt64] = [:]
    /// Pending payments old enough that the server must have a record of
    /// them if it ever got them, asked about on this connection; see
    /// `checkPendingSends`.
    private var unrecordedPayments: Set<String> = []
    /// Contacts by the child index the core uses for them, so a live message's
    /// topic names its sender without a core call.
    private var contactsByChildIndex: [UInt64: String] = [:]
    /// Every tribe this account knows, joined or left, by pubkey.
    var tribes: [String: Tribe] = [:]
    /// The tribes server's replies and the tribe work in flight, this session.
    struct TribeWork {
        /// Member lists the tribes server sent for tribes this account owns.
        var memberLists: [String: TribeMembers.List] = [:]
        /// Join requests answered this session; see `answerJoinRequest`.
        var sentAnswers: Set<String> = []
        /// Tribes whose update the tribes server has confirmed, until `updateRegistry` takes it.
        var updated: Set<String> = []
        /// Tribes with an update or delete on its way; see `changeOwnedTribe`.
        var changing: Set<String> = []
        /// The background registry refresh; see `refreshTribesInBackground`.
        var refresh: Task<Void, Never>?
        var needsRefresh = false
        /// Tribes queued for the next round of the refresh alone; see `recheckIfStale`.
        var toRecheck: Set<String> = []
        /// When each tribe's last read record was asked for, this session.
        var readAt: [String: ContinuousClock.Instant] = [:]
    }
    var tribeWork = TribeWork()
    static let tribeRecheck: Duration = .seconds(5 * 60)
    /// Chats whose read marker was sent since `getReads` was last asked: its
    /// answer may predate the marker, so it is not applied to them.
    var readsSentSinceGetReads: Set<String> = []
    /// The highest server index of a message dropped unstored; see `Setting.droppedIndex`.
    private(set) var droppedIndex: Int64
    /// A restore from the words is replaying history; see `Setting.needsRestore`.
    var restoring: Bool
    /// Whether `recoverOwnPhoto` has run for this engine.
    var photoRecoveryDone = false
    /// The aliases each tribe echoed back on this account's own messages;
    /// with the account's own tribe alias, what a mention of it looks like there.
    private(set) var echoedAliases: [String: Set<String>]
    /// The background re-check of stored messages for mentions; see `checkMentionsIfNeeded`.
    var mentionScan: Task<Void, Never>?
    /// The server's replies about money and the money work in flight, this session.
    struct MoneyWork {
        /// A page of payment history asked for and not yet answered; the
        /// answer lands in `paymentPage` (see `fetchPaymentHistory`).
        var awaitingPayments = false
        var paymentPage: [PaymentRecord]?
        /// An invoice asked of the server (`request_invoice`) and not yet
        /// answered; the answer lands in `answeredInvoice` (see `serverInvoice`).
        var awaitingInvoice = false
        var answeredInvoice: String?
        /// See `reconcileInBackground`.
        var reconcile: Task<Void, Never>?
        var needsReconcile = false
        /// Received payments stored up to this row id are judged by the
        /// next complete history refresh (`Storage.markNotArrived`): those
        /// stored before the last one began, so each has had a whole
        /// refresh for its row to land. Starts at what was stored at launch.
        var judgedThrough: Int64 = 0
        /// Received payments to tell once the history confirms them, by row
        /// id (`Storage.Applied.announceable`): what a launch or a restore
        /// found stored never enters.
        var untold: Set<Int64> = []
        /// Invoices being paid (by payment hash) and attachments being
        /// bought (`"purchase <token>"`) in this session, so a second click
        /// can never pay twice while the first is being sent.
        var sendsInFlight: Set<String> = []
        /// An invite being cancelled: the server answers with the balance
        /// alone, so one at a time (`cancelInvite`).
        var cancellingInvite = false
        /// The tags of async pays a send is waiting for the server to take
        /// (`waitForAsyncPay`), true once it has answered with one.
        var asyncPays: [String: Bool] = [:]
    }
    var money = MoneyWork()

    /// Attachments: the decrypted cache and the uploads waiting to go, and
    /// the memes server's bearer token (memory only).
    let media: MediaStore
    var memesToken: (host: String, token: MemesServer.Token)?
    /// The memes server's payment templates, fetched once a session (`paymentTemplates`).
    var templateList: (host: String, templates: [PaymentTemplate])?
    /// The call server's ticket endpoint and presence feed; see `callConnection`.
    var calls: CallServer?
    /// Largest attachment sent or downloaded, and the most the cache keeps.
    static let attachmentLimit = 100_000_000
    static let mediaCacheLimit = 500_000_000
    /// Videos and recordings up to this size download as they show; larger
    /// ones wait to be asked for (images have no such rule: they are small).
    public static let autoDownloadLimit = 25_000_000
    /// Where the official apps keep attachments.
    static let defaultMemesHost = "memes.sphinx.chat"
    static let defaultCallServer = "chat.sphinx.chat"

    /// History fetches: the run in flight and those queued behind it.
    var history = HistoryCursor()
    var historyWatchdog: Task<Void, Never>?
    /// Each `poll` waiting to check again.
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    static let historyStall: Duration = .seconds(30)

    static let historyPageSize: UInt32 = 100
    /// How long publishes wait behind the register of a new child key; see `complete`.
    static let registerSettle: Duration = .milliseconds(750)

    public init(mnemonic: String, storage: Storage) throws {
        seed = try Sphinxrs.mnemonicToSeed(mnemonic: Self.normalise(mnemonic: mnemonic))
        self.storage = storage
        network = try storage.value(for: .network) ?? "bitcoin"
        state = try storage.loadCoreState()
        if let stored = try storage.value(for: .deviceID) {
            deviceID = stored
        } else {
            deviceID = UUID().uuidString
            try storage.set(deviceID, for: .deviceID)
        }
        alias = try storage.value(for: .alias) ?? ""
        photoURL = try storage.value(for: .photoURL) ?? ""
        server = try storage.value(for: .server).flatMap(ServerAddress.init)
        clock = UniqueClock(last: try storage.value(for: .clock).flatMap { UInt64($0) } ?? 0)
        let (stream, continuation) = AsyncStream<Event>.makeStream()
        events = stream
        emit = continuation
        let contacts = try Self.contacts(in: state)
        contactsByChildIndex = Self.index(contacts)
        tribes = Dictionary(try storage.tribes().map { ($0.pubkey, $0) }, uniquingKeysWith: { $1 })
        droppedIndex = try storage.value(for: .droppedIndex).flatMap { Int64($0) } ?? -1
        restoring = try storage.value(for: .needsRestore) == "1"
        echoedAliases = try storage.echoedOwnAliases()
        media = MediaStore(profile: storage.directory)
        // The profile lock means no other process is uploading; anything
        // still uploading was cut off, and can be retried.
        try storage.failInterruptedUploads()
        let stored = try storage.highestMessageID() ?? 0
        money.judgedThrough = stored
        _ = try storage.apply(Storage.Commit(contacts: contacts.map { ($0.pubkey, $0.contactKey != nil) }))
    }

    // MARK: - Connection

    /// Connects once and returns when the account is online. Pass the invite code
    /// only when creating the account. A dropped connection stays dropped.
    public func connect(inviteCode: String? = nil, allowUntrustedCertificate: Bool = false) async throws {
        keepConnected = false
        reconnectTask?.cancel()
        reconnectTask = nil
        self.allowUntrustedCertificate = allowUntrustedCertificate
        try await establish(inviteCode: inviteCode)
        try await waitUntilRegistered()
    }

    /// Connects and keeps reconnecting with backoff until `disconnect()`.
    /// Progress is reported through `.connection` events.
    public func start(allowUntrustedCertificate: Bool = false) {
        // Accounts restored before the restore learned to recover the photo
        // get it on their first start instead.
        guard !closed else { return }
        if !restoring { recoverOwnPhoto() }
        self.allowUntrustedCertificate = allowUntrustedCertificate
        keepConnected = true
        watchNetwork()
        guard connection != .connected, reconnectTask == nil else { return }
        reconnectTask = Task { [weak self] in await self?.reconnectLoop(attempt: 0) }
    }

    /// Skips the wait before the next reconnect attempt.
    public func reconnectNow() {
        guard keepConnected, connection != .connected, connection != .connecting else { return }
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in await self?.reconnectLoop(attempt: 0) }
    }

    public func disconnect() async {
        keepConnected = false
        reconnectTask?.cancel()
        reconnectTask = nil
        networkWatch?.cancel()
        networkWatch = nil
        tribeWork.refresh?.cancel()
        tribeWork.refresh = nil
        money.reconcile?.cancel()
        money.reconcile = nil
        await teardown()
        setConnection(.offline(retryIn: nil))
    }

    /// Disconnects for good and ends `events`, so whoever follows them lets
    /// go of this engine. For an account being closed: it does not connect again.
    public func close() async {
        closed = true
        await disconnect()
        await calls?.close()
        emit.finish()
    }

    private func establish(inviteCode: String?) async throws {
        guard let server else { throw Failure.noServer }
        await teardown()
        setConnection(.connecting)
        do {
            try await run { _, _ in try Sphinxrs.setNetwork(network: network) }
            let xpub = try Sphinxrs.xpubFromSeed(seed: seed, time: clock.next(), network: network)
            let loginTime = clock.next()
            let signature = try Sphinxrs.rootSignMs(seed: seed, time: loginTime, network: network)
            let transport = Transport(
                server: server, clientID: xpub, username: loginTime, password: signature,
                allowUntrustedCertificate: allowUntrustedCertificate
            )
            do {
                try await transport.connect()
                // Closed or disconnected while connecting.
                if closed || Task.isCancelled { throw CancellationError() }
            } catch {
                await transport.close()
                throw error
            }
            self.transport = transport
            listener = Task { [weak self] in
                for await message in transport.inbound {
                    await Engine.$handlingInbound.withValue(true) { await self?.receive(message) }
                }
                await self?.connectionClosed(transport)
            }
            try await run { time, state in
                try Sphinxrs.initialSetup(
                    seed: seed, uniqueTime: time, state: state, device: deviceID, inviteCode: inviteCode
                )
            }
            let tribeTopic = try Sphinxrs.getTribeManagementTopic(
                seed: seed, uniqueTime: clock.next(), state: StateCodec.encode(state)
            )
            try await transport.subscribe([tribeTopic])
            setConnection(.connected)
            connectedAt = .now
            keepAliveTask = Task { [weak self] in await self?.keepAlive(transport) }
            // A returning account is already registered; a new one comes online
            // when the server's registration reply lands (see `complete`).
            if isRegistered {
                await cameOnline()
            }
        } catch {
            await teardown()
            setConnection(.offline(retryIn: nil))
            throw error
        }
    }

    /// Registered, and `cameOnline` has asked for what it needs (history
    /// among it, so `isSyncingHistory` already says whether it is coming).
    private func waitUntilRegistered() async throws {
        try await poll(timeout: .seconds(30), failure: .registrationTimedOut) {
            isRegistered && cameOnlineHere ? () : nil
        }
    }

    /// Waits for something a server reply sets to land in the engine:
    /// checks now and again after each commit (`wakeWaiters`), and also
    /// every `interval` when what it waits for is not the engine's (the
    /// network), until `timeout`.
    func poll<T>(
        timeout: Duration, every interval: Duration? = nil, failure: Failure, _ check: () async -> T?
    ) async throws -> T {
        let deadline = ContinuousClock.now + timeout
        while true {
            if let value = await check() { return value }
            let now = ContinuousClock.now
            guard now < deadline else { throw failure }
            try await nextChange(before: interval.map { min(deadline, now + $0) } ?? deadline)
        }
    }

    /// Suspends until `wakeWaiters`, or `until`; cancellation throws.
    private func nextChange(before until: ContinuousClock.Instant) async throws {
        try Task.checkCancellation()
        let id = UUID()
        let timer = Task { [weak self] in
            try? await Task.sleep(until: until, clock: .continuous)
            await self?.wake(id)
        }
        defer { timer.cancel() }
        await withTaskCancellationHandler {
            await withCheckedContinuation { waiters[id] = $0 }
        } onCancel: {
            Task { [weak self] in await self?.wake(id) }
        }
        try Task.checkCancellation()
    }

    private func wake(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume()
    }

    /// Lets every `poll` check again: what it waits for may have changed.
    func wakeWaiters() {
        let woken = waiters
        waiters = [:]
        for waiter in woken.values { waiter.resume() }
    }

    private func reconnectLoop(attempt: Int) async {
        var attempt = attempt
        while keepConnected, !Task.isCancelled {
            if attempt > 0 {
                let delay = min(30, 2 << min(attempt - 1, 4))
                setConnection(.offline(retryIn: delay))
                try? await Task.sleep(for: .seconds(delay))
                if !keepConnected || Task.isCancelled { break }
            }
            do {
                try await establish(inviteCode: nil)
                // Dropped again while coming online (`connectionClosed`
                // leaves the reconnect to this loop): go again, backing off.
                if transport != nil { break }
                attempt += 1
            } catch {
                emit.yield(.connectionError(PeelError.readable(error)))
                attempt += 1
            }
        }
        // A cancelled loop has already been replaced or stopped.
        if !Task.isCancelled { reconnectTask = nil }
    }

    /// The connection went: the broker closed it, or (`retryAt: 0`, at once)
    /// it stopped answering pings.
    private func connectionClosed(_ closed: Transport, retryAt attempt: Int = 1) async {
        guard transport === closed else { return }
        transport = nil
        endConnectionWork()
        await closed.close()
        setConnection(.offline(retryIn: nil))
        if keepConnected, reconnectTask == nil {
            reconnectTask = Task { [weak self] in await self?.reconnectLoop(attempt: attempt) }
        }
    }

    /// How often the connection is pinged, the MQTT keep-alive, and how
    /// long an answer may take before the connection counts as gone.
    static let keepAliveInterval: Duration = .seconds(15)
    static let pingTimeout: Duration = .seconds(5)

    /// Whether the connection still answers: a ping, and one with no answer
    /// within `pingTimeout` is closed and, if the engine keeps connected,
    /// reconnected at once. Asked on the keep-alive's beat, on each network
    /// change and before a Retry, so a dead connection never looks connected
    /// for longer than that.
    func connectionAnswers() async -> Bool {
        guard let transport else { return false }
        if await transport.answersPing(within: Self.pingTimeout) { return true }
        // A link that keeps dying soon after it comes up backs off as a
        // failed connect would; one that lived a while reconnects at once.
        let lived = connectedAt.map { ContinuousClock.now - $0 } ?? .zero
        shortLivedDrops = lived < Self.shortLived ? shortLivedDrops + 1 : 0
        await connectionClosed(transport, retryAt: shortLivedDrops)
        return false
    }

    /// The MQTT keep-alive for one connection, until it goes.
    private func keepAlive(_ connection: Transport) async {
        while !Task.isCancelled {
            try? await Task.sleep(for: Self.keepAliveInterval)
            guard !Task.isCancelled, transport === connection, await connectionAnswers() else { return }
        }
    }

    /// Follows the system's network (Wi-Fi to cellular, offline to online):
    /// each change checks the connection at once rather than at the next
    /// keep-alive, and one that comes online skips the reconnect's wait.
    /// Only a change of status or of the interfaces counts (the monitor also
    /// reports changes of cost and the like), once it has settled for
    /// `networkSettle` (a switch comes as a burst); the first path it reports
    /// is the one already in use.
    private func watchNetwork() {
        guard networkWatch == nil else { return }
        networkWatch = Task { [weak self] in
            var last: (NWPath.Status, [String])?
            var settling: Task<Void, Never>?
            for await path in NWPathMonitor() {
                let now = (path.status, path.availableInterfaces.map(\.name))
                let changed = last.map { $0 != now } ?? false
                last = now
                guard changed else { continue }
                settling?.cancel()
                let online = path.status == .satisfied
                settling = Task { [weak self] in
                    try? await Task.sleep(for: Self.networkSettle)
                    guard !Task.isCancelled else { return }
                    await self?.networkChanged(online: online)
                }
            }
            settling?.cancel()
        }
    }

    static let networkSettle: Duration = .seconds(1)

    private func networkChanged(online: Bool) async {
        guard keepConnected else { return }
        if connection == .connected {
            _ = await connectionAnswers()
        } else if online {
            reconnectNow()
        }
    }

    private func teardown() async {
        endConnectionWork()
        listener?.cancel()
        listener = nil
        if let transport {
            self.transport = nil
            await transport.close()
        }
    }

    /// What belongs to one connection and ends with it.
    private func endConnectionWork() {
        cameOnlineHere = false
        // A reply to this connection's status query can only come on it.
        unrecordedPayments = []
        resendGate = nil
        connectedAt = nil
        keepAliveTask?.cancel()
        keepAliveTask = nil
        resendTask?.cancel()
        resendTask = nil
        stopHistoryWatchdog()
    }

    /// A page asked for on a connection that has gone never comes; the run
    /// stays in `history` and `cameOnline` asks for it again.
    func stopHistoryWatchdog() {
        historyWatchdog?.cancel()
        historyWatchdog = nil
    }

    #if DEBUG
    /// Tests only: a transport that never connected stands for one whose
    /// connection has just gone (its publishes throw `notConnected`).
    func useTransportForTesting(_ transport: Transport?) { self.transport = transport }
    #endif

    private func setConnection(_ state: ConnectionState) {
        guard connection != state else { return }
        connection = state
        emit.yield(.connection(state))
    }

    // MARK: - The core contract

    /// Runs one core call against the current state. The returned state is
    /// committed before this function first suspends, so no other call can ever
    /// run against stale state. For what the server sent (`receive`), a
    /// payment counts for no more than `arrived` says came (`cappedToArrived`).
    @discardableResult
    func run(
        expectedSender: String? = nil, arrived: [String: UInt64]? = nil,
        _ call: (_ time: String, _ state: Data) throws -> RunReturn
    ) async throws -> RunReturn {
        let time = clock.next()
        var result = try call(time, StateCodec.encode(state))
        if let arrived { result.msgs = Self.cappedToArrived(result.msgs, arrived) }
        let followUps = try commit(result, time: time, expectedSender: expectedSender)
        try await complete(result, followUps)
        return result
    }

    struct FollowUps {
        var acknowledgedPings: [UInt64] = []
        var justRegistered = false
        var restorePlan: MessageCounts?
        /// Tribes first seen in this call, whose names are still to be looked up.
        var discoveredTribes = false
        /// Purchases of our paid attachments to answer.
        var purchases: [Message] = []
        /// The balance went up (or changed at all with an invoice open,
        /// `balanceCallsForReconcile`), or someone's payment came: the server's
        /// history may now settle an invoice made here or confirm the sats.
        var reconcile = false
    }

    /// What received payments brought, as Peel takes it: never more than the
    /// server says arrived for that message index (`arrived`), and nothing
    /// when it says nothing. The core Peel links reports the amount the
    /// sender wrote in the onion (`handle_msg.rs` ignores the topic's amount,
    /// and peels against `u64::MAX`), which a modified client can set to
    /// anything. "From me" is capped too: the core also calls a message
    /// ours when its date decrypts with the sender's shared secret
    /// (`dec_ts_matches`), which any sender can arrange, and our own copies
    /// carry no payment, so nothing real is lost.
    static func cappedToArrived(_ msgs: [Msg], _ arrived: [String: UInt64]) -> [Msg] {
        msgs.map { msg in
            guard let msat = msg.msat else { return msg }
            var msg = msg
            msg.msat = msg.index.flatMap { arrived[$0] }.map { min($0, msat) }
            return msg
        }
    }

    /// What arrived with a live message or a page of history, by message
    /// index, as the server sent it: a live payment's topic ends with its
    /// index, time, payment hash and amount
    /// (`{root}/{pk}/{idx}/res/{device}/{kind}/{index}/{ts}/{hash}/{msat}`,
    /// the mixer's `stream_res_topic`); a page carries each payment's amount
    /// beside its onion (`StateCodec.paymentAmounts`).
    static func arrivedMsat(kind: String, topic parts: [Substring], payload: Data) -> [String: UInt64] {
        switch kind {
        case "batch":
            return StateCodec.paymentAmounts(inBatch: payload) ?? [:]
        case "msg", "msgs", "stream":
            guard parts.count > 9, let msat = UInt64(parts[9]) else { return [:] }
            return [String(parts[6]): msat]
        default:
            return [:]
        }
    }

    /// Whether a new balance calls for the server's history: sats came in,
    /// maybe for an invoice made here or a payment; or, with an invoice
    /// open, any change, since a payment in and one out between two
    /// notices can leave it no higher (payments review F11).
    static func balanceCallsForReconcile(
        _ balance: UInt64, stored: UInt64, invoiceOpen: () throws -> Bool
    ) rethrows -> Bool {
        guard balance != stored else { return false }
        return try balance > stored || invoiceOpen()
    }

    /// History rows that pay an invoice made here and still open: incoming,
    /// not failed, with its payment hash. One per invoice.
    static func invoicePayments(in page: [PaymentRecord], open: Set<String>) -> [PaymentRecord] {
        var seen: Set<String> = []
        return page.filter { $0.incoming && !$0.failed && open.contains($0.rhash) && seen.insert($0.rhash).inserted }
    }

    /// The synchronous half: one transaction with everything the core reported,
    /// then the in-memory bookkeeping and events.
    func commit(
        _ result: RunReturn, time: String, expectedSender: String?,
        outgoing: Message? = nil, resend: Storage.Commit.Resend? = nil, invoices: [InvoiceRecord] = [],
        invites: [InviteRecord] = []
    ) throws -> FollowUps {
        // Whatever a poll waits for lands here (and a refused commit wakes it harmlessly).
        defer { wakeWaiters() }
        var followUps = FollowUps()
        var commit = Storage.Commit()
        commit.settings[.clock] = time
        commit.resend = resend
        commit.reads = Self.reads(result.lastRead).filter { !readsSentSinceGetReads.contains($0.key) }
        if let json = result.muteLevels, let mutes = JSON.decode([String: Int].self, from: json) {
            commit.mutes = mutes
        }

        let updates = try result.stateMp.map(StateCodec.decode) ?? [:]
        var newState = state
        newState.merge(updates) { _, new in new }
        for key in result.stateToDelete {
            newState[key] = nil
        }
        commit.state = updates
        commit.deleteState = result.stateToDelete
        followUps.justRegistered = !isRegistered && Self.isRegistered(newState)
        let changedContacts = Set(updates.keys.compactMap { $0.hasPrefix("c/") ? String($0.dropFirst(2)) : nil })
        let removedContacts = result.stateToDelete.compactMap { $0.hasPrefix("c/") ? String($0.dropFirst(2)) : nil }
        var contacts: [Contact]?
        if !changedContacts.isEmpty || !removedContacts.isEmpty {
            let all = try Self.contacts(in: newState)
            contacts = all
            commit.contacts = all.filter { changedContacts.contains($0.pubkey) }.map { ($0.pubkey, $0.contactKey != nil) }
                + removedContacts.map { ($0, false) }
        }

        if let balance = result.newBalance {
            commit.settings[.balanceMsat] = String(balance)
            followUps.reconcile = try Self.balanceCallsForReconcile(
                balance, stored: storage.balanceMsat() ?? 0, invoiceOpen: { try storage.hasOpenInvoice() }
            )
        }
        if let info = result.myContactInfo {
            commit.settings[.contactInfo] = info
        }
        // The server holds an async pay a send is waiting on (`waitForAsyncPay`).
        if let tag = result.asyncpayTag, money.asyncPays[tag] != nil {
            money.asyncPays[tag] = true
        }
        if let outgoing {
            commit.messages.append((outgoing, trustSender: false, replaces: nil))
        }
        commit.invoices = invoices
        commit.invites = invites
        // Only history pages carry a total.
        let arrival: Arrival = result.msgsTotal == nil ? .live : restoring ? .restore : .history
        commit.marksNewContacts = arrival != .restore
        // A send the asynchronous way lists the payment first, then its ping.
        if result.asyncpayTopic != nil, let main = result.msgs.first?.paymentHash {
            commit.pings = result.msgs.dropFirst().compactMap(\.paymentHash).filter { $0 != main }.map { ($0, main) }
        }
        var page: [PaymentRecord]?
        if let json = result.payments {
            page = PaymentRecord.decode(json)
            commit.payments = page ?? []
        }
        // A payment to an invoice made here, which this call settles
        // (`settle_inner` found its preimage): what arrived for it.
        if result.settleTopic != nil {
            commit.settling = result.msgs.compactMap { msg in
                guard let hash = msg.paymentHash, let msat = msg.msat else { return nil }
                return (hash, Int64(clamping: msat))
            }
        }
        let settled = JSON.decode(SettledStatus.self, from: result.settledStatus)
        if let settled, settled.status == Message.Delivery.delivered.rawValue, let hash = settled.paymentHash {
            commit.settled = [(hash, Date().millisecondsSince1970)]
        }
        // A payment to an invoice the server made for us shows only in its
        // history: an incoming row with the invoice's payment hash.
        if let page {
            let paid = Self.invoicePayments(in: page, open: try storage.openInvoices(among: page.map(\.rhash)))
            commit.settling += paid.map { ($0.rhash, $0.amountMsat) }
            commit.settled += paid.map { ($0.rhash, $0.ts) }
        }
        var landedPings: [String] = []
        var knownTribes = tribes
        var droppedIndex = self.droppedIndex
        var notTribes: Set<String> = []
        var echoedAliases = self.echoedAliases
        for msg in result.msgs {
            if let hash = msg.paymentHash, let pingTime = pingsByHash[hash] {
                followUps.acknowledgedPings.append(pingTime)
                landedPings.append(hash)
            }
            guard let decoded = Self.message(from: msg, expectedSender: expectedSender, state: newState) else { continue }
            var (message, trustSender) = (decoded.message, decoded.trustSender)
            if knownTribes[message.chat] == nil, !notTribes.contains(message.chat),
               let found = try discoveredTribe(message, trustSender: trustSender, state: newState, notTribes: &notTribes) {
                knownTribes[found.pubkey] = found
                commit.tribes.append(found)
                followUps.discoveredTribes = true
            }
            if let tribe = knownTribes[message.chat],
               let changed = Self.membership(
                   after: message, in: tribe, sent: tribe.sentAlias(account: alias), echoed: echoedAliases[message.chat] ?? [],
                   replaying: restoring) {
                knownTribes[tribe.pubkey] = changed
                commit.tribes.append(changed)
            }
            var replaces: String?
            if let tribe = knownTribes[message.chat] {
                if tribe.left {
                    if let index = message.serverIndex, index > droppedIndex {
                        droppedIndex = index
                        commit.settings[.droppedIndex] = String(index)
                    }
                    continue
                }
                // The sender pubkey is the tribe's; the alias and photo are
                // the member's and must not rename the tribe.
                trustSender = false
                // Someone else's boost reaches the other members without
                // sats; only there is the declared amount all there is.
                if message.type == MessageType.boost, message.amountMsat == nil {
                    message.amountMsat = DeclaredAmount.decode(message.body)
                }
                if let date = decoded.fields?.date, date > 0 {
                    message.timestamp = date
                }
                // Our own message coming back from the tribe takes over the row written at send.
                if message.fromMe {
                    replaces = decoded.fields?.originalUuid
                    if let echoed = message.senderAlias { echoedAliases[message.chat, default: []].insert(echoed) }
                } else if MessageType.content.contains(message.type), let content = message.content {
                    let aliases = ownTribeAliases(sent: tribe.sentAlias(account: alias), echoed: echoedAliases[message.chat] ?? [])
                    message.mentionsMe = mentions(content, aliases: aliases)
                }
            }
            commit.messages.append((message, trustSender, replaces))
        }
        var newTribe: String?
        if let json = result.newTribe, let info = JSON.decode(TribeInfo.self, from: json),
           Self.isPerson(info.pubkey, in: newState) != true {
            newTribe = info.pubkey
            // Replies on the management topic are only ever about this account's own tribes.
            var tribe = try knownTribes[info.pubkey] ?? Tribe(
                pubkey: info.pubkey, host: try storage.value(for: .tribeHost), isOwner: true
            )
            // This account's own tribe, as its own tribes server says.
            tribe.update(from: info, trustingPrivacy: true)
            knownTribes[tribe.pubkey] = tribe
            commit.tribes.append(tribe)
        }
        var members: TribeMembers.List?
        if let json = result.tribeMembers {
            members = JSON.decode(TribeMembers.List.self, from: json)
        }
        let sent = JSON.decode(SentStatus.self, from: result.sentStatus)
        let records = JSON.decode([SentStatus].self, from: result.tags)
        let live = sent.flatMap(Self.liveStatus)
        let answers = records.map { Self.recordedStatuses($0, unrecorded: unrecordedPayments) } ?? []
        if let live { commit.statuses.append(live) }
        commit.statuses += answers
        // Why a send failed, as the server put it (kept for an invoice we pay).
        for reply in [sent].compactMap({ $0 }) + (records ?? []) where reply.status == Message.Delivery.failed.rawValue {
            if let tag = reply.tag, let reason = (reply.message ?? reply.error)?.nilIfEmpty {
                commit.sendErrors[tag] = reason
            }
        }

        let settling = try storage.openInvoices(among: commit.settled.map(\.0))
        let applied = try storage.apply(commit)
        removeFiles(of: applied.purged)
        state = newState
        if let records {
            unrecordedPayments = []
            // Merged: a record once heard stays heard.
            if let gate = resendGate {
                resendGate?.recorded = (gate.recorded ?? []).union(records.compactMap(\.tag))
            }
        }
        if money.awaitingPayments, let page { money.paymentPage = page }
        if money.awaitingInvoice, let bolt11 = result.invoice { money.answeredInvoice = bolt11 }
        if let contacts {
            contactsByChildIndex = Self.index(contacts)
        }
        tribes = knownTribes
        if echoedAliases != self.echoedAliases {
            self.echoedAliases = echoedAliases
            emit.yield(.echoedAliases(echoedAliases))
            checkMentionsIfNeeded()
        }
        self.droppedIndex = droppedIndex
        if let members {
            tribeWork.memberLists[members.pubkey] = members
        }
        if let updated = newTribe {
            tribeWork.updated.insert(updated)
        }

        if let json = result.msgsCounts {
            do {
                let counts = try JSONDecoder().decode(MessageCounts.self, from: Data(json.utf8))
                if history.awaitingCounts {
                    history.awaitingCounts = false
                    followUps.restorePlan = counts
                }
            } catch {
                history.awaitingCounts = false
                emit.yield(.historyFailed("unreadable message counts: \(PeelError.readable(error))"))
            }
        }

        for hash in landedPings {
            pingsByHash[hash] = nil
        }
        if let ping = result.ping {
            notePing(ping)
        }
        if let balance = result.newBalance {
            emit.yield(.balance(msat: balance))
        }
        for message in applied.stored {
            emit.yield(.message(message, arrival))
        }
        // Purchases of our paid attachments, answered once this commit is done.
        if arrival != .restore {
            followUps.purchases = applied.stored.filter { $0.type == MessageType.purchase && !$0.fromMe && !$0.deleted }
        }
        // A restore ends with a reconcile of its own.
        if applied.newMoney, arrival != .restore { followUps.reconcile = true }
        // Told once the history confirms the sats, if it was news when it came.
        if arrival != .restore { money.untold.formUnion(applied.announceable) }
        for message in applied.confirmed where money.untold.remove(message.id ?? -1) != nil {
            emit.yield(.moneyReceived(message))
        }
        for message in applied.addedUs {
            emit.yield(.contactAdded(message))
        }
        // What the server said, then what its records settled.
        if let sent {
            emit.yield(.sendStatus(tag: sent.tag, status: sent.status))
        }
        for (tag, status) in answers {
            emit.yield(.sendStatus(tag: tag, status: status))
        }
        // Every payment that arrives settles; only one to an invoice made
        // here, open until this commit, is news, and only once.
        for (hash, _) in commit.settled where settling.contains(hash) {
            if let invoice = try storage.invoice(paymentHash: hash, incoming: true),
               invoice.status == .paid || invoice.status == .underpaid {
                emit.yield(.invoicePaid(invoice))
            }
        }
        if let error = result.error {
            // The core reports a failed "online" reply only in this text, with
            // the ping's tag at the end; the payment it was for no longer exists.
            if let tag = error.components(separatedBy: "async pay not found: ").last, tag.count == 64,
               let pingTime = pingsByTag.removeValue(forKey: tag) {
                followUps.acknowledgedPings.append(pingTime)
            }
            // A refused send carries its tag; a live message names its sender.
            let chat = try sent?.tag.flatMap { try storage.chat(forTag: $0) } ?? expectedSender
            if let chat {
                emit.yield(.conversationError(chat: chat, message: error))
            } else {
                emit.yield(.coreError(error))
            }
        }
        return followUps
    }

    /// Forgets a contact, the one state change no core call makes: the
    /// core's `c/` entry goes as the official apps drop it
    /// (`deleteContactFromState`), with the chat's rows in the same
    /// transaction (`Storage.deleteContact`), then the attachments' files.
    func forgetContact(_ pubkey: String) throws {
        defer { wakeWaiters() }
        var newState = state
        newState["c/\(pubkey)"] = nil
        let contacts = try Self.contacts(in: newState)
        let attachments = try storage.deleteContact(pubkey)
        state = newState
        contactsByChildIndex = Self.index(contacts)
        readsSentSinceGetReads.remove(pubkey)
        removeFiles(of: attachments.compactMap(\.body), outgoing: attachments.compactMap(\.id))
    }

    /// Removes the decrypted copies of attachments by their bodies, and
    /// uploads waiting in the outbox by message id, off the actor.
    private func removeFiles(of bodies: [String], outgoing ids: [Int64] = []) {
        let files = bodies.compactMap { body -> URL? in
            guard let fields = AttachmentFields.decode(body), let token = fields.mediaToken.flatMap(MediaToken.init),
                  let key = fields.mediaKey else { return nil }
            return media.cached(muid: token.muid, key: key)
        } + ids.map(media.outgoing)
        if !files.isEmpty {
            Task.detached { for file in files { try? FileManager.default.removeItem(at: file) } }
        }
    }

    typealias Publish = (topic: String, payload: Data)

    /// What `complete` publishes, in order: `now`, then `later` once the
    /// register of a new child key (a key exchange or a tribe join) has had
    /// time to land, because `later` may be addressed to that key, such as this
    /// account's own contact record (type 33). Without a new key, `later` is
    /// empty. Then `afterPay`, once the server has taken the async pay
    /// (`waitForAsyncPay`), which ends whichever of the two holds it: the
    /// ping in it would wake the recipient to redeem a payment the server
    /// may not hold yet. Without an async pay, `afterPay` is empty.
    static func publishPlan(_ result: RunReturn) -> (now: [Publish], later: [Publish], afterPay: [Publish]) {
        var now: [Publish] = []
        if let topic = result.settleTopic, let payload = result.settlePayload {
            now.append((topic, payload))
        }
        if let topic = result.registerTopic, let payload = result.registerPayload {
            now.append((topic, payload))
        }
        let topics: [Publish] = result.topics.enumerated().map { index, topic in
            (topic, index < result.payloads.count ? result.payloads[index] : Data())
        }
        let rest: [Publish], afterPay: [Publish]
        if let topic = result.asyncpayTopic, let payload = result.asyncpayPayload {
            (rest, afterPay) = ([(topic, payload)], topics)
        } else {
            (rest, afterPay) = (topics, [])
        }
        if result.registerTopic != nil, result.newChildIdx != nil {
            return (now, rest, afterPay)
        }
        return (now + rest, [], afterPay)
    }

    /// Set for the task that handles one inbound message, and whatever it
    /// awaits: the next inbound message, a server's answer among them,
    /// comes only once it is done (`publish`).
    @TaskLocal static var handlingInbound = false

    /// Background work of the engine's own (the history check, the tribes
    /// refresh, a reconnect's resends): a task started while an inbound
    /// message is handled would inherit `handlingInbound`, and a send in it
    /// would skip the wait for its async pay.
    static func background(_ work: @escaping @Sendable () async -> Void) -> Task<Void, Never> {
        Task { await $handlingInbound.withValue(false) { await work() } }
    }

    /// How long a send waits for the server to take its async pay before
    /// publishing the rest all the same, as the official apps do.
    static let asyncPaySettle: Duration = .seconds(10)

    /// Waits until the server has answered the async pay of one of `tags`
    /// (`asyncpayTag`, which `commit` notes in `money.asyncPays` for the
    /// tags `publish` listed there before it went), or `asyncPaySettle`.
    /// A wait that runs out, or is cancelled, returns: the state is
    /// committed and the payment may be held, so the rest still goes.
    private func waitForAsyncPay(_ tags: Set<String>) async {
        _ = try? await poll(timeout: Self.asyncPaySettle, failure: .notConnected) {
            tags.contains { money.asyncPays[$0] == true } ? () : nil
        }
    }

    /// Publishes in order on the current transport, read at call time so a
    /// reconnect during the register wait is used. Counts what left in `published`.
    private func publish(_ publishes: [Publish], published: inout Int) async throws {
        guard !publishes.isEmpty else { return }
        guard let transport else { throw Failure.notConnected }
        for publish in publishes {
            try await transport.publish(publish.topic, publish.payload)
            published += 1
        }
    }

    /// The asynchronous half: the network work the core asked for, in its order.
    /// `notConnected` means none of the result's publishes left, which the
    /// money sends take as nothing moved; the connection going after one has
    /// is another error.
    func complete(_ result: RunReturn, _ followUps: FollowUps) async throws {
        var published = 0
        do {
            try await publish(result, published: &published)
            try await followUp(result, followUps)
        } catch Failure.notConnected where published > 0 {
            throw PeelError("the connection went after sending")
        }
    }

    /// How far a money send's publish got (`commitAndPublish`).
    enum Published {
        /// Everything left.
        case all
        /// Nothing left: the connection had gone before the first publish
        /// (`complete`'s `notConnected`), so the send may be marked failed.
        case none
        /// Something failed once publishing had begun, or after: the payment
        /// may have gone, so the send stays pending until the server says.
        case unknown(any Error)
    }

    /// Commits a send (the state and its local row, written before anything
    /// is published), then publishes it and reports how far that got. A
    /// refused commit throws, and nothing is published. Every money send
    /// goes through here and maps only `.none` to failed.
    func commitAndPublish(
        _ result: RunReturn, time: String, outgoing: Message? = nil, resend: Storage.Commit.Resend? = nil,
        invoices: [InvoiceRecord] = [], invites: [InviteRecord] = []
    ) async throws -> Published {
        let followUps = try commit(
            result, time: time, expectedSender: nil, outgoing: outgoing, resend: resend, invoices: invoices,
            invites: invites
        )
        do {
            try await complete(result, followUps)
            return .all
        } catch Failure.notConnected {
            return .none
        } catch {
            return .unknown(error)
        }
    }

    /// What a money send whose publish ended `.unknown` reports.
    static func mayHaveGone(_ error: any Error) -> String {
        "The connection failed while sending; the payment may have gone. "
            + "It stays unconfirmed until the server says (\(PeelError.readable(error)))"
    }

    private func publish(_ result: RunReturn, published: inout Int) async throws {
        let (now, later, afterPay) = Self.publishPlan(result)
        // Listed before the async pay goes, so an answer that comes first
        // counts. Any of the result's tags, as the official apps match it.
        // Never while handling what the server sent (a key exchange's
        // answer): the answer would wait behind it in the inbound queue.
        let paying = !Self.handlingInbound && !afterPay.isEmpty ? Set(result.msgs.compactMap(\.tag)) : []
        for tag in paying { money.asyncPays[tag] = false }
        defer { for tag in paying { money.asyncPays[tag] = nil } }
        if !result.subscriptionTopics.isEmpty {
            guard let transport else { throw Failure.notConnected }
            try await transport.subscribe(result.subscriptionTopics)
        }
        try await publish(now, published: &published)
        if !later.isEmpty {
            // See `publishPlan`. A cancelled wait still publishes: the state is committed.
            try? await Task.sleep(for: Self.registerSettle)
            try await publish(later, published: &published)
        }
        if !afterPay.isEmpty {
            if !paying.isEmpty { await waitForAsyncPay(paying) }
            try await publish(afterPay, published: &published)
        }
    }

    private func followUp(_ result: RunReturn, _ followUps: FollowUps) async throws {
        for pingTime in followUps.acknowledgedPings {
            try await run { time, state in
                try Sphinxrs.pingDone(seed: seed, uniqueTime: time, state: state, pingTs: pingTime)
            }
        }
        if followUps.discoveredTribes { refreshTribesInBackground() }
        if followUps.reconcile { reconcileInBackground() }
        for purchase in followUps.purchases {
            do {
                try await answerPurchase(purchase)
            } catch {
                emit.yield(.conversationError(chat: purchase.chat, message: "A purchase could not be answered: \(PeelError.readable(error))"))
            }
        }
        if followUps.justRegistered {
            await cameOnline()
        }
        if let counts = followUps.restorePlan {
            try await startRestore(counts)
        }
        // Only batch responses carry a total.
        if result.msgsTotal != nil {
            try await advanceHistory(with: result)
        }
    }

    /// Turns what the core reported into a row, deciding which conversation it
    /// belongs to. The core recovers a message's sender from its signature, so a
    /// sender can only ever name themself; for a live message the child index in
    /// the topic names the contact as well and the two must agree. Contact
    /// records (type 33) are honoured by the core only when signed by this
    /// account. Messages from senders the core does not know are dropped.
    private static func message(
        from msg: Msg, expectedSender: String?, state: [String: Data]
    ) -> (message: Message, trustSender: Bool, fields: BodyFields?)? {
        guard let type = msg.type else { return nil }
        let fromMe = msg.fromMe ?? false
        let claimed = JSON.decode(SenderInfo.self, from: msg.sender)?.pubkey
        let chat: String
        var trustSender = false
        if fromMe {
            guard let to = msg.sentTo else { return nil }
            chat = to
        } else if let expectedSender {
            chat = expectedSender
            trustSender = claimed == expectedSender
        } else {
            guard let claimed, state["c/\(claimed)"] != nil else { return nil }
            chat = claimed
            trustSender = true
        }
        let fields = BodyFields.decode(msg.message)
        let msat = msg.msat.map { Int64(clamping: $0) }
        var message = Message(
            uuid: msg.uuid,
            serverIndex: msg.index.flatMap { UInt64($0) }.flatMap { Int64(exactly: $0) },
            type: Int(type), chat: chat, fromMe: fromMe,
            sender: msg.sender, body: msg.message, content: fields?.content,
            msat: msat,
            timestamp: msg.timestamp.map { Int64(clamping: $0) },
            tag: msg.tag, paymentHash: msg.paymentHash,
            replyUUID: fields?.replyUuid, threadUUID: fields?.threadUuid,
            // What reached this account (`msat`, held to what the server says
            // arrived by `cappedToArrived`); only without sats what the sender declared.
            amountMsat: MessageType.payments.contains(Int(type))
                ? msat ?? (fromMe ? DeclaredAmount.decode(msg.message) : nil) : nil
        )
        switch message.type {
        case MessageType.attachment:
            if let fields = AttachmentFields.decode(msg.message) { message.mediaType = fields.mediaType }
        case MessageType.invoice:
            // What a request asks for is what its invoice says, whatever its JSON claims.
            let invoice = requestInvoice(message.body)
            message.paymentHash = invoice?.paymentHash
            message.amountMsat = invoice.map { Int64(clamping: $0.amountMsat) }
            if let memo = invoice?.memo.nilIfEmpty { message.content = memo }
        case MessageType.invoicePayment:
            // Someone else's names the request only by the payment it rode
            // on (the core's hash, from the topic); our own copy carries no
            // payment, so its JSON (which we wrote) names it.
            if fromMe { message.paymentHash = msg.paymentHash ?? fields?.paymentHash?.lowercased() }
            message.amountMsat = msat
        case MessageType.purchase, MessageType.purchaseDeny:
            message.amountMsat = msat ?? (fromMe ? DeclaredAmount.decode(msg.message) : nil)
        default:
            break
        }
        return (message, trustSender, fields)
    }

    private func receive(_ inbound: Inbound) async {
        let parts = inbound.topic.split(separator: "/", omittingEmptySubsequences: false)
        let kind = parts.count > 5 ? String(parts[5]) : inbound.topic

        // Answering a ping needs our own route hint. Until registered, let it go:
        // the server re-sends pending pings when we ask for them on coming online.
        if kind == "ping", !isRegistered { return }

        // The child index in a live message's topic names the contact whose key
        // decrypted it; index 0 is the account key used for key exchange.
        var expectedSender: String?
        if ["msg", "msgs", "stream"].contains(kind), parts.count > 2, let index = UInt64(parts[2]), index > 0 {
            expectedSender = contactsByChildIndex[index]
        }
        do {
            let arrived = Self.arrivedMsat(kind: kind, topic: parts, payload: inbound.payload)
            try await run(expectedSender: expectedSender, arrived: arrived) { time, state in
                try Sphinxrs.handle(
                    topic: inbound.topic, payload: inbound.payload, seed: seed, uniqueTime: time,
                    state: state, myAlias: alias, myImg: photoURL
                )
            }
            if kind == "getreads" {
                try await publishPendingReads()
            }
        } catch {
            if let expectedSender {
                emit.yield(.conversationError(chat: expectedSender, message: "A message could not be read: \(PeelError.readable(error))"))
            } else {
                emit.yield(.coreError("\(kind): \(PeelError.readable(error))"))
            }
        }
    }

    /// Runs once per connection, as soon as the account is registered. Decides
    /// what history to fetch: resume a run a dropped connection interrupted, do
    /// the full restore an account brought back from its words still needs, or
    /// catch up from the newest message stored.
    private func cameOnline() async {
        let connection = transport
        emit.yield(.registered(contactInfo: try? storage.value(for: .contactInfo)))
        refreshTribesInBackground()
        reconcileInBackground()
        do {
            try await run { time, state in
                try Sphinxrs.fetchPings(seed: seed, uniqueTime: time, state: state)
            }
            try await fetchReadsAndMutes()
            // Best effort: catching up must not wait on it.
            do {
                try await checkPendingSends()
            } catch {
                emit.yield(.coreError("checking pending sends: \(PeelError.readable(error))"))
            }
            if let run = history.active {
                try await request(run)
            } else if restoring {
                history.awaitingCounts = true
                try await self.run { time, state in
                    try Sphinxrs.getMsgsCounts(seed: seed, uniqueTime: time, state: state)
                }
            } else {
                try await syncMessages()
            }
        } catch {
            emit.yield(.coreError("coming online: \(PeelError.readable(error))"))
        }
        cameOnlineHere = true
        wakeWaiters()
        // Only on the connection this ran for: one that went meanwhile has
        // its own `cameOnline` to come.
        guard let connection, transport === connection else { return }
        resendTask?.cancel()
        resendTask = Self.background { [weak self] in await self?.resendRecent(on: connection) }
    }

    /// Read markers by chat, as the core reports them. The core leaves them out
    /// when the server has none at all, which reads as empty.
    private static func reads(_ json: String?) -> [String: Int64] {
        JSON.decode([String: Int64].self, from: json) ?? [:]
    }

    /// Sends the markers moved here that the server does not have yet (read
    /// or marked unread while offline). Runs only in reply to `getReads`,
    /// whose markers have just replaced every other one: the server's are the
    /// truth, so a marker set on another device is never pushed back.
    private func publishPendingReads() async throws {
        for (chat, index) in try storage.pendingReads() {
            try await publishRead(chat, index: index)
        }
    }

    /// Asks the server what became of sends still pending here, as the Mac
    /// app does on start: a status published while this device was offline
    /// (an async payment redeemed later, say) is not sent again.
    /// A payment the server has no record of this long after it was sent
    /// never reached it (the mixer records every send it handles, an async
    /// one as pending), so it is marked failed and may be sent again.
    /// Also asks about every message a reconnect may send again by itself
    /// (`autoResendCandidates`), failed ones too, as a send can fail here
    /// after it left: `resendRecent` sends only those the records do not name.
    func checkPendingSends() async throws {
        let pending = try storage.pendingSendTags(
            textBefore: Date.now.addingTimeInterval(-Message.confirmationTimeout).millisecondsSince1970
        )
        let candidates = Set(try autoResendCandidates().compactMap(\.tag))
        var tags = pending.map(\.tag)
        tags += candidates.subtracting(tags).sorted()
        guard !tags.isEmpty else {
            resendGate = ([], [])
            return
        }
        let cutoff = Date.now.addingTimeInterval(-Message.unrecordedPaymentTimeout).millisecondsSince1970
        unrecordedPayments = Set(pending.filter { $0.movesMoney && $0.createdAt < cutoff }.map(\.tag))
        // Before the call: the reply can land while it is still publishing.
        resendGate = (candidates, nil)
        try await run { time, state in
            try Sphinxrs.getTags(seed: seed, uniqueTime: time, state: state, tags: tags, pubkey: nil)
        }
    }

    /// Read markers and mutes live on the server, shared by every device.
    func fetchReadsAndMutes() async throws {
        readsSentSinceGetReads = []
        try await run { time, state in
            try Sphinxrs.getReads(seed: seed, uniqueTime: time, state: state)
        }
        try await run { time, state in
            try Sphinxrs.getMutes(seed: seed, uniqueTime: time, state: state)
        }
    }

    /// A ping is "paymentHash:time:tag".
    private func notePing(_ ping: String) {
        let parts = ping.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, let time = UInt64(parts[1]) else { return }
        pingsByHash[parts[0]] = time
        if parts.count > 2, !parts[2].isEmpty {
            pingsByTag[parts[2]] = time
        }
    }
}

extension Engine {
    /// The row the one status the mixer publishes for a send moves
    /// (`Storage.applyStatus` only moves rows forward): COMPLETE and FAILED as
    /// they are. A PENDING is its last word on a payment it handed to the
    /// recipient but that did not settle in its window (a local payment whose
    /// recipient answered after `TIMEOUT_MS`; a Lightning one still in flight
    /// after its budget): the recipient has the message and no other status
    /// will come for that tag, so the row is unsettled, never failed, which
    /// would offer to pay again. Anything else changes nothing.
    static func liveStatus(_ sent: SentStatus) -> (tag: String, status: String)? {
        guard let tag = sent.tag, let delivery = Message.Delivery(rawValue: sent.status) else { return nil }
        switch delivery {
        case .delivered, .failed: return (tag, delivery.rawValue)
        case .pending: return (tag, Message.Delivery.unsettled.rawValue)
        case .unsettled: return nil
        }
    }

    /// The rows the mixer's records (the `getTags` reply) move: only a final
    /// status, since it also records an async payment as PENDING while it
    /// holds it for an offline recipient. A payment in `unrecorded` (past
    /// `unrecordedPaymentTimeout`, see `checkPendingSends`) it has no record
    /// of never reached it, and failed.
    static func recordedStatuses(_ records: [SentStatus], unrecorded: Set<String>) -> [(tag: String, status: String)] {
        var updates: [(tag: String, status: String)] = records.compactMap { record in
            guard let tag = record.tag, let delivery = Message.Delivery(rawValue: record.status),
                  delivery == .delivered || delivery == .failed else { return nil }
            return (tag, delivery.rawValue)
        }
        for tag in unrecorded.subtracting(records.compactMap(\.tag)).sorted() {
            updates.append((tag, Message.Delivery.failed.rawValue))
        }
        return updates
    }
}

struct SentStatus: Decodable {
    let tag: String?
    let status: String
    /// Why a send failed: `message` on a send's status, `error` on `get_tags`.
    var message: String?
    var error: String?
}

/// The server's answer to settling a payment to an invoice made here.
private struct SettledStatus: Decodable {
    let status: String
    let paymentHash: String?

    enum CodingKeys: String, CodingKey {
        case status
        case paymentHash = "payment_hash"
    }
}

/// Every core call needs a time that is never reused, even across restarts.
/// Milliseconds plus a little jitter, as the official apps send, forced to be
/// strictly increasing and persisted with each commit.
struct UniqueClock {
    private var last: UInt64

    init(last: UInt64) {
        self.last = last
    }

    mutating func next() -> String {
        let now = UInt64(Date().timeIntervalSince1970 * 1000) + UInt64.random(in: 0..<1000)
        last = max(now, last + 1)
        return String(last)
    }
}
