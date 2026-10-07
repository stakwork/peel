import Foundation
import Security
import Sphinxrs

/// Drives one account against the Sphinx core.
///
/// The core is a library of pure functions: each call takes the seed, a unique
/// time and the whole state, and returns a `RunReturn` describing what the client
/// must now do. `Engine` is that client. It commits the state the core hands back,
/// records what arrived, and performs the subscribes and publishes it asked for.
public actor Engine {
    public enum Event: Sendable {
        /// The server knows this account and has given it a route hint.
        case registered(contactInfo: String?)
        case balance(msat: UInt64)
        case message(Message)
        case sendStatus(tag: String?, status: String)
        case coreError(String)
        case disconnected
    }

    public enum Failure: Error, CustomStringConvertible {
        case notConnected
        case invalidContactInfo
        case registrationTimedOut
        case randomUnavailable

        public var description: String {
            switch self {
            case .notConnected: "not connected to the server"
            case .invalidContactInfo: "contact info must look like pubkey_lsp_scid"
            case .registrationTimedOut: "the server did not confirm registration in time"
            case .randomUnavailable: "the system random number generator failed"
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

    public nonisolated let events: AsyncStream<Event>
    private let emit: AsyncStream<Event>.Continuation

    private let seed: String
    private let network: String
    private let deviceID: String
    private let storage: Storage
    private var alias: String
    private var photoURL: String

    private var state: [String: Data]
    private var snapshot: Data?
    private var clock = UniqueClock()
    private var transport: Transport?
    private var listener: Task<Void, Never>?

    /// Pings that arrived before registration finished.
    private var heldPings: [Inbound] = []
    /// Payments waiting for us, by payment hash and by tag, with the ping time to acknowledge.
    private var pingsByHash: [String: UInt64] = [:]
    private var pingsByTag: [String: UInt64] = [:]

    private static let historyPageSize: UInt32 = 100

    public init(mnemonic: String, storage: Storage, network: String = "bitcoin") throws {
        let words = mnemonic.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        seed = try Sphinxrs.mnemonicToSeed(mnemonic: words)
        self.network = network
        self.storage = storage
        state = try storage.loadCoreState()
        if let stored = try storage.value(for: .deviceID) {
            deviceID = stored
        } else {
            deviceID = UUID().uuidString
            try storage.set(deviceID, for: .deviceID)
        }
        alias = try storage.value(for: .alias) ?? ""
        photoURL = try storage.value(for: .photoURL) ?? ""
        let (stream, continuation) = AsyncStream<Event>.makeStream()
        events = stream
        emit = continuation
    }

    /// What an invite code carries: where to connect and who sent it.
    public struct Invite: Sendable {
        public let code: String
        public let server: String?
        public let inviterContactInfo: String?
        public let inviterAlias: String?
        public let initialTribe: String?
    }

    public static func parseInvite(_ text: String) throws -> Invite {
        let parsed = try Sphinxrs.parseInvite(inviteQr: text.trimmingCharacters(in: .whitespacesAndNewlines))
        return Invite(
            code: parsed.code,
            server: parsed.lspHost,
            inviterContactInfo: parsed.inviterContactInfo,
            inviterAlias: parsed.inviterAlias,
            initialTribe: parsed.initialTribe
        )
    }

    public static func generateMnemonic() throws -> String {
        var entropy = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, entropy.count, &entropy) == errSecSuccess else {
            throw Failure.randomUnavailable
        }
        return try Sphinxrs.mnemonicFromEntropy(entropy: entropy.map { String(format: "%02x", $0) }.joined())
    }

    // MARK: - Account

    public var isRegistered: Bool {
        state["my_scid"] != nil && state["server_pubkey"] != nil
    }

    public func setAlias(_ alias: String) throws {
        try storage.set(alias, for: .alias)
        self.alias = alias
    }

    public func contacts() throws -> [Contact] {
        let json = try Sphinxrs.listContacts(state: stateSnapshot())
        return try JSONDecoder().decode([Contact].self, from: Data(json.utf8))
    }

    /// Gives every contact the core knows a row in storage, so it has a
    /// conversation even before any message or name has arrived.
    private func syncContacts() throws {
        for contact in try contacts() {
            try storage.upsertContact(pubkey: contact.pubkey, alias: nil, photoURL: nil)
        }
    }

    // MARK: - Connection

    /// Connects and announces this device. Pass the invite code only when
    /// creating the account.
    public func connect(
        to server: ServerAddress,
        inviteCode: String? = nil,
        allowUntrustedCertificate: Bool = false
    ) async throws {
        await disconnect()
        try await run { _, _ in try Sphinxrs.setNetwork(network: network) }
        try syncContacts()

        let xpub = try Sphinxrs.xpubFromSeed(seed: seed, time: clock.next(), network: network)
        let loginTime = clock.next()
        let signature = try Sphinxrs.rootSignMs(seed: seed, time: loginTime, network: network)
        let transport = Transport(
            server: server,
            clientID: xpub,
            username: loginTime,
            password: signature,
            allowUntrustedCertificate: allowUntrustedCertificate
        )
        let inbound = transport.inbound()
        do {
            try await transport.connect()
        } catch {
            await transport.close()
            throw error
        }
        self.transport = transport
        listener = Task { [weak self] in
            for await message in inbound {
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
            seed: seed, uniqueTime: clock.next(), state: stateSnapshot()
        )
        try await transport.subscribe([tribeTopic])

        // A returning account is already registered; a new one comes online when
        // the server's registration reply lands (see `complete`).
        if isRegistered {
            await cameOnline()
        }
    }

    public func disconnect() async {
        listener?.cancel()
        listener = nil
        if let transport {
            self.transport = nil
            await transport.close()
        }
    }

    /// Waits for the server to register a new account.
    public func waitUntilRegistered(timeout: Duration = .seconds(30)) async throws {
        let deadline = ContinuousClock.now + timeout
        while !isRegistered {
            guard ContinuousClock.now < deadline else { throw Failure.registrationTimedOut }
            try await Task.sleep(for: .milliseconds(200))
        }
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
        try storage.upsertContact(pubkey: parts[0], alias: theirAlias, photoURL: nil)
    }

    /// Sends a text message to a contact. Returns the tag the server will confirm.
    @discardableResult
    public func sendText(_ text: String, to pubkey: String) async throws -> String? {
        let body = String(decoding: try JSONEncoder().encode(["content": text]), as: UTF8.self)
        let result = try await run { time, state in
            try Sphinxrs.send(
                seed: seed, uniqueTime: time, to: pubkey, msgType: UInt8(MessageType.text), msgJson: body,
                state: state, myAlias: alias, myImg: photoURL, amtMsat: 0, isTribe: false
            )
        } afterCommit: { result in
            // The core only returns a tag and uuid for what was sent, so the local
            // row is written here, before the server's confirmation can arrive.
            let sent = result.msgs.first
            if let message = try storage.recordOutgoing(
                uuid: sent?.uuid, tag: sent?.tag, type: MessageType.text, chat: pubkey, body: body, content: text
            ) {
                emit.yield(.message(message))
            }
        }
        return result.msgs.first?.tag
    }

    /// Asks the server for messages newer than the newest one stored locally.
    public func syncMessages() async throws {
        let next = try storage.highestServerIndex().map { UInt64($0) + 1 } ?? 0
        try await fetchHistory(from: next)
    }

    // MARK: - The core contract

    /// Runs one core call against the current state. The returned state is
    /// committed before this function first suspends, so no other call can ever
    /// run against stale state.
    @discardableResult
    private func run(
        _ call: (_ time: String, _ state: Data) throws -> RunReturn,
        afterCommit: (RunReturn) throws -> Void = { _ in }
    ) async throws -> RunReturn {
        let result = try call(clock.next(), stateSnapshot())
        let followUps = try commit(result)
        try afterCommit(result)
        try await complete(result, followUps)
        return result
    }

    private struct FollowUps {
        var acknowledgedPings: [UInt64] = []
        var justRegistered = false
    }

    private func stateSnapshot() -> Data {
        if let snapshot { return snapshot }
        let encoded = StateCodec.encode(state)
        snapshot = encoded
        return encoded
    }

    /// The synchronous half: persist state, then record everything the core reported.
    private func commit(_ result: RunReturn) throws -> FollowUps {
        var followUps = FollowUps()
        let wasRegistered = isRegistered

        let updates = try result.stateMp.map(StateCodec.decode) ?? [:]
        if !updates.isEmpty || !result.stateToDelete.isEmpty {
            try storage.commitCoreState(set: updates, delete: result.stateToDelete)
            state.merge(updates) { _, new in new }
            for key in result.stateToDelete {
                state[key] = nil
            }
            snapshot = nil
        }
        followUps.justRegistered = !wasRegistered && isRegistered

        if let balance = result.newBalance {
            try storage.set(String(balance), for: .balanceMsat)
            emit.yield(.balance(msat: balance))
        }
        if let info = result.myContactInfo {
            try storage.set(info, for: .contactInfo)
        }
        if let ping = result.ping {
            notePing(ping)
        }
        for msg in result.msgs {
            if let hash = msg.paymentHash, let time = pingsByHash.removeValue(forKey: hash) {
                followUps.acknowledgedPings.append(time)
            }
            if let message = try storage.record(msg) {
                emit.yield(.message(message))
            }
        }
        if let json = result.sentStatus,
           let sent = try? JSONDecoder().decode(SentStatus.self, from: Data(json.utf8)) {
            if let tag = sent.tag {
                try storage.setStatus(sent.status, forTag: tag)
            }
            emit.yield(.sendStatus(tag: sent.tag, status: sent.status))
        }
        if let error = result.error {
            // A ping whose payment no longer exists must still be acknowledged.
            if let tag = error.components(separatedBy: "async pay not found: ").last, tag.count == 64,
               let time = pingsByTag.removeValue(forKey: tag) {
                followUps.acknowledgedPings.append(time)
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
    }

    private func receive(_ inbound: Inbound) async {
        let topic = inbound.topic.split(separator: "/", omittingEmptySubsequences: false)
        let kind = topic.count > 5 ? String(topic[5]) : inbound.topic

        // Answering a ping tells a payer we are reachable, which needs our own
        // route hint, so pings wait until registration has completed.
        if kind == "ping", !isRegistered {
            heldPings.append(inbound)
            return
        }
        do {
            let result = try await run { time, state in
                try Sphinxrs.handle(
                    topic: inbound.topic, payload: inbound.payload, seed: seed, uniqueTime: time,
                    state: state, myAlias: alias, myImg: photoURL
                )
            }
            // History arrives a page at a time; keep going until a short page.
            if kind == "batch", result.msgs.count >= Int(Self.historyPageSize),
               let last = result.msgs.compactMap({ $0.index.flatMap { UInt64($0) } }).max() {
                try await fetchHistory(from: last + 1)
            }
        } catch {
            emit.yield(.coreError("\(kind): \(error)"))
        }
    }

    /// Runs once per connection, as soon as the account is registered.
    private func cameOnline() async {
        emit.yield(.registered(contactInfo: try? storage.value(for: .contactInfo)))
        let held = heldPings
        heldPings = []
        for ping in held {
            await receive(ping)
        }
        do {
            try await run { time, state in
                try Sphinxrs.fetchPings(seed: seed, uniqueTime: time, state: state)
            }
            try await syncMessages()
        } catch {
            emit.yield(.coreError("coming online: \(error)"))
        }
    }

    private func fetchHistory(from index: UInt64) async throws {
        try await run { time, state in
            try Sphinxrs.fetchMsgsBatch(
                seed: seed, uniqueTime: time, state: state,
                lastMsgIdx: index, limit: Self.historyPageSize, reverse: false
            )
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

    private func connectionClosed(_ closed: Transport) async {
        guard transport === closed else { return }
        transport = nil
        await closed.close()
        emit.yield(.disconnected)
    }
}

private struct SentStatus: Decodable {
    let tag: String?
    let status: String
}

/// Every core call needs a time that is never reused. Milliseconds plus a little
/// jitter, as the official apps send, forced to be strictly increasing.
private struct UniqueClock {
    private var last: UInt64 = 0

    mutating func next() -> String {
        let now = UInt64(Date().timeIntervalSince1970 * 1000) + UInt64.random(in: 0..<1000)
        last = max(now, last + 1)
        return String(last)
    }
}
