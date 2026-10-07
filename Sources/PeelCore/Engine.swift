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
        case message(Message, Arrival)
        case sendStatus(tag: String?, status: String)
        /// A restore or catch-up fetched history up to `reached` of `end`.
        case history(phase: HistoryPhase, reached: UInt64, end: UInt64?)
        /// The server has nothing more; after a restore, the account is complete.
        case historyDone
        case historyFailed(String)
        /// An error that belongs to one conversation, such as a send the server refused.
        case conversationError(chat: String, message: String)
        /// Why the last attempt to connect failed.
        case connectionError(String)
        /// An error that belongs to no conversation in particular.
        case coreError(String)
        /// The name or photo this account sends changed (by the user, or
        /// filled in by a restore).
        case profile(alias: String, photoURL: String?)
        /// An attachment going up to or coming down from the memes server:
        /// bytes so far of the total, at most every 5% or 250 ms, and at the end.
        case transfer(messageID: Int64, direction: Direction, bytes: Int64, total: Int64)

        public enum Direction: Sendable {
            case upload, download
        }
    }

    /// How a message reached this device: as it was sent, in a history
    /// page (catching up after being offline), or in a restore.
    public enum Arrival: Sendable {
        case live, history, restore
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
        case notRetryable
        case invalidTribeLink
        case tribeDeleted
        case notInTribe
        case noTribeServer
        case tribeServerTimedOut
        case awaitingApproval
        case notTribeOwner
        case noSuchMessage
        case notDelivered
        case notInThread
        case notAChat
        case noMemesServer
        case notAnAttachment
        case attachmentWithoutKey
        case untrustedMediaHost(String)
        case uploadInProgress

        public var description: String {
            switch self {
            case .notRetryable: "only an undelivered message of ours can be sent again or discarded"
            case .noServer: "this account has no server recorded"
            case .notConnected: "not connected to the server"
            case .invalidContactInfo: "contact info must look like pubkey_lsp_scid"
            case .registrationTimedOut: "the server did not confirm registration in time"
            case .invalidTribeLink: "that is not a tribe link"
            case .tribeDeleted: "this tribe has been deleted"
            case .notInTribe: "this account is not in that tribe"
            case .noTribeServer: "the server has not named a tribes server for this account"
            case .tribeServerTimedOut: "the tribes server did not answer in time"
            case .awaitingApproval: "the tribe's owner has not approved this account yet"
            case .notTribeOwner: "only the tribe's owner can do that"
            case .noSuchMessage: "there is no such message in this chat"
            case .notDelivered: "that message has not been delivered yet; reply once it has"
            case .notInThread: "that message is not in that thread"
            case .notAChat: "that is neither a contact nor a tribe this account is in"
            case .noMemesServer: "this account has no memes server for attachments (set one with --memes-host)"
            case .notAnAttachment: "that message is not an attachment"
            case .attachmentWithoutKey: "this attachment came without its key (paid attachments are not supported)"
            case .untrustedMediaHost(let host): "the attachment is on \(host), not this account's memes server"
            case .uploadInProgress: "this attachment is still uploading"
            }
        }
    }

    /// A contact as the core knows it. Names and photos are not part of core state.
    public struct Contact: Decodable, Sendable {
        public let pubkey: String
        /// Present once the key exchange with this contact has completed.
        public let contactKey: String?
        /// The child key this account uses for the contact; it names them in topics.
        public let childIndex: UInt64

        enum CodingKeys: String, CodingKey {
            case pubkey
            case contactKey = "contact_key"
            case childIndex = "my_idx"
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
    /// Contacts by the child index the core uses for them, so a live message's
    /// topic names its sender without a core call.
    private var contactsByChildIndex: [UInt64: String] = [:]
    /// Every tribe this account knows, joined or left, by pubkey.
    private var tribes: [String: Tribe] = [:]
    /// Member lists the tribes server sent for tribes this account owns.
    private var memberLists: [String: TribeMembers.List] = [:]
    /// Join requests answered this session; see `answerJoinRequest`.
    private var sentAnswers: Set<String> = []
    /// Tribes whose update the tribes server has confirmed, until `updateRegistry` takes it.
    private var updatedTribes: Set<String> = []
    /// Tribes with an update or delete on its way; see `changeOwnedTribe`.
    private var changingTribes: Set<String> = []
    /// The highest server index of a message dropped unstored; see `Setting.droppedIndex`.
    private var droppedIndex: Int64
    /// A restore from the words is replaying history; see `Setting.needsRestore`.
    private var restoring: Bool
    /// Whether `recoverOwnPhoto` has run for this engine.
    private var photoRecoveryDone = false
    private var refreshingTribes = false
    private var tribesNeedRefresh = false

    /// Attachments: the decrypted cache and the uploads waiting to go, and
    /// the memes server's bearer token (memory only).
    private let media: MediaStore
    private var memesToken: (host: String, token: MemesServer.Token)?
    /// Largest attachment sent or downloaded, and the most the cache keeps.
    static let attachmentLimit = 100_000_000
    static let mediaCacheLimit = 500_000_000
    /// Where the official apps keep attachments.
    static let defaultMemesHost = "memes.sphinx.chat"

    /// A history fetch in progress: which kind, the next index to ask for, and
    /// where it ends (unknown until the server says). Runs queue behind one
    /// another; a restore is contacts first, then every message from the start.
    private struct HistoryRun {
        var phase: HistoryPhase
        var next: UInt64
        var end: UInt64?
    }
    private var history: HistoryRun?
    private var queuedHistory: [HistoryRun] = []
    private var awaitingCounts = false
    private var historyWatchdog: Task<Void, Never>?
    private static let historyStall: Duration = .seconds(30)

    private static let historyPageSize: UInt32 = 100
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
        media = MediaStore(profile: storage.directory)
        // The profile lock means no other process is uploading; anything
        // still uploading was cut off, and can be retried.
        try storage.failInterruptedUploads()
        _ = try storage.apply(Storage.Commit(contacts: contacts.map { ($0.pubkey, $0.contactKey != nil) }))
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

    /// The words in whatever someone typed or pasted: any case, separated by
    /// whitespace or commas.
    public static func words(in text: String) -> [String] {
        text.lowercased().split(whereSeparator: { $0.isWhitespace || $0 == "," }).map(String.init)
    }

    private static func normalise(mnemonic: String) -> String {
        words(in: mnemonic).joined(separator: " ")
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

    private static func index(_ contacts: [Contact]) -> [UInt64: String] {
        Dictionary(contacts.map { ($0.childIndex, $0.pubkey) }, uniquingKeysWith: { $1 })
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

    /// The name and photo this account sends with its messages.
    public var myAlias: String { alias }
    public var myPhotoURL: String? { photoURL.httpsOnly }

    /// The name others see. Names are not core state and the server keeps no
    /// profile: it travels with each message sent from now on (and with a
    /// tribe join), and a contact's app takes the newest one it sees, as with
    /// the official apps. Nothing is announced and sent messages keep the old one.
    public func setAlias(_ alias: String) throws {
        let alias = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !alias.isEmpty else { throw PeelError("the name cannot be empty") }
        try storage.set(alias, for: .alias)
        self.alias = alias
        emit.yield(.profile(alias: alias, photoURL: myPhotoURL))
    }

    /// The photo others see beside this account's messages: an https URL, or
    /// empty for none. It travels like the name. `uploadPhoto` puts a picture
    /// from this Mac on the memes server and passes its link here.
    public func setPhotoURL(_ url: String) throws {
        let url = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard url.isEmpty || url.httpsOnly != nil else { throw PeelError("a photo must be an https URL") }
        try storage.set(url, for: .photoURL)
        photoURL = url
        emit.yield(.profile(alias: alias, photoURL: myPhotoURL))
    }

    /// Makes a picture this account's photo, as the Mac app's profile screen
    /// does: a JPEG at quality 0.5 (here also at most 1024 px on its long
    /// side) uploaded in the clear to the memes server's `/public` route,
    /// whose public link becomes the photo URL. Returns the link.
    @discardableResult
    public func uploadPhoto(_ file: URL) async throws -> String {
        let memes = try memesServer()
        let limit = Self.attachmentLimit
        let jpeg = try await Task.detached { try ProfilePhoto.jpeg(from: file, limit: limit) }.value
        let muid = try await withMemes(memes) { token in
            try await memes.upload(
                jpeg, as: OutgoingFile(fileName: "image.jpg", mediaType: "image/jpg"), token: token, route: "public"
            )
        }
        let url = memes.publicURL(muid).absoluteString
        try setPhotoURL(url)
        return url
    }

    /// Hours after which an app asks for the PIN again; 0 means only at
    /// launch, nil that this account has never set it.
    public func pinTimeoutHours() throws -> Int? {
        try storage.value(for: .pinTimeoutHours).flatMap { Int($0) }
    }

    public func setPINTimeout(hours: Int) throws {
        try storage.set(String(max(0, hours)), for: .pinTimeoutHours)
    }

    /// Whether an app's notifications may show what a message says; on
    /// unless turned off.
    public func notificationShowsText() throws -> Bool {
        try storage.value(for: .notificationText) != "0"
    }

    public func setNotificationShowsText(_ shows: Bool) throws {
        try storage.set(shows ? "1" : "0", for: .notificationText)
    }

    public func setServer(_ server: ServerAddress) throws {
        try storage.set(server.description, for: .server)
        self.server = server
    }

    /// The tribes server this account's own tribes are listed on, as `host[:port]`.
    public func setTribeHost(_ host: String) throws {
        guard TribeLink.isPlainHost(host) else { throw PeelError("unreadable tribes host \(host)") }
        try storage.set(host, for: .tribeHost)
    }

    /// The memes server attachments go to and come from, as `host[:port]`.
    public func setMemesHost(_ host: String) throws {
        _ = try MemesServer(host: host)
        try storage.set(host, for: .memesHost)
    }

    public func contacts() throws -> [Contact] {
        try Self.contacts(in: state)
    }

    /// True while a restore or catch-up is still asking the server for history.
    public var isSyncingHistory: Bool {
        awaitingCounts || history != nil || !queuedHistory.isEmpty
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
        if !restoring { recoverOwnPhoto() }
        self.allowUntrustedCertificate = allowUntrustedCertificate
        keepConnected = true
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

    private func waitUntilRegistered() async throws {
        try await poll(timeout: .seconds(30), failure: .registrationTimedOut) { isRegistered ? () : nil }
    }

    /// Waits for something a server reply sets to land in the engine.
    private func poll<T>(timeout: Duration, failure: Failure, _ check: () async -> T?) async throws -> T {
        let deadline = ContinuousClock.now + timeout
        while true {
            if let value = await check() { return value }
            guard ContinuousClock.now < deadline else { throw failure }
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
                emit.yield(.connectionError("\(error)"))
                attempt += 1
            }
        }
        // A cancelled loop has already been replaced or stopped.
        if !Task.isCancelled { reconnectTask = nil }
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

    /// Sends a text message to a contact or a tribe, optionally as a reply to
    /// one of its messages or into a thread (both by uuid), with the links
    /// set as the Mac app sets them: a reply joins its parent's thread, or
    /// starts one at the parent; `inThread` may name any message of the
    /// thread, and a reply given with it must be in that thread. Returns the
    /// tag the server will confirm.
    @discardableResult
    public func sendText(
        _ text: String, to pubkey: String, replyTo: String? = nil, inThread: String? = nil
    ) async throws -> String? {
        let links = try links(replyTo: replyTo, inThread: inThread, in: pubkey)
        var fields = ["content": text]
        fields["replyUuid"] = links.replyTo
        fields["threadUuid"] = links.thread
        return try await deliver(body: try Self.json(fields), to: pubkey, replacing: nil)
    }

    /// `replyUuid` and `threadUuid` for a message to `chat`, as the Mac app
    /// sets them: a reply joins its parent's thread (`Message.threadRoot`),
    /// or starts one at the parent; `inThread` may name any message of the
    /// thread, or the thread itself when only its messages are stored (the
    /// original older than this Mac's history), and a reply given with it
    /// must be in that thread.
    private func links(
        replyTo: String?, inThread: String?, in chat: String
    ) throws -> (replyTo: String?, thread: String?) {
        var thread = try inThread.map { uuid in
            guard MessageUUID.isValid(uuid) else { throw Failure.noSuchMessage }
            if let named = try storage.message(uuid: uuid, in: chat) {
                // A deleted original still names its thread, which goes on.
                return named.deleted ? named.threadRoot : try linkable(uuid, in: chat).threadRoot
            }
            guard try storage.threadCount(uuid, in: chat) > 0 else { throw Failure.noSuchMessage }
            return uuid
        }
        if let replyTo {
            let parentThread = try linkable(replyTo, in: chat).threadRoot
            if let thread, parentThread != thread { throw Failure.notInThread }
            thread = parentThread
        }
        return (replyTo, thread)
    }

    /// A stored text message or attachment of `chat` that others hold under
    /// the same uuid (`Message.isLinkable`).
    private func linkable(_ uuid: String, in chat: String) throws -> Message {
        guard MessageUUID.isValid(uuid), let message = try storage.message(uuid: uuid, in: chat),
              MessageType.content.contains(message.type) else {
            throw Failure.noSuchMessage
        }
        guard message.isLinkable(inTribe: tribes[chat] != nil) else { throw Failure.notDelivered }
        return message
    }

    /// Deletes a message for everyone, as the official apps do: a type 17
    /// message naming it in `replyUuid`. Our own messages, and in a tribe this
    /// account owns, anyone's (the tribes server refuses the rest). As in the
    /// Mac app, a thread's original cannot be deleted while it has two or
    /// more replies (`Message.isDeletable`). The row is emptied once the
    /// server has the delete; one that fails to send can be sent again. A
    /// tribe delete pays the tribe's price like any message.
    public func deleteMessage(id: Int64) async throws {
        guard let message = try storage.message(id: id), MessageType.content.contains(message.type),
              !message.deleted, let uuid = message.uuid else { throw Failure.noSuchMessage }
        let tribe = try openTribe(message.chat)
        guard message.isDeletable(
            inTribe: tribe != nil, ownsTribe: tribe?.canManage == true,
            threadCount: try storage.threadCount(uuid, in: message.chat)
        ) else {
            throw PeelError(
                "only your own sent messages, or any in a tribe you own, can be deleted; "
                    + "not a thread's first message while it has replies"
            )
        }
        _ = try await deliver(
            body: try Self.json(["content": "", "replyUuid": uuid]), to: message.chat, replacing: nil,
            type: MessageType.delete
        )
    }

    /// Sends an undelivered message again. The core gives every send a new uuid
    /// and tag, so the same row takes them over and moves to now; the server's
    /// echo then matches that row rather than adding a second one. A tribe
    /// message pays the tribe's current price, as a first send would, but
    /// never more than the price it was first sent at: a raise since then
    /// shows in the tribe's header, and the message must be sent anew.
    @discardableResult
    public func resend(messageID: Int64) async throws -> String? {
        guard let message = try storage.message(id: messageID), message.isRetryable(), let body = message.body else {
            throw Failure.notRetryable
        }
        if let tribe = try openTribe(message.chat), let paid = message.msat,
           tribe.messageAmountMsat > UInt64(max(paid, 0)) {
            throw PeelError("this tribe now charges more per message; send it as a new message")
        }
        if message.type == MessageType.attachment {
            return try await uploadAndDeliver(message)
        }
        return try await deliver(body: body, to: message.chat, replacing: messageID)
    }

    /// Drops an undelivered message of ours from this Mac. It never reached the
    /// server, so there is nothing to delete anywhere else.
    public func discard(messageID: Int64) throws {
        guard let message = try storage.message(id: messageID), message.isRetryable() else {
            throw Failure.notRetryable
        }
        try storage.deleteMessage(id: messageID)
        try? FileManager.default.removeItem(at: media.outgoing(messageID))
    }

    /// The tribe a message to `pubkey` goes to, if it is one. Only a tribe
    /// this account is in and accepted by takes messages.
    private func openTribe(_ pubkey: String) throws -> Tribe? {
        guard let tribe = tribes[pubkey] else { return nil }
        if tribe.status == .pending, !tribe.left { throw Failure.awaitingApproval }
        guard tribe.canPost else { throw Failure.notInTribe }
        return tribe
    }

    private static func json(_ fields: [String: String]) throws -> String {
        String(decoding: try JSONEncoder().encode(fields), as: UTF8.self)
    }

    /// One text message or attachment through the core. A tribe message
    /// carries sats (the tribe's current price, at least 3) and the alias in
    /// the form tribes accept. The core only returns a tag and uuid for what
    /// was sent; the local row is written in the same transaction as the
    /// state, before publishing. If the publish fails the row is marked failed,
    /// ready to send again, and the failure is reported as a send status
    /// rather than thrown.
    private func deliver(
        body: String, to pubkey: String, replacing id: Int64?, type: Int = MessageType.text
    ) async throws -> String? {
        let tribe = try openTribe(pubkey)
        let time = clock.next()
        let result = try Sphinxrs.send(
            seed: seed, uniqueTime: time, to: pubkey, msgType: UInt8(type), msgJson: body,
            state: StateCodec.encode(state), myAlias: tribe == nil ? alias : tribeAlias(alias), myImg: photoURL,
            amtMsat: tribe?.messageAmountMsat ?? 0, isTribe: tribe != nil
        )
        let sent = result.msgs.first
        let now = Date().millisecondsSince1970
        var outgoing: Message?
        var resend: Storage.Commit.Resend?
        if let id {
            resend = (id, pubkey, sent?.uuid, sent?.tag, now)
        } else {
            let fields = BodyFields.decode(body)
            outgoing = Message(
                uuid: sent?.uuid, type: type, chat: pubkey, fromMe: true, body: body,
                content: fields?.content, msat: tribe.map { Int64(clamping: $0.messageAmountMsat) },
                timestamp: now, tag: sent?.tag, status: Message.Delivery.pending.rawValue,
                replyUUID: fields?.replyUuid, threadUUID: fields?.threadUuid
            )
        }
        let followUps = try commit(result, time: time, expectedSender: nil, outgoing: outgoing, resend: resend)
        do {
            try await complete(result, followUps)
        } catch {
            if let tag = sent?.tag {
                try storage.setStatus(.failed, tag: tag)
            }
            emit.yield(.sendStatus(tag: sent?.tag, status: Message.Delivery.failed.rawValue))
            emit.yield(.conversationError(chat: pubkey, message: "Not delivered: \(PeelError.readable(error))"))
        }
        return sent?.tag
    }

    /// Marks a chat read up to its newest message, here and on the server, so
    /// the account's other devices agree. Offline, only the local marker moves;
    /// the server catches up when `getReads` next shows it behind.
    public func markRead(_ chat: String) async throws {
        guard let index = try storage.highestServerIndex(in: chat) else { return }
        guard try storage.setRead(chat: chat, index: index) else { return }
        try await publishRead(chat, index: index)
    }

    private func publishRead(_ chat: String, index: Int64) async throws {
        guard transport != nil, state["c/\(chat)"] != nil, let index = UInt64(exactly: index) else { return }
        try await run { time, state in
            try Sphinxrs.read(seed: seed, uniqueTime: time, state: state, pubkey: chat, msgIdx: index)
        }
    }

    /// Sets how loud a chat may be. The level lives on the server, which uses it
    /// for push notifications, so this needs a connection.
    public func setMute(_ chat: String, level: MuteLevel) async throws {
        guard transport != nil else { throw Failure.notConnected }
        try await run { time, state in
            try Sphinxrs.mute(seed: seed, uniqueTime: time, state: state, pubkey: chat, muteLevel: UInt8(level.rawValue))
        }
        try storage.setMute(chat: chat, level: level)
    }

    // MARK: - Attachments

    /// Sends a file to a contact or a tribe as the official apps do: encrypted
    /// with a fresh key, uploaded to the memes server, then a type 6 message
    /// with the media token and key (see the phase 3 notes). The row is
    /// written first and the encrypted file kept until the memes server has
    /// it, so a failed upload or send can be retried without the file. Like
    /// `sendText`, a failure is reported through events, not thrown; the
    /// upload reports `.transfer` progress. `stored` is told the row's id as
    /// soon as the row exists, before the upload (an app shows the file from
    /// disk meanwhile). Returns the row's id.
    @discardableResult
    public func sendAttachment(
        _ file: URL, text: String = "", to pubkey: String, replyTo: String? = nil, inThread: String? = nil,
        stored: (@Sendable (Int64) -> Void)? = nil
    ) async throws -> Int64 {
        let tribe = try openTribe(pubkey)
        guard tribe != nil || Self.isPerson(pubkey, in: state) == true else { throw Failure.notAChat }
        _ = try memesServer()
        let links = try links(replyTo: replyTo, inThread: inThread, in: pubkey)
        let limit = Self.attachmentLimit
        let (outgoing, plain, sealed, key) = try await Task.detached {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else { throw PeelError("\(file.path) is not a file") }
            guard (values.fileSize ?? 0) <= limit else { throw MemesServer.Failure.tooLarge(limit) }
            let plain = try Data(contentsOf: file)
            guard plain.count <= limit else { throw MemesServer.Failure.tooLarge(limit) }
            let key = MediaCrypto.newKey()
            return (OutgoingFile(name: file.lastPathComponent, data: plain), plain,
                    try MediaCrypto.encrypt(plain, key: key), key)
        }.value
        let body = try Self.attachmentBody(
            text: text, key: key, mediaType: outgoing.mediaType, token: nil,
            replyTo: links.replyTo, thread: links.thread
        )
        let draft = Message(
            type: MessageType.attachment, chat: pubkey, fromMe: true, body: body, content: text,
            msat: tribe.map { Int64(clamping: $0.messageAmountMsat) }, timestamp: Date().millisecondsSince1970,
            status: Message.Delivery.pending.rawValue, replyUUID: links.replyTo, threadUUID: links.thread,
            mediaType: outgoing.mediaType, fileName: outgoing.fileName,
            fileSize: Int64(plain.count), upload: Message.Upload.pending.rawValue
        )
        guard let row = try storage.apply(Storage.Commit(messages: [(draft, false, nil)])).first, let id = row.id else {
            throw PeelError("the attachment was not stored")
        }
        do {
            try await Task.detached { [media] in try media.write(sealed, to: media.outgoing(id)) }.value
        } catch {
            // Without the encrypted file the row could never be sent.
            try? storage.deleteMessage(id: id)
            throw error
        }
        stored?(id)
        emit.yield(.message(row, .live))
        try await uploadAndDeliver(row, file: (plain, sealed))
        return id
    }

    /// The message JSON of an attachment, as the Mac app's `formatMsg`: the
    /// key twice (the core encrypts `mediaKeyForSelf` to this account, so our
    /// other devices and a restore can read it), the MIME type and, once
    /// uploaded, the media token.
    private static func attachmentBody(
        text: String?, key: String, mediaType: String?, token: String?, replyTo: String?, thread: String?
    ) throws -> String {
        var fields = ["content": text ?? "", "mediaKey": key, "mediaKeyForSelf": key]
        fields["mediaType"] = mediaType
        fields["mediaToken"] = token
        fields["replyUuid"] = replyTo
        fields["threadUuid"] = thread
        return try json(fields)
    }

    /// Uploads an attachment of ours if the memes server does not have it
    /// yet, then sends the message. An upload that fails marks the row failed.
    /// A first send passes the file and its encrypted form; a retry claims
    /// the row's upload (so it runs only once at a time), reads the outbox,
    /// and leaves the cache to fill on the first download.
    @discardableResult
    private func uploadAndDeliver(_ message: Message, file: (plain: Data, sealed: Data)? = nil) async throws -> String? {
        guard let id = message.id, var body = message.body, let fields = AttachmentFields.decode(body),
              let key = fields.mediaKey else { throw Failure.notRetryable }
        if message.uploadState != .done {
            if file == nil {
                guard try storage.claimUpload(id: id) else { throw Failure.uploadInProgress }
            }
            do {
                let memes = try memesServer()
                let outbox = media.outgoing(id)
                let sealed = if let file { file.sealed } else {
                    try await Task.detached { try Data(contentsOf: outbox) }.value
                }
                let outgoing = OutgoingFile(fileName: message.fileName ?? "file", mediaType: message.mediaType ?? "")
                let progress = transferProgress(id, .upload)
                let muid = try await withMemes(memes) { token in
                    try await memes.upload(sealed, as: outgoing, token: token, progress: progress)
                }
                // A year, as the official apps give their tokens.
                let expiry = UInt32(clamping: Int(Date().timeIntervalSince1970) + 365 * 24 * 3600)
                let token = try Sphinxrs.makeMediaToken(
                    seed: seed, uniqueTime: clock.next(), state: StateCodec.encode(state), host: memes.host,
                    muid: muid, to: message.chat, expiry: expiry
                )
                body = try Self.attachmentBody(
                    text: message.content, key: key, mediaType: message.mediaType, token: token,
                    replyTo: message.replyUUID, thread: message.threadUUID
                )
                try storage.setUpload(.done, id: id, body: body)
                // Our own copy is in the cache from the start, as in the official apps.
                let plain = file?.plain
                try? await Task.detached { [media] in
                    if let plain { _ = try? media.store(plain, muid: muid, key: key, limit: Self.mediaCacheLimit) }
                    try FileManager.default.removeItem(at: outbox)
                }.value
            } catch {
                try storage.setUpload(.failed, id: id)
                // It has no tag yet, so the row itself says it failed.
                if let row = try storage.message(id: id) { emit.yield(.message(row, .live)) }
                emit.yield(.conversationError(chat: message.chat, message: "Not uploaded: \(PeelError.readable(error))"))
                return nil
            }
        }
        return try await deliver(
            body: body, to: message.chat, replacing: id, type: MessageType.attachment
        )
    }

    /// Reports a transfer's progress as an event for that row.
    private func transferProgress(_ id: Int64, _ direction: Event.Direction) -> MemesServer.Progress {
        let emit = emit
        return { bytes, total in emit.yield(.transfer(messageID: id, direction: direction, bytes: bytes, total: total)) }
    }

    /// Downloads and decrypts an attachment into the profile's cache, or
    /// finds it there, reporting `.transfer` progress while it downloads.
    /// Only from this account's memes server; the bytes are checked against
    /// the declared type, and nothing is ever opened.
    public func downloadAttachment(messageID: Int64) async throws -> DownloadedAttachment {
        guard let message = try storage.message(id: messageID), message.type == MessageType.attachment,
              let fields = AttachmentFields.decode(message.body), let mediaToken = fields.mediaToken,
              let token = MediaToken(mediaToken) else { throw Failure.notAnAttachment }
        // A paid attachment comes without its key until it is bought.
        guard let key = fields.mediaKey?.nilIfEmpty else { throw Failure.attachmentWithoutKey }
        let memes = try memesServer()
        guard token.host == memes.host else { throw Failure.untrustedMediaHost(token.host) }
        let declared = AttachmentKind(mediaType: fields.mediaType)
        var fileName = message.fileName
        let stored: (file: URL, kind: AttachmentKind, size: Int)
        let cached = media.lookup(muid: token.muid, key: key)
        if let cached {
            stored = try await Task.detached {
                let plain = try Data(contentsOf: cached, options: .mappedIfSafe)
                return (cached, AttachmentKind.verified(plain, declared: declared), plain.count)
            }.value
        } else {
            // Encryption adds a header, padding and a MAC to what was sent.
            let limit = Self.attachmentLimit + 128
            let progress = transferProgress(messageID, .download)
            let (sealed, name) = try await withMemes(memes) { auth in
                try await memes.download(mediaToken: mediaToken, token: auth, limit: limit, progress: progress)
            }
            stored = try await Task.detached { [media] in
                let plain = try MediaCrypto.decrypt(sealed, key: key)
                let file = try media.store(plain, muid: token.muid, key: key, limit: Self.mediaCacheLimit)
                return (file, AttachmentKind.verified(plain, declared: declared), plain.count)
            }.value
            try storage.setFile(id: messageID, name: name, size: Int64(stored.size))
            fileName = fileName ?? name
        }
        return DownloadedAttachment(
            file: stored.file, kind: stored.kind, fileName: fileName, size: stored.size, cached: cached != nil
        )
    }

    /// The account's memes server: the one recorded, else the official
    /// apps' own, except on a local test server, which has none unless named.
    private func memesServer() throws -> MemesServer {
        if let host = try storage.value(for: .memesHost) { return try MemesServer(host: host) }
        guard let server, !ServerAddress.isLoopback(host: server.host) else { throw Failure.noMemesServer }
        return try MemesServer(host: Self.defaultMemesHost)
    }

    /// Runs a memes server call with a bearer token, signing in again once
    /// if the server no longer takes the one kept.
    private func withMemes<T>(_ memes: MemesServer, _ call: (MemesServer.Token) async throws -> T) async throws -> T {
        do {
            return try await call(memesSignIn(memes, refresh: false))
        } catch let error as MemesServer.Failure where error.isUnauthorized {
            return try await call(memesSignIn(memes, refresh: true))
        }
    }

    /// The bearer token: kept in memory until shortly before it expires. A
    /// new one is had by signing the server's challenge with the account key.
    private func memesSignIn(_ memes: MemesServer, refresh: Bool) async throws -> MemesServer.Token {
        if !refresh, let kept = memesToken, kept.host == memes.host, kept.token.isFresh { return kept.token }
        let (id, challenge) = try await memes.challenge()
        guard let bytes = MemesServer.challengeBytes(challenge) else {
            throw MemesServer.Failure.unreadableReply("sign-in")
        }
        let signature = try Sphinxrs.signBase64(
            seed: seed, idx: 0, time: clock.next(), network: network, msg: MediaToken.base64URLEncode(bytes)
        )
        let pubkey = try Sphinxrs.pubkeyFromSeed(seed: seed, idx: 0, time: clock.next(), network: network)
        let token = try await memes.verify(id: id, signature: signature, pubkey: pubkey)
        memesToken = (memes.host, token)
        return token
    }

    // MARK: - Tribes

    /// What the tribes server says about the tribe a link points to, so the
    /// price can be shown before joining.
    public func tribeInfo(link text: String) async throws -> TribeInfo {
        guard let link = TribeLink(text) else { throw Failure.invalidTribeLink }
        return try await tribeInfo(link)
    }

    private func tribeInfo(_ link: TribeLink) async throws -> TribeInfo {
        let info = try await TribeInfo.fetch(pubkey: link.pubkey, host: link.host)
        guard info.deleted != true else { throw Failure.tribeDeleted }
        return info
    }

    /// Joins the tribe a `sphinx.chat://?action=tribeV2` link points to, paying
    /// its price to join (1 sat if it has none, as the official apps do). The
    /// tribe is recorded before the join goes out, so the history it replays
    /// is filed under the tribe. Joining a tribe already joined does nothing.
    /// `agreedJoinMsat` is the price the person was shown; the join fails
    /// rather than pay anything else.
    @discardableResult
    public func joinTribe(link text: String, agreedJoinMsat: UInt64? = nil) async throws -> Tribe {
        guard let link = TribeLink(text) else { throw Failure.invalidTribeLink }
        // A member the owner declined or removed may ask again.
        if var joined = tribes[link.pubkey], !joined.left, joined.status == .active || joined.status == .pending {
            // Found in history on another tribes server, so never looked up:
            // the link the person pasted says where it is listed.
            guard joined.host == nil else { return joined }
            joined.update(from: try await tribeInfo(link))
            joined.host = link.host
            try record(joined)
            return joined
        }
        let info = try await tribeInfo(link)
        if let agreedJoinMsat, info.joinAmountMsat != agreedJoinMsat {
            throw PeelError("the price to join has changed; look the tribe up again")
        }
        guard let routeHint = info.routeHint else { throw PeelError("the tribes server gave no route to this tribe") }
        let previous = tribes[link.pubkey]
        var tribe = previous ?? Tribe(pubkey: link.pubkey)
        tribe.update(from: info)
        tribe.host = link.host
        tribe.left = false
        // A private tribe's owner must approve the request first.
        tribe.status = tribe.isPrivate ? .pending : .active
        try record(tribe)
        do {
            try await run { time, state in
                try Sphinxrs.joinTribe(
                    seed: seed, uniqueTime: time, state: state, tribePubkey: tribe.pubkey, tribeRouteHint: routeHint,
                    alias: tribeAlias(alias), amtMsat: info.joinAmountMsat, isPrivate: tribe.isPrivate
                )
            }
        } catch {
            try? record(previous, pubkey: tribe.pubkey)
            throw error
        }
        return tribe
    }

    /// Tells the tribe this account is leaving, as the official apps do, and
    /// hides it. The tribes server keeps the member on its list, so what the
    /// tribe still sends is dropped. A tribe that never accepted this account,
    /// removed it or was deleted refuses messages, so it is only hidden. The
    /// owner cannot leave, only delete the tribe, as in the official apps.
    public func leaveTribe(_ pubkey: String) async throws {
        guard let joined = tribes[pubkey], !joined.left else { throw Failure.notInTribe }
        if joined.isOwner, joined.status == .active {
            throw PeelError("the owner cannot leave a tribe; delete it instead")
        }
        var tribe = joined
        tribe.left = true
        try record(tribe)
        guard joined.status == .active else { return }
        do {
            try await sendToTribe(joined, type: MessageType.groupLeave)
        } catch {
            try? record(joined)
            throw error
        }
    }

    /// A membership or owner message to a tribe: no text, the fields the
    /// official apps add, and the tribe's price per message, as they pay it.
    private func sendToTribe(_ tribe: Tribe, type: Int, fields: [String: String] = [:]) async throws {
        let body = try Self.json(fields.merging(["content": ""]) { field, _ in field })
        try await run { time, state in
            try Sphinxrs.send(
                seed: seed, uniqueTime: time, to: tribe.pubkey, msgType: UInt8(type), msgJson: body,
                state: state, myAlias: tribeAlias(alias), myImg: photoURL, amtMsat: tribe.messageAmountMsat,
                isTribe: true
            )
        }
    }

    /// A tribe this account owns and is still in.
    private func ownedTribe(_ pubkey: String) throws -> Tribe {
        guard let tribe = tribes[pubkey], tribe.canManage else { throw Failure.notTribeOwner }
        return tribe
    }

    /// Runs one change to a tribe this account owns (an update or the
    /// delete) with its registry host and the tribes server, one at a time
    /// per tribe: the server's reply names only the tribe, so a second change
    /// would take the first one's reply, and each would undo the other's fields.
    private func changeOwnedTribe<T>(
        _ pubkey: String, _ change: (_ tribe: Tribe, _ host: String, _ server: String) async throws -> T
    ) async throws -> T {
        let tribe = try ownedTribe(pubkey)
        guard let host = tribe.host else { throw Failure.noTribeServer }
        let server = try tribeServer()
        guard changingTribes.insert(pubkey).inserted else {
            throw PeelError("another change to this tribe is still being saved")
        }
        defer { changingTribes.remove(pubkey) }
        return try await change(tribe, host, server)
    }

    /// How someone asked to join a private tribe: the request message, as the
    /// official apps answer from the chat, or the member on the owner's list.
    public enum JoinRequest: Sendable {
        case message(uuid: String)
        case member(pubkey: String, alias: String)
    }

    /// The owner approves or declines a request to join a private tribe. The
    /// answer names the request (`replyUuid`), as the official apps send it,
    /// and the member's key (`member`) when known, which the tribes server
    /// reads first. An approved member gets the recent history from the tribe.
    public func answerJoinRequest(in pubkey: String, _ request: JoinRequest, approve: Bool) async throws {
        var tribe = try ownedTribe(pubkey)
        var fields: [String: String] = [:]
        switch request {
        case .message(let uuid):
            fields["replyUuid"] = uuid
        case .member(let member, let alias):
            guard member.isPubkey else { throw PeelError("that is not a member's key") }
            // The request may not be stored, so the server's list must show
            // the member waiting; fetched when this session has none.
            if memberLists[pubkey] == nil {
                _ = try await tribeMembers(pubkey)
                tribe = try ownedTribe(pubkey)
            }
            guard memberLists[pubkey]?.pending.contains(where: { $0.pubkey == member }) == true else {
                throw PeelError("that member is not waiting for an answer")
            }
            fields["member"] = member
            fields["replyUuid"] = try storage.joinRequest(in: pubkey, from: alias)
        }
        // Each answer costs the tribe's price; a request is answered once. Our
        // answer is stored only when the server echoes it, so until then the
        // request is held in `sentAnswers` and the member taken off the list.
        let replyUuid = fields["replyUuid"]
        if let replyUuid, try sentAnswers.contains(replyUuid) || storage.isAnswered(request: replyUuid, in: pubkey) {
            throw PeelError("that request has already been answered")
        }
        if let replyUuid { sentAnswers.insert(replyUuid) }
        if let member = fields["member"] { memberLists[pubkey]?.pending.removeAll { $0.pubkey == member } }
        do {
            try await sendToTribe(tribe, type: approve ? MessageType.memberApprove : MessageType.memberReject, fields: fields)
        } catch {
            if let replyUuid { sentAnswers.remove(replyUuid) }
            if fields["member"] != nil { memberLists[pubkey] = nil }
            throw error
        }
    }

    /// The owner removes a member, named by the key on the owner's member
    /// list. The tribes server tells only that member and the owner, and
    /// refuses to remove the owner.
    public func kickMember(_ member: String, from pubkey: String) async throws {
        let tribe = try ownedTribe(pubkey)
        guard member.isPubkey else { throw PeelError("that is not a member's key") }
        try await sendToTribe(tribe, type: MessageType.groupKick, fields: ["member": member])
    }

    /// The owner deletes a tribe. The tribes server sends every member a
    /// delete message (type 22) from the tribe and drops it. The Mac app also
    /// sends its own type 22 first, but the command usually lands first and
    /// that payment then cannot be routed (the mixer answers "no root for
    /// scid"), so Peel sends only the command. The server's answer carries
    /// nothing a client can read, so the tribe is hidden here only once the
    /// registry stops listing it; until then the owner can try again.
    public func deleteTribe(_ pubkey: String) async throws {
        try await changeOwnedTribe(pubkey) { tribe, host, server in
            try await run { time, state in
                try Sphinxrs.deleteTribe(
                    seed: seed, uniqueTime: time, state: state, tribeServerPubkey: server, tribePubkey: pubkey
                )
            }
            try await poll(timeout: .seconds(15), failure: .tribeServerTimedOut) {
                await Self.isGone(pubkey, host: host) ? () : nil
            }
            var deleted = tribe
            deleted.left = true
            deleted.status = .deleted
            try record(deleted)
        }
    }

    /// Whether the registry has stopped serving a tribe (or says it is
    /// deleted). Any other failure, such as the network, counts as still there.
    private static func isGone(_ pubkey: String, host: String) async -> Bool {
        do {
            return try await TribeInfo.fetch(pubkey: pubkey, host: host).deleted == true
        } catch let error as TribeInfo.NotServed {
            return error.isGone
        } catch {
            return false
        }
    }

    /// What a tribe this account owns is set to, to start an edit from.
    public func tribeSettings(_ pubkey: String) async throws -> TribeSettings {
        guard let host = try ownedTribe(pubkey).host else { throw Failure.noTribeServer }
        return try await TribeInfo.fetch(pubkey: pubkey, host: host).settings
    }

    /// Changes a tribe this account owns and waits for the tribes server to
    /// confirm. Members see the change the next time they look the tribe up.
    @discardableResult
    public func updateTribe(_ pubkey: String, settings: TribeSettings) async throws -> Tribe {
        try await updateRegistry(pubkey) { record in
            try settings.validated(currentImage: record["img"] as? String).fields(over: record)
        }
    }

    /// Pins one of a tribe's messages for every member, or unpins with nil.
    /// Only the owner can; the pin is part of the tribe's registry record.
    public func pinMessage(_ uuid: String?, in pubkey: String) async throws {
        // Every member must hold the message under the same uuid: the tribe's.
        if let uuid, try storage.message(uuid: uuid, in: pubkey)?.isPinnable != true {
            throw PeelError("only a message the tribe has delivered can be pinned")
        }
        try await updateRegistry(pubkey) { record in
            var record = record
            record["pin"] = uuid ?? NSNull()
            return record
        }
    }

    /// Sends the tribes server the tribe's whole record with `change` made to
    /// it: an update replaces the record, so the fields Peel does not edit
    /// go back as they were.
    @discardableResult
    private func updateRegistry(
        _ pubkey: String, _ change: ([String: Any]) throws -> [String: Any]
    ) async throws -> Tribe {
        try await changeOwnedTribe(pubkey) { tribe, host, server in
            let data = try await TribeInfo.record(pubkey: pubkey, host: host)
            guard let current = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  current["pubkey"] as? String == pubkey else {
                throw PeelError("the tribes server answered for a different tribe")
            }
            var fields = try change(current)
            fields["pubkey"] = pubkey
            if (fields["owner_alias"] as? String)?.isEmpty != false {
                fields["owner_alias"] = tribeAlias(alias)
            }
            let json = String(decoding: try JSONSerialization.data(withJSONObject: fields), as: UTF8.self)
            updatedTribes.remove(pubkey)
            try await run { time, state in
                try Sphinxrs.updateTribe(
                    seed: seed, uniqueTime: time, state: state, tribeServerPubkey: server, tribeJson: json
                )
            }
            _ = try await poll(timeout: .seconds(15), failure: .tribeServerTimedOut) { updatedTribes.remove(pubkey) }
            return tribes[pubkey] ?? tribe
        }
    }

    /// Saves a tribe, or forgets it when nil, here and on disk.
    private func record(_ tribe: Tribe?, pubkey: String? = nil) throws {
        guard let pubkey = tribe?.pubkey ?? pubkey else { return }
        if let tribe { try storage.save([tribe]) } else { try storage.deleteTribe(pubkey) }
        tribes[pubkey] = tribe
    }

    /// The tribe's members. The tribes server gives the list only to the
    /// owner; anyone else gets the people seen posting.
    public func tribeMembers(_ pubkey: String) async throws -> TribeMembers {
        guard let tribe = tribes[pubkey], !tribe.left else { throw Failure.notInTribe }
        let seen = try storage.tribeSenders(pubkey)
        guard tribe.isOwner else { return TribeMembers(members: seen, complete: false) }
        let server = try tribeServer()
        memberLists[pubkey] = nil
        try await run { time, state in
            try Sphinxrs.listTribeMembers(
                seed: seed, uniqueTime: time, state: state, tribeServerPubkey: server, tribePubkey: pubkey
            )
        }
        let list = try await poll(timeout: .seconds(15), failure: .tribeServerTimedOut) { memberLists[pubkey] }
        // The server's list has no photos; take them from what members posted.
        let photos = Dictionary(seen.map { ($0.alias, $0.photoURL) }, uniquingKeysWith: { $1 })
        func members(_ entries: [TribeMembers.List.Entry], pending: Bool) -> [TribeMember] {
            entries.map { TribeMember(alias: $0.alias, photoURL: photos[$0.alias] ?? nil, pubkey: $0.pubkey, pending: pending) }
        }
        return TribeMembers(members: members(list.confirmed, pending: false) + members(list.pending, pending: true), complete: true)
    }

    /// Creates a tribe on the account's tribes server, owned by this account,
    /// and waits for the server to list it. Needs the tribes host recorded
    /// (from the config on signup or restore, or `--tribe-host`) so the new
    /// tribe has a link to share.
    @discardableResult
    public func createTribe(_ settings: TribeSettings) async throws -> Tribe {
        let new = try settings.validated()
        let server = try tribeServer()
        guard try storage.value(for: .tribeHost) != nil else { throw Failure.noTribeServer }
        let owned = Set(tribes.values.filter(\.isOwner).map(\.pubkey))
        var fields = try new.fields()
        fields["owner_alias"] = tribeAlias(alias)
        let json = String(decoding: try JSONSerialization.data(withJSONObject: fields), as: UTF8.self)
        try await run { time, state in
            try Sphinxrs.createTribe(
                seed: seed, uniqueTime: time, state: state, tribeServerPubkey: server, tribeJson: json
            )
        }
        return try await poll(timeout: .seconds(15), failure: .tribeServerTimedOut) {
            tribes.values.first { $0.isOwner && !owned.contains($0.pubkey) && $0.name == new.name }
        }
    }

    /// A tribe this account is in but has no record of, as after a restore:
    /// a tribes server names its host on the joins it forwards, including our
    /// own join coming back. Only a core contact with no contact key can be a
    /// tribe (people always have one), and the host is kept only when it is
    /// the account's own tribes server, so a stranger cannot make Peel fetch
    /// from a host of their choosing.
    /// A chat the core holds a contact key for goes into `notTribes`, so it
    /// is looked up once per call.
    private func discoveredTribe(
        _ message: Message, trustSender: Bool, state: [String: Data], notTribes: inout Set<String>
    ) throws -> Tribe? {
        guard trustSender || message.fromMe, let host = message.senderInfo?.host?.nilIfEmpty,
              let isPerson = Self.isPerson(message.chat, in: state) else { return nil }
        guard !isPerson else {
            notTribes.insert(message.chat)
            return nil
        }
        let tribeHost = try storage.value(for: .tribeHost)
        return Tribe(pubkey: message.chat, host: host == tribeHost ? host : nil)
    }

    /// What a tribe message says about this account's place in the tribe,
    /// or nil if nothing changes. Our own join or leave (replayed on a
    /// restore, or sent from another device) says whether we are in it; our
    /// own request to join comes back only from this device's send, since
    /// the tribe forwards it to the owner alone. The owner's answers reach a
    /// member from the tribe itself: a rejection or a removal, which the
    /// tribes server sends only to that member and the owner, and the
    /// tribe's deletion. A member who is pending, declined or removed gets
    /// nothing else from the tribe, so an approval or a join that reaches
    /// them means they are in, which is how a restore (with no request in
    /// history) sees a declined member who asked again and was approved.
    /// The tribes server marks what the owner sends with role 0, including
    /// the join it sends the owner on creation, so our own message with it
    /// says this account owns the tribe, as after a restore.
    /// A restore (`replaying`) leaves deleted tribes out, as the Mac app does
    /// (it restores only tribes the registry still serves); a deletion heard
    /// otherwise keeps its bar so the user sees what happened.
    private static func membership(after message: Message, in tribe: Tribe, replaying: Bool) -> Tribe? {
        var changed = tribe
        if message.fromMe {
            if message.senderInfo?.role == 0 { changed.isOwner = true }
            switch message.type {
            case MessageType.groupJoin: changed.left = false; changed.status = .active
            case MessageType.memberRequest: changed.left = false; changed.status = .pending
            case MessageType.groupLeave: changed.left = true
            default: break
            }
        } else if [MessageType.tribeDelete, MessageType.groupKick, MessageType.memberReject].contains(message.type),
                  message.senderInfo?.role != 0 {
            // The owner's decisions carry the owner's role; the tribes server
            // already refuses them from anyone else, and this does not rely on it.
            return nil
        } else if message.type == MessageType.tribeDelete {
            // Only the owner can delete, so this is true for the owner too.
            changed.status = .deleted
            if replaying { changed.left = true }
        } else if !tribe.isOwner {
            switch message.type {
            case MessageType.memberApprove, MessageType.groupJoin:
                if [.pending, .rejected, .removed].contains(tribe.status) { changed.status = .active }
            case MessageType.memberReject: changed.status = .rejected
            case MessageType.groupKick: changed.status = .removed
            default: break
            }
        }
        return changed == tribe ? nil : changed
    }

    /// Whether the core holds a contact key for `pubkey`: people always have
    /// one, tribes never. Nil when the core has no such contact.
    private static func isPerson(_ pubkey: String, in state: [String: Data]) -> Bool? {
        guard state["c/\(pubkey)"] != nil,
              let json = try? Sphinxrs.getContact(state: StateCodec.encode(state), pubkey: pubkey),
              let contact = try? JSONDecoder().decode(Contact.self, from: Data(json.utf8)) else { return nil }
        return contact.contactKey != nil
    }

    private func tribeServer() throws -> String {
        guard let server = try? Sphinxrs.getDefaultTribeServer(state: StateCodec.encode(state)), !server.isEmpty else {
            throw Failure.noTribeServer
        }
        return server
    }

    /// An account made without the tribes host (the config could not be read
    /// at signup, or made before Peel kept it) takes it from the public config.
    /// Never from a joined link, which anyone can write.
    private func recordConfiguredTribeHost() async {
        guard (try? storage.value(for: .tribeHost)) == nil, let server, !ServerAddress.isLoopback(host: server.host),
              let host = try? await ServerConfig.fetch(network: network).usableTribeHost else { return }
        try? setTribeHost(host)
    }

    /// Takes the registry's current name, photo and prices for each joined
    /// tribe, a few at a time, and saves what changed in one write. Failures
    /// leave what is stored. A call while a refresh runs makes it go round
    /// once more instead of starting a second one.
    private func refreshTribes() async {
        tribesNeedRefresh = true
        guard !refreshingTribes else { return }
        refreshingTribes = true
        defer { refreshingTribes = false }
        while tribesNeedRefresh {
            tribesNeedRefresh = false
            let joined = tribes.values.compactMap { tribe in tribe.left ? nil : tribe.host.map { (tribe.pubkey, $0) } }
            let infos = await withTaskGroup(of: TribeInfo?.self) { group in
                var pending = joined[...]
                func addNext() {
                    guard let (pubkey, host) = pending.popFirst() else { return }
                    group.addTask { try? await TribeInfo.fetch(pubkey: pubkey, host: host) }
                }
                for _ in 0..<4 { addNext() }
                var infos: [TribeInfo] = []
                while let result = await group.next() {
                    if let result { infos.append(result) }
                    addNext()
                }
                return infos
            }
            let changed = infos.compactMap { info -> Tribe? in
                guard var current = tribes[info.pubkey], !current.left else { return nil }
                current.update(from: info)
                return current == tribes[info.pubkey] ? nil : current
            }
            do {
                try storage.save(changed)
                for tribe in changed { tribes[tribe.pubkey] = tribe }
            } catch {
                emit.yield(.coreError("saving tribes: \(error)"))
            }
        }
    }

    /// Asks the server for messages newer than the newest one stored locally.
    public func syncMessages() async throws {
        // Messages dropped from left tribes are not stored but still count.
        let highest = max(try storage.highestServerIndex() ?? -1, droppedIndex)
        let next = highest < 0 ? 0 : UInt64(highest) + 1
        try await startHistory(HistoryRun(phase: .messages, next: next, end: nil))
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
        let followUps = try commit(result, time: time, expectedSender: expectedSender)
        try await complete(result, followUps)
        return result
    }

    private struct FollowUps {
        var acknowledgedPings: [UInt64] = []
        var justRegistered = false
        var restorePlan: MessageCounts?
        /// Tribes first seen in this call, whose names are still to be looked up.
        var discoveredTribes = false
    }

    /// The synchronous half: one transaction with everything the core reported,
    /// then the in-memory bookkeeping and events.
    private func commit(
        _ result: RunReturn, time: String, expectedSender: String?,
        outgoing: Message? = nil, resend: Storage.Commit.Resend? = nil
    ) throws -> FollowUps {
        var followUps = FollowUps()
        var commit = Storage.Commit()
        commit.settings[.clock] = time
        commit.resend = resend
        commit.reads = Self.reads(result.lastRead)
        if let json = result.muteLevels, let mutes = try? JSONDecoder().decode([String: Int].self, from: Data(json.utf8)) {
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
        }
        if let info = result.myContactInfo {
            commit.settings[.contactInfo] = info
        }
        if let outgoing {
            commit.messages.append((outgoing, trustSender: false, replaces: nil))
        }
        var landedPings: [String] = []
        var knownTribes = tribes
        var droppedIndex = self.droppedIndex
        var notTribes: Set<String> = []
        let myTribeAlias = tribeAlias(alias)
        for msg in result.msgs {
            if let hash = msg.paymentHash, let pingTime = pingsByHash[hash] {
                followUps.acknowledgedPings.append(pingTime)
                landedPings.append(hash)
            }
            guard var (message, trustSender) = Self.message(from: msg, expectedSender: expectedSender, state: newState)
            else { continue }
            if knownTribes[message.chat] == nil, !notTribes.contains(message.chat),
               let found = try discoveredTribe(message, trustSender: trustSender, state: newState, notTribes: &notTribes) {
                knownTribes[found.pubkey] = found
                commit.tribes.append(found)
                followUps.discoveredTribes = true
            }
            if let tribe = knownTribes[message.chat],
               let changed = Self.membership(after: message, in: tribe, replaying: restoring) {
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
                let fields = BodyFields.decode(message.body)
                if let date = fields?.date, date > 0 {
                    message.timestamp = date
                }
                // Our own message coming back from the tribe takes over the row written at send.
                if message.fromMe { replaces = fields?.originalUuid }
                if !message.fromMe, message.type == MessageType.text, let content = message.content {
                    message.mentionsMe = mentions(content, alias: myTribeAlias)
                }
            }
            commit.messages.append((message, trustSender, replaces))
        }
        var newTribe: String?
        if let json = result.newTribe, let info = try? JSONDecoder().decode(TribeInfo.self, from: Data(json.utf8)),
           Self.isPerson(info.pubkey, in: newState) != true {
            newTribe = info.pubkey
            // Replies on the management topic are only ever about this account's own tribes.
            var tribe = try knownTribes[info.pubkey] ?? Tribe(
                pubkey: info.pubkey, host: try storage.value(for: .tribeHost), isOwner: true
            )
            tribe.update(from: info)
            knownTribes[tribe.pubkey] = tribe
            commit.tribes.append(tribe)
        }
        var members: TribeMembers.List?
        if let json = result.tribeMembers {
            members = try? JSONDecoder().decode(TribeMembers.List.self, from: Data(json.utf8))
        }
        let sent = result.sentStatus.flatMap { try? JSONDecoder().decode(SentStatus.self, from: Data($0.utf8)) }
        if let sent, let tag = sent.tag {
            commit.statuses.append((tag, sent.status))
        }

        var purged: [String] = []
        let stored = try storage.apply(commit, purged: &purged)
        // A deleted attachment's decrypted copy goes with it.
        let deletedFiles = purged.compactMap { body -> URL? in
            guard let fields = AttachmentFields.decode(body), let token = fields.mediaToken.flatMap(MediaToken.init),
                  let key = fields.mediaKey else { return nil }
            return media.cached(muid: token.muid, key: key)
        }
        if !deletedFiles.isEmpty {
            Task.detached { for file in deletedFiles { try? FileManager.default.removeItem(at: file) } }
        }
        state = newState
        if let contacts {
            contactsByChildIndex = Self.index(contacts)
        }
        tribes = knownTribes
        self.droppedIndex = droppedIndex
        if let members {
            memberLists[members.pubkey] = members
        }
        if let updated = newTribe {
            updatedTribes.insert(updated)
        }

        if let json = result.msgsCounts {
            do {
                let counts = try JSONDecoder().decode(MessageCounts.self, from: Data(json.utf8))
                if awaitingCounts {
                    awaitingCounts = false
                    followUps.restorePlan = counts
                }
            } catch {
                awaitingCounts = false
                emit.yield(.historyFailed("unreadable message counts: \(error)"))
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
        // Only history pages carry a total.
        let arrival: Arrival = result.msgsTotal == nil ? .live : restoring ? .restore : .history
        for message in stored {
            emit.yield(.message(message, arrival))
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

    typealias Publish = (topic: String, payload: Data)

    /// What `complete` publishes, in order: `now`, then `later` once the
    /// register of a new child key (a key exchange or a tribe join) has had
    /// time to land, because `later` may be addressed to that key, such as this
    /// account's own contact record (type 33). Without a new key, `later` is empty.
    static func publishPlan(_ result: RunReturn) -> (now: [Publish], later: [Publish]) {
        var now: [Publish] = []
        if let topic = result.settleTopic, let payload = result.settlePayload {
            now.append((topic, payload))
        }
        if let topic = result.registerTopic, let payload = result.registerPayload {
            now.append((topic, payload))
        }
        var rest: [Publish] = []
        if let topic = result.asyncpayTopic, let payload = result.asyncpayPayload {
            rest.append((topic, payload))
        }
        for (index, topic) in result.topics.enumerated() {
            rest.append((topic, index < result.payloads.count ? result.payloads[index] : Data()))
        }
        if result.registerTopic != nil, result.newChildIdx != nil {
            return (now, rest)
        }
        return (now + rest, [])
    }

    /// Publishes in order on the current transport, read at call time so a
    /// reconnect during the register wait is used.
    private func publish(_ publishes: [Publish]) async throws {
        guard !publishes.isEmpty else { return }
        guard let transport else { throw Failure.notConnected }
        for publish in publishes {
            try await transport.publish(publish.topic, publish.payload)
        }
    }

    /// The asynchronous half: the network work the core asked for, in its order.
    private func complete(_ result: RunReturn, _ followUps: FollowUps) async throws {
        let (now, later) = Self.publishPlan(result)
        if !result.subscriptionTopics.isEmpty {
            guard let transport else { throw Failure.notConnected }
            try await transport.subscribe(result.subscriptionTopics)
        }
        try await publish(now)
        if !later.isEmpty {
            // See `publishPlan`. A cancelled wait still publishes: the state is committed.
            try? await Task.sleep(for: Self.registerSettle)
            try await publish(later)
        }

        for pingTime in followUps.acknowledgedPings {
            try await run { time, state in
                try Sphinxrs.pingDone(seed: seed, uniqueTime: time, state: state, pingTs: pingTime)
            }
        }
        if followUps.discoveredTribes {
            Task { [weak self] in await self?.refreshTribes() }
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
    private static func message(from msg: Msg, expectedSender: String?, state: [String: Data]) -> (Message, Bool)? {
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
            trustSender = true
        }
        let fields = BodyFields.decode(msg.message)
        var message = Message(
            uuid: msg.uuid,
            serverIndex: msg.index.flatMap { UInt64($0) }.flatMap { Int64(exactly: $0) },
            type: Int(type), chat: chat, fromMe: fromMe,
            sender: msg.sender, body: msg.message, content: fields?.content,
            msat: msg.msat.map { Int64(clamping: $0) },
            timestamp: msg.timestamp.map { Int64(clamping: $0) },
            tag: msg.tag, paymentHash: msg.paymentHash,
            replyUUID: fields?.replyUuid, threadUUID: fields?.threadUuid
        )
        if message.type == MessageType.attachment, let fields = AttachmentFields.decode(msg.message) {
            message.mediaType = fields.mediaType
        }
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
            expectedSender = contactsByChildIndex[index]
        }
        do {
            let result = try await run(expectedSender: expectedSender) { time, state in
                try Sphinxrs.handle(
                    topic: inbound.topic, payload: inbound.payload, seed: seed, uniqueTime: time,
                    state: state, myAlias: alias, myImg: photoURL
                )
            }
            if kind == "getreads" {
                try await republishStaleReads(server: Self.reads(result.lastRead))
            }
        } catch {
            if let expectedSender {
                emit.yield(.conversationError(chat: expectedSender, message: "A message could not be read: \(error)"))
            } else {
                emit.yield(.coreError("\(kind): \(error)"))
            }
        }
    }

    /// Runs once per connection, as soon as the account is registered. Decides
    /// what history to fetch: resume a run a dropped connection interrupted, do
    /// the full restore an account brought back from its words still needs, or
    /// catch up from the newest message stored.
    private func cameOnline() async {
        emit.yield(.registered(contactInfo: try? storage.value(for: .contactInfo)))
        Task { [weak self] in
            await self?.recordConfiguredTribeHost()
            await self?.refreshTribes()
        }
        do {
            try await run { time, state in
                try Sphinxrs.fetchPings(seed: seed, uniqueTime: time, state: state)
            }
            try await fetchReadsAndMutes()
            if let run = history {
                try await request(run)
            } else if restoring {
                awaitingCounts = true
                try await self.run { time, state in
                    try Sphinxrs.getMsgsCounts(seed: seed, uniqueTime: time, state: state)
                }
            } else {
                try await syncMessages()
            }
        } catch {
            emit.yield(.coreError("coming online: \(error)"))
        }
    }

    /// Read markers by chat, as the core reports them. The core leaves them out
    /// when the server has none at all, which reads as empty.
    private static func reads(_ json: String?) -> [String: Int64] {
        json.flatMap { try? JSONDecoder().decode([String: Int64].self, from: Data($0.utf8)) } ?? [:]
    }

    /// Tells the server again about chats read here further than it knows,
    /// such as while offline. Runs only in reply to `getReads`.
    private func republishStaleReads(server: [String: Int64]) async throws {
        for (chat, index) in try storage.lastReads() where (server[chat] ?? -1) < index {
            try await publishRead(chat, index: index)
        }
    }

    /// Read markers and mutes live on the server, shared by every device.
    private func fetchReadsAndMutes() async throws {
        try await run { time, state in
            try Sphinxrs.getReads(seed: seed, uniqueTime: time, state: state)
        }
        try await run { time, state in
            try Sphinxrs.getMutes(seed: seed, uniqueTime: time, state: state)
        }
    }

    /// Contacts first (one message per contact key, from which the core
    /// recreates each contact), then every message from the beginning.
    private func startRestore(_ counts: MessageCounts) async throws {
        var runs: [HistoryRun] = []
        if counts.firstForEachKey > 0 {
            runs.append(HistoryRun(phase: .contacts, next: 0, end: counts.firstForEachKeyHighestIndex))
        }
        if counts.total > 0 {
            runs.append(HistoryRun(phase: .messages, next: 0, end: counts.totalHighestIndex))
        }
        guard let first = runs.first else {
            try await historyEnded()
            return
        }
        queuedHistory.append(contentsOf: runs.dropFirst())
        try await startHistory(first)
    }

    /// Starts a run, or queues it behind the one in flight: all batch replies
    /// look alike, so two runs can never be in the air at once.
    private func startHistory(_ run: HistoryRun) async throws {
        guard history == nil else {
            queuedHistory.append(run)
            return
        }
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
        // A page that never comes ends the run, so nothing waits forever.
        historyWatchdog?.cancel()
        let expected = run.next
        historyWatchdog = Task { [weak self] in
            try? await Task.sleep(for: Self.historyStall)
            guard !Task.isCancelled else { return }
            await self?.historyStalled(at: expected)
        }
    }

    /// History comes a page at a time. Each page moves the cursor past its
    /// highest index; a page that moves it nowhere ends the run, so an
    /// unreadable message cannot cause an endless loop.
    private func advanceHistory(with result: RunReturn) async throws {
        guard var run = history else { return }
        run.end = run.end ?? result.msgsTotal
        let reached = result.msgs.compactMap { $0.index.flatMap { UInt64($0) } }.max()
        guard let reached, reached >= run.next, reached < UInt64(Int64.max) else {
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
        historyWatchdog?.cancel()
        history = nil
        if !queuedHistory.isEmpty {
            try await startHistory(queuedHistory.removeFirst())
        } else {
            try await historyEnded()
        }
    }

    private func historyEnded() async throws {
        if restoring {
            try storage.set("0", for: .needsRestore)
            restoring = false
            recoverOwnPhoto()
            // The first ask came before the restore rebuilt the contacts, and
            // the core drops markers for contacts it does not know.
            try await fetchReadsAndMutes()
        }
        emit.yield(.historyDone)
    }

    /// The server keeps no profile; the account's own photo comes back only
    /// on the messages it sent (its own direct messages; tribes rewrite the
    /// sender). Fills a photo never set on this Mac from the newest of them;
    /// one set or removed here (stored, even empty) wins. Best effort, once
    /// per engine: a failure here must not stop a restore finishing.
    private func recoverOwnPhoto() {
        guard !photoRecoveryDone else { return }
        photoRecoveryDone = true
        if (try? storage.value(for: .photoURL)) ?? nil == nil, let photo = try? storage.newestOwnPhotoURL() {
            try? setPhotoURL(photo)
        }
    }

    private func historyStalled(at expected: UInt64) {
        guard let run = history, run.next == expected else { return }
        history = nil
        queuedHistory = []
        emit.yield(.historyFailed("no answer from the server for \(Self.historyStall) while fetching \(run.phase)"))
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
