import Foundation
import Sphinxrs

/// Drives one account against the Sphinx core.
///
/// The core is a library of pure functions: each call takes the seed, a unique
/// time and the whole state, and returns a `RunReturn` describing what the client
/// must now do. `Engine` is that client. It commits the state the core hands back,
/// records what arrived, and performs the subscribes and publishes it asked for.
public actor Engine {
    public enum Event: Sendable {
        case connection(ConnectionState)
        /// The server knows this account and has given it a route hint.
        case registered(contactInfo: String?)
        case balance(msat: UInt64)
        case message(Message)
        case sendStatus(tag: String?, status: String)
        /// A restore or catch-up fetched history up to `reached` of `end`.
        case history(phase: HistoryPhase, reached: UInt64, end: UInt64?)
        case coreError(String)
    }

    public enum HistoryPhase: Sendable {
        /// The first message per contact key, from which the core rebuilds contacts.
        case contacts
        case messages
    }

    /// What the server holds for this account, as `getMsgsCounts` reports it.
    public struct MessageCounts: Decodable, Sendable {
        public let total: UInt64
        public let firstForEachKey: UInt64
        public let totalHighestIndex: UInt64
        public let firstForEachKeyHighestIndex: UInt64

        enum CodingKeys: String, CodingKey {
            case total
            case firstForEachKey = "first_for_each_scid"
            case totalHighestIndex = "total_highest_index"
            case firstForEachKeyHighestIndex = "first_for_each_scid_highest_index"
        }
    }

    public enum ConnectionState: Sendable, Equatable {
        case offline(retryIn: Int?)
        case connecting
        case connected

        public var label: String {
            switch self {
            case .offline(let seconds?): "Offline, retrying in \(seconds)s"
            case .offline(nil): "Offline"
            case .connecting: "Connecting"
            case .connected: "Connected"
            }
        }
    }

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case noServer
        case notConnected
        case invalidContactInfo
        case registrationTimedOut
        case restoreTimedOut

        public var description: String {
            switch self {
            case .noServer: "this account has no server recorded"
            case .notConnected: "not connected to the server"
            case .invalidContactInfo: "contact info must look like pubkey_lsp_scid"
            case .registrationTimedOut: "the server did not confirm registration in time"
            case .restoreTimedOut: "the server stopped answering during the restore"
            }
        }
    }

    /// A contact as the core knows it. Names and photos are not part of core state.
    public struct Contact: Decodable, Sendable {
        public let pubkey: String
        /// Present once the key exchange with this contact has completed.
        public let contactKey: String?

        enum CodingKeys: String, CodingKey {
            case pubkey
            case contactKey = "contact_key"
        }
    }

    /// What an invite code carries: where to connect and who sent it.
    public struct Invite: Sendable {
        public let code: String
        public let server: String?
        public let inviterContactInfo: String?
        public let inviterAlias: String?
    }

    public nonisolated let events: AsyncStream<Event>
    public nonisolated let storage: Storage
    private let emit: AsyncStream<Event>.Continuation

    private let seed: String
    private let network: String
    private let deviceID: String
    private var alias: String
    private var photoURL: String
    private var server: ServerAddress?
    private var allowUntrustedCertificate = false

    private var state: [String: Data]
    private var clock: UniqueClock
    public private(set) var connection: ConnectionState = .offline(retryIn: nil)
    private var transport: Transport?
    private var listener: Task<Void, Never>?
    private var keepConnected = false
    private var reconnectTask: Task<Void, Never>?

    /// Payments waiting for us while we were offline: payment hash and tag → the
    /// ping time to acknowledge once the payment lands.
    private var pingsByHash: [String: UInt64] = [:]
    private var pingsByTag: [String: UInt64] = [:]
    /// A history fetch in progress: which kind, the next index to ask for, and
    /// where it ends (unknown until the server says).
    private struct HistoryRun {
        var phase: HistoryPhase
        var next: UInt64
        var end: UInt64?
    }
    private var history: HistoryRun?
    private var counts: MessageCounts?

    private static let historyPageSize: UInt32 = 100

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
        _ = try storage.apply(Storage.Commit(contacts: Self.readiness(in: state)))
    }

    // MARK: - Pure helpers

    public static func generateMnemonic() throws -> String {
        let entropy = (0..<16).map { _ in UInt8.random(in: .min ... .max) }
        return try Sphinxrs.mnemonicFromEntropy(entropy: entropy.map { String(format: "%02x", $0) }.joined())
    }

    /// Checks twelve words and returns them in canonical form.
    public static func validate(mnemonic: String) throws -> String {
        let words = normalise(mnemonic: mnemonic)
        _ = try Sphinxrs.mnemonicToSeed(mnemonic: words)
        return words
    }

    private static func normalise(mnemonic: String) -> String {
        mnemonic.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    public static func parseInvite(_ text: String) throws -> Invite {
        let parsed = try Sphinxrs.parseInvite(inviteQr: text.trimmingCharacters(in: .whitespacesAndNewlines))
        return Invite(
            code: parsed.code,
            server: parsed.lspHost,
            inviterContactInfo: parsed.inviterContactInfo,
            inviterAlias: parsed.inviterAlias
        )
    }

    /// The contacts an account holds, without deriving its seed.
    public static func contacts(in storage: Storage) throws -> [Contact] {
        try contacts(in: storage.loadCoreState())
    }

    private static func readiness(in state: [String: Data]) throws -> [(pubkey: String, ready: Bool)] {
        try contacts(in: state).map { ($0.pubkey, $0.contactKey != nil) }
    }

    private static func contacts(in state: [String: Data]) throws -> [Contact] {
        let json = try Sphinxrs.listContacts(state: StateCodec.encode(state))
        return try JSONDecoder().decode([Contact].self, from: Data(json.utf8))
    }

    private static func isRegistered(_ state: [String: Data]) -> Bool {
        state["my_scid"] != nil && state["server_pubkey"] != nil
    }

    // MARK: - Account

    public var isRegistered: Bool { Self.isRegistered(state) }

    public func setAlias(_ alias: String) throws {
        try storage.set(alias, for: .alias)
        self.alias = alias
    }

    public func setServer(_ server: ServerAddress) throws {
        try storage.set(server.description, for: .server)
        self.server = server
    }

    public func contacts() throws -> [Contact] {
        try Self.contacts(in: state)
    }

    // MARK: - Connection

    /// Connects once and returns when the account is online. Pass the invite code
    /// only when creating the account. A dropped connection stays dropped.
    public func connect(inviteCode: String? = nil, allowUntrustedCertificate: Bool = false) async throws {
        keepConnected = false
        reconnectTask?.cancel()
        self.allowUntrustedCertificate = allowUntrustedCertificate
        try await establish(inviteCode: inviteCode)
        try await waitUntilRegistered()
    }

    /// Connects and keeps reconnecting with backoff until `disconnect()`.
    /// Progress is reported through `.connection` events.
    public func start(allowUntrustedCertificate: Bool = false) {
        self.allowUntrustedCertificate = allowUntrustedCertificate
        keepConnected = true
        guard connection != .connected, reconnectTask == nil else { return }
        reconnectTask = Task { [weak self] in await self?.reconnectLoop(attempt: 0) }
    }

    public func disconnect() async {
        keepConnected = false
        reconnectTask?.cancel()
        reconnectTask = nil
        await teardown()
        setConnection(.offline(retryIn: nil))
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
            } catch {
                await transport.close()
                throw error
            }
            self.transport = transport
            listener = Task { [weak self] in
                for await message in transport.inbound {
                    await self?.receive(message)
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

    private func waitUntilRegistered(timeout: Duration = .seconds(30)) async throws {
        let deadline = ContinuousClock.now + timeout
        while !isRegistered {
            guard ContinuousClock.now < deadline else { throw Failure.registrationTimedOut }
            try await Task.sleep(for: .milliseconds(200))
        }
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
                break
            } catch {
                emit.yield(.coreError("connecting: \(error)"))
                attempt += 1
            }
        }
        reconnectTask = nil
    }

    private func connectionClosed(_ closed: Transport) async {
        guard transport === closed else { return }
        transport = nil
        await closed.close()
        setConnection(.offline(retryIn: nil))
        if keepConnected, reconnectTask == nil {
            reconnectTask = Task { [weak self] in await self?.reconnectLoop(attempt: 1) }
        }
    }

    private func teardown() async {
        listener?.cancel()
        listener = nil
        if let transport {
            self.transport = nil
            await transport.close()
        }
    }

    private func setConnection(_ state: ConnectionState) {
        guard connection != state else { return }
        connection = state
        emit.yield(.connection(state))
    }

    // MARK: - Contacts and messages

    /// Starts a key exchange with a contact given as `pubkey_lsp_scid`.
    public func addContact(_ contactInfo: String, alias theirAlias: String? = nil, inviteCode: String? = nil) async throws {
        let parts = contactInfo.split(separator: "_", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, parts[0].count == 66 else { throw Failure.invalidContactInfo }
        try await run { time, state in
            try Sphinxrs.addContact(
                seed: seed, uniqueTime: time, state: state,
                toPubkey: parts[0], routeHint: "\(parts[1])_\(parts[2])",
                myAlias: alias, myImg: photoURL,
                // The official apps attach 5 sats to the first key-exchange message.
                amtMsat: 5000,
                inviteCode: inviteCode, theirAlias: theirAlias
            )
        }
        try storage.upsertContact(pubkey: parts[0], alias: theirAlias)
    }

    /// Sends a text message to a contact. Returns the tag the server will confirm.
    @discardableResult
    public func sendText(_ text: String, to pubkey: String) async throws -> String? {
        let body = String(decoding: try JSONEncoder().encode(["content": text]), as: UTF8.self)
        let time = clock.next()
        let result = try Sphinxrs.send(
            seed: seed, uniqueTime: time, to: pubkey, msgType: UInt8(MessageType.text), msgJson: body,
            state: StateCodec.encode(state), myAlias: alias, myImg: photoURL, amtMsat: 0, isTribe: false
        )
        // The core only returns a tag and uuid for what was sent; the local row
        // is written in the same transaction as the state, before publishing.
        let sent = result.msgs.first
        let outgoing = Message(
            uuid: sent?.uuid, type: MessageType.text, chat: pubkey, fromMe: true, body: body, content: text,
            timestamp: Date().millisecondsSince1970, tag: sent?.tag, status: Message.Delivery.pending.rawValue
        )
        let followUps = try commit(result, time: time, expectedSender: nil, outgoing: outgoing)
        try await complete(result, followUps)
        return sent?.tag
    }

    /// Asks the server for messages newer than the newest one stored locally.
    public func syncMessages() async throws {
        let next = try storage.highestServerIndex().map { $0 + 1 } ?? 0
        try await startHistory(HistoryRun(phase: .messages, next: next, end: nil))
    }

    /// Rebuilds contacts and history on a device that is new to the account:
    /// first one message per contact key, from which the core recreates each
    /// contact, then every message from the beginning. Returns when the server
    /// has nothing more. Call after `connect()`.
    public func restore(timeout: Duration = .seconds(600)) async throws {
        let deadline = ContinuousClock.now + timeout
        // Coming online already started a catch-up; let it finish rather than race it.
        try await waitForHistory(until: deadline)
        counts = nil
        try await run { time, state in
            try Sphinxrs.getMsgsCounts(seed: seed, uniqueTime: time, state: state)
        }
        let countsDeadline = ContinuousClock.now + .seconds(20)
        while counts == nil {
            guard ContinuousClock.now < countsDeadline else { throw Failure.restoreTimedOut }
            try await Task.sleep(for: .milliseconds(200))
        }
        guard let counts else { return }
        if counts.firstForEachKey > 0 {
            try await startHistory(HistoryRun(phase: .contacts, next: 0, end: counts.firstForEachKeyHighestIndex))
        } else if counts.total > 0 {
            try await syncMessages()
        }
        try await waitForHistory(until: deadline)
    }

    private func waitForHistory(until deadline: ContinuousClock.Instant) async throws {
        while history != nil {
            guard ContinuousClock.now < deadline else { throw Failure.restoreTimedOut }
            try await Task.sleep(for: .milliseconds(250))
        }
    }

    // MARK: - The core contract

    /// Runs one core call against the current state. The returned state is
    /// committed before this function first suspends, so no other call can ever
    /// run against stale state.
    @discardableResult
    private func run(
        expectedSender: String? = nil,
        _ call: (_ time: String, _ state: Data) throws -> RunReturn
    ) async throws -> RunReturn {
        let time = clock.next()
        let result = try call(time, StateCodec.encode(state))
        let followUps = try commit(result, time: time, expectedSender: expectedSender, outgoing: nil)
        try await complete(result, followUps)
        return result
    }

    private struct FollowUps {
        var acknowledgedPings: [UInt64] = []
        var justRegistered = false
    }

    /// The synchronous half: one transaction with everything the core reported,
    /// then the in-memory bookkeeping and events.
    private func commit(_ result: RunReturn, time: String, expectedSender: String?, outgoing: Message?) throws -> FollowUps {
        var followUps = FollowUps()
        var commit = Storage.Commit()
        commit.settings[.clock] = time

        let updates = try result.stateMp.map(StateCodec.decode) ?? [:]
        var newState = state
        newState.merge(updates) { _, new in new }
        for key in result.stateToDelete {
            newState[key] = nil
        }
        commit.state = updates
        commit.deleteState = result.stateToDelete
        followUps.justRegistered = !isRegistered && Self.isRegistered(newState)
        let syncedContacts = Set(updates.keys.compactMap { $0.hasPrefix("c/") ? String($0.dropFirst(2)) : nil })
        if !syncedContacts.isEmpty || result.stateToDelete.contains(where: { $0.hasPrefix("c/") }) {
            commit.contacts = try Self.readiness(in: newState)
        }

        if let balance = result.newBalance {
            commit.settings[.balanceMsat] = String(balance)
        }
        if let info = result.myContactInfo {
            commit.settings[.contactInfo] = info
        }
        if let outgoing {
            commit.messages.append((outgoing, trustSender: false))
        }
        var landedPings: [String] = []
        for msg in result.msgs {
            if let hash = msg.paymentHash, let pingTime = pingsByHash[hash] {
                followUps.acknowledgedPings.append(pingTime)
                landedPings.append(hash)
            }
            if let message = Self.message(
                from: msg, expectedSender: expectedSender, state: newState, syncedContacts: syncedContacts
            ) {
                commit.messages.append(message)
            }
        }
        let sent = result.sentStatus.flatMap { try? JSONDecoder().decode(SentStatus.self, from: Data($0.utf8)) }
        if let sent, let tag = sent.tag {
            commit.statuses.append((tag, sent.status))
        }

        let stored = try storage.apply(commit)
        state = newState

        if let json = result.msgsCounts {
            counts = try? JSONDecoder().decode(MessageCounts.self, from: Data(json.utf8))
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
        for message in stored {
            emit.yield(.message(message))
        }
        if let sent {
            emit.yield(.sendStatus(tag: sent.tag, status: sent.status))
        }
        if let error = result.error {
            // The core reports a failed "online" reply only in this text, with
            // the ping's tag at the end; the payment it was for no longer exists.
            if let tag = error.components(separatedBy: "async pay not found: ").last, tag.count == 64,
               let pingTime = pingsByTag.removeValue(forKey: tag) {
                followUps.acknowledgedPings.append(pingTime)
            }
            emit.yield(.coreError(error))
        }
        return followUps
    }

    /// The asynchronous half: the network work the core asked for, in its order.
    private func complete(_ result: RunReturn, _ followUps: FollowUps) async throws {
        var publishes: [(topic: String, payload: Data)] = []
        if let topic = result.settleTopic, let payload = result.settlePayload {
            publishes.append((topic, payload))
        }
        if let topic = result.registerTopic, let payload = result.registerPayload {
            publishes.append((topic, payload))
        }
        if let topic = result.asyncpayTopic, let payload = result.asyncpayPayload {
            publishes.append((topic, payload))
        }
        for (index, topic) in result.topics.enumerated() {
            publishes.append((topic, index < result.payloads.count ? result.payloads[index] : Data()))
        }

        if !result.subscriptionTopics.isEmpty || !publishes.isEmpty {
            guard let transport else { throw Failure.notConnected }
            if !result.subscriptionTopics.isEmpty {
                try await transport.subscribe(result.subscriptionTopics)
            }
            for publish in publishes {
                try await transport.publish(publish.topic, publish.payload)
            }
        }

        for pingTime in followUps.acknowledgedPings {
            try await run { time, state in
                try Sphinxrs.pingDone(seed: seed, uniqueTime: time, state: state, pingTs: pingTime)
            }
        }
        if followUps.justRegistered {
            await cameOnline()
        }
        // Only batch responses carry a total.
        if result.msgsTotal != nil {
            try await advanceHistory(with: result)
        }
    }

    /// Turns what the core reported into a row, deciding which conversation it
    /// belongs to. The sender inside a message is self-declared; for a live
    /// message the engine knows which contact's key decrypted it and uses that.
    /// Messages from history name only known contacts, and never rename them.
    private static func message(
        from msg: Msg, expectedSender: String?, state: [String: Data], syncedContacts: Set<String>
    ) -> (Message, Bool)? {
        guard let type = msg.type else { return nil }
        let fromMe = msg.fromMe ?? false
        let claimed = msg.sender.flatMap { try? JSONDecoder().decode(SenderInfo.self, from: Data($0.utf8)) }?.pubkey
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
            // A contact record the core just applied was signed by this account's
            // own key on another device, so what it says about the contact holds.
            trustSender = Int(type) == MessageType.contactKeyRecord && syncedContacts.contains(claimed)
        }
        let message = Message(
            uuid: msg.uuid,
            serverIndex: msg.index.flatMap { UInt64($0) }.map { Int64(clamping: $0) },
            type: Int(type), chat: chat, fromMe: fromMe,
            sender: msg.sender, body: msg.message, content: BodyFields.content(of: msg.message),
            msat: msg.msat.map { Int64(clamping: $0) },
            timestamp: msg.timestamp.map { Int64(clamping: $0) },
            tag: msg.tag, paymentHash: msg.paymentHash
        )
        return (message, trustSender)
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
            expectedSender = try? Sphinxrs.contactPubkeyByChildIndex(state: StateCodec.encode(state), childIdx: index)
        }
        do {
            try await run(expectedSender: expectedSender) { time, state in
                try Sphinxrs.handle(
                    topic: inbound.topic, payload: inbound.payload, seed: seed, uniqueTime: time,
                    state: state, myAlias: alias, myImg: photoURL
                )
            }
        } catch {
            emit.yield(.coreError("\(kind): \(error)"))
        }
    }

    /// Runs once per connection, as soon as the account is registered.
    private func cameOnline() async {
        emit.yield(.registered(contactInfo: try? storage.value(for: .contactInfo)))
        do {
            try await run { time, state in
                try Sphinxrs.fetchPings(seed: seed, uniqueTime: time, state: state)
            }
            try await syncMessages()
        } catch {
            emit.yield(.coreError("coming online: \(error)"))
        }
    }

    private func startHistory(_ run: HistoryRun) async throws {
        history = run
        try await request(run)
    }

    private func request(_ run: HistoryRun) async throws {
        try await self.run { time, state in
            switch run.phase {
            case .contacts:
                try Sphinxrs.fetchFirstMsgsPerKey(
                    seed: seed, uniqueTime: time, state: state,
                    lastMsgIdx: run.next, limit: Self.historyPageSize, reverse: false
                )
            case .messages:
                try Sphinxrs.fetchMsgsBatch(
                    seed: seed, uniqueTime: time, state: state,
                    lastMsgIdx: run.next, limit: Self.historyPageSize, reverse: false
                )
            }
        }
    }

    /// History comes a page at a time. Each page moves the cursor past its
    /// highest index; a page that moves it nowhere ends the run, so an
    /// unreadable message cannot cause an endless loop.
    private func advanceHistory(with result: RunReturn) async throws {
        guard var run = history else { return }
        if run.end == nil, let total = result.msgsTotal {
            run.end = total
        }
        let reached = result.msgs.compactMap { $0.index.flatMap { UInt64($0) } }.max()
        guard let reached, reached >= run.next else {
            try await finish(run)
            return
        }
        run.next = reached + 1
        emit.yield(.history(phase: run.phase, reached: reached, end: run.end))
        if let end = run.end, run.next > end {
            try await finish(run)
            return
        }
        history = run
        try await request(run)
    }

    private func finish(_ run: HistoryRun) async throws {
        history = nil
        // Contacts first, then whatever messages are still missing.
        if run.phase == .contacts, let counts, counts.total > 0 {
            try await syncMessages()
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

private struct SentStatus: Decodable {
    let tag: String?
    let status: String
}

/// Every core call needs a time that is never reused, even across restarts.
/// Milliseconds plus a little jitter, as the official apps send, forced to be
/// strictly increasing and persisted with each commit.
private struct UniqueClock {
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
