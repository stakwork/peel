import Foundation
import Observation
#if os(macOS)
import AppKit
#endif
import PeelCore

/// Everything the windows show, kept current from the engine and storage.
@MainActor @Observable
final class AppModel {
    enum Phase { case loading, locked, onboarding, ready }

    /// How far a restore from twelve words has got.
    struct RestoreProgress {
        struct Count {
            var reached: UInt64
            var end: UInt64?

            var fraction: Double? {
                guard let end, end > 0 else { return nil }
                return min(1, Double(reached) / Double(end))
            }
        }

        enum Outcome { case finished, failed(String) }

        var contacts: Count?
        var messages: Count?
        var outcome: Outcome?

        var finished: Bool {
            if case .finished = outcome { true } else { false }
        }
    }

    /// What the sidebar has selected.
    enum Destination: Hashable {
        case threads, mentions, payments, account
        case chat(String)
    }

    var phase: Phase = .loading
    var connection: Engine.ConnectionState = .offline(retryIn: nil)
    var conversations: [Conversation] = []
    /// The open chat's main conversation: in a tribe with threads collapsed,
    /// plus the messages its replies quote.
    var timeline = Timeline.empty
    var destination: Destination? {
        didSet {
            if selectedChat != oldValue?.chat {
                newMessages = nil
                keepsUnread = nil
                // A jump into this chat (`focus(on:)`) set both just before.
                if focus?.message.chat != selectedChat {
                    focus = nil
                    timelineLimit = nil
                }
                observeMessages()
                if openThread?.chat != selectedChat { openThread = nil }
            }
            markSelectedChatRead()
        }
    }
    /// The thread open in the side panel, and what it holds.
    var openThread: ThreadRef? {
        didSet { if openThread != oldValue { observeThread() } }
    }
    private(set) var thread: ChatThread?
    /// Threads this account started or wrote in, for the Threads list.
    private(set) var threads: [ThreadSummary] = []
    /// What each composer is replying to.
    var replyTargets: [ComposerID: Message] = [:]
    /// Files waiting in each composer until it sends.
    var pendingFiles: [ComposerID: [URL]] = [:]
    /// The composer files are being dragged towards, for its overlay.
    var dropTarget: ComposerID?
    /// The price in sats, as typed, the files in a composer are sold for; empty for free.
    var attachmentPrices: [ComposerID: String] = [:]
    /// Bumped to put the cursor in a composer.
    var composerFocus: [ComposerID: Int] = [:]
    /// The image viewer, when open.
    var viewer: ImageViewerState?
    /// What each composer holds unsent, kept while a thread covers its
    /// chat or another chat is open.
    var drafts: [ComposerID: String] = [:]
    /// The open chat's rows and the open thread's, worked out once per
    /// change of what they show rather than on every redraw.
    private(set) var chatRows: [ChatRow] = []
    private(set) var threadRows: [ChatRow] = []
    /// Downloads, uploads and local copies of attachments, by message id;
    /// each observed on its own so a progress tick redraws only its tile.
    @ObservationIgnored var attachmentHandles: [Int64: AttachmentHandle] = [:]
    var searchQuery = ""
    var myAlias: String?
    /// The photo sent with this account's messages, https or nil.
    var myPhotoURL: String?
    var myContactInfo: String?
    /// The server this account talks to, as `host:port`.
    var myServer: String?
    var balanceMsat: UInt64? {
        didSet { if let balanceMsat { money.balance(balanceMsat) } }
    }
    /// Payments and boosts over this ask for a second click (`Engine`'s threshold).
    var paymentConfirmationMsat = Engine.defaultPaymentConfirmationMsat
    /// Payments and boosts on their way to the engine, so a double click
    /// never sends one twice.
    @ObservationIgnored var moneyInFlight: Set<String> = []
    /// What the one-tap Boost tips (the engine's boost amount).
    var boostAmountMsat = Engine.defaultBoostAmountMsat
    /// The latest error that belongs to no conversation (the engine's own,
    /// a failed observation), shown across the main window until dismissed.
    var notice: String?
    /// The latest error that belongs to a conversation, shown inside it.
    var conversationNotices: [String: String] = [:]
    /// Unread counts and mute levels by chat.
    var readStates: [String: ChatReadState] = [:]
    /// The open chat's read marker as it was when it opened, before it was
    /// marked read: "New messages" goes above the first incoming message
    /// past it. `after` is nil when nothing was unread, and once you send.
    private var newMessages: (chat: String, after: Int64?)?
    /// The open chat, marked unread by hand: it is not marked read again
    /// until you leave it, scroll to its bottom or send in it.
    private var keepsUnread: String?
    /// A message to scroll to and light up once its list shows it (the
    /// chat's, or with `inThread` its thread panel's); see `focus(on:)`.
    var focus: FocusTarget?
    /// The open chat's timeline reaches back to this message (older than
    /// the newest 200), for `focus`.
    private var timelineLimit: Int?
    /// Unread mentions in tribes that are not muted, for the sidebar.
    var unreadMentions: Int {
        readStates.values.reduce(0) { $0 + $1.shownMentions }
    }
    /// Unread messages by each chat's notification level; the Dock badge.
    var unreadCount: Int {
        readStates.values.reduce(0) { $0 + $1.shownUnread }
    }
    /// Why the last attempt to connect failed; cleared once connected.
    var connectionError: String?
    /// When the engine will next try to reconnect, for a live countdown.
    var reconnectAt: Date?
    var restoreProgress = RestoreProgress()
    /// Local notifications and the Dock badge.
    let notifier = Notifier()
    /// Sats arriving: the header's count-up and pill, Payments' unseen count.
    let money = MoneyArrivals()

    /// The app's own account keeps its words in the Keychain. Launching with
    /// `-profile <name>` opens a development profile instead, whose words sit in
    /// a plain file; the window says so.
    private(set) var profile: Profile?
    private(set) var engine: Engine?
    private var messagesTask: Task<Void, Never>?
    private var threadTask: Task<Void, Never>?
    private var tribeTask: Task<Void, Never>?
    /// The open account's observations and event loop, cancelled when it closes.
    /// Their loops skip what a stream still hands over after that.
    private var accountTasks: [Task<Void, Never>] = []
    /// When the PIN was last entered. The PIN itself is never kept.
    private var unlockedAt: Date?

    /// Hours after which the app asks for the PIN again when it comes to the
    /// front; 0 means only at launch. Kept with the account; an account that
    /// has never set it here takes the `pinTimeoutHours` default earlier
    /// builds read, which is left in place.
    private(set) var pinTimeoutHours = 0

    init() {
        do {
            if let development = UserDefaults.standard.string(forKey: "profile") {
                profile = try Profile(name: development, kind: .development)
            } else {
                profile = try Profile(name: "default", kind: .app)
            }
        } catch {
            notice = PeelError.readable(error)
        }
        notifier.model = self
        money.arrived = { [weak self] receipts in
            guard let self else { return }
            notifier.moneyReceived(receipts)
            // Locked, nothing says how much, as the notification does not.
            if phase == .ready, !isLockDue { CopyFeedback.announce("Received \(Receipt.label(receipts))") }
        }
    }

    var usesFileSecrets: Bool { profile?.kind == .development }

    var selectedChat: String? { destination?.chat }

    /// Tribes matching the sidebar search.
    var tribeConversations: [Conversation] { filteredConversations.filter(\.isTribe) }

    /// Direct messages matching the sidebar search.
    var directConversations: [Conversation] { filteredConversations.filter { !$0.isTribe } }

    private var filteredConversations: [Conversation] {
        let query = searchQuery.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return conversations }
        return conversations.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var selectedConversation: Conversation? {
        conversations.first { $0.chat == selectedChat }
    }

    /// The open tribe's details: price, description, whether this account owns it.
    private(set) var selectedTribe: Tribe?

    func start() async {
        guard phase == .loading, let profile else { return }
        guard profile.hasAccount else {
            phase = .onboarding
            return
        }
        guard !profile.requiresPIN else {
            // Left from a session that ended without locking.
            notifier.removeAllDelivered()
            phase = .locked
            return
        }
        do {
            try await open(profile, pin: "")
            enterApp()
        } catch {
            notice = PeelError.readable(error)
            phase = .onboarding
        }
    }

    /// Opens the account with its PIN at launch, or lets the user back in after
    /// the PIN timeout. Throws `SecretStoreFailure.wrongPIN` for a wrong PIN.
    func unlock(pin: String) async throws {
        guard let profile else { return }
        if engine == nil {
            try await open(profile, pin: pin)
        } else {
            // Checking the PIN means deriving its key, which is slow on purpose.
            try await Task.detached { try profile.verifyPIN(pin) }.value
        }
        enterApp()
    }

    /// Removes the account's words and data from this Mac, for when the PIN is
    /// lost. The account itself lives on and can be restored from its words.
    /// If removing fails part-way, the app starts over from whatever is left:
    /// the lock screen while the words remain, onboarding once they are gone.
    func forgetAccount() async throws {
        guard let profile else { return }
        await engine?.close()
        engine = nil
        resetAccountState()
        do {
            try profile.delete()
            phase = .onboarding
        } catch {
            phase = .loading
            await start()
            notice = "Could not forget the account: \(PeelError.readable(error))"
            throw error
        }
    }

    // MARK: Account screen

    /// The name others see on the messages sent from now on. The engine's
    /// `.profile` event updates `myAlias`.
    func setName(_ name: String) async throws {
        try await signedIn().setAlias(name)
    }

    /// An https image link, or empty to remove the photo.
    func setPhotoURL(_ url: String) async throws {
        try await signedIn().setPhotoURL(url)
    }

    /// Works the rows out again when who they name changed (your profile,
    /// the contact), not only when the messages did.
    private func rebuildRows() {
        rebuildChatRows()
        rebuildThreadRows()
    }

    private func rebuildChatRows() {
        guard let chat = selectedChat else { return chatRows = [] }
        chatRows = ChatRow.rows(
            timeline.messages, threads: timeline.threads, parents: timeline.parents, boosts: timeline.boosts,
            requests: timeline.requests, purchases: timeline.purchases, inTribe: isTribe(chat), people: people(in: chat),
            newAfter: newMessagesAfter(in: chat)
        )
    }

    private func rebuildThreadRows() {
        guard let open = openThread, let thread else { return threadRows = [] }
        threadRows = ChatRow.rows(
            thread.messages, parents: thread.parents, boosts: thread.boosts, purchases: thread.purchases,
            inTribe: isTribe(open.chat), people: people(in: open.chat), threadRoot: open.uuid, original: thread.original,
            newAfter: newMessagesAfter(in: open.chat)
        )
    }

    private func newMessagesAfter(in chat: String) -> Int64? {
        newMessages?.chat == chat ? newMessages?.after : nil
    }

    /// You and the contact, as a chat's rows name them.
    func people(in chat: String) -> ChatRow.People {
        let contact = conversations.first { $0.chat == chat }
        return ChatRow.People(
            me: (myAlias ?? "You", myPhotoURL), contact: (contact?.name ?? "Someone", contact?.photoURL)
        )
    }

    func isTribe(_ chat: String) -> Bool {
        conversations.first { $0.chat == chat }?.isTribe ?? false
    }

    /// Uploads a picture from this Mac and makes it the photo.
    func uploadPhoto(_ file: URL) async throws {
        try await signedIn().uploadPhoto(file)
    }

    /// Asks for a picture, beside the window.
    func choosePicture() -> URL? {
        Self.chooseFiles(prompt: "Choose", multiple: false, types: [.image]).first
    }

    /// The twelve words, after the PIN. Nothing here keeps or logs them.
    func revealWords(pin: String) async throws -> [String] {
        guard let profile else { throw PeelError("no profile") }
        return try await Task.detached { try profile.words(pin: pin) }.value
    }

    /// Reseals the words under a new PIN, typed twice.
    func changePIN(from oldPIN: String, to newPIN: String, confirmation: String) async throws {
        guard let profile else { throw PeelError("no profile") }
        guard newPIN == confirmation else { throw PeelError("The new PINs don't match.") }
        try await Task.detached { try profile.changePIN(from: oldPIN, to: newPIN) }.value
    }

    func setPINTimeout(hours: Int) async throws {
        try await signedIn().setPINTimeout(hours: hours)
        pinTimeoutHours = hours
    }

    /// Asks for the PIN again if the timeout has passed. Called when the app
    /// comes to the front.
    func lockIfDue() {
        guard isLockDue else { return }
        Clipboard.clearSecret()
        notifier.removeAllDelivered()
        phase = .locked
    }

    /// The PIN timeout has passed, though Peel may not have come to the front
    /// to lock yet; notifications already say nothing.
    var isLockDue: Bool {
        guard phase == .ready, profile?.requiresPIN == true, pinTimeoutHours > 0, let unlockedAt else { return false }
        return Date.now.timeIntervalSince(unlockedAt) > Double(pinTimeoutHours) * 3600
    }

    /// Peel is quitting: what notifications said must not outlive a PIN.
    func willTerminate() {
        Clipboard.clearSecret()
        if profile?.requiresPIN == true { notifier.removeAllDelivered() }
    }

    /// Creates an account from an invite and returns its twelve words, to show
    /// once. The app opens when the user confirms they wrote them down.
    func createAccount(invite input: String, name: String, pin: String) async throws -> [String] {
        guard let profile else { throw PeelError("no profile") }
        try PIN.validate(pin)
        guard let invite = try? Engine.parseInvite(input) else {
            throw PeelError("That doesn't look like a Sphinx invite.")
        }
        let created = try await Account.signup(profile, invite: invite, alias: name, pin: pin)
        await attach(created.engine)
        return Engine.words(in: created.mnemonic)
    }

    /// Brings an account back from its twelve words, then pulls contacts and
    /// history in the background; `restoreProgress` follows it.
    func restoreAccount(words: [String], name: String, pin: String) async throws {
        guard let profile else { throw PeelError("no profile") }
        try PIN.validate(pin)
        let mnemonic = words.joined(separator: " ")
        let engine = try await Account.restore(profile, mnemonic: mnemonic, alias: name, pin: pin)
        // Reset before the engine starts, so its first progress events are kept.
        restoreProgress = RestoreProgress()
        await attach(engine)
    }

    /// Opens the main window, from onboarding or the lock screen.
    func enterApp() {
        unlockedAt = .now
        phase = .ready
        Task { await notifier.refreshPermission() }
    }

    // MARK: Notifications

    /// Whether Peel is the app in front, where the open chat is being read.
    var isFrontmost: Bool {
        #if os(macOS)
        NSApplication.shared.isActive
        #else
        true
        #endif
    }

    /// Asks the system for permission, after the offer explained it.
    func enableNotifications() async {
        await notifier.requestPermission()
    }

    func dismissNotificationOffer() {
        notifier.dismissOffer()
    }

    func openNotificationSettings() {
        notifier.openSystemSettings()
    }

    /// Off: notifications say only "New message".
    func setNotificationShowsText(_ shows: Bool) async throws {
        try await signedIn().setNotificationShowsText(shows)
        notifier.showsText = shows
    }

    /// A click on a notification: Peel to the front with that chat open,
    /// at the message it was for, or Payments for sats received.
    func openFromNotification(_ chat: String, messageID: Int64?) {
        #if os(macOS)
        NSApplication.shared.activate()
        #endif
        guard phase == .ready || phase == .locked else { return }
        if chat == Notifier.paymentsThread {
            destination = .payments
        } else if let message = messageID.flatMap({ try? engine?.storage.message(id: $0) }), message.chat == chat {
            focus(on: message)
        } else {
            destination = .chat(chat)
        }
    }

    /// Opens a message's chat (with `inThread`, its thread panel) scrolled to
    /// it, lit for a moment. One older than the newest 200 is loaded with
    /// everything after it; one deleted since opens the chat with a notice.
    /// Takes precedence over "New messages".
    func focus(on message: Message, inThread: Bool = false) {
        let chat = message.chat
        guard let storage = engine?.storage else { return }
        // As stored now: it may have been deleted since the list was drawn.
        var current = message
        do {
            if let id = message.id {
                guard let stored = try storage.message(id: id), !stored.deleted else {
                    destination = .chat(chat)
                    conversationNotices[chat] = "That message was deleted"
                    return
                }
                current = stored
            }
        } catch {
            // Could not check; go to it as it was.
        }
        let opening = selectedChat != chat
        if !inThread, opening || !timelineShows(current),
           let limit = try? storage.timelineLimit(reaching: current), limit > Storage.pageSize {
            // Before `focus`, so the list now showing never sees it.
            timelineLimit = max(limit, timelineLimit ?? 0)
            if !opening { observeMessages() }
        }
        focus = FocusTarget(message: current, inThread: inThread)
        if opening { destination = .chat(chat) }
        if inThread { openThread(of: current) }
    }

    /// Whether the open chat's timeline has a row for `message`: its own, or
    /// a collapsed thread's that it is the original of or a reply in.
    private func timelineShows(_ message: Message) -> Bool {
        timeline.messages.contains { $0.id == message.id }
            || message.uuid.map { timeline.threads[$0] != nil } ?? false
            || message.threadUUID.map { timeline.threads[$0] != nil } ?? false
    }

    /// The chat's list is back at its bottom: a timeline grown for a jump
    /// goes back to the newest 200, so later changes re-read only those.
    func chatListAtBottom() {
        guard timelineLimit != nil else { return }
        timelineLimit = nil
        observeMessages()
    }

    func resend(_ message: Message) async {
        guard let id = message.id else { return }
        await attempt("send again", in: message.chat) { try await $0.resend(messageID: id) }
    }

    /// Deletes a message for everyone; a refusal shows in its chat.
    func delete(_ message: Message) async {
        guard let id = message.id else { return }
        await attempt("delete", in: message.chat) { try await $0.deleteMessage(id: id) }
    }

    func discard(_ message: Message) async {
        guard let id = message.id else { return }
        await attempt("discard", in: message.chat) { try await $0.discard(messageID: id) }
    }

    /// Runs an action on one chat; a failure shows above that chat's
    /// composer. Returns whether it succeeded.
    @discardableResult
    func attempt(_ what: String, in chat: String, _ action: (Engine) async throws -> Void) async -> Bool {
        guard let engine else { return false }
        conversationNotices[chat] = nil
        do {
            try await action(engine)
            return true
        } catch {
            conversationNotices[chat] = "Could not \(what): \(PeelError.readable(error))"
            return false
        }
    }

    func dismissNotice(in chat: String) {
        conversationNotices[chat] = nil
    }

    func setMute(_ chat: String, _ level: MuteLevel) async {
        await attempt("change notifications", in: chat) { try await $0.setMute(chat, level: level) }
    }

    func reconnectNow() async {
        await engine?.reconnectNow()
    }

    /// Marks the open chat read while the window is in front, so a message that
    /// arrives while you look at it never shows as unread.
    func markSelectedChatRead() {
        guard let chat = selectedChat else { return }
        noteNewMessages(in: chat)
        guard isFrontmost, phase == .ready, keepsUnread != chat else { return }
        notifier.removeDelivered(in: [chat])
        guard let engine, (readStates[chat]?.unread ?? 0) > 0 else { return }
        Task {
            do {
                try await engine.markRead(chat)
            } catch {
                conversationNotices[chat] = "Could not mark as read: \(PeelError.readable(error))"
            }
        }
    }

    /// Once per opening, as soon as the chat's read state is known and
    /// before it is marked read: where "New messages" goes.
    private func noteNewMessages(in chat: String) {
        guard newMessages?.chat != chat, let state = readStates[chat] else { return }
        newMessages = (chat, state.unread > 0 ? state.lastRead ?? -1 : nil)
        // Rows not loaded yet are built with it when they arrive.
        if newMessages?.after != nil, !timeline.messages.isEmpty { rebuildRows() }
    }

    /// Marks a chat unread from one message on, or from its newest incoming
    /// message. On the open chat it then stays unread while you look, with
    /// "New messages" moved to where it now starts.
    func markUnread(_ chat: String, from message: Message? = nil) async {
        let open = chat == selectedChat
        if open { keepsUnread = chat }
        var marker: Int64?
        let done = await attempt("mark as unread", in: chat) { engine in
            marker = try await engine.markUnread(chat, fromServerIndex: message?.serverIndex)
        }
        // Left and came back meanwhile: the hold has ended, so has this.
        guard open, keepsUnread == chat else { return }
        if done {
            newMessages = (chat, marker)
            rebuildRows()
        } else {
            keepsUnread = nil
        }
    }

    /// The open chat's list reached its bottom: a chat kept unread is read now.
    func reachedBottom(of chat: String) {
        guard keepsUnread == chat else { return }
        keepsUnread = nil
        markSelectedChatRead()
    }

    /// Sending reads the chat (the server moves its marker too); "New
    /// messages" has done its job.
    func sent(in chat: String) {
        if keepsUnread == chat { keepsUnread = nil }
        // The sent message's row rebuilds the rest without it.
        if newMessages?.chat == chat { newMessages = (chat, nil) }
    }

    /// What a tribe link points to, to show before paying to join.
    func previewTribe(_ link: String) async throws -> TribeInfo {
        guard let engine else { throw PeelError("not signed in") }
        return try await engine.tribeInfo(link: link)
    }

    /// Joins a tribe from its link, paying only the price shown, and opens it.
    func joinTribe(_ link: String, agreedJoinMsat: UInt64) async throws {
        guard let engine else { return }
        let tribe = try await engine.joinTribe(link: link, agreedJoinMsat: agreedJoinMsat)
        destination = .chat(tribe.pubkey)
    }

    func leaveTribe(_ pubkey: String) async throws {
        guard let engine else { return }
        try await engine.leaveTribe(pubkey)
        if selectedChat == pubkey { destination = nil }
    }

    func tribeMembers(_ pubkey: String) async throws -> TribeMembers {
        try await signedIn().tribeMembers(pubkey)
    }

    /// Creates a tribe owned by this account and opens it.
    func createTribe(_ settings: TribeSettings) async throws {
        let tribe = try await signedIn().createTribe(settings)
        destination = .chat(tribe.pubkey)
    }

    func tribeSettings(_ pubkey: String) async throws -> TribeSettings {
        try await signedIn().tribeSettings(pubkey)
    }

    func updateTribe(_ pubkey: String, _ settings: TribeSettings) async throws {
        try await signedIn().updateTribe(pubkey, settings: settings)
    }

    func deleteTribe(_ pubkey: String) async throws {
        try await signedIn().deleteTribe(pubkey)
        if selectedChat == pubkey { destination = nil }
    }

    func kick(_ member: String, from pubkey: String) async throws {
        try await signedIn().kickMember(member, from: pubkey)
    }

    func answerJoinRequest(in pubkey: String, _ request: Engine.JoinRequest, approve: Bool) async throws {
        try await signedIn().answerJoinRequest(in: pubkey, request, approve: approve)
    }

    /// Answers a request shown in the open tribe; a failure shows above its
    /// composer. Returns whether the answer went out.
    func answerJoinRequest(_ message: Message, approve: Bool) async -> Bool {
        guard let uuid = message.uuid else { return false }
        return await attempt(approve ? "approve" : "decline", in: message.chat) {
            try await $0.answerJoinRequest(in: message.chat, .message(uuid: uuid), approve: approve)
        }
    }

    /// Pins a message (by uuid) for every member, or unpins with nil.
    func pin(_ uuid: String?, in pubkey: String) async {
        await attempt(uuid == nil ? "unpin" : "pin", in: pubkey) { try await $0.pinMessage(uuid, in: pubkey) }
    }

    /// Who can be @mentioned in a tribe, read off the main thread.
    func mentionCandidates(in pubkey: String) async -> [TribeMember] {
        guard let storage = engine?.storage else { return [] }
        return await Task.detached { (try? storage.mentionCandidates(in: pubkey)) ?? [] }.value
    }

    /// Tribe messages that mention this account, newest first, as they change.
    /// Followed only while the Mentions list is open.
    func mentionUpdates() -> (some AsyncSequence<[Message], any Error>)? {
        engine?.storage.mentions()
    }

    /// This account's key, which names it on a tribe's member list.
    var myPubkey: String? {
        myContactInfo?.split(separator: "_").first.map(String.init)
    }

    func signedIn() throws -> Engine {
        guard let engine else { throw PeelError("not signed in") }
        return engine
    }

    /// Adds a contact from the contact info they shared.
    func addContact(_ contactInfo: String, alias: String) async throws {
        guard let engine else { return }
        let alias = alias.trimmed
        try await engine.addContact(contactInfo.trimmed, alias: alias.isEmpty ? nil : alias)
    }

    private func open(_ profile: Profile, pin: String) async throws {
        // Loading derives keys and opens the database; keep it off the main thread.
        let engine = try await Task.detached { try await Account.load(profile, pin: pin) }.value
        await attach(engine)
    }

    /// Drops everything shown about the account that was open.
    private func resetAccountState() {
        accountTasks.forEach { $0.cancel() }
        accountTasks = []
        Clipboard.clearSecret()
        conversations = []
        destination = nil
        timeline = .empty
        openThread = nil
        threads = []
        replyTargets = [:]
        // Peel's own pasted or promised files: in a tray, or under a failed upload.
        (pendingFiles.values.joined() + attachmentHandles.values.compactMap(\.localFile))
            .forEach { IncomingFiles.discard($0) }
        pendingFiles = [:]
        viewer = nil
        attachmentHandles = [:]
        drafts = [:]
        chatRows = []
        threadRows = []
        readStates = [:]
        conversationNotices = [:]
        notice = nil
        restoreProgress = RestoreProgress()
        myAlias = nil
        myPhotoURL = nil
        myContactInfo = nil
        myServer = nil
        money.reset()
        balanceMsat = nil
        paymentConfirmationMsat = Engine.defaultPaymentConfirmationMsat
        moneyInFlight = []
        boostAmountMsat = Engine.defaultBoostAmountMsat
        unlockedAt = nil
        notifier.reset()
    }

    private func attach(_ engine: Engine) async {
        // An error from before this account opened no longer applies.
        notice = nil
        self.engine = engine
        let storage = engine.storage
        myAlias = await engine.myAlias
        myPhotoURL = await engine.myPhotoURL
        myContactInfo = try? storage.value(for: .contactInfo)
        myServer = try? storage.value(for: .server)
        pinTimeoutHours = ((try? await engine.pinTimeoutHours()) ?? nil)
            ?? UserDefaults.standard.integer(forKey: "pinTimeoutHours")
        balanceMsat = try? storage.balanceMsat()
        paymentConfirmationMsat = (try? await engine.paymentConfirmationMsat()) ?? Engine.defaultPaymentConfirmationMsat
        boostAmountMsat = (try? await engine.boostAmountMsat()) ?? Engine.defaultBoostAmountMsat
        connection = await engine.connection
        let showsText = (try? await engine.notificationShowsText()) ?? false
        // Forgotten while loading.
        guard self.engine === engine else { return }
        notifier.attach(storage, showsText: showsText)
        // A notification clicked on the lock screen chose the chat before there was an engine.
        if selectedChat != nil { observeMessages() }
        accountTasks = [
            Task { await self.observeConversations(storage) },
            Task { await self.observeReadStates(storage) },
            Task { await self.observeThreads(storage) },
            Task { await self.consumeEvents(engine) },
        ]
        await engine.start()
    }

    private func consumeEvents(_ engine: Engine) async {
        for await event in engine.events where !Task.isCancelled {
            switch event {
            case .connection(let state):
                connection = state
                if state == .connected { connectionError = nil }
                if case .offline(let seconds?) = state {
                    reconnectAt = .now.addingTimeInterval(TimeInterval(seconds))
                } else {
                    reconnectAt = nil
                }
            case .conversationError(let chat, let message):
                conversationNotices[chat] = message
            case .connectionError(let message):
                connectionError = message
            case .registered(let contactInfo):
                myContactInfo = contactInfo
            case .balance(let msat):
                balanceMsat = msat
            case .coreError(let message):
                notice = message
            case .history(let phase, let reached, let end):
                switch phase {
                case .contacts: restoreProgress.contacts = .init(reached: reached, end: end)
                case .messages: restoreProgress.messages = .init(reached: reached, end: end)
                }
            case .historyDone:
                restoreProgress.outcome = .finished
                notifier.historyEnded()
            case .profile(let alias, let photoURL):
                myAlias = alias
                myPhotoURL = photoURL
                rebuildRows()
            case .historyFailed(let reason):
                restoreProgress.outcome = .failed(reason)
                notifier.historyEnded()
            case .transfer(let id, _, let bytes, let total):
                attachment(id).transfer(bytes: bytes, total: total)
            case .message(let row, _) where row.deleted:
                // Its decrypted file is gone; nothing may still point at it.
                if let id = row.id { attachmentHandles[id] = nil }
            case .message(let message, let arrival):
                notifier.received(message, arrival)
            case .moneyReceived(let message):
                money.received(Receipt(message))
            case .invoicePaid(let invoice):
                money.received(Receipt(invoice))
            case .sendStatus:
                break
            }
        }
    }

    private func observeConversations(_ storage: Storage) async {
        do {
            for try await rows in storage.conversations() where !Task.isCancelled {
                let open = { (rows: [Conversation]) in rows.first { $0.chat == self.selectedChat } }
                let changed = open(conversations) != open(rows)
                conversations = rows
                // Rows carry the contact's name and photo, and whether it is a tribe.
                if changed { rebuildRows() }
                if destination == nil, let first = rows.first {
                    destination = .chat(first.chat)
                }
            }
        } catch {
            if !Task.isCancelled { notice = PeelError.readable(error) }
        }
    }

    private func observeReadStates(_ storage: Storage) async {
        do {
            for try await states in storage.readStates() where !Task.isCancelled {
                let previous = readStates
                readStates = states
                notifier.readStatesChanged(to: states, from: previous, unread: unreadCount)
                markSelectedChatRead()
            }
        } catch {
            if !Task.isCancelled { notice = PeelError.readable(error) }
        }
    }

    /// Follows the open chat's messages and, for a tribe, its details, which a
    /// join or a registry refresh can change.
    private func observeMessages() {
        messagesTask?.cancel()
        tribeTask?.cancel()
        timeline = .empty
        chatRows = []
        selectedTribe = nil
        guard let storage = engine?.storage, let chat = selectedChat else { return }
        messagesTask = Task {
            do {
                for try await timeline in storage.timeline(
                    in: chat, limit: timelineLimit ?? Storage.pageSize
                ) where !Task.isCancelled {
                    self.timeline = timeline
                    rebuildChatRows()
                }
            } catch {
                if !Task.isCancelled { notice = PeelError.readable(error) }
            }
        }
        tribeTask = Task {
            do {
                for try await tribe in storage.tribe(chat) where !Task.isCancelled {
                    selectedTribe = tribe
                }
            } catch {
                if !Task.isCancelled { notice = PeelError.readable(error) }
            }
        }
    }

    /// Follows the thread open in the side panel.
    private func observeThread() {
        threadTask?.cancel()
        thread = nil
        threadRows = []
        guard let storage = engine?.storage, let open = openThread else { return }
        threadTask = Task {
            do {
                for try await thread in storage.thread(open.uuid, in: open.chat) where !Task.isCancelled {
                    self.thread = thread
                    rebuildThreadRows()
                }
            } catch {
                if !Task.isCancelled { notice = PeelError.readable(error) }
            }
        }
    }

    private func observeThreads(_ storage: Storage) async {
        do {
            for try await rows in storage.threads() where !Task.isCancelled {
                threads = rows
            }
        } catch {
            if !Task.isCancelled { notice = PeelError.readable(error) }
        }
    }
}

private extension AppModel.Destination {
    var chat: String? {
        if case .chat(let chat) = self { chat } else { nil }
    }
}
