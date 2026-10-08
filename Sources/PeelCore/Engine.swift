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
        /// The aliases tribes echoed back on this account's messages changed
        /// (`echoedOwnAliases`).
        case echoedAliases([String: Set<String>])
        /// An attachment going up to or coming down from the memes server:
        /// bytes so far of the total, at most every 5% or 250 ms, and at the end.
        case transfer(messageID: Int64, direction: Direction, bytes: Int64, total: Int64)
        /// Sats reached this account, worth a notification: a direct payment
        /// to it or a boost on one of its own messages, new to this Mac, past
        /// the chat's read marker, with real sats (`msat`; `amountMsat` is the
        /// amount). Follows its `.message`. The chat's mute level is for the
        /// listener to apply. Never sent for history already read, nor in a
        /// restore.
        case moneyReceived(Message)
        /// An invoice made here was paid and the server has settled it, as
        /// stored: `paid`, or `underpaid` with what arrived in `paidMsat`.
        /// Once per invoice: a settle repeated later is not sent again.
        case invoicePaid(InvoiceRecord)

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
        case noCallServer
        case notAnAttachment
        case attachmentWithoutKey
        case untrustedMediaHost(String)
        case uploadInProgress
        case invalidAmount
        case balanceUnknown
        case insufficientBalance
        /// Over the confirmation threshold: show the amount, then call again
        /// with it as `confirmedMsat`.
        case needsConfirmation(amountMsat: UInt64)
        case notBoostable
        case paymentToTribe
        case noteTooLong
        case nameTooLong
        case invoiceExpired
        /// Paid before, from here or another device, or being paid now.
        case invoiceAlreadyPaid
        case invoicePending
        case ownInvoice
        /// An invoice that names no amount: the core would send nothing.
        case invoiceWithoutAmount
        case serverTimedOut
        case noInvoiceFromServer
        case notAnInvoice
        case unreadableInvoice
        /// The server's invoice differs from the one asked of it.
        case invoiceMismatch
        case memoTooLong
        case requestToTribe
        case requestExpired
        case notAPaymentRequest
        case notAContact
        case emptyName
        case photoNotHTTPS
        case unreadableTribeHost(String)
        case unreadableCallServer(String)
        case callOnAnotherServer
        case accountClosed
        case notDeletable
        /// The tribe's price per message is now above what this message or
        /// boost (`boost`) paid.
        case tribePriceRose(boost: Bool)
        case joinPriceChanged
        case noRouteToTribe
        case ownerCannotLeave
        case tribeChangeInProgress
        case tribeServerMismatch
        case tribeNeedsName
        case tribeImageNotHTTPS
        /// A tribe price or escrow over what the network carries.
        case amountTooLarge
        case notAMemberKey
        case memberNotWaiting
        case alreadyAnswered
        case notPinnable
        case invalidPrice
        case notAFile(String)
        case notAPaidAttachment
        case purchaseInProgress
        case alreadyBought
        case unknownTimeZone(String)
        case publicTribeTimeZone
        /// A tribe's local time is per member.
        case memberNeeded

        public var description: String {
            switch self {
            case .invoiceExpired: "that invoice has expired"
            case .invoiceAlreadyPaid: "that invoice has already been paid"
            case .invoicePending: "a payment of that invoice is still on its way"
            case .ownInvoice: "that is this account's own invoice"
            case .invoiceWithoutAmount: "that invoice names no amount; Peel only pays invoices that say how much"
            case .serverTimedOut: "the server did not answer in time"
            case .noInvoiceFromServer: "the server made no invoice (its Lightning node may be down); try again later"
            case .invalidAmount: "the amount must be more than nothing"
            case .balanceUnknown: "the balance is not known yet; connect first"
            case .insufficientBalance: "the balance is not enough for that"
            case .needsConfirmation(let msat): "\(Sats.format(msat: msat)) is over the confirmation threshold; confirm it first"
            case .notBoostable: "only someone else's delivered message can be boosted"
            case .paymentToTribe: "a payment to a tribe goes to the tribes server; boost a message instead"
            case .noteTooLong: "the note is too long to go with a payment"
            case .nameTooLong: "your name is too long to go with a payment"
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
            case .noMemesServer: "this account has no memes server for attachments"
            case .noCallServer: "this account has no call server"
            case .notAnAttachment: "that message is not an attachment"
            case .attachmentWithoutKey: "this attachment is paid; it opens once bought"
            case .untrustedMediaHost(let host): "the attachment is on \(host), not this account's memes server"
            case .uploadInProgress: "this attachment is still uploading"
            case .notAnInvoice: "that is not a Lightning invoice"
            case .unreadableInvoice: "that invoice cannot be read"
            case .invoiceMismatch: "the server's invoice does not match what was asked for"
            case .memoTooLong: "the memo is too long for an invoice"
            case .requestToTribe: "payment requests go to a person, not a tribe"
            case .requestExpired: "this request's invoice has expired; ask again with a new one"
            case .notAPaymentRequest: "that is not someone's payment request"
            case .notAContact: "that is not a contact"
            case .emptyName: "the name cannot be empty"
            case .photoNotHTTPS: "a photo must be an https URL"
            case .unreadableTribeHost(let host): "unreadable tribes host \(host)"
            case .unreadableCallServer(let host): "unreadable call server \(host)"
            case .callOnAnotherServer: "that call is not on this account's call server"
            case .accountClosed: "this account is closed"
            case .notDeletable:
                "only your own sent messages, or any in a tribe you own, can be deleted; "
                    + "not a thread's first message while it has replies"
            case .tribePriceRose(let boost):
                "this tribe now charges more per message; \(boost ? "boost again as a new boost" : "send it as a new message")"
            case .joinPriceChanged: "the price to join has changed; look the tribe up again"
            case .noRouteToTribe: "the tribes server gave no route to this tribe"
            case .ownerCannotLeave: "the owner cannot leave a tribe; delete it instead"
            case .tribeChangeInProgress: "another change to this tribe is still being saved"
            case .tribeServerMismatch: "the tribes server answered for a different tribe"
            case .tribeNeedsName: "a tribe needs a name"
            case .tribeImageNotHTTPS: "the image must be an https link"
            case .amountTooLarge: "an amount is too large"
            case .notAMemberKey: "that is not a member's key"
            case .memberNotWaiting: "that member is not waiting for an answer"
            case .alreadyAnswered: "that request has already been answered"
            case .notPinnable: "only a message the tribe has delivered can be pinned"
            case .invalidPrice: "a price must be from 1 to \(Engine.maxAttachmentPriceSats.formatted()) sats"
            case .notAFile(let path): "\(path) is not a file"
            case .notAPaidAttachment: "that is not a paid attachment someone sent"
            case .purchaseInProgress: "this attachment is already being bought"
            case .alreadyBought: "this attachment is already bought"
            case .unknownTimeZone(let identifier): "unknown time zone \(identifier); use a name like Europe/London"
            case .publicTribeTimeZone: "your time zone is never sent in public tribes"
            case .memberNeeded: "a tribe has a local time per member; name the member"
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
        /// Their server's node.
        public let lsp: String?

        enum CodingKeys: String, CodingKey {
            case pubkey
            case lsp
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
    /// Set by `close()`; nothing connects or refreshes after it.
    private var closed = false

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
    private var tribes: [String: Tribe] = [:]
    /// Member lists the tribes server sent for tribes this account owns.
    private var memberLists: [String: TribeMembers.List] = [:]
    /// Join requests answered this session; see `answerJoinRequest`.
    private var sentAnswers: Set<String> = []
    /// Tribes whose update the tribes server has confirmed, until `updateRegistry` takes it.
    private var updatedTribes: Set<String> = []
    /// Tribes with an update or delete on its way; see `changeOwnedTribe`.
    private var changingTribes: Set<String> = []
    /// Chats whose read marker was sent since `getReads` was last asked: its
    /// answer may predate the marker, so it is not applied to them.
    private var readsSentSinceGetReads: Set<String> = []
    /// The highest server index of a message dropped unstored; see `Setting.droppedIndex`.
    private var droppedIndex: Int64
    /// A restore from the words is replaying history; see `Setting.needsRestore`.
    private var restoring: Bool
    /// Whether `recoverOwnPhoto` has run for this engine.
    private var photoRecoveryDone = false
    /// The aliases each tribe echoed back on this account's own messages;
    /// with the account's own tribe alias, what a mention of it looks like there.
    private var echoedAliases: [String: Set<String>]
    /// The background re-check of stored messages for mentions; see `checkMentionsIfNeeded`.
    private var mentionScan: Task<Void, Never>?
    /// The background registry refresh; see `refreshTribesInBackground`.
    private var tribeRefresh: Task<Void, Never>?
    private var tribesNeedRefresh = false
    /// Tribes queued for the next round of the refresh alone; see `recheckIfStale`.
    private var tribesToRecheck: Set<String> = []
    /// When each tribe's last read record was asked for, this session.
    private var tribeReadAt: [String: ContinuousClock.Instant] = [:]
    static let tribeRecheck: Duration = .seconds(5 * 60)
    /// A page of payment history asked for and not yet answered; the
    /// answer lands here (see `fetchPaymentHistory`).
    private var awaitingPayments = false
    private var paymentPage: [PaymentRecord]?
    /// An invoice asked of the server (`request_invoice`) and not yet
    /// answered; the answer lands here (see `serverInvoice`).
    private var awaitingInvoice = false
    private var answeredInvoice: String?
    /// See `checkOpenInvoices`; `historyCheckedAt` is when the history was
    /// last fetched back to what is stored (milliseconds), this session.
    private var invoiceCheck: Task<Void, Never>?
    private var invoicesNeedCheck = false
    private var historyCheckedAt: Int64?
    /// Invoices being paid in this session, so a second click can never
    /// pay one twice while the first is being sent.
    private var payingInvoices: Set<String> = []

    /// Attachments: the decrypted cache and the uploads waiting to go, and
    /// the memes server's bearer token (memory only).
    private let media: MediaStore
    private var memesToken: (host: String, token: MemesServer.Token)?
    /// The call server's ticket endpoint and presence feed; see `callConnection`.
    private var calls: CallServer?
    /// Largest attachment sent or downloaded, and the most the cache keeps.
    static let attachmentLimit = 100_000_000
    static let mediaCacheLimit = 500_000_000
    /// Where the official apps keep attachments.
    static let defaultMemesHost = "memes.sphinx.chat"
    static let defaultCallServer = "chat.sphinx.chat"

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
        echoedAliases = try storage.echoedOwnAliases()
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
    /// The aliases each tribe echoed back on this account's own messages,
    /// by tribe; with the name, what a mention of it looks like there
    /// (`ownMentionAliases`). Changes arrive as `.echoedAliases`.
    public var echoedOwnAliases: [String: Set<String>] { echoedAliases }

    /// The name others see. Names are not core state and the server keeps no
    /// profile: it travels with each message sent from now on (and with a
    /// tribe join), and a contact's app takes the newest one it sees, as with
    /// the official apps. Nothing is announced and sent messages keep the old one.
    public func setAlias(_ alias: String) throws {
        let alias = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !alias.isEmpty else { throw Failure.emptyName }
        try storage.set(alias, for: .alias)
        self.alias = alias
        emit.yield(.profile(alias: alias, photoURL: myPhotoURL))
        checkMentionsIfNeeded()
    }

    /// Re-checks stored tribe messages for mentions of this account whenever
    /// the aliases that name it have changed since the last check (or were
    /// never checked: history stored before mentions were flagged), only in
    /// the tribes affected unless the account's alias changed. Runs in the
    /// background, off this actor, once at a time; a change meanwhile starts
    /// another when it ends. Not during a restore, which flags what it stores
    /// and checks at its end. Called on rename, when an echo brings a new
    /// alias, and at the end of each history sync.
    private func checkMentionsIfNeeded() {
        guard mentionScan == nil, !restoring, !alias.isEmpty else { return }
        let mark = MentionScan(sent: tribeAlias(alias), echoed: echoedAliases)
        let last = (try? storage.value(for: .mentionScan)).flatMap(MentionScan.init(stored:))
        guard mark != last, let stored = mark.stored else { return }
        let chats = mark.chats(changedSince: last)
        let storage = storage
        mentionScan = Task.detached { [weak self] in
            let result = Result {
                try storage.rescanMentions(sent: mark.sent, echoed: mark.echoed, in: chats)
                try storage.set(stored, for: .mentionScan)
            }
            await self?.mentionScanEnded(result)
        }
    }

    /// The aliases may have changed while the scan ran; a failed one waits
    /// for the next trigger.
    private func mentionScanEnded(_ result: Result<Void, any Error>) {
        mentionScan = nil
        switch result {
        case .success: checkMentionsIfNeeded()
        case .failure(let error): emit.yield(.coreError("checking mentions: \(PeelError.readable(error))"))
        }
    }

    /// The photo others see beside this account's messages: an https URL, or
    /// empty for none. It travels like the name. `uploadPhoto` puts a picture
    /// from this Mac on the memes server and passes its link here.
    public func setPhotoURL(_ url: String) throws {
        let url = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard url.isEmpty || url.httpsOnly != nil else { throw Failure.photoNotHTTPS }
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
        guard TribeLink.isPlainHost(host) else { throw Failure.unreadableTribeHost(host) }
        try storage.set(host, for: .tribeHost)
    }

    /// The memes server attachments go to and come from, as `host[:port]`.
    public func setMemesHost(_ host: String) throws {
        _ = try MemesServer(host: host)
        try storage.set(host, for: .memesHost)
    }

    /// The call server calls are started on, as `host[:port]`.
    public func setCallServer(_ host: String) throws {
        let host = host.lowercased()
        guard TribeLink.baseURL(host) != nil else { throw Failure.unreadableCallServer(host) }
        try storage.set(host, for: .callServer)
        // Its socket would otherwise stay open to the old server.
        if let old = calls, old.host != host {
            calls = nil
            Task { await old.close() }
        }
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
        guard !closed else { return }
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
        tribeRefresh?.cancel()
        tribeRefresh = nil
        invoiceCheck?.cancel()
        invoiceCheck = nil
        await teardown()
        setConnection(.offline(retryIn: nil))
    }

    /// Disconnects for good and ends `events`, so whoever follows them lets
    /// go of this engine. For an account being closed: it does not connect again.
    public func close() async {
        closed = true
        await disconnect()
        await calls?.close()
        historyWatchdog?.cancel()
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
                emit.yield(.connectionError(PeelError.readable(error)))
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
        // A reply to this connection's status query can only come on it.
        unrecordedPayments = []
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
        guard let parts = Self.contactInfoParts(contactInfo) else { throw Failure.invalidContactInfo }
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
            throw Failure.notDeletable
        }
        _ = try await deliver(
            body: try Self.json(["content": "", "replyUuid": uuid]), to: message.chat, type: MessageType.delete,
            replacing: nil
        )
    }

    /// Sends an undelivered message again. The core gives every send a new uuid
    /// and tag, so the same row takes them over and moves to now; the server's
    /// echo then matches that row rather than adding a second one. A tribe
    /// message pays the tribe's current price, as a first send would, but
    /// never more than the price it was first sent at: a raise since then
    /// shows in the tribe's header, and the message must be sent anew.
    /// A payment or boost goes again only once it failed (`isRetryable`), for
    /// the same amount, within the balance and, like a new one, confirmed
    /// when over the threshold; a boost in a tribe only if that amount still
    /// covers the tribe's price, and only while its message can be boosted.
    @discardableResult
    public func resend(messageID: Int64, confirmedMsat: UInt64? = nil) async throws -> String? {
        guard let message = try storage.message(id: messageID), message.isRetryable(), let body = message.body else {
            throw Failure.notRetryable
        }
        let tribe = try openTribe(message.chat)
        guard MessageType.payments.contains(message.type) else {
            if let tribe, let paid = message.msat, tribe.messageAmountMsat > UInt64(max(paid, 0)) {
                throw Failure.tribePriceRose(boost: false)
            }
            if message.type == MessageType.attachment {
                return try await uploadAndDeliver(message)
            }
            if message.type == MessageType.invoice,
               Self.requestInvoice(body)?.isExpired() != false {
                throw Failure.requestExpired
            }
            return try await deliver(body: body, to: message.chat, type: message.type, replacing: messageID)
        }
        guard let amount = message.amountMsat.flatMap(UInt64.init(exactly:)), amount > 0 else {
            throw Failure.notRetryable
        }
        // The same rule as a new boost: never pay for a message deleted since.
        if message.type == MessageType.boost {
            _ = try boostTarget(message.replyUUID.flatMap { try storage.message(uuid: $0, in: message.chat) })
        }
        if let tribe, tribe.paymentPriceMsat > amount {
            throw Failure.tribePriceRose(boost: true)
        }
        try checkPayment(amount, .threshold(confirmedMsat))
        return try await deliver(body: body, to: message.chat, type: message.type, amountMsat: amount, replacing: messageID)
    }

    // MARK: - Payments and boosts

    /// Payments and boosts over this many msat need the person's confirmation
    /// (`Failure.needsConfirmation`); the app asks before calling again.
    /// 100 sats unless the person chose otherwise (Tom, 2026-10-07); 0 asks
    /// for every payment.
    public static let defaultPaymentConfirmationMsat: UInt64 = 100_000

    public func paymentConfirmationMsat() throws -> UInt64 {
        try storage.value(for: .paymentConfirmationMsat).flatMap { UInt64($0) } ?? Self.defaultPaymentConfirmationMsat
    }

    public func setPaymentConfirmation(msat: UInt64) throws {
        try storage.set(String(msat), for: .paymentConfirmationMsat)
    }

    /// The balance the server last reported, in msat; nil until it has.
    public func balanceMsat() throws -> UInt64? {
        try storage.balanceMsat()
    }

    /// Boosts someone else's delivered message, as the Mac app does: type 29
    /// naming it by `replyUuid`. In a tribe the boost also pays the tribe's
    /// price per message and escrow, so the total is that plus `amountMsat`;
    /// the tribes server passes all of it to the message's author. Like
    /// `sendText`, a failure to deliver is reported through events, not
    /// thrown. Returns the tag the server will confirm.
    @discardableResult
    public func boost(messageID: Int64, amountMsat: UInt64, confirmedMsat: UInt64? = nil) async throws -> String? {
        try await boost(messageID: messageID, amountMsat: amountMsat, confirmation: .threshold(confirmedMsat))
    }

    /// Whether a payment is held to the confirmation threshold, and the
    /// amount the person confirmed if asked; or sent unasked (one-tap boost).
    private enum Confirmation {
        case threshold(UInt64?)
        case unasked
    }

    private func boost(messageID: Int64, amountMsat: UInt64, confirmation: Confirmation) async throws -> String? {
        guard amountMsat > 0 else { throw Failure.invalidAmount }
        let (message, uuid) = try boostTarget(try storage.message(id: messageID))
        guard let total = Self.boostTotalMsat(tipMsat: amountMsat, in: try openTribe(message.chat)) else {
            throw Failure.insufficientBalance
        }
        try checkPayment(total, confirmation)
        let body = try Self.json(["content": "", "replyUuid": uuid])
        return try await deliver(body: body, to: message.chat, type: MessageType.boost, amountMsat: total, replacing: nil)
    }

    /// The official apps' one-tap boost (Tom, 2026-10-07: the same UX): the
    /// account's boost amount (`boostAmountMsat`) plus, in a tribe, its price
    /// and escrow, sent at once with no confirmation of any kind; the
    /// threshold, "Always confirm" included, is for a boost with an amount
    /// (`boost`, the CLI's), payments and invoices. The boost amount itself
    /// was approved when it was saved (`setBoostAmount`). Only the balance is
    /// checked. A message is boosted once this way (Tom, 2026-10-07): with
    /// any boost of ours on it, failed ones included (those offer Retry), a
    /// tap is ignored and returns nil, which also covers a double click.
    @discardableResult
    public func quickBoost(messageID: Int64) async throws -> String? {
        if let message = try storage.message(id: messageID), let uuid = message.uuid,
           try storage.lastOwnBoost(on: uuid, in: message.chat) != nil {
            return nil
        }
        return try await boost(messageID: messageID, amountMsat: try boostAmountMsat(), confirmation: .unasked)
    }

    /// The official apps' default tip, 100 sats ("Default tip amount").
    public static let defaultBoostAmountMsat: UInt64 = 100_000

    public func boostAmountMsat() throws -> UInt64 {
        try storage.value(for: .boostAmountMsat).flatMap { UInt64($0) }.flatMap { $0 > 0 ? $0 : nil }
            ?? Self.defaultBoostAmountMsat
    }

    /// Every later one-tap boost sends this amount unasked, so one over the
    /// confirmation threshold must be confirmed (`confirmedMsat`) like a payment.
    public func setBoostAmount(msat: UInt64, confirmedMsat: UInt64? = nil) throws {
        guard msat > 0 else { throw Failure.invalidAmount }
        if Self.needsConfirmation(msat, confirmedMsat: confirmedMsat, thresholdMsat: try paymentConfirmationMsat()) {
            throw Failure.needsConfirmation(amountMsat: msat)
        }
        try storage.set(String(msat), for: .boostAmountMsat)
    }

    /// Whether `amountMsat` must be confirmed first: over the threshold (0
    /// asks for everything) and not confirmed for exactly this amount.
    static func needsConfirmation(_ amountMsat: UInt64, confirmedMsat: UInt64?, thresholdMsat: UInt64) -> Bool {
        confirmedMsat != amountMsat && amountMsat > thresholdMsat
    }

    /// What a boost with this tip pays: in a tribe its price per message and
    /// escrow (`Tribe.paymentPriceMsat`) plus the tip, else the tip; nil if
    /// it cannot be counted.
    static func boostTotalMsat(tipMsat: UInt64, in tribe: Tribe?) -> UInt64? {
        let (total, overflow) = (tribe?.paymentPriceMsat ?? 0).addingReportingOverflow(tipMsat)
        return overflow ? nil : total
    }

    /// The message a boost is for, and its uuid, if it may be boosted
    /// (`Message.isBoostable`), for a new boost and a retry alike.
    private func boostTarget(_ message: Message?) throws -> (Message, String) {
        guard let message, message.isBoostable, let uuid = message.uuid, MessageUUID.isValid(uuid) else {
            throw Failure.notBoostable
        }
        return (message, uuid)
    }

    /// Sends sats to a contact in their chat with an optional note (type 5),
    /// as the Mac app's payment does. Only to a person: in a tribe it would
    /// pay the tribes server. Delivery is reported as for `sendText`.
    @discardableResult
    public func sendPayment(
        to pubkey: String, amountMsat: UInt64, text: String = "", confirmedMsat: UInt64? = nil
    ) async throws -> String? {
        guard amountMsat > 0 else { throw Failure.invalidAmount }
        guard tribes[pubkey] == nil else { throw Failure.paymentToTribe }
        guard Self.isPerson(pubkey, in: state) == true else { throw Failure.notAContact }
        try checkPayment(amountMsat, .threshold(confirmedMsat))
        let body = try Self.json(["content": text])
        return try await deliver(
            body: body, to: pubkey, type: MessageType.directPayment, amountMsat: amountMsat, replacing: nil
        )
    }

    /// Refuses an amount over the last balance the server reported (less
    /// `reserveMsat` kept back for routing fees), or over the confirmation
    /// threshold unless the person confirmed exactly this amount (a
    /// confirmation never covers a total that changed since, such as a tribe
    /// raising its price between the two clicks). A one-tap boost
    /// (`.unasked`) is checked against the balance only.
    private func checkPayment(_ amountMsat: UInt64, _ confirmation: Confirmation, reserveMsat: UInt64 = 0) throws {
        guard let balance = try balanceMsat() else { throw Failure.balanceUnknown }
        let (needed, overflow) = amountMsat.addingReportingOverflow(reserveMsat)
        guard !overflow, needed <= balance else { throw Failure.insufficientBalance }
        if case .threshold(let confirmedMsat) = confirmation,
           Self.needsConfirmation(amountMsat, confirmedMsat: confirmedMsat, thresholdMsat: try paymentConfirmationMsat()) {
            throw Failure.needsConfirmation(amountMsat: amountMsat)
        }
    }

    // MARK: - Invoices and payment history

    /// What paying an invoice keeps back for routing fees when checking the
    /// balance: 1%, at least 10 sats. The fee itself is known only after.
    public static func feeReserveMsat(for amountMsat: UInt64) -> UInt64 {
        max(amountMsat / 100, 10_000)
    }

    /// Fetches a page of the server's payment history, newest first, older
    /// than `before` (milliseconds; nil for the newest), and stores it.
    /// Returns how many rows came: fewer than a page means the end.
    @discardableResult
    public func fetchPaymentHistory(before: Int64? = nil) async throws -> Int {
        try await fetchPaymentPage(before: before).count
    }

    /// Fetches what is new since the history was last fetched: the newest
    /// page, and older ones until they reach what is stored, so a busy spell
    /// leaves no gap that paging back would skip. At most 20 pages a time.
    public func refreshPaymentHistory() async throws {
        let started = Date().millisecondsSince1970
        let newestStored = try storage.newestPaymentTimestamp()
        var before: Int64?
        for _ in 0..<20 {
            let page = try await fetchPaymentPage(before: before)
            guard page.count >= Int(Self.paymentPageSize), let newestStored, let oldest = page.map(\.ts).min(),
                  oldest > newestStored else {
                historyCheckedAt = started
                return
            }
            before = oldest
        }
    }

    /// One page at a time: a fetch waits for the one on its way (the
    /// server's answer names no request).
    private func fetchPaymentPage(before: Int64?) async throws -> [PaymentRecord] {
        try await poll(timeout: .seconds(30), failure: .serverTimedOut) { awaitingPayments ? nil : () }
        guard transport != nil else { throw Failure.notConnected }
        awaitingPayments = true
        paymentPage = nil
        defer {
            awaitingPayments = false
            paymentPage = nil
        }
        let since = before.map { UInt64(max($0 - 1, 0)) } ?? UInt64(Date().millisecondsSince1970)
        try await run { time, state in
            try Sphinxrs.fetchPayments(
                seed: seed, uniqueTime: time, state: state, since: since, limit: Self.paymentPageSize,
                scid: nil, remoteOnly: false, minMsat: 0, reverse: true
            )
        }
        return try await poll(timeout: .seconds(15), failure: .serverTimedOut) { paymentPage }
    }

    public static let paymentPageSize: UInt32 = 50

    /// Makes an invoice to receive `amountMsat`, as the official apps do:
    /// the server's Lightning node makes it (`request_invoice`) and credits
    /// this account when it is paid, so it is paid even while Peel is
    /// closed. The payment shows only as a balance change and a row in the
    /// server's history, which marks the invoice paid (see
    /// `checkOpenInvoices`). An amount is required.
    public func createInvoice(amountMsat: UInt64, memo: String = "") async throws -> InvoiceRecord {
        try await serverInvoice(amountMsat: amountMsat, memo: memo, chat: nil)
    }

    private func serverInvoice(amountMsat: UInt64, memo: String, chat: String?) async throws -> InvoiceRecord {
        guard amountMsat > 0 else { throw Failure.invalidAmount }
        guard isRegistered, transport != nil, let server = try ownKeys()?.server else { throw Failure.notConnected }
        let memo = memo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard memo.utf8.count <= 300 else { throw Failure.memoTooLong }
        // The server's answer names no request, so one at a time: wait for
        // the one on its way, as a history page does.
        try await poll(timeout: .seconds(30), failure: .serverTimedOut) { awaitingInvoice ? nil : () }
        awaitingInvoice = true
        answeredInvoice = nil
        defer {
            awaitingInvoice = false
            answeredInvoice = nil
        }
        try await run { time, state in
            try Sphinxrs.requestInvoice(seed: seed, uniqueTime: time, state: state, amtMsat: amountMsat, description: memo)
        }
        // The server sends nothing back when it cannot make one (no Lightning
        // node). A late answer to an earlier request that differs is dropped.
        let invoice = try await poll(timeout: .seconds(30), failure: .noInvoiceFromServer) { () -> Invoice? in
            guard let bolt11 = answeredInvoice else { return nil }
            answeredInvoice = nil
            return try? Self.checkServerInvoice(bolt11, amountMsat: amountMsat, memo: memo, server: server)
        }
        let record = InvoiceRecord(
            paymentHash: invoice.paymentHash, incoming: true, bolt11: invoice.bolt11,
            amountMsat: Int64(clamping: amountMsat), memo: invoice.memo, payee: invoice.payee,
            createdAt: Date().millisecondsSince1970, expiresAt: invoice.expiresAt?.millisecondsSince1970,
            status: .open, chat: chat
        )
        _ = try storage.apply(Storage.Commit(invoices: [record]))
        return record
    }

    /// The server's answer to `request_invoice`, checked against what was
    /// asked: its node is the payee, for exactly the amount and memo, and
    /// not expired. Refuses a late answer to an earlier request that differs.
    static func checkServerInvoice(
        _ bolt11: String, amountMsat: UInt64, memo: String, server: String, now: Date = .now
    ) throws -> Invoice {
        let invoice = try Invoice(bolt11)
        guard invoice.payee == server, invoice.amountMsat == amountMsat, invoice.memo == memo,
              !invoice.isExpired(now: now) else {
            throw Failure.invoiceMismatch
        }
        return invoice
    }

    /// This account's pubkey and its server's node, from the contact info
    /// the core reports (`pubkey_lsp_scid`); nil before registering.
    private nonisolated func ownKeys() throws -> (pubkey: String, server: String)? {
        try storage.value(for: .contactInfo).flatMap(Self.contactInfoParts).map { ($0[0], $0[1]) }
    }

    /// `pubkey_lsp_scid` split in three, or nil when it is not that.
    static func contactInfoParts(_ contactInfo: String) -> [String]? {
        let parts = contactInfo.split(separator: "_", omittingEmptySubsequences: false).map(String.init)
        return parts.count == 3 && parts[0].count == 66 ? parts : nil
    }

    /// Looks in the server's history for payments to invoices made here,
    /// which arrive only as a balance change and a history row (`commit`
    /// matches the row by payment hash): on coming online, as Peel may have
    /// been closed when one was paid, and whenever the balance goes up. Only
    /// while an invoice made here was open and unexpired when the history
    /// was last brought up to date. One check at a time; a call during one
    /// runs it again after. Stopped by `disconnect`.
    private func checkInvoicesInBackground() {
        guard !closed else { return }
        invoicesNeedCheck = true
        guard invoiceCheck == nil else { return }
        invoiceCheck = Task { [weak self] in await self?.checkOpenInvoices() }
    }

    private func checkOpenInvoices() async {
        while invoicesNeedCheck, !Task.isCancelled {
            invoicesNeedCheck = false
            do {
                guard try storage.hasInvoicesAwaitingHistory(checkedAt: historyCheckedAt) else { break }
                try await refreshPaymentHistory()
            } catch {
                if !Task.isCancelled {
                    emit.yield(.coreError("checking invoices for payments: \(PeelError.readable(error))"))
                }
                break
            }
        }
        // A cancelled check has already been replaced or stopped.
        if !Task.isCancelled { invoiceCheck = nil }
    }

    /// Asks a contact for sats in their chat (type 2), with an invoice the
    /// server makes for this account, as the official apps do. Returns the
    /// invoice; the message's delivery is reported as for `sendText`.
    @discardableResult
    public func requestPayment(from pubkey: String, amountMsat: UInt64, memo: String = "") async throws -> InvoiceRecord {
        guard tribes[pubkey] == nil else { throw Failure.requestToTribe }
        guard Self.isPerson(pubkey, in: state) == true else { throw Failure.notAContact }
        let record = try await serverInvoice(amountMsat: amountMsat, memo: memo, chat: pubkey)
        let body = try Self.json(["content": record.memo, "invoice": record.bolt11])
        try await deliver(body: body, to: pubkey, type: MessageType.invoice, replacing: nil)
        return record
    }

    /// Pays a pasted invoice. Refuses one that is expired, names no amount,
    /// is this account's own, was paid before (here, or by any device the
    /// server's history shows) or is being paid; over the balance less a
    /// fee reserve; and over the confirmation threshold unless confirmed.
    /// The payment is recorded as pending before anything is published, and
    /// stays so, never to be paid again, until the server says how it went.
    @discardableResult
    public func payInvoice(_ bolt11: String, confirmedMsat: UInt64? = nil) async throws -> InvoiceRecord {
        try await pay(Invoice(bolt11), chat: nil, confirmedMsat: confirmedMsat)
    }

    /// Pays someone's payment request in their chat. When the invoice pays
    /// them, the payment carries the type 3 message that tells their app,
    /// as the official apps do; otherwise it pays the invoice as pasted.
    @discardableResult
    public func payRequest(messageID: Int64, confirmedMsat: UInt64? = nil) async throws -> InvoiceRecord {
        guard let message = try storage.message(id: messageID), message.type == MessageType.invoice, !message.fromMe,
              let bolt11 = BodyFields.decode(message.body)?.invoice else {
            throw Failure.notAPaymentRequest
        }
        return try await pay(Invoice(bolt11), chat: message.chat, confirmedMsat: confirmedMsat)
    }

    /// What stops paying this invoice from here, as paying it checks (the
    /// confirmation threshold aside): no amount, expired, this account's
    /// own, pending or paid (here or, by the history, from another device),
    /// or more than the balance less the fee reserve. Nil when nothing does.
    /// Reads only storage, so an app can ask before offering Pay.
    public nonisolated func invoiceProblem(_ invoice: Invoice) throws -> Failure? {
        guard invoice.amountMsat > 0 else { return .invoiceWithoutAmount }
        guard !invoice.isExpired() else { return .invoiceExpired }
        if invoice.payee == (try ownKeys())?.pubkey { return .ownInvoice }
        switch try storage.paidState(paymentHash: invoice.paymentHash) {
        case .own?: return .ownInvoice
        case .pending?: return .invoicePending
        case .paid?: return .invoiceAlreadyPaid
        case nil: break
        }
        guard let balance = try storage.balanceMsat() else { return .balanceUnknown }
        let (needed, overflow) = invoice.amountMsat.addingReportingOverflow(Self.feeReserveMsat(for: invoice.amountMsat))
        return overflow || needed > balance ? .insufficientBalance : nil
    }

    private func pay(_ invoice: Invoice, chat: String?, confirmedMsat: UInt64?) async throws -> InvoiceRecord {
        let hash = invoice.paymentHash
        if let problem = try invoiceProblem(invoice) { throw problem }
        // The balance and fee reserve are `invoiceProblem`'s; this asks the threshold.
        try checkPayment(invoice.amountMsat, .threshold(confirmedMsat))
        guard transport != nil else { throw Failure.notConnected }
        guard payingInvoices.insert(hash).inserted else { throw Failure.invoicePending }
        defer { payingInvoices.remove(hash) }

        let toContact = chat.map { invoice.payee == $0 && Self.isPerson($0, in: state) == true } ?? false
        var time = clock.next()
        let result: RunReturn
        if toContact {
            result = try Sphinxrs.payContactInvoice(
                seed: seed, uniqueTime: time, state: StateCodec.encode(state), bolt11: invoice.bolt11,
                myAlias: alias, myImg: photoURL, isTribe: false
            )
        } else if invoice.payee == (try ownKeys())?.server {
            // Made by our own server's node (`request_invoice`, as Receive and
            // requests in a chat are): the server moves the sats between its
            // accounts (`pay_local_invoice`). An onion ending at its own node
            // it refuses ("expected a forwarded onion").
            result = try Sphinxrs.pay(seed: seed, uniqueTime: time, state: StateCodec.encode(state), bolt11: invoice.bolt11)
        } else {
            do {
                result = try Sphinxrs.payInvoice(
                    seed: seed, uniqueTime: time, state: StateCodec.encode(state), bolt11: invoice.bolt11,
                    overpayMsat: invoice.amountMsat
                )
            } catch where invoice.hopHints.isEmpty {
                // No route this account can build: the server pays it (its
                // own node finds the route), as the official apps fall back.
                time = clock.next()
                result = try Sphinxrs.pay(seed: seed, uniqueTime: time, state: StateCodec.encode(state), bolt11: invoice.bolt11)
            }
        }
        guard let tag = (result.msgs.first { $0.paymentHash == hash } ?? result.msgs.first)?.tag else {
            throw PeelError("the core gave the payment no tag")
        }
        let record = InvoiceRecord(
            paymentHash: hash, incoming: false, bolt11: invoice.bolt11, amountMsat: Int64(clamping: invoice.amountMsat),
            memo: invoice.memo, payee: invoice.payee, createdAt: Date().millisecondsSince1970,
            expiresAt: invoice.expiresAt?.millisecondsSince1970, status: .pending, tag: tag, chat: chat
        )
        // Written with the state before publishing; refused (and nothing
        // published) if the invoice is already being paid or paid.
        let followUps = try commit(result, time: time, expectedSender: nil, invoices: [record])
        let unsent = transport == nil
        do {
            try await complete(result, followUps)
        } catch {
            guard unsent else {
                let message = "The connection failed while paying; the payment may have gone. "
                    + "It stays unconfirmed until the server says (\(PeelError.readable(error)))"
                if let chat { emit.yield(.conversationError(chat: chat, message: message)) } else { emit.yield(.coreError(message)) }
                return record
            }
            try storage.setStatus(.failed, tag: tag, error: "not connected")
            emit.yield(.sendStatus(tag: tag, status: Message.Delivery.failed.rawValue))
            throw error
        }
        return record
    }

    /// A payment request's invoice, from its JSON; nil when it cannot be read.
    static func requestInvoice(_ body: String?) -> Invoice? {
        BodyFields.decode(body)?.invoice.flatMap { try? Invoice($0) }
    }

    /// Whether the bindings would split this JSON into type 34 fragments
    /// (`should_chunk_for_send` in `sphinx-ffi/src/chunk.rs`): each fragment
    /// carries the whole amount, so a payment must never be split. The same
    /// sum, with a margin.
    static func wouldBeSplit(_ body: String, alias: String, photoURL: String) -> Bool {
        // chunk.rs: MAX_MSG_LEN, FIXED_PROTOCOL_OVERHEAD_BYTES, ROUTE_HINT_OVERHEAD_ALLOWANCE_BYTES.
        let maxMessage = 869, protocolOverhead = 250, routeHint = 50, margin = 32
        struct Sender: Encodable { let alias: String; let img: String }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        // Two strings always encode.
        let sender = try! encoder.encode(Sender(alias: alias, img: photoURL)).count
        return body.utf8.count + margin > maxMessage - protocolOverhead - routeHint - sender
    }

    /// A payment's body and photo URL as they fit in one message: without the
    /// time-zone offset, then without the photo, rather than not at all. The
    /// photo only decorates the payment, and the official apps (like Peel)
    /// keep a contact's photo when a message comes without one. What still
    /// does not fit is the name's fault when it would not fit alone, else the note's.
    static func fittingPayment(_ body: String, alias: String, photoURL: String) throws -> (String, String) {
        guard wouldBeSplit(body, alias: alias, photoURL: photoURL) else { return (body, photoURL) }
        let body = try TimeZoneOffset.setting(nil, in: body)
        if !wouldBeSplit(body, alias: alias, photoURL: photoURL) { return (body, photoURL) }
        if !wouldBeSplit(body, alias: alias, photoURL: "") { return (body, "") }
        throw wouldBeSplit("{}", alias: alias, photoURL: "") ? Failure.nameTooLong : Failure.noteTooLong
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

    static func json(_ fields: [String: String]) throws -> String {
        String(decoding: try JSONEncoder().encode(fields), as: UTF8.self)
    }

    /// Whether the core holds `pubkey` as a person (not a tribe).
    func isContact(_ pubkey: String) -> Bool { Self.isPerson(pubkey, in: state) == true }

    /// A tribe this account knows, as last stored.
    func knownTribe(_ pubkey: String) -> Tribe? { tribes[pubkey] }

    /// One message through the core: text, an attachment, a delete, a
    /// payment or a boost. A text message to a tribe carries sats (the
    /// tribe's current price, at least 3); a payment or boost carries
    /// `amountMsat`. A tribe message goes with the alias in the form tribes
    /// accept. The core only returns a tag and uuid for what was sent; the
    /// local row is written in the same transaction as the state, before
    /// publishing. If the publish fails the row is marked failed, ready to send
    /// again, and the failure is reported as a send status rather than thrown.
    /// A payment is marked failed only when nothing was published (no
    /// connection): once anything went out it may have paid, so it stays
    /// pending, never to be sent again, until the server says.
    private func deliver(
        body: String, to pubkey: String, type: Int = MessageType.text, amountMsat: UInt64? = nil,
        replacing id: Int64?
    ) async throws -> String? {
        let tribe = try openTribe(pubkey)
        // By what is stored: a send never waits on the network, so sends go
        // at once and in order (`TimeZones.swift`).
        let offset = try offsetShared(in: pubkey, type: type)
        var body = try TimeZoneOffset.setting(offset, in: body)
        if tribe != nil, offset != nil { recheckIfStale(pubkey) }
        let myAlias = tribe == nil ? alias : tribeAlias(alias)
        var photoURL = photoURL
        if amountMsat != nil { (body, photoURL) = try Self.fittingPayment(body, alias: myAlias, photoURL: photoURL) }
        let sats = amountMsat ?? tribe?.messageAmountMsat(type: type) ?? 0
        let time = clock.next()
        let result = try Sphinxrs.send(
            seed: seed, uniqueTime: time, to: pubkey, msgType: UInt8(type), msgJson: body,
            state: StateCodec.encode(state), myAlias: myAlias, myImg: photoURL,
            amtMsat: sats, isTribe: tribe != nil
        )
        let sent = result.msgs.first
        let now = Date().millisecondsSince1970
        var outgoing: Message?
        var resend: Storage.Commit.Resend?
        if let id {
            resend = (id, pubkey, sent?.uuid, sent?.tag, sent?.paymentHash, now)
        } else {
            let fields = BodyFields.decode(body)
            outgoing = Message(
                uuid: sent?.uuid, type: type, chat: pubkey, fromMe: true, body: body,
                content: fields?.content, msat: sats > 0 ? Int64(clamping: sats) : nil,
                timestamp: now, tag: sent?.tag, paymentHash: sent?.paymentHash,
                status: Message.Delivery.pending.rawValue,
                replyUUID: fields?.replyUuid, threadUUID: fields?.threadUuid,
                amountMsat: amountMsat.map { Int64(clamping: $0) }
            )
            if type == MessageType.invoice, let invoice = Self.requestInvoice(body) {
                outgoing?.paymentHash = invoice.paymentHash
                outgoing?.amountMsat = Int64(clamping: invoice.amountMsat)
            }
        }
        let followUps = try commit(result, time: time, expectedSender: nil, outgoing: outgoing, resend: resend)
        // Nothing is published without a connection (`complete` checks first).
        let unsent = transport == nil
        do {
            try await complete(result, followUps)
        } catch {
            guard amountMsat == nil || unsent else {
                emit.yield(.conversationError(
                    chat: pubkey, message: "The connection failed while sending; the payment may have gone. "
                        + "It stays unconfirmed until the server says (\(error))"
                ))
                return sent?.tag
            }
            if let tag = sent?.tag {
                try storage.setStatus(.failed, tag: tag)
            }
            emit.yield(.sendStatus(tag: sent?.tag, status: Message.Delivery.failed.rawValue))
            emit.yield(.conversationError(chat: pubkey, message: "Not delivered: \(PeelError.readable(error))"))
            return sent?.tag
        }
        // The server moves the chat's read marker to what was just sent.
        readsSentSinceGetReads.insert(pubkey)
        do {
            try storage.readBySending(in: pubkey)
        } catch {
            // Sent all the same; the next `getReads` brings the marker.
            emit.yield(.coreError("marking read after sending: \(PeelError.readable(error))"))
        }
        return sent?.tag
    }

    /// Marks a chat read up to its newest message, here and on the server, so
    /// the account's other devices agree. Never moves the marker back (the
    /// server's may be past what is stored here). Offline, the marker waits
    /// as pending and goes once the server answers `getReads`.
    public func markRead(_ chat: String) async throws {
        guard let index = try storage.highestServerIndex(in: chat),
              try storage.setRead(chat: chat, index: index, as: .read) else { return }
        try await publishRead(chat, index: index)
    }

    /// Marks a chat unread from one message (by server index) on, or from
    /// its newest incoming message so it counts one: the marker goes just
    /// before it, as the official apps' "Mark as Unread" does, and the server
    /// takes the lower marker as it is. Threads share the chat's marker.
    /// Returns the new marker.
    @discardableResult
    public func markUnread(_ chat: String, fromServerIndex index: Int64? = nil) async throws -> Int64 {
        // The server keeps markers only for core contacts (tribes included).
        guard state["c/\(chat)"] != nil else { throw Failure.notAChat }
        guard let index = try index ?? storage.newestIncomingIndex(in: chat), index > 0 else {
            throw Failure.noSuchMessage
        }
        if try storage.setRead(chat: chat, index: index - 1, as: .unread) {
            try await publishRead(chat, index: index - 1)
        }
        return index - 1
    }

    /// Sends a marker set here; once sent, it is no longer pending.
    private func publishRead(_ chat: String, index: Int64) async throws {
        guard transport != nil, state["c/\(chat)"] != nil, let msgIdx = UInt64(exactly: index) else { return }
        try await run { time, state in
            try Sphinxrs.read(seed: seed, uniqueTime: time, state: state, pubkey: chat, msgIdx: msgIdx)
        }
        readsSentSinceGetReads.insert(chat)
        try storage.readSent(chat: chat, index: index)
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
    /// disk meanwhile). `priceSats` sells it, as the official apps do: the
    /// price goes in the media token and, in a direct message, the key stays
    /// out of the message until a buyer pays (see `answerPurchase`).
    /// Returns the row's id.
    @discardableResult
    public func sendAttachment(
        _ file: URL, text: String = "", to pubkey: String, replyTo: String? = nil, inThread: String? = nil,
        priceSats: UInt64? = nil, stored: (@Sendable (Int64) -> Void)? = nil
    ) async throws -> Int64 {
        if let priceSats, priceSats == 0 || priceSats > Self.maxAttachmentPriceSats {
            throw Failure.invalidPrice
        }
        let tribe = try openTribe(pubkey)
        guard tribe != nil || Self.isPerson(pubkey, in: state) == true else { throw Failure.notAChat }
        _ = try memesServer()
        let links = try links(replyTo: replyTo, inThread: inThread, in: pubkey)
        let limit = Self.attachmentLimit
        let (outgoing, plain, sealed, key) = try await Task.detached {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else { throw Failure.notAFile(file.path) }
            guard (values.fileSize ?? 0) <= limit else { throw MemesServer.Failure.tooLarge(limit) }
            let plain = try Data(contentsOf: file)
            guard plain.count <= limit else { throw MemesServer.Failure.tooLarge(limit) }
            let key = MediaCrypto.newKey()
            return (OutgoingFile(name: file.lastPathComponent, data: plain), plain,
                    try MediaCrypto.encrypt(plain, key: key), key)
        }.value
        let body = try Self.attachmentBody(
            text: text, key: key, mediaType: outgoing.mediaType, token: nil,
            replyTo: links.replyTo, thread: links.thread, draftPrice: priceSats
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
    /// A paid one in a direct message leaves `mediaKey` out (the seller
    /// sends it to each buyer); a tribe keeps it, as the official apps do.
    /// Before the upload the row keeps the price as `price`, which never
    /// goes out: the sent JSON is made again with the token.
    private static func attachmentBody(
        text: String?, key: String, mediaType: String?, token: String?, replyTo: String?, thread: String?,
        withholdKey: Bool = false, draftPrice: UInt64? = nil
    ) throws -> String {
        var fields = ["content": text ?? "", "mediaKeyForSelf": key]
        if !withholdKey { fields["mediaKey"] = key }
        fields["price"] = draftPrice.map(String.init)
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
              let key = fields.ownKey else { throw Failure.notRetryable }
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
                let price = BodyFields.decode(body)?.price.flatMap { UInt64($0) }
                let (time, coreState) = (clock.next(), try StateCodec.encode(state))
                let token = try price.map {
                    try Sphinxrs.makeMediaTokenWithPrice(
                        seed: seed, uniqueTime: time, state: coreState, host: memes.host, muid: muid, to: message.chat,
                        expiry: expiry, price: $0
                    )
                } ?? Sphinxrs.makeMediaToken(
                    seed: seed, uniqueTime: time, state: coreState, host: memes.host, muid: muid, to: message.chat,
                    expiry: expiry
                )
                body = try Self.attachmentBody(
                    text: message.content, key: key, mediaType: message.mediaType, token: token,
                    replyTo: message.replyUUID, thread: message.threadUUID,
                    withholdKey: price != nil && tribes[message.chat] == nil
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
        return try await deliver(body: body, to: message.chat, type: MessageType.attachment, replacing: id)
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
        // A paid one comes without its key: someone else's opens with the key
        // its seller sent once bought; our own keeps it as `mediaKeyForSelf`.
        let carried = message.fromMe ? fields.ownKey : fields.mediaKey
        guard let key = try carried?.nilIfEmpty ?? storage.purchasedKey(for: message) else {
            throw Failure.attachmentWithoutKey
        }
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

    // MARK: - Paid attachments

    /// The most an attachment may be sold for: a mistyped price should not
    /// be a fortune.
    public static let maxAttachmentPriceSats: UInt64 = 10_000_000

    /// Buys someone else's paid attachment, as the official apps do: a
    /// purchase (type 7) to the seller carrying the price its media token
    /// names, with that token and the attachment's uuid. The seller's app
    /// answers with the key (type 8), and the attachment then downloads and
    /// decrypts like any other; or with a refund (type 9). Nothing of it is
    /// fetched before. Refused when not for sale, already bought or on its
    /// way, over the balance, or over the confirmation threshold unless
    /// confirmed. Delivery is reported as for `sendText`.
    @discardableResult
    public func buyAttachment(messageID: Int64, confirmedMsat: UInt64? = nil) async throws -> String? {
        guard let message = try storage.message(id: messageID), !message.fromMe, !message.deleted,
              let price = message.attachmentPriceMsat, let uuid = message.uuid, MessageUUID.isValid(uuid),
              let token = AttachmentFields.decode(message.body)?.mediaToken else {
            throw Failure.notAPaidAttachment
        }
        // Only from this account's memes server, like any download.
        guard let host = MediaToken(token)?.host, host == (try memesServer()).host else {
            throw Failure.untrustedMediaHost(MediaToken(token)?.host ?? "")
        }
        switch try storage.purchaseState(of: message) {
        case .processing?: throw Failure.purchaseInProgress
        case .unlocked?: throw Failure.alreadyBought
        case .locked?, .failed?, .denied?, .forSale?, nil: break
        }
        try checkPayment(price, .threshold(confirmedMsat))
        let purchaseKey = "purchase \(token)"
        guard payingInvoices.insert(purchaseKey).inserted else { throw Failure.purchaseInProgress }
        defer { payingInvoices.remove(purchaseKey) }
        let body = try Self.json(["content": "", "mediaToken": token, "replyUuid": uuid])
        return try await deliver(body: body, to: message.chat, type: MessageType.purchase, amountMsat: price, replacing: nil)
    }

    /// The seller's side, as the official apps answer a purchase of one of
    /// their paid attachments in a direct message (in a tribe the tribes
    /// server holds the key and answers): the key when the sats that came
    /// (`msat`, what really arrived) cover the price, give or take the
    /// official apps' 3 sats for routing (never more than a tenth of the
    /// price, so a cheap one is not given away). A purchase is answered
    /// once. One that pays too little is left unanswered: the official apps
    /// refund it automatically, but two of this account's devices online at
    /// once would each refund it (see docs/phases/04-money.md).
    private func answerPurchase(_ purchase: Message) async throws {
        guard !purchase.fromMe, tribes[purchase.chat] == nil,
              let token = AttachmentFields.decode(purchase.body)?.mediaToken,
              let attachment = try storage.ownAttachment(token: token, in: purchase.chat),
              let price = attachment.attachmentPriceMsat,
              let fields = AttachmentFields.decode(attachment.body),
              let key = fields.ownKey,
              try !storage.isAnswered(purchase: purchase, token: token) else { return }
        let paid = UInt64(max(purchase.msat ?? 0, 0))
        guard paid > 0, paid + min(3000, price / 10) >= price else {
            emit.yield(.conversationError(
                chat: purchase.chat,
                message: "A purchase of your paid attachment brought \(Sats.format(msat: paid, of: price)), so its key was not sent"
            ))
            return
        }
        var answer = ["content": "", "mediaKey": key, "mediaKeyForSelf": key, "mediaToken": token]
        answer["mediaType"] = fields.mediaType
        try await deliver(body: try Self.json(answer), to: purchase.chat, type: MessageType.purchaseAccept, replacing: nil)
    }

    /// The account's memes server: the one recorded, else the official
    /// apps' own, except on a local test server, which has none unless named.
    private func memesServer() throws -> MemesServer {
        if let host = try storage.value(for: .memesHost) { return try MemesServer(host: host) }
        guard let server, !ServerAddress.isLoopback(host: server.host) else { throw Failure.noMemesServer }
        return try MemesServer(host: Self.defaultMemesHost)
    }

    // MARK: - Calls

    /// The account's call server: the one recorded, else the official apps'
    /// own, except on a local test server, which has none unless named.
    public func callServer() throws -> String {
        if let host = try storage.value(for: .callServer) { return host }
        guard let server, !ServerAddress.isLoopback(host: server.host) else { throw Failure.noCallServer }
        return Self.defaultCallServer
    }

    /// Starts a call in a contact's chat or a tribe: a new room with a random
    /// name on the call server, posted as a call message in the `call::`
    /// form. A tribe takes only the 3-sat floor for it. Only while connected,
    /// since a call message is never sent again (its room would be stale);
    /// a publish that fails all the same is reported as a send status for
    /// the tag returned, like any send's. Joining is the caller's.
    public func startCall(in pubkey: String, audioOnly: Bool) async throws -> (link: CallLink, tag: String?) {
        let tribe = try openTribe(pubkey)
        guard tribe != nil || Self.isPerson(pubkey, in: state) == true else { throw Failure.notAChat }
        let link = try CallLink.new(server: callServer(), audioOnly: audioOnly)
        guard transport != nil else { throw Failure.notConnected }
        let tag = try await deliver(body: Self.json(["content": link.message]), to: pubkey, type: MessageType.call, replacing: nil)
        return (link, tag)
    }

    /// The call a message links to, checked against this account's call
    /// server: a call message, or text that is only a call link (the Mac
    /// app reads both as calls). Nil for anything else, and on an account
    /// with no call server.
    public func callLink(in message: Message) -> CallLink? {
        guard !message.deleted, [MessageType.call, MessageType.text].contains(message.type),
              let content = message.content, let server = try? callServer() else { return nil }
        return CallLink(message: content, server: server)
    }

    /// A ticket to join a call: the LiveKit server and a token, asked of
    /// this account's call server under the name `chat` knows this account
    /// by (the tribe alias in a tribe), with its photo and a Hive link's
    /// key. Memory only; never store or log it.
    public func callTicket(for link: CallLink, in chat: String?) async throws -> CallTicket {
        let name = chat.flatMap { tribes[$0] } != nil || alias.isEmpty ? tribeAlias(alias) : alias
        return try await callConnection(for: link).ticket(for: link, participantName: name, photoURL: myPhotoURL)
    }

    /// Who is on a call, from the call server's presence feed, until the
    /// stream is dropped. Ask only for calls on screen and recent.
    public func callPresence(of link: CallLink) async throws -> AsyncStream<CallPresence> {
        try await callConnection(for: link).presence(room: link.room)
    }

    /// The engine's one connection to its call server, made again when the
    /// setting changes. A link from another server is refused: a ticket is
    /// only ever asked of the configured server.
    private func callConnection(for link: CallLink) async throws -> CallServer {
        guard !closed else { throw Failure.accountClosed }
        let host = try callServer()
        guard link.server == host else { throw Failure.callOnAnotherServer }
        if let calls, calls.host == host { return calls }
        let old = calls
        let server = try CallServer(host: host)
        calls = server
        await old?.close()
        return server
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
            throw Failure.joinPriceChanged
        }
        guard let routeHint = info.routeHint else { throw Failure.noRouteToTribe }
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
            throw Failure.ownerCannotLeave
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
            throw Failure.tribeChangeInProgress
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
            guard member.isPubkey else { throw Failure.notAMemberKey }
            // The request may not be stored, so the server's list must show
            // the member waiting; fetched when this session has none.
            if memberLists[pubkey] == nil {
                _ = try await tribeMembers(pubkey)
                tribe = try ownedTribe(pubkey)
            }
            guard memberLists[pubkey]?.pending.contains(where: { $0.pubkey == member }) == true else {
                throw Failure.memberNotWaiting
            }
            fields["member"] = member
            fields["replyUuid"] = try storage.joinRequest(in: pubkey, from: alias)
        }
        // Each answer costs the tribe's price; a request is answered once. Our
        // answer is stored only when the server echoes it, so until then the
        // request is held in `sentAnswers` and the member taken off the list.
        let replyUuid = fields["replyUuid"]
        if let replyUuid, try sentAnswers.contains(replyUuid) || storage.isAnswered(request: replyUuid, in: pubkey) {
            throw Failure.alreadyAnswered
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
        guard member.isPubkey else { throw Failure.notAMemberKey }
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
            throw Failure.notPinnable
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
                throw Failure.tribeServerMismatch
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
    func discoveredTribe(
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
    /// tribe's deletion. Someone else's join never concerns us. The owner's
    /// approval goes to every member, naming the approved one by their alias
    /// in the tribe, so it lets us in only when it names us (`approvalNamesUs`:
    /// the alias we send, `sent`, and those the tribe `echoed`). That is how a
    /// restore (with no request in history) sees a declined or removed member
    /// who asked again and was approved, while another member's approval or
    /// join heard after our removal leaves us out. Names are all an approval
    /// carries (the server drops the member key), so this can miss: a member
    /// renamed between asking and the approval, restored before anything of
    /// theirs echoed the old name, stays out. A member who is out hears no
    /// approvals live, so a wrong match (another `name_2`) needs history
    /// replayed out of order. The tribes server marks what the owner sends with role 0, including
    /// the join it sends the owner on creation, so our own message with it
    /// says this account owns the tribe, as after a restore.
    /// A restore (`replaying`) leaves deleted tribes out, as the Mac app does
    /// (it restores only tribes the registry still serves); a deletion heard
    /// otherwise keeps its bar so the user sees what happened.
    static func membership(
        after message: Message, in tribe: Tribe, sent: String, echoed: Set<String>, replaying: Bool
    ) -> Tribe? {
        var changed = tribe
        if message.fromMe {
            if message.senderInfo?.role == 0 { changed.isOwner = true }
            switch message.type {
            case MessageType.groupJoin: changed.left = false; changed.status = .active
            case MessageType.memberRequest: changed.left = false; changed.status = .pending
            case MessageType.groupLeave: changed.left = true
            default: break
            }
        } else if [MessageType.tribeDelete, MessageType.groupKick, MessageType.memberReject, MessageType.memberApprove]
                    .contains(message.type), message.senderInfo?.role != 0 {
            // The owner's decisions carry the owner's role; the tribes server
            // already refuses them from anyone else, and this does not rely on it.
            return nil
        } else if message.type == MessageType.tribeDelete {
            // Only the owner can delete, so this is true for the owner too.
            changed.status = .deleted
            if replaying { changed.left = true }
        } else if !tribe.isOwner {
            switch message.type {
            case MessageType.memberApprove:
                if let alias = message.senderAlias, approvalNamesUs(alias, sent: sent, echoed: echoed),
                   [.pending, .rejected, .removed].contains(tribe.status) {
                    changed.status = .active
                }
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
        contact(pubkey, in: state).map { $0.contactKey != nil }
    }

    /// The core's record of `pubkey`; `state` needs only its `c/` entry.
    static func contact(_ pubkey: String, in state: [String: Data]) -> Contact? {
        guard state["c/\(pubkey)"] != nil,
              let json = try? Sphinxrs.getContact(state: StateCodec.encode(state), pubkey: pubkey) else { return nil }
        return try? JSONDecoder().decode(Contact.self, from: Data(json.utf8))
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

    /// Runs `refreshTribes` in the background. A call while it runs makes it
    /// go round once more instead of starting a second one; `disconnect` cancels it.
    private func refreshTribesInBackground() {
        tribesNeedRefresh = true
        startTribeRefresh()
    }

    private func startTribeRefresh() {
        guard !closed, tribeRefresh == nil else { return }
        tribeRefresh = Task { [weak self] in
            await self?.recordConfiguredTribeHost()
            await self?.refreshTribes()
        }
    }

    /// A joined tribe as its registry record now says, if that changes it.
    private func merged(_ info: TribeInfo) -> Tribe? {
        guard var current = tribes[info.pubkey], !current.left else { return nil }
        current.update(from: info)
        return current == tribes[info.pubkey] ? nil : current
    }

    /// Takes the registry's current name, photo and prices for each joined
    /// tribe (or only those in `tribesToRecheck`), a few at a time, and saves
    /// what changed in one write. Failures leave what is stored.
    private func refreshTribes() async {
        while tribesNeedRefresh || !tribesToRecheck.isEmpty, !Task.isCancelled {
            let all = tribesNeedRefresh, only = tribesToRecheck
            tribesNeedRefresh = false
            tribesToRecheck = []
            let joined = tribes.values.compactMap { tribe in
                tribe.left || !(all || only.contains(tribe.pubkey)) ? nil : tribe.host.map { (tribe.pubkey, $0) }
            }
            let asked = ContinuousClock.now
            let infos = await withTaskGroup(of: TribeInfo?.self) { group in
                var pending = joined[...]
                func addNext() {
                    guard !Task.isCancelled, let (pubkey, host) = pending.popFirst() else { return }
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
            guard !Task.isCancelled else { break }
            saveRecords(infos, asked: asked)
        }
        // A cancelled refresh has already been replaced or stopped.
        if !Task.isCancelled { tribeRefresh = nil }
    }

    /// Saves what registry answers change in joined tribes, in one write,
    /// and notes when each answered tribe was asked (`tribeReadAt`).
    func saveRecords(_ infos: [TribeInfo], asked: ContinuousClock.Instant) {
        for info in infos { tribeReadAt[info.pubkey] = asked }
        let changed = infos.compactMap(merged)
        do {
            try storage.save(changed)
            for tribe in changed { tribes[tribe.pubkey] = tribe }
        } catch {
            emit.yield(.coreError("saving tribes: \(PeelError.readable(error))"))
        }
    }

    /// After a send that carried the offset to a tribe: queues its record
    /// for the background refresh when the last one read this session is
    /// older than `tribeRecheck`, so a tribe made public soon stops getting
    /// it (design README, "Time zones"). The send never waits. True when queued.
    @discardableResult
    func recheckIfStale(_ pubkey: String, now: ContinuousClock.Instant = .now) -> Bool {
        guard tribeReadAt[pubkey].map({ now - $0 > Self.tribeRecheck }) ?? true,
              !tribesToRecheck.contains(pubkey) else { return false }
        tribesToRecheck.insert(pubkey)
        startTribeRefresh()
        return true
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
        /// Purchases of our paid attachments to answer.
        var purchases: [Message] = []
        /// The balance went up: maybe an invoice made here was paid.
        var checkInvoices = false
    }

    /// History rows that pay an invoice made here and still open: incoming,
    /// not failed, with its payment hash. One per invoice.
    static func invoicePayments(in page: [PaymentRecord], open: Set<String>) -> [PaymentRecord] {
        var seen: Set<String> = []
        return page.filter { $0.incoming && !$0.failed && open.contains($0.rhash) && seen.insert($0.rhash).inserted }
    }

    /// The synchronous half: one transaction with everything the core reported,
    /// then the in-memory bookkeeping and events.
    private func commit(
        _ result: RunReturn, time: String, expectedSender: String?,
        outgoing: Message? = nil, resend: Storage.Commit.Resend? = nil, invoices: [InvoiceRecord] = []
    ) throws -> FollowUps {
        var followUps = FollowUps()
        var commit = Storage.Commit()
        commit.settings[.clock] = time
        commit.resend = resend
        commit.reads = Self.reads(result.lastRead).filter { !readsSentSinceGetReads.contains($0.key) }
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
            // Sats came in: maybe for an invoice made here.
            followUps.checkInvoices = balance > (try storage.balanceMsat() ?? 0)
        }
        if let info = result.myContactInfo {
            commit.settings[.contactInfo] = info
        }
        if let outgoing {
            commit.messages.append((outgoing, trustSender: false, replaces: nil))
        }
        commit.invoices = invoices
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
        let settled = result.settledStatus.flatMap { try? JSONDecoder().decode(SettledStatus.self, from: Data($0.utf8)) }
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
        let sentAlias = tribeAlias(alias)
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
               let changed = Self.membership(
                   after: message, in: tribe, sent: sentAlias, echoed: echoedAliases[message.chat] ?? [],
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
                let fields = BodyFields.decode(message.body)
                if let date = fields?.date, date > 0 {
                    message.timestamp = date
                }
                // Our own message coming back from the tribe takes over the row written at send.
                if message.fromMe {
                    replaces = fields?.originalUuid
                    if let echoed = message.senderAlias { echoedAliases[message.chat, default: []].insert(echoed) }
                } else if MessageType.content.contains(message.type), let content = message.content {
                    let aliases = ownTribeAliases(sent: sentAlias, echoed: echoedAliases[message.chat] ?? [])
                    message.mentionsMe = mentions(content, aliases: aliases)
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
        let records = result.tags.flatMap { try? JSONDecoder().decode([SentStatus].self, from: Data($0.utf8)) }
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

        var purged: [String] = []
        var received: [Message] = []
        let settling = try storage.openInvoices(among: commit.settled.map(\.0))
        let stored = try storage.apply(commit, purged: &purged, received: &received)
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
        if records != nil { unrecordedPayments = [] }
        if awaitingPayments, let page { paymentPage = page }
        if awaitingInvoice, let bolt11 = result.invoice { answeredInvoice = bolt11 }
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
        // Only history pages carry a total.
        let arrival: Arrival = result.msgsTotal == nil ? .live : restoring ? .restore : .history
        for message in stored {
            emit.yield(.message(message, arrival))
        }
        // Purchases of our paid attachments, answered once this commit is done.
        if arrival != .restore {
            followUps.purchases = stored.filter { $0.type == MessageType.purchase && !$0.fromMe && !$0.deleted }
        }
        for message in received where arrival != .restore {
            emit.yield(.moneyReceived(message))
        }
        // What the server said, then what its records settled.
        if let sent {
            emit.yield(.sendStatus(tag: sent.tag, status: sent.status))
        }
        for (tag, status) in answers {
            emit.yield(.sendStatus(tag: tag, status: status))
        }
        // Every payment that arrives settles; only one to an invoice made
        // here, open until this commit, is news, and only once: a request
        // paid with a type 3 was told by its `.moneyReceived`.
        for (hash, _) in commit.settled where settling.contains(hash) && !received.contains(where: { $0.paymentHash == hash }) {
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
        if followUps.discoveredTribes { refreshTribesInBackground() }
        if followUps.checkInvoices { checkInvoicesInBackground() }
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
            // What reached this account, which the core checked against the
            // payment; only without sats what the sender declared.
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
            if fromMe { message.paymentHash = msg.paymentHash ?? BodyFields.decode(msg.message)?.paymentHash?.lowercased() }
            message.amountMsat = msat
        case MessageType.purchase, MessageType.purchaseDeny:
            message.amountMsat = msat ?? (fromMe ? DeclaredAmount.decode(msg.message) : nil)
        default:
            break
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
            try await run(expectedSender: expectedSender) { time, state in
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
        emit.yield(.registered(contactInfo: try? storage.value(for: .contactInfo)))
        refreshTribesInBackground()
        checkInvoicesInBackground()
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
            emit.yield(.coreError("coming online: \(PeelError.readable(error))"))
        }
    }

    /// Read markers by chat, as the core reports them. The core leaves them out
    /// when the server has none at all, which reads as empty.
    private static func reads(_ json: String?) -> [String: Int64] {
        json.flatMap { try? JSONDecoder().decode([String: Int64].self, from: Data($0.utf8)) } ?? [:]
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
    private func checkPendingSends() async throws {
        let pending = try storage.pendingSends(
            textBefore: Date.now.addingTimeInterval(-Message.confirmationTimeout).millisecondsSince1970
        )
        // Invoices we pay are tracked the same way.
        let invoices = try storage.pendingInvoicePayments()
        guard !pending.isEmpty || !invoices.isEmpty else { return }
        let cutoff = Date.now.addingTimeInterval(-Message.unrecordedPaymentTimeout)
        unrecordedPayments = Set(pending.compactMap { message in
            MessageType.moneySends.contains(message.type) && message.date < cutoff ? message.tag : nil
        } + invoices.compactMap { $0.created < cutoff ? $0.tag : nil })
        let tags = pending.compactMap(\.tag) + invoices.compactMap(\.tag)
        try await run { time, state in
            try Sphinxrs.getTags(seed: seed, uniqueTime: time, state: state, tags: tags, pubkey: nil)
        }
    }

    /// Read markers and mutes live on the server, shared by every device.
    private func fetchReadsAndMutes() async throws {
        readsSentSinceGetReads = []
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
        checkMentionsIfNeeded()
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

extension Engine {
    /// The row the one status the mixer publishes for a send moves
    /// (`Storage.setStatus` only moves rows forward): COMPLETE and FAILED as
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
