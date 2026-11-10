import Foundation
import Network
import PeelDiagnostics
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
    /// This account's key (child index 0, hex), which signs every message we
    /// send, signs in to the memes server and names our preferences file there.
    let accountKey: String
    /// This device among the account's (`Setting.deviceID`): the core's
    /// device, and the one a device request names (`Engine+DeviceRequests`).
    let deviceID: String
    var alias: String
    var photoURL: String
    var server: ServerAddress?
    private var allowUntrustedCertificate = false
    /// The route the last connection came by, and when the named one was last tried (see `connectFirstRoute`).
    private var lastRoute: ServerAddress?
    private var primaryProbedAt: ContinuousClock.Instant?
    /// `Setting.lastRoute` has been read, at the first connect.
    private var lastRouteRead = false

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
    /// History caught up on this connection (`CatchUpTracker`).
    var catchUp = CatchUpTracker()
    /// A register naming an invite may have reached the server: the account
    /// may exist and hold the invite's sats (`Account.signup`).
    private(set) var inviteMayBeRedeemed = false
    /// This connection's pings (`keepAlive`), and the system's network
    /// changes while the engine keeps connected (`watchNetwork`).
    private var keepAliveTask: Task<Void, Never>?
    private var networkWatch: Task<Void, Never>?
    /// The sends a reconnect makes by itself: its resends (`resendRecent`),
    /// then the keys purchases are still owed (`answerOwedPurchases`), then
    /// the agent's requests still to finish (`answerOwedDeviceRequests`).
    private var resendTask: Task<Void, Never>?
    /// The tags of the reconnect's candidates that `checkPendingSends` asked
    /// the server about on this connection, and the tags its records named
    /// (any status), nil until they come; see `resendRecent`.
    private(set) var resendGate: ResendGate?
    /// When this connection came up, and how many in a row went within
    /// `shortLived` of coming up: such a drop backs off rather than
    /// reconnecting at once (`connectionAnswers`).
    private(set) var connectedAt: ContinuousClock.Instant?
    /// The first catch-up on this connection has been noted in the diagnostics.
    var caughtUpNoted = false
    private var shortLivedDrops = 0
    static let shortLived: Duration = .seconds(60)
    /// When the connect in progress began (`establish`), nil between connects;
    /// and how long one may take before its reconnect loop counts as stuck
    /// and a drop replaces it (`connectionClosed`).
    private var establishingSince: ContinuousClock.Instant?
    static let stuckEstablish: Duration = .seconds(90)
    /// How long `cameOnline` may take before the connection is dropped to
    /// connect again (`cameOnlineWithinTimeout`), and how long it waits
    /// before each new try of a fetch that failed (`retrying`).
    static let cameOnlineTimeout: Duration = .seconds(45)
    static let cameOnlineRetryDelays: [Duration] = [.seconds(2), .seconds(5), .seconds(15)]

    /// Payments waiting for us while we were offline: payment hash and tag → the
    /// ping time to acknowledge once the payment lands.
    private var pingsByHash: [String: UInt64] = [:]
    private var pingsByTag: [String: UInt64] = [:]
    /// Pending payments old enough that the server must have a record of
    /// them if it ever got them, asked about on this connection; see
    /// `checkPendingSends`.
    private var unrecordedPayments: Set<String> = []
    /// When each chat's own messages were last asked about
    /// (`checkOwnMessageStatus`), the tags asked on this connection, those
    /// the server's records named (any status), and those it had no record
    /// of at the next ask: not asked about again on this connection.
    private var ownStatusCheckedAt: [String: ContinuousClock.Instant] = [:]
    private var ownStatusAsked: Set<String> = []
    private var ownStatusHeard: Set<String> = []
    private var unknownTags: Set<String> = []
    /// Contacts by the child index the core uses for them, so a live message's
    /// topic names its sender without a core call.
    private var contactsByChildIndex: [UInt64: String] = [:]
    /// Every tribe this account knows, joined or left, by pubkey.
    var tribes: [String: Tribe] = [:]
    /// What answers the agent's device requests here, and the requests it
    /// is answering now (`Engine+DeviceRequests`).
    var deviceRequestHandler: DeviceRequestHandler?
    var answeringRequests: Set<String> = []
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
        /// What this device heard in a tribe another device of this account
        /// joined, before its core knew the tribe (`unfiled`), oldest first,
        /// with our own tribes host once our join or an approval naming us
        /// came: replayed once our registry lists the tribe (`confirmTribes`).
        var held: [String: HeldTribe] = [:]
        /// The chats in `held`, oldest first: the first to go when it is full.
        var heldOrder: [String] = []
        /// Chats our tribes registry did not list, this session: never asked again.
        var notListed: Set<String> = []
    }
    struct HeldTribe {
        var host: String?
        var msgs: [Msg] = []
    }
    /// How many unfiled chats, and messages in each, are held at most.
    static let heldTribes = 20, heldPerTribe = 500
    var tribeWork = TribeWork()
    static let tribeRecheck: Duration = .seconds(5 * 60)
    /// Chats whose read marker was sent since `getReads` was last asked: its
    /// answer may predate the marker, so it is not applied to them.
    var readsSentSinceGetReads: Set<String> = []
    /// The same for mutes and `getMutes`.
    var mutesSetSinceGetMutes: Set<String> = []
    /// When `getReads` and `getMutes` were last asked, until the reads are
    /// answered: a refresh waits for an answer rather than ask again.
    var readsAskedAt: ContinuousClock.Instant?
    /// A restore from the words is replaying history; see `Setting.needsRestore`.
    var restoring: Bool
    /// Whether `recoverOwnProfile` has settled the name and photo for this engine.
    var profileRecoveryDone = false
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
    var preferencesWork = PreferencesWork()
    /// The call server's ticket endpoint and presence feed; see `callConnection`.
    var calls: CallServer?
    /// Largest attachment downloaded, and the most the cache keeps.
    static let attachmentLimit = 100_000_000
    /// Largest file sent. The memes server takes at most 32 MiB and 512
    /// bytes per upload, multipart framing included (sphinx-meme
    /// `lsat/size.go`, unchanged on memes.sphinx.chat), and answers 413
    /// past it; 32 MB leaves room for the encryption and the framing.
    public static let sendLimit = 32_000_000
    static let mediaCacheLimit = 500_000_000
    /// Videos and recordings up to this size download as they show; larger
    /// ones wait to be asked for (images have no such rule: they are small).
    public static let autoDownloadLimit = 25_000_000
    /// Where the official apps keep attachments.
    static let defaultMemesHost = "memes.sphinx.chat"
    static let defaultCallServer = "chat.sphinx.chat"

    /// History fetches and where history stands (`HistoryCursor`).
    var history = HistoryCursor()
    var historyWatchdog: Task<Void, Never>?
    typealias CoreRecoveryReason = DiagnosticEvent.CoreRecoveryReason
    /// The core's failures in a row, across connections: reset by a history page handled and by `caughtUp`.
    var consecutiveCoreFailures = 0
    /// Catch-ups asked for again by `checkSync` on this connection, since it came up or was last caught up.
    var catchUpRetries = 0
    /// What the last `.syncFailing` event said.
    private(set) var syncFailing = false
    /// `needsFullRestart` was emitted: once per engine.
    var fullRestartRequested = false
    /// The app left the front with a catch-up in flight and it was kept running (`appLeftForeground(keepingCatchUp:)`).
    var keepingCatchUpInBackground = false
    /// When history last moved on this connection (an ask, a page, a run
    /// starting); nil with none in flight. A run flagged in flight with no
    /// activity for `historyStall` is stuck (`catchUpIfIdle`).
    var lastHistoryActivity: ContinuousClock.Instant?
    /// When the catch-up now running began, and why (for the diagnostics).
    var catchUpStarted: ContinuousClock.Instant?
    var catchUpReason: DiagnosticEvent.CatchUpReason = .cameOnline
    /// Bounds the time a connection spends Syncing (`checkSync`).
    var syncWatchdog: Task<Void, Never>?
    /// Asks the server now and then whether anything came that was never delivered live (`selfCheck`).
    var selfCheckTask: Task<Void, Never>?
    /// How many messages catch-ups (pages of history, not a restore) stored that this device did not have:
    /// what the live subscription never delivered (`selfCheck`).
    var newFromCatchUp = 0
    /// The old transport's disconnect and shutdown, started by `connectionClosed` in the background and
    /// awaited before the next connect makes a client (`teardown`): never two clients of one client ID at once.
    var closing: Task<Void, Never>?
    /// The app left the front with history in flight, which was abandoned:
    /// nothing is known of the connection until the next ping answers.
    public private(set) var unverified = false
    /// When the app left the front (the first time, if it left twice), nil in front or before it did.
    var leftForegroundAt: ContinuousClock.Instant?
    /// The network path changed (status or interfaces) since the connection was begun, in the
    /// background or not: the connection is bound to the old path and may be a zombie
    /// (`appBecameActive`, `networkChanged`). Cleared when a new connection is begun.
    public private(set) var pathChangedSinceBackground = false
    /// Pages of history that came, so a catch-up's first answer can be told from its ask.
    var historyPages = 0
    /// How long `appBecameActive` gives a connection to answer; tests shorten it.
    var verifyTimeout = Engine.foregroundVerifyTimeout
    /// A connection of a app away for longer than this is not trusted but rebuilt (`appBecameActive`).
    static let awayRebuildThreshold: Duration = .seconds(20)
    /// The hard bound on the ping and the catch-up ask a short-away foreground makes.
    static let foregroundVerifyTimeout: Duration = .seconds(6)
    static let syncCheckInterval: Duration = .seconds(10)
    static let syncBound: Duration = .seconds(60)
    /// While a connection in front is not caught up and nothing is in flight, catch-up is asked for again
    /// after each of these (the last repeats), counted from the one before: independent of the stall watchdog.
    static let catchUpRetryDelays: [Duration] = [.seconds(2), .seconds(5), .seconds(15), .seconds(30)]
    static func catchUpRetryDelay(afterRetries retries: Int) -> Duration {
        catchUpRetryDelays[min(max(retries, 0), catchUpRetryDelays.count - 1)]
    }
    /// How long a catch-up in flight as the app leaves the front may go on under a background task.
    static let backgroundCatchUpBound: Duration = .seconds(25)
    /// Failures of the core in a row (a history page it refuses even after `recoverCore`, a coming online
    /// that fails twice) before the state is reloaded and the connection rebuilt, and before everything is
    /// initialised again (`needsFullRestart`).
    static let coreFailureReloadThreshold = 3
    static let coreFailureReinitThreshold = 6
    /// Failed catch-up attempts on one connection (`catchUpRetries`) from which it is shown as failing.
    static let failingThreshold = 3
    /// The first self-check comes this long after a connection is caught up, the rest every `selfCheckInterval`.
    static let selfCheckFirstDelay: Duration = .seconds(20)
    static let selfCheckInterval: Duration = .seconds(60)
    /// How often `watchSelfCheck` looks at whether one is due.
    static let selfCheckTick: Duration = .seconds(5)
    /// How long a self-check waits for its catch-up to end (the history stall watchdog has its say after).
    static let selfCheckBound: Duration = .seconds(35)
    /// Each `poll` waiting to check again.
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    static let historyStall: Duration = .seconds(30)

    static let historyPageSize: UInt32 = 100
    /// How long publishes wait behind the register of a new child key; see `complete`.
    static let registerSettle: Duration = .milliseconds(750)

    public init(mnemonic: String, storage: Storage) throws {
        seed = try Self.seed(of: mnemonic)
        self.storage = storage
        network = try storage.value(for: .network) ?? "bitcoin"
        let persisted = try Self.loadPersistedState(storage)
        state = persisted.state
        if let stored = try storage.value(for: .deviceID) {
            deviceID = stored
        } else {
            deviceID = UUID().uuidString
            try storage.set(deviceID, for: .deviceID)
        }
        alias = persisted.alias
        photoURL = persisted.photoURL
        server = persisted.server
        clock = UniqueClock(last: persisted.clock)
        accountKey = try Sphinxrs.pubkeyFromSeed(seed: seed, idx: 0, time: clock.next(), network: network)
        let (stream, continuation) = AsyncStream<Event>.makeStream()
        events = stream
        emit = continuation
        let contacts = persisted.contacts
        contactsByChildIndex = Self.index(contacts)
        tribes = persisted.tribes
        restoring = persisted.restoring
        echoedAliases = persisted.echoedAliases
        media = MediaStore(profile: storage.directory)
        // The profile lock means no other process is uploading; anything
        // still uploading was cut off, and can be retried.
        try storage.failInterruptedUploads()
        let stored = try storage.highestMessageID() ?? 0
        money.judgedThrough = stored
        history.from = persisted.historyFrom
        _ = try storage.apply(Storage.Commit(contacts: contacts.map { ($0.pubkey, $0.contactKey != nil) }))
    }

    /// Everything the engine keeps in memory that storage holds the truth of: read by `init`, which
    /// is what a relaunch runs, and again by `recoverCore`.
    struct PersistedState {
        var state: [String: Data]
        var alias: String
        var photoURL: String
        var server: ServerAddress?
        /// `Setting.clock`: the last unique time a call used.
        var clock: UInt64
        var contacts: [Contact]
        var tribes: [String: Tribe]
        var restoring: Bool
        var echoedAliases: [String: Set<String>]
        var historyFrom: UInt64
    }

    static func loadPersistedState(_ storage: Storage) throws -> PersistedState {
        let state = try storage.loadCoreState()
        return PersistedState(
            state: state,
            alias: try storage.value(for: .alias) ?? "",
            photoURL: try storage.value(for: .photoURL) ?? "",
            server: try storage.value(for: .server).flatMap(ServerAddress.init),
            clock: try storage.value(for: .clock).flatMap { UInt64($0) } ?? 0,
            contacts: try Self.contacts(in: state),
            tribes: Dictionary(try storage.tribes().map { ($0.pubkey, $0) }, uniquingKeysWith: { $1 }),
            restoring: try storage.value(for: .needsRestore) == "1",
            echoedAliases: try storage.echoedOwnAliases(),
            historyFrom: try Self.historyFrom(storage)
        )
    }

    /// Where history stands (`HistoryCursor.from`), read before any
    /// connection could store a live message above messages not fetched
    /// yet. A profile from before it was kept starts after its newest
    /// message stored (or dropped from a left tribe), as it did then.
    private static func historyFrom(_ storage: Storage) throws -> UInt64 {
        if let kept = try storage.value(for: .historyFrom) { return UInt64(kept) ?? 0 }
        let dropped = try storage.value(for: .droppedIndex).flatMap { Int64($0) } ?? -1
        let highest = max(try storage.highestServerIndex() ?? -1, dropped)
        let from = highest < 0 ? 0 : UInt64(highest) + 1
        try storage.set(String(from), for: .historyFrom)
        return from
    }

    // MARK: - Connection

    /// Connects once and returns when the account is online. A dropped
    /// connection stays dropped.
    public func connect(allowUntrustedCertificate: Bool = false) async throws {
        keepConnected = false
        reconnectTask?.cancel()
        reconnectTask = nil
        self.allowUntrustedCertificate = allowUntrustedCertificate
        try await establish()
        try await waitUntilRegistered()
    }

    /// Connects and keeps reconnecting with backoff until `disconnect()`.
    /// Progress is reported through `.connection` events.
    public func start(allowUntrustedCertificate: Bool = false) {
        // Accounts restored before the restore learned to recover the name and
        // photo get them on their first start instead.
        guard !closed else { return }
        if !restoring { recoverOwnProfile() }
        self.allowUntrustedCertificate = allowUntrustedCertificate
        keepConnected = true
        watchNetwork()
        guard connection != .connected, reconnectTask == nil else { return }
        reconnectTask = Task { [weak self] in await self?.reconnectLoop(attempt: 0) }
    }

    /// Checks the current connection with the same ping as the keep-alive.
    /// A silent connection follows the normal reconnect path.
    public func checkConnection() async -> Bool {
        guard connection == .connected else { return false }
        return await connectionAnswers()
    }

    /// Picks history up where it stands when nothing is asking for it: for
    /// a connection that answered a ping after the app was away, whose
    /// live messages (QoS 0, a clean session) may have been lost on the
    /// way. Does nothing before `cameOnline` has run on this connection
    /// (it fetches by itself) or while history is already being asked for.
    public func catchUpIfIdle(reason: DiagnosticEvent.CatchUpReason = .foreground) async {
        guard let attempt = transport, cameOnlineHere else { return }
        var reason = reason
        if history.isSyncing {
            // Really in flight: something moved within the stall time.
            if let last = lastHistoryActivity, ContinuousClock.now - last < Self.historyStall { return }
            // The flag outlived whatever set it (an ask that never left, a
            // run nothing answers): treat it as stuck and ask again.
            abandonHistory(reason: .stuckFlag)
            reason = .stuckFlag
        }
        unverified = false
        do {
            try await resumeHistory(reason: reason)
        } catch {
            // The ask could not be made (or was cancelled, which
            // `resumeHistory` has recorded): a connection that cannot take
            // it is dead, so drop it and connect again.
            guard !Task.isCancelled, !(error is CancellationError), transport === attempt else { return }
            Diagnostics.recordCoreFailure(site: .catchUp, kind: reason.rawValue, detail: PeelError.readable(error))
            // The core's state may be what is wrong, and a new connection would meet it again.
            await recoverCore(reason: .catchUp)
            await dropOnPurpose(attempt, reason: .catchUpError)
        }
    }

    /// Drops a connection that is still the engine's, on purpose, so it connects again: the
    /// reason is recorded (`DiagnosticEvent.ReconnectReason`) and the reconnect starts at once
    /// (`retryAt: 0`) unless `retryAt` says to back off.
    func dropOnPurpose(_ connection: Transport, reason: DiagnosticEvent.ReconnectReason, retryAt: Int = 0) async {
        guard transport === connection else { return }
        Diagnostics.recordForcedReconnect(reason: reason)
        await connectionClosed(connection, retryAt: retryAt)
    }

    /// The app left the front. A catch-up or history ask in flight is given
    /// up (a reply may never come to a suspended app) and the connection is
    /// marked unverified, so the next foreground pings it and catches up.
    /// A restore keeps its run.
    ///
    /// With `keepingCatchUp` (the app holds a background task for it) a catch-up in flight is left
    /// running instead, and true is returned: `finishBackgroundCatchUp` then bounds it. Whatever is
    /// abandoned starts again from the unchanged cursor (`history.from`) at the next foreground.
    @discardableResult
    public func appLeftForeground(keepingCatchUp: Bool = false) -> Bool {
        // The clock is the continuous one: it keeps counting while the app is suspended.
        if leftForegroundAt == nil { leftForegroundAt = .now }
        let inFlight = history.isSyncing
        Diagnostics.recordBackground(inFlightCatchUp: inFlight)
        guard inFlight, !restoring else { return false }
        if keepingCatchUp, transport != nil {
            keepingCatchUpInBackground = true
            return true
        }
        abandonHistory(reason: .appLeftForeground)
        unverified = true
        return false
    }

    /// Waits for the catch-up `appLeftForeground(keepingCatchUp:)` kept, at most `bound`: it ends when
    /// history is no longer in flight (caught up, failed or the connection gone) or the app is back in
    /// front; past the bound it is abandoned as `appLeftForeground` does.
    public func finishBackgroundCatchUp(bound: Duration? = nil) async {
        let bound = bound ?? Engine.backgroundCatchUpBound
        guard keepingCatchUpInBackground else { return }
        defer { keepingCatchUpInBackground = false }
        do {
            try await poll(timeout: bound, every: .seconds(1), failure: .registrationTimedOut) {
                !history.isSyncing || transport == nil || leftForegroundAt == nil ? () : nil
            }
        } catch {
            expireBackgroundCatchUp()
        }
    }

    /// The system is about to suspend the app (or the bound passed): gives up what was kept.
    public func expireBackgroundCatchUp() {
        guard keepingCatchUpInBackground, leftForegroundAt != nil, !restoring else { return }
        keepingCatchUpInBackground = false
        abandonHistory(reason: .appLeftForeground)
        unverified = true
        wakeWaiters()
    }

    /// Looks at a connection that is not caught up, at first every `catchUpRetryDelays[0]`, then at the
    /// pace of `catchUpRetryDelay(afterRetries:)`, for as long as it is not caught up: a catch-up that
    /// failed is asked for again whatever the stall watchdog does.
    private func watchSync(_ connection: Transport) async {
        while !Task.isCancelled {
            try? await Task.sleep(for: Self.catchUpRetryDelay(afterRetries: catchUpRetries))
            guard !Task.isCancelled, transport === connection, !catchUp.isCaughtUp else { return }
            await checkSync(connection)
        }
    }

    /// Tells listeners when the connection starts or stops being shown as failing
    /// (`consecutiveCoreFailures`, `catchUpRetries`).
    func updateFailing() {
        let failing = consecutiveCoreFailures >= Self.coreFailureReloadThreshold || catchUpRetries >= Self.failingThreshold
        guard failing != syncFailing else { return }
        syncFailing = failing
        emit.yield(.syncFailing(failing))
    }

    /// The core handled something history needed: nothing is failing any more.
    func noteCoreSuccess() {
        consecutiveCoreFailures = 0
        updateFailing()
    }

    /// Runs the self-check on a connection that is caught up, in front and idle: first `selfCheckFirstDelay`
    /// after it was caught up, then every `selfCheckInterval`. (Not `watchSync`'s loop: caught up ends that.)
    private func watchSelfCheck(_ connection: Transport) async {
        var due: ContinuousClock.Instant?
        var ran = false
        while !Task.isCancelled {
            try? await Task.sleep(for: Self.selfCheckTick)
            guard !Task.isCancelled, transport === connection else { return }
            guard catchUp.isCaughtUp, !history.isSyncing, cameOnlineHere, !restoring, leftForegroundAt == nil else {
                due = nil
                continue
            }
            let deadline = due ?? ContinuousClock.now + (ran ? Self.selfCheckInterval : Self.selfCheckFirstDelay)
            due = deadline
            guard ContinuousClock.now >= deadline else { continue }
            due = nil
            let trigger: DiagnosticEvent.SelfCheckTrigger = ran ? .periodic : .afterCaughtUp
            ran = true
            await selfCheck(reason: trigger)
        }
    }

    /// Asks the server for history from the cursor, as a catch-up does, and counts the messages that were new
    /// to this device (`newFromCatchUp`): a message the server holds that never came live means the live
    /// path is dead while pings still answer (`judgeSelfCheck`).
    func selfCheck(reason: DiagnosticEvent.SelfCheckTrigger) async {
        guard let connection = transport, cameOnlineHere, !restoring, !history.isSyncing else { return }
        let from = history.from
        let before = newFromCatchUp
        do {
            try await resumeHistory(reason: .selfCheck)
        } catch {
            guard !Task.isCancelled, !(error is CancellationError), transport === connection else { return }
            await dropOnPurpose(connection, reason: .catchUpError)
            return
        }
        // A catch-up that does not end is the stall watchdog's and `syncBound`'s to deal with.
        do {
            try await poll(timeout: Self.selfCheckBound, failure: .registrationTimedOut) {
                transport !== connection || !history.isSyncing ? () : nil
            }
        } catch {
            return
        }
        guard transport === connection else { return }
        await judgeSelfCheck(on: connection, trigger: reason, from: from, missed: newFromCatchUp - before)
    }

    /// Records what a self-check found; messages that came from history and never live drop the connection,
    /// so a clean one (a new login, subscriptions and catch-up) takes its place.
    func judgeSelfCheck(on connection: Transport, trigger: DiagnosticEvent.SelfCheckTrigger, from: UInt64, missed: Int) async {
        let highest = (try? storage.highestServerIndex()).map { Int($0) }
        Diagnostics.recordSelfCheck(trigger: trigger, from: from, missed: missed, highest: highest)
        guard missed > 0 else { return }
        await dropOnPurpose(connection, reason: .selfCheckMissed)
    }

    /// One look at a connection that is up and not caught up: catch-up is
    /// asked for when it came online and nothing asks; and one that has
    /// neither been caught up nor moved history for `syncBound` is dropped,
    /// so it connects afresh rather than showing Syncing for ever.
    func checkSync(_ connection: Transport) async {
        guard transport === connection, !catchUp.isCaughtUp else { return }
        if cameOnlineHere {
            // Moving within the stall time is left alone (`catchUpIfIdle` says the same); anything else
            // is a catch-up that did not finish, asked for again.
            let moving = history.isSyncing && (lastHistoryActivity.map { ContinuousClock.now - $0 < Self.historyStall } ?? false)
            if !moving {
                catchUpRetries += 1
                updateFailing()
                await catchUpIfIdle(reason: .watchdog)
                guard transport === connection, !catchUp.isCaughtUp else { return }
            }
        }
        // A restore takes as long as it takes; an account not yet registered has nothing to catch up.
        guard !restoring, isRegistered, let since = [connectedAt, lastHistoryActivity].compactMap({ $0 }).max() else { return }
        let waited = ContinuousClock.now - since
        guard waited > Self.syncBound else { return }
        Diagnostics.recordCatchUp(.abandon, reason: .syncBound, milliseconds: Self.milliseconds(of: waited))
        history.abandon()
        // The core's state may be what the catch-up cannot get past: reload it before the new connection.
        await recoverCore(reason: .syncBound)
        // This is the watchdog: dropping the connection must not cancel the task doing it.
        syncWatchdog = nil
        await dropOnPurpose(connection, reason: .syncBound)
    }

    /// The app came to the front (or a push woke it): decides whether the connection can be
    /// trusted. An app that was suspended gets no word of a socket the system closed under it
    /// (`nw_connection ... unconnected`, EBADF reads are logged by Network.framework, not raised),
    /// so a connection that looks up proves nothing after the app was away.
    ///
    /// - offline or connecting: connect now (`reconnect`).
    /// - connected, and away longer than `awayRebuildThreshold`, or the path changed, or
    ///   `unverified`, or a read failed, or not caught up: the old transport is not trusted; it is
    ///   dropped and a fresh login, transport, subscription and `cameOnline` (which resumes
    ///   history from `history.from`) take its place (`rebuild`).
    /// - connected, away briefly, nothing changed: a real round trip under `foregroundVerifyTimeout`,
    ///   a ping and a catch-up ask that is answered; either failing rebuilds, else `trust`.
    ///
    /// The path monitor and this hard timeout stand in for handling the NWConnection's own
    /// `.failed`, `.cancelled` and `.waiting` states: MQTTNIO and NIOTS do not expose the
    /// NWConnection, so what it would say is learned by asking the broker.
    public func appBecameActive(reason: ForegroundReason) async {
        let away = awaySeconds()
        // A push wakes the app in the background: it has not come to the front.
        if reason == .foreground { leftForegroundAt = nil }
        guard connection == .connected, let current = transport else {
            Diagnostics.recordForegroundDecision(action: .reconnect, reason: .offline, awaySeconds: away)
            Diagnostics.recordForegroundPing(answered: false, milliseconds: 0)
            reconnectNow()
            return
        }
        if let cause = untrustedCause(of: current, away: away) {
            Diagnostics.recordForegroundDecision(action: .rebuild, reason: cause, awaySeconds: away)
            await dropOnPurpose(current, reason: .foregroundRebuild)
            return
        }
        Diagnostics.recordForegroundDecision(action: .verify, reason: .none, awaySeconds: away)
        let timeout = verifyTimeout
        let outcome = await Self.within(timeout) { [self] in await self.verifyRoundTrip(on: current, reason: reason) } ?? .timedOut
        // Cancelled: a check cut short proves nothing.
        guard !Task.isCancelled else { return }
        switch outcome {
        case .ok:
            Diagnostics.recordForegroundDecision(action: .trust, reason: .none, awaySeconds: away)
        case .pingFailed, .timedOut:
            let cause: DiagnosticEvent.ForegroundCause = outcome == .pingFailed ? .pingFailed : .verifyTimeout
            Diagnostics.recordForegroundDecision(action: .rebuild, reason: cause, awaySeconds: away)
            await dropOnPurpose(current, reason: .foregroundRebuild)
        }
    }

    private enum VerifyOutcome: Sendable { case ok, pingFailed, timedOut }

    /// Whole seconds the app has been away: from leaving the front, or from the connection coming
    /// up when that was later (a connection made since is not an old one).
    private func awaySeconds() -> Int {
        guard let left = leftForegroundAt else { return 0 }
        let since = max(left, connectedAt ?? left)
        return Int(Self.milliseconds(of: ContinuousClock.now - since) / 1_000)
    }

    /// Why the transport can no longer be trusted, most telling first; nil when nothing says so.
    private func untrustedCause(of connection: Transport, away: Int) -> DiagnosticEvent.ForegroundCause? {
        if connection.hasReadFailure { return .readFailure }
        if pathChangedSinceBackground { return .pathChange }
        if Duration.seconds(away) > Self.awayRebuildThreshold { return .away }
        if unverified { return .unverified }
        // History moving right now (begun in front) is a catch-up under way, not a stuck one.
        let moving = history.isSyncing && lastHistoryActivity.map { ContinuousClock.now - $0 < Self.historyStall } == true
        if isRegistered, !restoring, !catchUp.isCaughtUp, !moving { return .notCaughtUp }
        return nil
    }

    /// A ping, then a catch-up ask, and waits for its first answer: a page, or caught up.
    private func verifyRoundTrip(on connection: Transport, reason: ForegroundReason) async -> VerifyOutcome {
        let started = ContinuousClock.now
        let answered = await connectionAnswers()
        Diagnostics.recordForegroundPing(answered: answered, milliseconds: Self.milliseconds(of: ContinuousClock.now - started))
        guard answered else { return .pingFailed }
        let pages = historyPages
        await catchUpIfIdle(reason: reason == .push ? .push : .foreground)
        while !Task.isCancelled, transport === connection {
            if catchUp.isCaughtUp || historyPages > pages { return .ok }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return .timedOut
    }

    /// `work`'s result, or nil when it has not finished within `timeout`. The work is cancelled
    /// then and not waited for, so a hung one never holds the caller.
    private static func within<T: Sendable>(_ timeout: Duration, _ work: @escaping @Sendable () async -> T) async -> T? {
        let (results, report) = AsyncStream.makeStream(of: T?.self)
        let job = Task { report.yield(await work()) }
        let timer = Task {
            try? await Task.sleep(for: timeout)
            report.yield(nil)
        }
        defer {
            job.cancel()
            timer.cancel()
            report.finish()
        }
        for await result in results { return result }
        return nil
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
        preferencesWork.scheduled?.cancel()
        await disconnect()
        await calls?.close()
        emit.finish()
    }

    /// How long the fallback route is kept first before the named one is tried again.
    static let primaryProbeInterval: Duration = .seconds(300)
    /// How long a route has to connect before it is closed and the next one
    /// is tried (never beside it: both would hold one client ID). A network
    /// that drops the MQTT port lets a connect hang for the client's whole
    /// timeout; this caps that wait. A working route connects well within it.
    static let nextRouteAfter: Duration = .milliseconds(1500)

    /// The routes tried one at a time: a route's client is made only when none is alive, so the routes'
    /// shared client ID is never held by two clients at once (the broker takes a session over from the
    /// older one when a second connects with the ID, and a client left connecting reads on).
    struct RouteTurns: Equatable {
        let count: Int
        private(set) var next = 0
        /// The route whose client is alive, until `ended`.
        private(set) var live: Int?

        init(count: Int) { self.count = count }

        /// The next route to try, none while one is alive or when they are all tried.
        mutating func begin() -> Int? {
            guard live == nil, next < count else { return nil }
            live = next
            next += 1
            return live
        }

        /// The live route's client is closed.
        mutating func ended() { live = nil }

        /// How long `route` has to connect before it is closed for the next: the last has the client's own
        /// timeout.
        func window(of route: Int) -> Duration? { route + 1 < count ? Engine.nextRouteAfter : nil }
    }

    /// Connects `transport`: the connect's result, or nil when it did not end within `limit` (nil: the
    /// client's own timeout bounds it) or the caller was cancelled.
    private static func connectRoute(_ transport: Transport, within limit: Duration?) async -> Result<Void, Error>? {
        let (events, sink) = AsyncStream.makeStream(of: Result<Void, Error>?.self)
        Task {
            let result: Result<Void, Error>
            do {
                try await transport.connect()
                result = .success(())
            } catch {
                result = .failure(error)
            }
            sink.yield(result)
        }
        let timer = limit.map { limit in
            Task {
                try? await Task.sleep(for: limit)
                sink.yield(nil)
            }
        }
        defer {
            timer?.cancel()
            sink.finish()
        }
        for await event in events { return event }
        return nil
    }

    /// Connects by the first of the server's routes that answers (see
    /// `ServerAddress.routes`), signing a fresh login for each, with full
    /// certificate verification on every one. The routes are tried one at a
    /// time (`RouteTurns`): each but the last has `nextRouteAfter` to connect,
    /// and a route that fails or is too slow is closed, awaited (bounded by
    /// `Transport.closeTimeout`), before the next one's client is made. The
    /// first to connect is kept. Throws the last route's error when none
    /// connects; the caller's backoff applies then.
    private func connectFirstRoute(of server: ServerAddress, xpub: String) async throws -> Transport {
        if !lastRouteRead {
            lastRouteRead = true
            // A route stored for another server, or one that is no longer a
            // fallback, is ignored.
            if let stored = try? storage.value(for: .lastRoute), let route = ServerAddress(stored),
               route == server.fallback {
                lastRoute = route
                // The named route is tried again `primaryProbeInterval` after it
                // was last tried, counted across launches; with no record, now.
                if let tried = (try? storage.value(for: .primaryTriedAt)).flatMap({ $0.flatMap(Double.init) }) {
                    let elapsed = max(0, Date.now.timeIntervalSince1970 - tried)
                    primaryProbedAt = ContinuousClock.now - .seconds(elapsed)
                }
            }
        }
        let now = ContinuousClock.now
        let probe = primaryProbedAt.map { now - $0 >= Self.primaryProbeInterval } ?? true
        let routes = server.routes(lastWorked: lastRoute, probingPrimary: probe)
        if routes.first == server {
            primaryProbedAt = now
            if lastRoute != nil, lastRoute == server.fallback { storePrimaryTried() }
        }

        if let testing = Self.connectingForTesting {
            try await testing.connect()
            if closed || Task.isCancelled { throw CancellationError() }
            return testing
        }

        // A login signed for each route; its client is made only when the
        // route starts, since every client made must be shut down.
        var logins: [(time: String, signature: String)] = []
        for _ in routes {
            let loginTime = clock.next()
            logins.append((loginTime, try Sphinxrs.rootSignMs(seed: seed, time: loginTime, network: network)))
        }

        var turns = RouteTurns(count: routes.count)
        var failure: Error = Failure.noServer
        while let index = turns.begin() {
            if closed || Task.isCancelled { throw CancellationError() }
            let transport = Transport(
                server: routes[index], clientID: xpub, username: logins[index].time, password: logins[index].signature,
                allowUntrustedCertificate: allowUntrustedCertificate
            )
            let outcome = await Self.connectRoute(transport, within: turns.window(of: index))
            // Closed or disconnected while connecting.
            if closed || Task.isCancelled {
                await transport.close()
                throw CancellationError()
            }
            if case .success? = outcome {
                rememberRoute(routes[index], of: server)
                return transport
            }
            if case .failure(let error)? = outcome { failure = error }
            // Failed or too slow: closed, and awaited, before the next route's client exists.
            await transport.close()
            turns.ended()
        }
        throw failure
    }

    /// Keeps the route that connected, in memory and in the profile, so the
    /// next connect (after a relaunch too) starts with it.
    private func rememberRoute(_ route: ServerAddress, of server: ServerAddress) {
        guard route != lastRoute else { return }
        lastRoute = route
        let isFallback = route == server.fallback
        let stored = isFallback ? route.description : ""
        if (try? storage.value(for: .lastRoute)) != stored {
            try? storage.set(stored, for: .lastRoute)
        }
        // Moving to the fallback means the named route was tried first on
        // this connect and did not answer in time.
        if isFallback { storePrimaryTried() }
    }

    private func storePrimaryTried() {
        try? storage.set(String(Int(Date.now.timeIntervalSince1970)), for: .primaryTriedAt)
    }

    private func establish() async throws {
        guard let server else { throw Failure.noServer }
        // A signup whose registration was never confirmed registers with
        // its invite again: the server answers `already_registered` if the
        // first register landed, and needs the invite if it did not.
        let inviteCode = try isRegistered ? nil : storedInvite()?.code
        await teardown()
        // Every client made before this has been shut down (or abandoned): one alive now is a leak.
        let alive = Transport.liveCount
        Diagnostics.recordTransportLifecycle(stage: alive == 0 ? .establish : .leak, live: alive)
        // A new connection is bound to the path as it is now and has been heard from: what was
        // noted of the old one (a path change, an abandoned catch-up) does not apply to it.
        pathChangedSinceBackground = false
        unverified = false
        setConnection(.connecting)
        establishingSince = .now
        defer { establishingSince = nil }
        do {
            try await run { _, _ in try Sphinxrs.setNetwork(network: network) }
            let xpub = try Sphinxrs.xpubFromSeed(seed: seed, time: clock.next(), network: network)
            let transport = try await connectFirstRoute(of: server, xpub: xpub)
            self.transport = transport
            listener = Task { [weak self] in
                for await message in transport.inbound {
                    await Engine.$handlingInbound.withValue(true) { await self?.receive(message) }
                }
                await self?.listenerEnded(transport)
            }
            // How far the register got, as for a money send: only `.none`
            // says it never left.
            let time = clock.next()
            let setup = try Sphinxrs.initialSetup(
                seed: seed, uniqueTime: time, state: StateCodec.encode(state), device: deviceID, inviteCode: inviteCode
            )
            let published = try await commitAndPublish(setup, time: time)
            if case .none = published { throw Failure.notConnected }
            if inviteCode != nil { inviteMayBeRedeemed = true }
            if case .unknown(let error) = published { throw error }
            let tribeTopic = try Sphinxrs.getTribeManagementTopic(
                seed: seed, uniqueTime: clock.next(), state: StateCodec.encode(state)
            )
            // This transport's own subscriptions, asserted again whatever the setup subscribed (a repeat is
            // harmless): one the broker refuses is a connection that cannot be trusted, dropped and rebuilt.
            var topics: [String] = []
            for topic in setup.subscriptionTopics + [tribeTopic] where !topics.contains(topic) { topics.append(topic) }
            do {
                try await transport.subscribe(topics)
                Diagnostics.recordSubscribed(topics: topics.count, ok: true)
            } catch {
                Diagnostics.recordSubscribed(topics: topics.count, ok: false)
                throw error
            }
            setConnection(.connected)
            connectedAt = .now
            keepAliveTask = Task { [weak self] in await self?.keepAlive(transport) }
            syncWatchdog?.cancel()
            syncWatchdog = Task { [weak self] in await self?.watchSync(transport) }
            selfCheckTask?.cancel()
            selfCheckTask = Task { [weak self] in await self?.watchSelfCheck(transport) }
            // A returning account is already registered; a new one comes online
            // when the server's registration reply lands (see `complete`).
            if isRegistered {
                await cameOnlineWithinTimeout()
            }
        } catch {
            await teardown()
            setConnection(.offline(retryIn: nil))
            throw error
        }
    }

    /// The broker's messages ended: the broker closed the connection, or a read failed on it.
    private func listenerEnded(_ ended: Transport) async {
        if ended.hasReadFailure { await dropOnPurpose(ended, reason: .readFailure, retryAt: 1) } else { await connectionClosed(ended) }
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
        // The isolation named, not inferred: an optimized build ran the
        // inferred one off this actor and stopped at the runtime's check.
        await withTaskCancellationHandler(operation: {
            await withCheckedContinuation(isolation: self) { waiters[id] = $0 }
        }, onCancel: {
            Task { [weak self] in await self?.wake(id) }
        }, isolation: self)
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
                try await establish()
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
    func connectionClosed(_ closed: Transport, retryAt attempt: Int = 1) async {
        guard transport === closed else { return }
        transport = nil
        endConnectionWork()
        setConnection(.offline(retryIn: nil))
        // Closed in the background, after the reconnect starts: closing a
        // socket gone bad must never delay or block the way back.
        // The next connect waits for it (`teardown`), so two clients of one ID are never alive together;
        // after an earlier close still in flight.
        let earlier = closing
        let closingNow = Task {
            await earlier?.value
            await closed.close()
        }
        closing = closingNow
        guard keepConnected else {
            await closingNow.value
            return
        }
        // A loop still in `establish` leaves the reconnect to itself
        // (see `reconnectLoop`); one that has been there longer than
        // `stuckEstablish` is not progressing, and is replaced, so a hung
        // loop is never the reason a drop is not reconnected.
        let stuck = establishingSince.map { ContinuousClock.now - $0 > Self.stuckEstablish } ?? false
        if reconnectTask == nil || stuck {
            reconnectTask?.cancel()
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
        let started = ContinuousClock.now
        let answered = await transport.answersPing(within: Self.pingTimeout)
        let took = ContinuousClock.now - started
        let readFailed = transport.hasReadFailure
        let timedOut = !answered && !readFailed && took >= Self.pingTimeout
        // A cancelled caller's ping ends early and proves nothing: not a dead connection.
        if answered || !Task.isCancelled {
            Diagnostics.recordPingResult(ok: answered, milliseconds: Self.milliseconds(of: took), timedOut: timedOut)
        }
        if answered {
            unverified = false
            return true
        }
        if Task.isCancelled { return false }
        // A link that keeps dying soon after it comes up backs off as a
        // failed connect would; one that lived a while reconnects at once.
        let lived = connectedAt.map { ContinuousClock.now - $0 } ?? .zero
        shortLivedDrops = lived < Self.shortLived ? shortLivedDrops + 1 : 0
        await dropOnPurpose(transport, reason: readFailed ? .readFailure : timedOut ? .pingTimeout : .pingFailed, retryAt: shortLivedDrops)
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
                Self.noteNetwork(path)
                let now = (path.status, path.availableInterfaces.map(\.name))
                let changed = last.map { $0 != now } ?? false
                last = now
                guard changed else { continue }
                // Noted at once, not after the settle: a connection made before this change is
                // bound to the old path, and the app may come to the front before it settles.
                await self?.notePathChanged()
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

    /// Observation only: the raw path as an enum record (docs/diagnostics.md); never an interface name.
    private static func noteNetwork(_ path: NWPath) {
        let status: DiagnosticEvent.NetworkStatus = switch path.status {
        case .satisfied: .satisfied
        case .requiresConnection: .requiresConnection
        default: .unsatisfied
        }
        let interface: DiagnosticEvent.NetworkInterface =
            path.usesInterfaceType(.wifi) ? .wifi
            : path.usesInterfaceType(.cellular) ? .cellular
            : path.usesInterfaceType(.wiredEthernet) ? .wiredEthernet
            : path.availableInterfaces.isEmpty ? .none : .other
        Diagnostics.recordNetwork(status: status, interface: interface, isExpensive: path.isExpensive,
                                  isConstrained: path.isConstrained)
    }

    static let networkSettle: Duration = .seconds(1)

    private func notePathChanged() {
        pathChangedSinceBackground = true
        Diagnostics.recordPathChangeFlagged(awaySeconds: leftForegroundAt.map { Int(Self.milliseconds(of: ContinuousClock.now - $0) / 1_000) })
    }

    /// The path settled. A connection is bound to the path it was made on, and may be a zombie
    /// that answers nothing after a switch, so coming online on a new path rebuilds it rather
    /// than pinging it; going offline pings, which has the keep-alive's say. A rebuild already
    /// made (by the foreground, say) has cleared the flag, and is not made twice.
    private func networkChanged(online: Bool) async {
        guard keepConnected else { return }
        if connection == .connected {
            if online {
                guard pathChangedSinceBackground, let current = transport else { return }
                await dropOnPurpose(current, reason: .pathChange)
            } else {
                _ = await connectionAnswers()
            }
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
        // The old client's disconnect and shutdown, started by `connectionClosed`, must end (each is bounded
        // by `Transport.closeTimeout`) before another client is made.
        if let pending = closing {
            await pending.value
            if closing == pending { closing = nil }
        }
    }

    /// What belongs to one connection and ends with it.
    private func endConnectionWork() {
        cameOnlineHere = false
        catchUp.reset()
        // A reply to this connection's status query can only come on it.
        unrecordedPayments = []
        ownStatusCheckedAt = [:]
        ownStatusAsked = []
        ownStatusHeard = []
        unknownTags = []
        resendGate = nil
        connectedAt = nil
        caughtUpNoted = false
        keepAliveTask?.cancel()
        keepAliveTask = nil
        syncWatchdog?.cancel()
        syncWatchdog = nil
        selfCheckTask?.cancel()
        selfCheckTask = nil
        lastHistoryActivity = nil
        catchUpStarted = nil
        resendTask?.cancel()
        resendTask = nil
        stopHistoryWatchdog()
        keepingCatchUpInBackground = false
        catchUpRetries = 0
        updateFailing()
    }

    // MARK: - Recovery

    /// Reads again from storage everything `init` read (`loadPersistedState`), and forgets what only
    /// the old connection knew, so the next core call starts from what a relaunch would: the core is
    /// stateless, and this is the only state of the engine that can fall out of step with storage.
    /// `.reinit` also drops the session's other caches. The seed and the transport are not touched.
    ///
    /// `keepingHistory` leaves the run in flight and its watchdog alone: for retrying the very page
    /// that failed, which needs its run to advance. Otherwise the run is abandoned (not a restore's),
    /// and the next catch-up asks again from `history.from`.
    func recoverCore(reason: CoreRecoveryReason, keepingHistory: Bool = false) async {
        let stage: DiagnosticEvent.CoreRecoveryStage = reason == .reinit ? .reinit : .reloadState
        do {
            // All of it read before any is assigned: a failure leaves the engine as it was.
            let persisted = try Self.loadPersistedState(storage)
            resendTask?.cancel()
            resendTask = nil
            if !keepingHistory {
                stopHistoryWatchdog()
                if !restoring { abandonHistory(reason: .error) }
            }
            state = persisted.state
            contactsByChildIndex = Self.index(persisted.contacts)
            tribes = persisted.tribes
            alias = persisted.alias
            photoURL = persisted.photoURL
            server = persisted.server
            echoedAliases = persisted.echoedAliases
            restoring = persisted.restoring
            history.from = persisted.historyFrom
            // Never back: a later call must not reuse a time an earlier one used.
            clock = UniqueClock(last: max(clock.last, persisted.clock))
            pingsByHash = [:]
            pingsByTag = [:]
            unrecordedPayments = []
            ownStatusCheckedAt = [:]
            ownStatusAsked = []
            ownStatusHeard = []
            unknownTags = []
            resendGate = nil
            historyPages = 0
            if stage == .reinit {
                memesToken = nil
                templateList = nil
                profileRecoveryDone = false
                readsSentSinceGetReads = []
                mutesSetSinceGetMutes = []
                readsAskedAt = nil
                if !keepingHistory, !restoring { history = HistoryCursor(); history.from = persisted.historyFrom }
            }
            _ = try Sphinxrs.setNetwork(network: network)
            Diagnostics.recordCoreRecovery(reason: reason, stage: stage)
            emit.yield(.coreRecovered(reason: reason, stage: stage))
        } catch {
            Diagnostics.recordCoreFailure(site: .catchUp, kind: "recover", detail: "recovery \(reason.rawValue): \(PeelError.readable(error))")
            emit.yield(.coreError("recovering the core: \(PeelError.readable(error))"))
        }
    }

    /// The core failed again after `recoverCore`: counted, and past the thresholds the state is
    /// reloaded and the connection rebuilt (it subscribes and catches up from the cursor again), and
    /// at the last one everything is initialised again (`.needsFullRestart`, which the app answers by
    /// opening the account afresh; the engine does the deepest recovery it can meanwhile).
    func noteCoreFailure() async {
        consecutiveCoreFailures += 1
        updateFailing()
        guard consecutiveCoreFailures >= Self.coreFailureReloadThreshold else { return }
        let reinit = consecutiveCoreFailures >= Self.coreFailureReinitThreshold
        await recoverCore(reason: reinit ? .reinit : .repeated)
        if reinit, !fullRestartRequested {
            fullRestartRequested = true
            emit.yield(.needsFullRestart)
        }
        if let current = transport { await dropOnPurpose(current, reason: .coreFailure) }
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

    /// Tests only: the in-memory state a failure left behind, to be reloaded by `recoverCore`.
    func corruptStateForTesting() {
        state = [:]
        contactsByChildIndex = [:]
        tribes = [:]
        alias = "corrupted"
        history.from = 0
    }

    /// Tests only: where history stands in memory.
    func setHistoryFromForTesting(_ from: UInt64) { history.from = from }

    /// Tests only: the contacts index as the engine holds it.
    var contactsByChildIndexForTesting: [UInt64: String] { contactsByChildIndex }

    /// Tests only: the clock's last unique time, and a clock moved on.
    var clockLastForTesting: UInt64 { clock.last }
    func setClockForTesting(last: UInt64) { clock = UniqueClock(last: last) }

    /// Tests only: the failures counted so far.
    func setConsecutiveCoreFailuresForTesting(_ count: Int) {
        consecutiveCoreFailures = count
        updateFailing()
    }

    /// Tests only: the next `count` inbound messages fail in the core before it is called (see `receive`).
    var failingHandlesForTesting = 0
    func setFailingHandlesForTesting(_ count: Int) { failingHandlesForTesting = count }

    /// Tests only: `cameOnline` has run on the transport set.
    func cameOnlineForTesting() { cameOnlineHere = true }

    /// Tests only: history last moved `age` ago.
    func backdateHistoryActivityForTesting(by age: Duration) { lastHistoryActivity = .now - age }

    /// Tests only: the app left the front `age` ago.
    func backdateLeftForegroundForTesting(by age: Duration) { leftForegroundAt = .now - age }

    /// Tests only: the path changed (as the monitor notes it).
    func markPathChangedForTesting() { notePathChanged() }

    /// Tests only: the engine says connected, and caught up or not.
    func setConnectedForTesting(caughtUp: Bool) {
        setConnection(.connected)
        if caughtUp { catchUp.finish() }
    }

    /// Tests only: a page of history came.
    func historyPageArrivedForTesting() { historyPages += 1 }

    /// Tests only: an old transport's close still in flight, as `connectionClosed` leaves it.
    func setClosingForTesting(_ task: Task<Void, Never>?) { closing = task }

    /// Tests only: how long `appBecameActive` gives a connection to answer.
    func setVerifyTimeoutForTesting(_ timeout: Duration) { verifyTimeout = timeout }

    /// Tests only: this connection came up `age` ago.
    func backdateConnectionForTesting(by age: Duration) { connectedAt = .now - age }

    /// Tests only: the connection every connect in this task makes, such
    /// as `Transport(publishing:)`, in place of one to the server.
    @TaskLocal static var connectingForTesting: Transport?
    #else
    static var connectingForTesting: Transport? { nil }
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
    /// payment counts for no more than `arrived` says came (`cappedToArrived`),
    /// the message `indices` it carried move where history stands
    /// (both from `arrived(kind:topic:page:)`), and a `live` message's contact
    /// record only when this account signed it (`isForeignContactRecord`, which
    /// may make the call a second time).
    @discardableResult
    func run(
        expectedSender: String? = nil, arrived: [String: UInt64]? = nil, indices: [UInt64]? = nil,
        live: Bool = false,
        _ call: (_ time: String, _ state: Data) throws -> RunReturn
    ) async throws -> RunReturn {
        let time = clock.next()
        var result = try call(time, StateCodec.encode(state))
        if let arrived { result.msgs = Self.cappedToArrived(result.msgs, arrived) }
        // Nothing of it is committed or published, not even the message, and
        // sats it carries are not settled.
        if live, try isForeignContactRecord(result, again: call) { return result }
        let followUps = try commit(result, time: time, expectedSender: expectedSender, indices: indices)
        try await complete(result, followUps)
        return result
    }

    struct FollowUps {
        var acknowledgedPings: [UInt64] = []
        var justRegistered = false
        var restorePlan: MessageCounts?
        /// Tribes first seen in this call, whose names are still to be looked up.
        var discoveredTribes = false
        /// A tribe another device of this account joined is to be asked of
        /// our own tribes registry (`TribeWork.held`, `confirmTribes`).
        var confirmTribes = false
        /// Purchases of our paid attachments to answer.
        var purchases: [Message] = []
        /// Messages from the agent contact (`deviceAgent`), which may be its
        /// requests to this device.
        var deviceRequests: (agent: String, messages: [Message])?
        /// The balance went up (or changed at all with an invoice open,
        /// `balanceCallsForReconcile`), or someone's payment came: the server's
        /// history may now settle an invoice made here or confirm the sats.
        var reconcile = false
        /// What follows a page of history, the cursor already moved (`HistoryCursor.advance`).
        var historyPage: HistoryCursor.Page?
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

    /// Whether a live message's result is a contact record (type 33) that
    /// would write contacts though this account did not sign it. The core
    /// Peel links (`bd9e140`) takes one from anyone (`handle_msg.rs`; upstream
    /// checks the signer since SR-017): it writes the record's route and
    /// contact key over the contact it names, with the topic's child index,
    /// and gives that contact as the message's sender, so the result does not
    /// say who signed it. Against the state the record would leave, the same
    /// call writes nothing and gives the signer (`overwrite_incoming_type_33`
    /// returns early), so it is made once more there. Only this account's own
    /// key, which its other devices sign with, may have signed one. History
    /// pages need none of this: the core checks the signer there itself.
    private func isForeignContactRecord(
        _ result: RunReturn, again call: (_ time: String, _ state: Data) throws -> RunReturn
    ) throws -> Bool {
        let isRecord = { (msg: Msg) in msg.type == UInt8(MessageType.contactKeyRecord) }
        guard result.msgs.contains(where: isRecord),
              let updates = try result.stateMp.map(StateCodec.decode),
              updates.keys.contains(where: { $0.hasPrefix("c/") }) else { return false }
        let again = try call(clock.next(), StateCodec.encode(state.merging(updates) { _, new in new }))
        let signer = again.msgs.first(where: isRecord).flatMap { JSON.decode(SenderInfo.self, from: $0.sender)?.pubkey }
        return signer != accountKey
    }

    /// The topics a live message comes on: pushed (`stream`), or asked for.
    static let liveKinds: Set<String> = ["msg", "msgs", "stream"]

    /// What the server says it sent, beside what the core reads, by message
    /// index: what arrived with each payment (`cappedToArrived`), and every
    /// message's index, those the core cannot read too, which moves where
    /// history stands. A live message's topic ends with its index, time and,
    /// for a payment, its hash and amount
    /// (`{root}/{pk}/{idx}/res/{device}/{kind}/{index}/{ts}/{hash}/{msat}`,
    /// the mixer's `stream_res_topic`); a page of history carries each
    /// beside its onion (`page`, from `StateCodec.onions`).
    static func arrived(
        kind: String, topic parts: [Substring], page: [Data]?
    ) -> (msat: [String: UInt64], indices: [UInt64]?) {
        if let page { return (StateCodec.paymentAmounts(of: page), page.map(StateCodec.index(of:))) }
        guard liveKinds.contains(kind), parts.count > 6 else { return ([:], nil) }
        let msat = parts.count > 9 ? UInt64(parts[9]).map { [String(parts[6]): $0] } : nil
        return (msat ?? [:], UInt64(parts[6]).map { [$0] })
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
        invites: [InviteRecord] = [], indices: [UInt64]? = nil, keepMembership: Bool = false,
        deviceSend: Storage.Commit.DeviceSend? = nil, keysends: [KeysendRecord] = [],
        walletBudget: Storage.Commit.WalletBudgetCheck? = nil
    ) throws -> FollowUps {
        // Whatever a poll waits for lands here (and a refused commit wakes it harmlessly).
        defer { wakeWaiters() }
        var followUps = FollowUps()
        var commit = Storage.Commit()
        commit.settings[.clock] = time
        commit.resend = resend
        commit.deviceSend = deviceSend
        commit.reads = Self.reads(result.lastRead).filter { !readsSentSinceGetReads.contains($0.key) }
        if let json = result.muteLevels, let mutes = JSON.decode([String: Int].self, from: json) {
            commit.mutes = mutes.filter { !mutesSetSinceGetMutes.contains($0.key) }
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
        commit.keysends = keysends
        commit.walletBudget = walletBudget
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
        var held: [(chat: String, msg: Msg, host: String?)] = []
        var notTribes: Set<String> = []
        var echoedAliases = self.echoedAliases
        // The tags of our copies taken in this call, with their uuids (`isReplay`).
        var tagged: [String: String] = [:]
        for msg in result.msgs {
            if let hash = msg.paymentHash, let pingTime = pingsByHash[hash] {
                followUps.acknowledgedPings.append(pingTime)
                landedPings.append(hash)
            }
            guard let decoded = Self.message(from: msg, expectedSender: expectedSender, state: newState, accountKey: accountKey) else { continue }
            var (message, trustSender) = (decoded.message, decoded.trustSender)
            // A member's replay of our tag: dropped before it can name a
            // tribe, change our membership or aliases, or be stored.
            if try isReplay(message, original: decoded.fields?.originalUuid, state: newState, taken: &tagged) {
                continue
            }
            // Filed under its signer, which this device's core does not know:
            // a tribe joined on another device. Held, not stored, until the
            // tribe is known; our join, or the owner's approval naming us,
            // makes it one to ask our own tribes registry about.
            if decoded.unfiled, knownTribes[message.chat] == nil {
                let host = tribeToConfirm(message, state: newState)
                if host != nil { followUps.confirmTribes = true }
                held.append((message.chat, msg, host))
                continue
            }
            if knownTribes[message.chat] == nil, !notTribes.contains(message.chat),
               let found = try discoveredTribe(message, trustSender: trustSender, state: newState, notTribes: &notTribes) {
                knownTribes[found.pubkey] = found
                commit.tribes.append(found)
                followUps.discoveredTribes = true
            }
            // Ours signed by the chat itself is a tribe's forward or forged. The
            // core files any signer as a contact at the index it wrote to, so
            // a contact without a contact key is no proof of a tribe.
            if decoded.signedByChat, knownTribes[message.chat] == nil { continue }
            if !keepMembership, let tribe = knownTribes[message.chat],
               let changed = Self.membership(
                   after: message, in: tribe, sent: tribe.sentAlias(account: alias), echoed: echoedAliases[message.chat] ?? [],
                   replaying: restoring) {
                knownTribes[tribe.pubkey] = changed
                commit.tribes.append(changed)
            }
            var replaces: String?
            if let tribe = knownTribes[message.chat] {
                // Left: what the tribe still sends is dropped, but for our own
                // leave (or a join stored without changing membership,
                // `keepMembership`), kept so its tag is held: a later copy of
                // it (the tribe's replay to a re-join, or a member's) is then
                // a replay (`isReplay`), not our leave or join again.
                if tribe.left {
                    if message.fromMe, message.tag != nil,
                       [MessageType.groupLeave, MessageType.groupJoin].contains(message.type) {
                        commit.messages.append((message, false, decoded.fields?.originalUuid))
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
        // The proof that came with a COMPLETE, for an invoice we pay or an app's keysend.
        if let sent, sent.status == Message.Delivery.delivered.rawValue, let tag = sent.tag,
           let preimage = sent.preimage?.nilIfEmpty {
            commit.preimages = [(tag, preimage)]
        }
        // Why a send failed, as the server put it (kept for an invoice we pay).
        for reply in [sent].compactMap({ $0 }) + (records ?? []) where reply.status == Message.Delivery.failed.rawValue {
            if let tag = reply.tag, let reason = (reply.message ?? reply.error)?.nilIfEmpty {
                commit.sendErrors[tag] = reason
            }
        }

        // What the server sent moves where history stands, written with it:
        // a page of history by every index on it, a live message by its own.
        var cursor = history
        var pageIndices: [UInt64]?
        if arrival != .live {
            let indices = indices ?? result.msgs.compactMap { $0.index.flatMap { UInt64($0) } }
            pageIndices = indices
            followUps.historyPage = cursor.advance(indices: indices, total: result.msgsTotal)
        } else {
            for index in indices ?? [] { cursor.cameLive(index) }
        }
        if cursor.from != history.from {
            commit.settings[.historyFrom] = String(cursor.from)
        }

        let settling = try storage.openInvoices(among: commit.settled.map(\.0))
        let applied = try storage.apply(commit)
        // What the server sent, as numbers only: a page of history, or a message that came live.
        if let pageIndices {
            Diagnostics.recordHistoryPage(
                count: pageIndices.count, maxIndex: pageIndices.max().map { Int(clamping: $0) }, new: applied.inserted)
            if arrival == .history { newFromCatchUp += applied.inserted }
        } else if let index = indices?.first {
            let row = applied.stored.first { $0.serverIndex == Int64(clamping: index) } ?? applied.stored.first
            Diagnostics.recordLiveMessage(
                index: Int(clamping: index), fromMe: row?.fromMe, type: row?.type, new: applied.inserted > 0)
        }
        removeFiles(of: applied.purged)
        state = newState
        history = cursor
        if let records {
            unrecordedPayments = []
            if !ownStatusAsked.isEmpty { ownStatusHeard.formUnion(records.compactMap(\.tag)) }
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
        hold(held)
        if echoedAliases != self.echoedAliases {
            self.echoedAliases = echoedAliases
            emit.yield(.echoedAliases(echoedAliases))
            checkMentionsIfNeeded()
        }
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
            if deviceRequestHandler != nil, let agent = deviceAgent {
                followUps.deviceRequests = (agent, applied.stored.filter { $0.chat == agent && !$0.fromMe })
            }
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
            Diagnostics.recordCoreFailure(site: .commit, kind: nil, detail: error)
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
        mutesSetSinceGetMutes.remove(pubkey)
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
        invoices: [InvoiceRecord] = [], invites: [InviteRecord] = [], deviceSend: Storage.Commit.DeviceSend? = nil,
        keysends: [KeysendRecord] = [], walletBudget: Storage.Commit.WalletBudgetCheck? = nil
    ) async throws -> Published {
        let followUps = try commit(
            result, time: time, expectedSender: nil, outgoing: outgoing, resend: resend, invoices: invoices,
            invites: invites, deviceSend: deviceSend, keysends: keysends, walletBudget: walletBudget
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

    /// How `mayHaveGone` begins: a notice about the connection at that moment,
    /// which the app drops once it is stale (`ConnectionNotices`).
    public static let connectionFailedNotice = "The connection failed while sending"

    /// What a money send whose publish ended `.unknown` reports: `what`
    /// went, a payment, or a message that paid a tribe's price.
    static func mayHaveGone(_ error: any Error, what: String = "payment") -> String {
        "\(connectionFailedNotice); the \(what) may have gone. "
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

    /// Messages already read by the core, committed as if the core had just
    /// returned them (a held tribe's, once the tribe is known); with
    /// `keepMembership`, stored without changing the tribe's membership.
    func replay(_ msgs: [Msg], keepMembership: Bool = false) async throws {
        let result = RunReturn(
            msgs: msgs, msgsTotal: nil, msgsCounts: nil, subscriptionTopics: [], settleTopic: nil, settlePayload: nil,
            asyncpayTopic: nil, asyncpayPayload: nil, registerTopic: nil, registerPayload: nil, topics: [], payloads: [],
            stateMp: nil, stateToDelete: [], newBalance: nil, myContactInfo: nil, sentStatus: nil, settledStatus: nil,
            registerResponse: nil, asyncpayTag: nil, error: nil, newTribe: nil, tribeMembers: nil, newInvite: nil,
            inviterContactInfo: nil, inviterAlias: nil, initialTribe: nil, lspHost: nil, invoice: nil, route: nil,
            node: nil, lastRead: nil, muteLevels: nil, payments: nil, paymentsTotal: nil, tags: nil, deletedMsgs: nil,
            newChildIdx: nil, ping: nil
        )
        let followUps = try commit(result, time: clock.next(), expectedSender: nil, keepMembership: keepMembership)
        try await complete(result, followUps)
    }

    private func followUp(_ result: RunReturn, _ followUps: FollowUps) async throws {
        for pingTime in followUps.acknowledgedPings {
            try await run { time, state in
                try Sphinxrs.pingDone(seed: seed, uniqueTime: time, state: state, pingTs: pingTime)
            }
        }
        if followUps.discoveredTribes { refreshTribesInBackground() }
        if followUps.confirmTribes { confirmTribesInBackground() }
        if followUps.reconcile { reconcileInBackground() }
        for purchase in followUps.purchases {
            do {
                try await answerPurchase(purchase)
            } catch {
                emit.yield(.conversationError(chat: purchase.chat, message: "A purchase could not be answered: \(PeelError.readable(error))"))
            }
        }
        if let (agent, messages) = followUps.deviceRequests {
            for message in messages { await answerDeviceRequest(in: message, from: agent) }
        }
        if followUps.justRegistered {
            await cameOnline()
        }
        if let counts = followUps.restorePlan {
            try await startRestore(counts)
        }
        if let page = followUps.historyPage {
            try await advanceHistory(page)
        }
    }

    /// Turns what the core reported into a row, deciding which conversation it
    /// belongs to. The core recovers a message's sender from its signature, so a
    /// sender can only ever name themself; for a live message the child index in
    /// the topic names the contact as well and the two must agree. Contact
    /// records (type 33) count only when this account signed them: the core
    /// checks those in history, `run` live ones (`isForeignContactRecord`);
    /// they come back with no `sentTo`, so never as ours.
    /// Messages from senders the core does not know are dropped.
    /// The core calls a message ours by a tag or a date a contact can
    /// arrange, so a copy of ours is kept only when signed by this account
    /// or by the chat it is filed under, which `commit` then requires to be
    /// a tribe (docs/phases/04-money.md, "Who may write ours").
    /// On another device of this account, a tribe joined elsewhere is not in
    /// the core yet: its forward of ours comes with no `sentTo`, and the
    /// owner's approval from a sender the core does not know. Each is filed
    /// under its signer as `unfiled`, which `commit` keeps only once the
    /// tribe is known.
    private static func message(
        from msg: Msg, expectedSender: String?, state: [String: Data], accountKey: String
    ) -> (message: Message, trustSender: Bool, signedByChat: Bool, unfiled: Bool, fields: BodyFields?)? {
        guard let type = msg.type else { return nil }
        let fromMe = msg.fromMe ?? false
        let sender = JSON.decode(SenderInfo.self, from: msg.sender)
        let claimed = sender?.pubkey
        let chat: String
        var trustSender = false
        var unfiled = false
        if fromMe {
            // Ours signed by our own key with no `sentTo` (a contact record) is never filed.
            guard let to = msg.sentTo ?? claimed.flatMap({ $0 == accountKey ? nil : $0 }) else { return nil }
            guard claimed == accountKey || claimed == to else { return nil }
            chat = to
            unfiled = msg.sentTo == nil
        } else if let expectedSender {
            chat = expectedSender
            trustSender = claimed == expectedSender
        } else if let claimed, state["c/\(claimed)"] != nil {
            chat = claimed
            trustSender = true
        } else if let claimed, Int(type) == MessageType.memberApprove, sender?.host?.nilIfEmpty != nil {
            chat = claimed
            unfiled = true
        } else {
            return nil
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
        return (message, trustSender, fromMe && claimed != accountKey, unfiled, fields)
    }

    func receive(_ inbound: Inbound) async {
        let parts = inbound.topic.split(separator: "/", omittingEmptySubsequences: false)
        let kind = parts.count > 5 ? String(parts[5]) : inbound.topic

        // Answering a ping needs our own route hint. Until registered, let it go:
        // the server re-sends pending pings when we ask for them on coming online.
        if kind == "ping", !isRegistered { return }
        // The server's health, every 15 s: the core only reads it back and
        // Peel shows none, so it costs a core call and a write for nothing.
        if kind == "health" { return }

        // The child index in a live message's topic names the contact whose key
        // decrypted it; index 0 is the account key used for key exchange.
        let live = Self.liveKinds.contains(kind)
        var expectedSender: String?
        if live, parts.count > 2, let index = UInt64(parts[2]), index > 0 {
            expectedSender = contactsByChildIndex[index]
        }
        do {
            try await process(inbound, kind: kind, topic: parts, live: live, expectedSender: expectedSender)
            if kind == "batch" { noteCoreSuccess() }
        } catch {
            Diagnostics.recordCoreFailure(site: .receive, kind: kind, detail: PeelError.readable(error))
            // A page of history the core refuses is retried once after the engine read its state again
            // from storage, as a relaunch would: the page is still in hand, and its run still set.
            if kind == "batch", !Task.isCancelled, !(error is CancellationError) {
                await recoverCore(reason: .pageFailed, keepingHistory: true)
                do {
                    try await process(inbound, kind: kind, topic: parts, live: live, expectedSender: expectedSender)
                    noteCoreSuccess()
                    return
                } catch {
                    Diagnostics.recordCoreFailure(site: .receive, kind: kind, detail: "after recovery: \(PeelError.readable(error))")
                    report(error, kind: kind, expectedSender: expectedSender)
                    await noteCoreFailure()
                    return
                }
            }
            report(error, kind: kind, expectedSender: expectedSender)
        }
    }

    /// One inbound message through the core: the call, committed and followed up (`run`).
    private func process(
        _ inbound: Inbound, kind: String, topic parts: [Substring], live: Bool, expectedSender: String?
    ) async throws {
        #if DEBUG
        if failingHandlesForTesting > 0 {
            failingHandlesForTesting -= 1
            throw Failure.notConnected
        }
        #endif
        let page = kind == "batch" ? StateCodec.onions(inBatch: inbound.payload) : nil
        let arrived = Self.arrived(kind: kind, topic: parts, page: page)
        try await run(expectedSender: expectedSender, arrived: arrived.msat, indices: arrived.indices, live: live) { time, state in
            let handle = { (payload: Data) in
                try Sphinxrs.handle(
                    topic: inbound.topic, payload: payload, seed: self.seed, uniqueTime: time,
                    state: state, myAlias: self.alias, myImg: self.photoURL
                )
            }
            do {
                return try handle(inbound.payload)
            } catch let refusal {
                guard let page else { throw refusal }
                return try Self.readablePart(of: page, refusal: refusal, handle: handle)
            }
        }
        if kind == "getreads" {
            readsAskedAt = nil
            try await publishPendingReads()
        }
    }

    private func report(_ error: any Error, kind: String, expectedSender: String?) {
        if let expectedSender {
            emit.yield(.conversationError(chat: expectedSender, message: "A message could not be read: \(PeelError.readable(error))"))
        } else {
            emit.yield(.coreError("\(kind): \(PeelError.readable(error))"))
        }
    }

    /// `cameOnline`, given `cameOnlineTimeout`: one that hangs (a fetch the
    /// connection swallowed) must not leave `establish`, and with it the
    /// reconnect loop, waiting for ever. One that does not finish in time is
    /// cancelled and its connection dropped, so the loop connects again and
    /// the next `cameOnline` catches up.
    private func cameOnlineWithinTimeout() async {
        let connection = transport
        let online = Task { [weak self] in await self?.cameOnline() }
        do {
            try await poll(timeout: Self.cameOnlineTimeout, failure: .registrationTimedOut) {
                cameOnlineHere || transport !== connection ? () : nil
            }
        } catch {
            online.cancel()
            if let connection { await dropOnPurpose(connection, reason: .cameOnlineTimeout, retryAt: 1) }
        }
    }

    /// Runs `step` and, when it fails, again after each of
    /// `cameOnlineRetryDelays`, until it works; the last failure is thrown.
    /// Stops at once when the task is cancelled or the connection it was
    /// for has gone (the next one comes online by itself).
    private func retrying(on connection: Transport?, _ step: () async throws -> Void) async throws {
        var delays = Self.cameOnlineRetryDelays[...]
        while true {
            do {
                try await step()
                return
            } catch {
                guard let delay = delays.popFirst(), !Task.isCancelled, transport === connection else { throw error }
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled, transport === connection else { throw error }
            }
        }
    }

    /// Runs once per connection, as soon as the account is registered. Decides
    /// what history to fetch: resume a run a dropped connection interrupted, do
    /// the full restore an account brought back from its words still needs, or
    /// catch up from where history stands (`syncMessages`). Then, in the
    /// background, it sends again what a reconnect sends by itself
    /// (`resendRecent`), answers purchases still owed their key
    /// (`answerOwedPurchases`) and finishes the agent's requests a stop cut
    /// short (`answerOwedDeviceRequests`).
    private func cameOnline() async {
        let connection = transport
        emit.yield(.registered(contactInfo: try? storage.value(for: .contactInfo)))
        refreshTribesInBackground()
        if tribeWork.held.values.contains(where: { $0.host != nil }) { confirmTribesInBackground() }
        reconcileInBackground()
        // The account's preferences, a restore's included: applied as soon
        // as it is online, and anything changed here offline goes up.
        schedulePreferencesSync(after: .zero)
        do {
            try await cameOnlineSteps(on: connection)
        } catch {
            emit.yield(.coreError("coming online: \(PeelError.readable(error))"))
            Diagnostics.recordCoreFailure(site: .cameOnline, kind: nil, detail: PeelError.readable(error))
            // The fetches failed past their retries: the engine's state may be what they trip on.
            // Read it again, as a relaunch would, and go through the steps once more.
            if !Task.isCancelled, !(error is CancellationError), let connection, transport === connection {
                await recoverCore(reason: .cameOnline)
                do {
                    try await cameOnlineSteps(on: connection)
                } catch {
                    emit.yield(.coreError("coming online: \(PeelError.readable(error))"))
                    Diagnostics.recordCoreFailure(
                        site: .cameOnline, kind: nil, detail: "after recovery: \(PeelError.readable(error))")
                    if !Task.isCancelled, !(error is CancellationError) { await noteCoreFailure() }
                }
            }
        }
        addInviterIfPending()
        // Only on the connection this ran for: one that went meanwhile has
        // its own `cameOnline` to come (and one that was given up on, by
        // `cameOnlineWithinTimeout`, must not mark the next one online).
        guard let connection, transport === connection else {
            wakeWaiters()
            return
        }
        cameOnlineHere = true
        wakeWaiters()
        resendTask?.cancel()
        resendTask = Self.background { [weak self] in
            await self?.resendRecent(on: connection)
            await self?.answerOwedPurchases(on: connection)
            await self?.answerOwedDeviceRequests(on: connection)
        }
    }

    /// What coming online asks of the server, each step retried after `cameOnlineRetryDelays`.
    private func cameOnlineSteps(on connection: Transport?) async throws {
        try await retrying(on: connection) {
            _ = try await run { time, state in
                try Sphinxrs.fetchPings(seed: seed, uniqueTime: time, state: state)
            }
        }
        try await retrying(on: connection) { try await fetchReadsAndMutes() }
        // Best effort: catching up must not wait on it.
        do {
            try await checkPendingSends()
        } catch {
            Diagnostics.recordCoreFailure(site: .checkPending, kind: nil, detail: PeelError.readable(error))
            emit.yield(.coreError("checking pending sends: \(PeelError.readable(error))"))
        }
        try await retrying(on: connection) { try await resumeHistory(reason: .cameOnline) }
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

    /// How long a chat's own messages are left before they are asked about again.
    static let ownStatusWait: Duration = .seconds(60)
    /// How many tags one `getTags` carries.
    static let ownStatusChunk = 50

    /// Asks the server what became of this chat's own messages it has not
    /// confirmed (no status, or pending), a chunk at a time: the answers
    /// land as statuses and the chat's bolts follow. Called when the chat is
    /// opened, the app comes to the front and history pages arrive; at most
    /// once per `ownStatusWait` for a chat, and not for a tag the server had
    /// no record of at the last ask. Best effort: a failure is left to the
    /// next ask or connect (`checkPendingSends`).
    public func checkOwnMessageStatus(in chat: String) async {
        guard transport != nil, cameOnlineHere else { return }
        if let asked = ownStatusCheckedAt[chat], ContinuousClock.now - asked < Self.ownStatusWait { return }
        // A reply to an earlier ask has come by now.
        unknownTags.formUnion(ownStatusAsked.subtracting(ownStatusHeard))
        ownStatusAsked = []
        ownStatusHeard = []
        guard let unconfirmed = try? storage.unconfirmedTags(in: chat) else { return }
        let tags = unconfirmed.filter { !unknownTags.contains($0) }
        guard !tags.isEmpty else { return }
        ownStatusCheckedAt[chat] = .now
        ownStatusAsked.formUnion(tags)
        for start in stride(from: 0, to: tags.count, by: Self.ownStatusChunk) {
            let chunk = Array(tags[start..<min(start + Self.ownStatusChunk, tags.count)])
            do {
                try await run { time, state in
                    try Sphinxrs.getTags(seed: seed, uniqueTime: time, state: state, tags: chunk, pubkey: nil)
                }
            } catch {
                return
            }
        }
    }

    /// Asks the server what became of sends still pending here, as the Mac
    /// app does on start: a status published while this device was offline
    /// (an async payment redeemed later, say) is not sent again.
    /// A payment (or a message that paid a tribe's price) the server has no
    /// record of this long after it was sent never reached it (the mixer
    /// records every send it handles, an async one as pending), so it is
    /// marked failed and may be sent again.
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

    /// Asks again for the markers and mutes the account's other devices set,
    /// as the official apps do each time they come to the front: the server
    /// pushes neither (mixer `READ` and `MUTE` answer nothing). Only once
    /// `cameOnline` has asked on this connection, and not while an ask is
    /// still unanswered (`readsRefreshWait`). A failure is left to the next
    /// connect, which asks again.
    public func refreshReadsAndMutes() async {
        guard transport != nil, cameOnlineHere else { return }
        if let asked = readsAskedAt, ContinuousClock.now - asked < Self.readsRefreshWait { return }
        try? await fetchReadsAndMutes()
    }

    /// How long a refresh waits for an unanswered `getReads` before asking again.
    static let readsRefreshWait: Duration = .seconds(30)

    /// Read markers and mutes live on the server, shared by every device.
    func fetchReadsAndMutes() async throws {
        // With an ask still unanswered, its late answer may predate what
        // was sent since: keep guarding those chats until one is answered.
        if readsAskedAt == nil {
            readsSentSinceGetReads = []
            mutesSetSinceGetMutes = []
        }
        readsAskedAt = .now
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
    /// The mixer's proof on a send's COMPLETE (sphinx `SendOnionRes`); the
    /// records `get_tags` answers with carry none. Kept only when it hashes
    /// to the payment's hash (`Storage.keepPreimage`).
    var preimage: String?
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
    private(set) var last: UInt64

    init(last: UInt64) {
        self.last = last
    }

    mutating func next() -> String {
        let now = UInt64(Date().timeIntervalSince1970 * 1000) + UInt64.random(in: 0..<1000)
        last = max(now, last + 1)
        return String(last)
    }
}
