import Foundation
import Observation
import AgentKit
import PeelCore
import PeelDiagnostics

/// Everything the windows show, kept current from the engine and storage.
@MainActor @Observable
public final class AppModel {
    public enum Phase: Sendable { case loading, locked, onboarding, ready }

    /// How far a restore from twelve words has got, and why history (a
    /// restore's or a catch-up's) stopped, until it resumes.
    public struct RestoreProgress: Sendable {
        public struct Count: Sendable {
            public var reached: UInt64
            public var end: UInt64?

            public var fraction: Double? {
                guard let end, end > 0 else { return nil }
                return min(1, Double(reached) / Double(end))
            }
        }

        public enum Outcome: Sendable { case finished, failed(String) }

        /// A restore from the words has not finished, this launch or an earlier one.
        public var restoring = false
        public var contacts: Count?
        public var messages: Count?
        public var outcome: Outcome?

        public var finished: Bool {
            if case .finished = outcome { true } else { false }
        }

        public var paused: String? {
            if case .failed(let reason) = outcome { reason } else { nil }
        }

        /// A count's line on the restore screen: "120 of 300", "35 checked",
        /// or before any, "Waiting" ("None" once finished).
        public func label(_ count: Count?, noun: String) -> String {
            guard let count else { return finished ? "None" : "Waiting" }
            if let end = count.end { return "\(count.reached.formatted()) of \(end.formatted())" }
            return "\(count.reached.formatted()) \(noun)"
        }

        /// One line of the restore screen: what it is, its count or the
        /// connection, and how far along it is.
        public struct Line: Sendable {
            public enum State: Sendable { case waiting, active, done }

            public let title: String
            public let detail: String
            public let state: State
            public var fraction: Double?
        }

        /// The restore screen's lines: the account (its connection), then
        /// contacts, then messages, as the server sends them back.
        public func lines(connection: Engine.ConnectionState) -> [Line] {
            func state(started: Bool, done: Bool) -> Line.State {
                done ? .done : started ? .active : .waiting
            }
            return [
                Line(title: "Account", detail: connection.label, state: connection == .connected ? .done : .active),
                Line(title: "Contacts", detail: label(contacts, noun: "checked"),
                     state: state(started: contacts != nil, done: messages != nil || finished)),
                Line(title: "Messages", detail: label(messages, noun: "received"),
                     state: state(started: messages != nil, done: finished), fraction: messages?.fraction),
            ]
        }
    }

    /// What the sidebar has selected.
    public enum Destination: Hashable, Sendable {
        case threads, mentions, automations, payments, account
        /// The agent chat, Peel's own row in Direct messages.
        case agent
        case chat(String)
        /// Every app listed: on the Mac the person's own and those the
        /// workspaces pinned (`AppsView`), on the iPhone the workspaces'.
        case apps
        /// An app a Stadeum workspace pinned, by the workspace's peer id and
        /// the app's name there, or one of the person's own (no peer); the
        /// Mac's alone, shown by its own strut.
        case app(peer: String?, name: String)
    }

    /// Account's categories, listed where the sidebar was while it is open.
    public enum AccountPage: Hashable, Sendable, CaseIterable {
        case profile, payments, assistant, brain, connections, dictation, notifications, security
    }

    public var phase: Phase = .loading {
        // Locked, no call is watched.
        didSet {
            if phase != oldValue {
                TimelineLog.log("app phase \(oldValue) -> \(phase)")
                calls.watchesRecent = phase == .ready
                phaseChanged(phase)
            }
        }
    }
    /// The Mac's dictation drops what it holds of the account when it locks or closes.
    @ObservationIgnored public var phaseChanged: @MainActor (Phase) -> Void = { _ in }
    public var connection: Engine.ConnectionState = .offline(retryIn: nil)
    public var conversations: [Conversation] = []
    /// The open chat's main conversation: in a tribe with threads collapsed,
    /// plus the messages its replies quote.
    public var timeline = Timeline.empty
    /// The chat whose messages `timeline` and `chatRows` hold: nil from a
    /// reset until they have loaded, so the chat's list is made once, with
    /// them, rather than empty and then again.
    public private(set) var loadedChat: String?
    public var destination: Destination? {
        didSet {
            if destination == .account, oldValue != .account { accountReturn = oldValue }
            // The agent chat is its DM while it has one (`agentChat`).
            followAgentChat()
            if selectedChat != oldValue?.chat {
                heldUnread = selectedChat.flatMap { readStates[$0] }.flatMap { $0.isUnread ? $0 : nil }
                newMessages = nil
                keepsUnread = nil
                // A jump into this chat (`focus(on:)`) set both just before.
                if focus?.message.chat != selectedChat {
                    focus = nil
                    timelineWindow = nil
                }
                newestLimit = Storage.pageSize
                loadingOlder = false
                observeMessages()
                checkOwnMessageStatus()
                if openThread?.chat != selectedChat { openThread = nil }
                if search?.chat != selectedChat { search = nil }
            }
            markSelectedChatRead()
        }
    }
    /// The search open in the chat, if any (`ChatSearch.swift`).
    public var search: ChatSearch?
    /// The thread open in the side panel, and what it holds.
    public var openThread: ThreadRef? {
        didSet { if openThread != oldValue { observeThread() } }
    }
    public private(set) var thread: ChatThread?
    /// Threads this account started or wrote in, for the Threads list.
    public private(set) var threads: [ThreadSummary] = []
    /// What each composer is replying to.
    public var replyTargets: [ComposerID: Message] = [:]
    /// Files waiting in each composer until it sends.
    public var pendingFiles: [ComposerID: [URL]] = [:]
    /// The composer files are being dragged towards, for its overlay.
    public var dropTarget: ComposerID?
    /// The price in sats, as typed, the files in a composer are sold for; empty for free.
    public var attachmentPrices: [ComposerID: String] = [:]
    /// The composer whose Send sats panel is open, from its bolt.
    public var sendingSats: ComposerID?
    /// Bumped to put the cursor in a composer.
    public var composerFocus: [ComposerID: Int] = [:]
    /// The sidebar has the keyboard (a row was clicked): a chat opened from
    /// it leaves the cursor out of its composer, so the arrows go on moving.
    public var sidebarHasKeys = false
    /// The image viewer, when open.
    public var viewer: ImageViewerState?
    /// What each composer holds unsent, kept while a thread covers its
    /// chat or another chat is open.
    public var drafts: [ComposerID: String] = [:]
    /// The agent's device requests whose cards wait on you, by the agent's
    /// chat, then request id: their lines draw the card (`ChatRow.approval`).
    public var waitingCards: [String: [String: ToolIntent]] = [:] {
        didSet { if waitingCards[selectedChat ?? ""] != oldValue[selectedChat ?? ""] { rebuildChatRows() } }
    }
    /// The open chat's rows and the open thread's, worked out once per
    /// change of what they show rather than on every redraw.
    public private(set) var chatRows: [ChatRow] = [] {
        didSet { calls.refreshRecent(from: chatRows) }
    }
    public private(set) var threadRows: [ChatRow] = []
    /// The engine's aliases each tribe echoed back on your messages
    /// (`Engine.echoedOwnAliases`), and from them and your name what a
    /// mention of you looks like in each tribe and elsewhere
    /// (`mentionAliases(in:)`), worked out when either changes.
    @ObservationIgnored private var echoedAliases: [String: Set<String>] = [:]
    private var tribeMentionAliases: [String: Set<String>] = [:]
    private var plainMentionAliases: Set<String> = []
    /// Downloads, uploads and local copies of attachments, by message id;
    /// each observed on its own so a progress tick redraws only its tile.
    @ObservationIgnored public var attachmentHandles: [Int64: AttachmentHandle] = [:]
    /// The main window's menus and panels (`peelMenuHost(main:)`).
    @ObservationIgnored public weak var mainPresenter: (any MenuHosting)?
    /// The sidebar's search, which filters its lists.
    public var searchQuery = ""
    /// Which sidebar sections are open and shown in full, kept with the
    /// account (`Engine.sidebarLayout`).
    public var sidebarLayout = ChatSections.Layout() {
        didSet {
            guard sidebarLayout != savedLayout, let engine else { return }
            savedLayout = sidebarLayout
            let layout = sidebarLayout
            Task { try? await engine.setSidebarLayout(layout) }
        }
    }
    /// The layout as the account has it, so loading it saves nothing.
    @ObservationIgnored private var savedLayout = ChatSections.Layout()
    /// The open chat's read state as it was when it was opened from Unread
    /// (`sidebarSections`).
    private var heldUnread: ChatReadState?
    /// Bumped to put the cursor in the sidebar's search (⌘F with no chat open).
    public var sidebarSearchFocus = 0
    public var myAlias: String?
    /// The photo sent with this account's messages, https or nil.
    public var myPhotoURL: String?
    public var myContactInfo: String? {
        didSet { myHue = PersonHue(pubkey: myPubkey ?? "", alias: nil, inTribe: false) }
    }
    /// The server this account talks to, as `host:port`.
    public var myServer: String?
    public var balanceMsat: UInt64? {
        didSet { if let balanceMsat { money.balance(balanceMsat) } }
    }
    /// Sats promised to people still offline (`Storage.waitingMsat`): still
    /// in the balance, but not to be spent again.
    public var waitingMsat: UInt64 = 0
    /// Whether the account's twelve words were checked (`Engine.wordsConfirmed`);
    /// true until the account loads, so nothing asks before it is known.
    public var wordsConfirmed = true
    /// "4,000 waiting", shown beside the balance; nil when nothing waits.
    public var waitingText: String? { waitingMsat > 0 ? "\(Sats.number(msat: waitingMsat)) waiting" : nil }
    /// "4,996 sats · 4,000 waiting"; nil until the server reports a balance.
    public var balanceText: String? { balanceMsat.map { Sats.format(msat: $0) + (waitingText.map { " · \($0)" } ?? "") } }
    /// Payments and boosts over this ask for a second click (`Engine`'s threshold).
    public var paymentConfirmationMsat = Engine.defaultPaymentConfirmationMsat
    /// Payments and boosts on their way to the engine, so a double click
    /// never sends one twice.
    @ObservationIgnored public var moneyInFlight: Set<String> = []
    /// What the one-tap Boost tips (the engine's boost amount).
    public var boostAmountMsat = Engine.defaultBoostAmountMsat
    /// A one-tap boost amount from another device the last Boost asked to
    /// confirm (`quickBoost`), and the notice that asked: the next Boost of
    /// that message sends it while the notice is still shown.
    @ObservationIgnored public var boostToConfirm: (messageID: Int64, msat: UInt64, notice: String)?
    /// Run headers' looked-up sender zones (nil: none), by chat, then
    /// alias and moment; see `withSenderZones`.
    @ObservationIgnored public var senderZoneCache: [String: [String: TimeZone?]] = [:]
    /// The senders whose zones are being read, by chat.
    @ObservationIgnored public var senderZonesAsked: [String: Set<String>] = [:]
    /// The latest error that belongs to no conversation (the engine's own,
    /// a failed observation), shown across the main window until dismissed.
    public var notice: String?
    /// Peel recorded a problem from the last run (a crash, or ended while it
    /// was in front): the notice offers the record (`AppModel+Diagnostics`).
    public var diagnosticsNotice = Diagnostics.previousRun().isProblem
    /// The record's text while its sheet is open.
    public var diagnosticsRecord: DiagnosticRecord?
    /// The notice a failed background check with the server put up
    /// (`Engine.Event.serverCheckError`): dismissed by itself once connected.
    @ObservationIgnored private var serverCheckNotice: String?
    /// The latest error that belongs to a conversation, shown inside it.
    public var conversationNotices: [String: String] = [:]
    /// Unread counts and mute levels by chat.
    public var readStates: [String: ChatReadState] = [:]
    /// The open chat's read marker as it was when it opened, before it was
    /// marked read: "New messages" goes above the first incoming message
    /// past it. `after` is nil when nothing was unread, and once you send.
    private var newMessages: (chat: String, after: Int64?)? {
        didSet { newMessagesReached = false }
    }
    /// The chat's list has stood at its newest since "New messages" was
    /// placed: it stays drawn for the visit, but a list made again opens
    /// where it was (`anchor(of:)`), not at it. Read only as a list is made.
    @ObservationIgnored private var newMessagesReached = false
    /// Where each list stood when last still, by its composer: the chat's
    /// and each thread's, kept while Peel runs. Not observed: a list reads
    /// it only when it is made.
    @ObservationIgnored private var listAnchors: [ComposerID: ListAnchor] = [:]
    /// The open chat, marked unread by hand: it is not marked read again
    /// until you leave it, scroll to its bottom or send in it.
    private var keepsUnread: String?
    /// A message to scroll to and light up once its list shows it (the
    /// chat's, or with `inThread` its thread panel's); see `focus(on:)`.
    public var focus: FocusTarget?
    /// For `focus` on a message older than the newest 200: the open chat's
    /// timeline is a window from just before it, not its newest messages,
    /// so each change re-reads that window rather than everything since.
    /// Reaching the window's bottom takes it further (`chatListAtBottom`).
    private var timelineWindow: (start: TimelineStart, limit: Int)?
    /// How many of the open chat's newest messages its timeline reads, when
    /// no jump's window is open: a page more each time the list asks for
    /// older ones (`loadOlder`), back to one page on opening a chat.
    private var newestLimit = Storage.pageSize
    /// Whether the open chat may have messages above its timeline: it reads
    /// its newest messages, and as many came as were asked for.
    public var mayHaveOlder: Bool {
        timelineWindow == nil && timeline.messages.count >= newestLimit
    }
    /// Whether the open chat shows a jump's window rather than its newest messages.
    public var showsWindow: Bool { timelineWindow != nil }
    /// An older page asked for (`loadOlder`) and not here yet.
    public private(set) var loadingOlder = false
    /// Whether the open chat's list ends at its newest message: false while
    /// a window short of it is open.
    public var timelineReachesNewest: Bool {
        guard let timelineWindow else { return true }
        return timeline.messages.count < timelineWindow.limit
    }
    /// Unread mentions, muted chats too, for the sidebar's Mentions row:
    /// they agree with the rows' gold counts (`sidebarCount`).
    public var unreadMentions: Int {
        readStates.values.reduce(0) { $0 + $1.mentions }
    }
    /// Unread messages by each chat's notification level; the Dock badge.
    public var unreadCount: Int {
        readStates.values.reduce(0) { $0 + $1.shownUnread }
    }
    /// Why the last attempt to connect failed; cleared once connected.
    public var connectionError: String?
    /// When the engine will next try to reconnect, for a live countdown.
    public var reconnectAt: Date?
    public private(set) var checkingConnection = false
    public var showingConnection = false
    public var restoreProgress = RestoreProgress()
    /// Local notifications and the Dock badge.
    public let notifier: Notifier
    /// Sats arriving: the header's count-up and pill, Payments' unseen count.
    public let money = MoneyArrivals()
    /// Calls: presence, the recent calls, and the call this device is on.
    public let calls: CallStore
    /// The person's Stadeum workspaces, paired on this device, and the apps listed.
    public let stadeum = Stadeum()
    /// What the app supplies: panels, the clipboard, playback, calls, presence.
    @ObservationIgnored public let platform: Platform
    /// The web pane beside the chat, with this profile's website data.
    @ObservationIgnored public private(set) lazy var webPresenter = platform.web(profile)
    /// The agent's tools, memory and automations, where the platform has them.
    public var agentHost: (any AgentHost)? { platform.agent }

    /// The app's own account keeps its words in the Keychain. Launching with
    /// `-profile <name>` opens a development profile instead, whose words sit in
    /// a plain file; the window says so.
    public private(set) var profile: Profile?
    public private(set) var engine: Engine?
    /// The account's agent on this Mac (`AppModel+Agent`), open with the
    /// account: its model, name and rules, and the earlier local chat.
    public var agent: AgentSession?
    /// The agent's own contact, whose DM is the agent chat
    /// (docs/agent-on-strut.md, "One conversation"), set by the Mac app; on
    /// the phone always the account's agent. Nil until the agent has its own
    /// account, and the agent chat is the local one (`Destination.agent`),
    /// read only, with its set-up.
    public var agentContact: String? {
        didSet { if agentContact != oldValue { followAgentChat() } }
    }

    /// The agent's DM, once its contact is a chat here: the agent's one row,
    /// never a direct message beside it, and where `.agent` opens.
    public private(set) var agentChat: String?

    /// Your message the agent is still answering in its open DM
    /// (`AgentDM.unanswered`), worked out with its rows; nil over a jump's
    /// window, which may stop between your message and its reply.
    public private(set) var agentUnanswered: Message?

    /// Where the agent's row goes: its DM while that is the agent chat.
    public var agentDestination: Destination { agentChat.map(Destination.chat) ?? .agent }

    /// The agent's DM as the agent chat, both ways: the agent chat open when
    /// its DM comes is the DM; the DM open when it stops being the agent
    /// chat (the brain moved off this Mac) is the agent chat again.
    /// The agent's contact once it is a chat here: ready, for the phone's agent row.
    static func agentChat(contact: String?, in conversations: [Conversation]) -> String? {
        contact.flatMap { contact in conversations.contains { $0.chat == contact } ? contact : nil }
    }

    private func followAgentChat() {
        let chat = Self.agentChat(contact: agentContact, in: conversations)
        if chat != agentChat {
            let old = agentChat
            agentChat = chat
            if chat == nil { agentUnanswered = nil }
            // Not as the account closes, which takes the agent first.
            if let old, agent != nil, destination == .chat(old) { destination = .agent }
            // The same for where Account's Chats goes back to (the brain moved from Account › Brain).
            if let old, agent != nil, accountReturn == .chat(old) { accountReturn = .agent }
            if selectedChat == chat || selectedChat == old { rebuildChatRows() }
        }
        if destination == .agent, let agentChat { destination = .chat(agentChat) }
    }
    /// Where the Connect panel is open from, if it is.
    public var agentConnectFrom: AgentConnectSource?
    /// The Account category shown, kept while Account is closed (`openAccount`).
    public var accountPage = AccountPage.profile
    /// What Account's Chats goes back to: what was open before it (`closeAccount`).
    private var accountReturn: Destination?
    private var messagesTask: Task<Void, Never>?
    private var threadTask: Task<Void, Never>?
    private var pinTask: Task<Void, Never>?
    /// The open account's observations and event loop, cancelled when it closes.
    /// Their loops skip what a stream still hands over after that.
    private var accountTasks: [Task<Void, Never>] = []
    /// When the person last used Peel: the PIN entered, then each key press,
    /// click or scroll in its windows (`noteActivity`). The PIN timeout
    /// counts from here. The PIN itself is never kept.
    @ObservationIgnored private var lastActiveAt: Date?

    /// Hours without use after which the app asks for the PIN again, in
    /// front or not; 0 means only at launch. A preference of this device
    /// (the PIN is this device's); one never set here takes the
    /// `pinTimeoutHours` default earlier builds read, which is left in place.
    public private(set) var pinTimeoutHours = 0

    public init(platform: Platform) {
        self.platform = platform
        notifier = Notifier(presence: platform.presence)
        calls = CallStore(provider: platform.calls)
        do {
            if let development = UserDefaults.standard.string(forKey: "profile") {
                profile = try Profile(name: development, kind: .development)
            } else {
                profile = try Profile(name: "default", kind: .app)
            }
        } catch {
            notice = PeelError.noted(error)
        }
        notifier.model = self
        calls.chatTitle = { [weak self] chat in self?.chatTitle(chat) ?? "Call" }
        calls.chatNotice = { [weak self] chat, change in
            guard let self else { return }
            let notice = change(conversationNotices[chat])
            // An unchanged notice is not written, so the open chat does not redraw.
            if notice != conversationNotices[chat] { conversationNotices[chat] = notice }
        }
        money.arrived = { [weak self] receipts in
            guard let self else { return }
            notifier.moneyReceived(receipts)
            // Locked, nothing says how much, as the notification does not.
            if phase == .ready, !isLockDue { CopyFeedback.announce("Received \(Receipt.label(receipts))") }
        }
    }

    public var usesFileSecrets: Bool { profile?.kind == .development }

    public var selectedChat: String? { destination?.chat }

    /// The sidebar's chats as shown: Unread, then the recent tribes and
    /// direct messages, matching its search. The open chat, unread when it
    /// was opened, stays in Unread until another is opened, so it does not
    /// jump away as it is read and ⌥⇧↓ goes on from it.
    public var sidebarSections: ChatSections {
        var states = readStates
        if let heldUnread, heldUnread.chat == selectedChat, states[heldUnread.chat]?.isUnread != true {
            states[heldUnread.chat] = heldUnread
        }
        // The agent's DM is the agent's own row.
        let chats = agentChat.map { agent in conversations.filter { $0.chat != agent } } ?? conversations
        return ChatSections(chats, states: states, layout: sidebarLayout, query: searchQuery, open: selectedChat)
    }

    /// Go › Next (⌥⇧↓) or Previous (⌥⇧↑) Unread Chat: the next chat in the
    /// sidebar's Unread section, going round. From anywhere in the main
    /// window, as ⌘F (`takesCommands`).
    public func openUnread(by offset: Int) {
        guard takesCommands, let chat = sidebarSections.unread(from: selectedChat, by: offset) else { return }
        destination = .chat(chat)
    }

    /// Account, at one of its categories: the agent chat's gear, a Peel Home
    /// link, the dictation offer.
    public func openAccount(_ page: AccountPage) {
        accountPage = page
        destination = .account
    }

    /// Account's Chats: back to what was open before, unless it went
    /// meanwhile (a chat left or deleted, the agent's chat or automations
    /// with the agent gone).
    public func closeAccount() {
        switch accountReturn {
        case .chat(let chat)? where !conversations.contains(where: { $0.chat == chat }):
            destination = nil
        case .agent? where agent == nil, .automations? where agent == nil:
            destination = nil
        default:
            destination = accountReturn
        }
    }

    /// The open account's database while it is unlocked; nil when locked,
    /// though locking leaves the engine open, or when no account is open.
    /// What may be read or written for the person outside the main window
    /// (the Mac's Dictation History).
    public var unlockedStorage: Storage? {
        phase == .ready && !isLockDue ? engine?.storage : nil
    }

    /// Whether a menu command may act on the main window: unlocked, the
    /// main window key (not the call window or a Peel panel), no Peel menu
    /// or panel and no image viewer up.
    /// Checked in the action, never through `.disabled`, which a command
    /// does not follow (#131).
    public var takesCommands: Bool {
        guard phase == .ready, !isLockDue, viewer == nil, let presenter = mainPresenter,
              !presenter.anythingOpen else { return false }
        return presenter.hostsKeyWindow
    }

    public var selectedConversation: Conversation? {
        conversations.first { $0.chat == selectedChat }
    }

    /// Every tribe's details by pubkey, joined or left: price, description,
    /// the pin, whether this account owns it.
    public private(set) var tribes: [String: Tribe] = [:]
    /// Tribes linked in messages, by link, as their cards last read them.
    public private(set) var linkedTribes: [TribeLink: LinkedTribe] = [:]
    /// Each tribe's members as last read (`tribeMembers`), for the counts
    /// shown outside the Members panel (`TribeMembers.countLabel`).
    public private(set) var knownMembers: [String: TribeMembers] = [:]
    @ObservationIgnored private var readingMembers: Set<String> = []
    /// The open tribe's pinned message, read from storage however old.
    public private(set) var pinnedMessage: Message?
    /// Invites made here by code, and those still waiting to be used,
    /// newest first.
    public private(set) var invites: [String: InviteRecord] = [:]
    public private(set) var pendingInvites: [InviteRecord] = []

    public func start() async {
        guard phase == .loading, let profile else { return }
        Diagnostics.setAction(.launch)
        defer { Diagnostics.setAction(.other) }
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
            notice = PeelError.noted(error, couldNot: "open the account")
            phase = .onboarding
        }
    }

    /// Opens the account with its PIN at launch, or lets the user back in after
    /// the PIN timeout. Throws `SecretStoreFailure.wrongPIN` for a wrong PIN.
    public func unlock(pin: String) async throws {
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
    public func forgetAccount() async throws {
        guard let profile else { return }
        await engine?.close()
        engine = nil
        resetAccountState()
        await webPresenter.forgetWebsiteData()
        do {
            // What the agent remembered and the automations it ran go too.
            try agentHost?.forget(profile)
            try profile.delete()
            phase = .onboarding
        } catch {
            phase = .loading
            await start()
            notice = PeelError.noted(error, couldNot: "forget the account")
            throw error
        }
    }

    // MARK: Account screen

    /// The name others see on the messages sent from now on. The engine's
    /// `.profile` event updates `myAlias`.
    public func setName(_ name: String) async throws {
        try await signedIn().setAlias(name)
    }

    public func removePhoto() async throws {
        try await signedIn().setPhotoURL("")
    }

    /// Works the rows out again when who they name changed (your profile,
    /// the contact), not only when the messages did.
    public func rebuildRows() {
        rebuildChatRows()
        rebuildThreadRows()
    }

    private func rebuildChatRows() {
        guard let chat = selectedChat else { return chatRows = [] }
        let rows = withSenderZones(ChatRow.rows(
            timeline.messages, threads: timeline.threads, parents: timeline.parents, boosts: timeline.boosts,
            requests: timeline.requests, purchases: timeline.purchases, inTribe: isTribe(chat), people: people(in: chat),
            callServer: calls.server, newAfter: newMessagesAfter(in: chat), approvals: waitingCards[chat] ?? [:],
            agentDM: chat == agentChat
        ), in: chat)
        agentUnanswered = chat == agentChat && timelineReachesNewest ? AgentDM.unanswered(in: timeline.messages) : nil
        // Setting the same rows still redraws the list and diffs every row.
        // Recent calls age with the clock, so they are looked at again anyway.
        TimelineLog.log("\(TimelineLog.tag(chat)) rows built: \(rows.count) (changed \(rows != chatRows)), "
            + "new messages at \(rows.firstIndex(where: \.startsNew).map { "\($0)" } ?? "none")")
        if rows != chatRows { chatRows = rows } else { calls.refreshRecent(from: rows) }
    }

    private func rebuildThreadRows() {
        guard let open = openThread, let thread else { return threadRows = [] }
        let rows = withSenderZones(ChatRow.rows(
            thread.messages, parents: thread.parents, boosts: thread.boosts, purchases: thread.purchases,
            inTribe: isTribe(open.chat), people: people(in: open.chat), callServer: calls.server,
            threadRoot: open.uuid, original: thread.original,
            newAfter: newMessagesAfter(in: open.chat)
        ), in: open.chat)
        if rows != threadRows { threadRows = rows }
    }

    private func newMessagesAfter(in chat: String) -> Int64? {
        newMessages?.chat == chat ? newMessages?.after : nil
    }

    /// You, as the sidebar, Account, member lists and rows name you.
    public var me: Sender { Sender(alias: myAlias, photoURL: myPhotoURL, hue: myHue, isMe: true) }

    /// You in `chat`: as you appear in a tribe where you set your own name
    /// or photo (`Tribe.myAlias`, `myPhotoURL`), else `me`.
    public func me(in chat: String) -> Sender {
        guard let tribe = tribes[chat] else { return me }
        return Sender(alias: tribe.myAlias ?? myAlias, photoURL: tribe.myPhotoURL ?? myPhotoURL, hue: myHue, isMe: true)
    }

    /// You and the contact, as a chat's rows name them.
    public func people(in chat: String) -> ChatRow.People {
        people(in: chat, conversation: conversations.first { $0.chat == chat })
    }

    /// The same, with the chat's conversation already found.
    public func people(in chat: String, conversation: Conversation?) -> ChatRow.People {
        ChatRow.People(
            me: me(in: chat),
            contact: Sender(alias: conversation?.name, photoURL: conversation?.photoURL,
                            hue: hue(pubkey: chat, alias: nil, inTribe: false))
        )
    }

    public func isTribe(_ chat: String) -> Bool {
        conversations.first { $0.chat == chat }?.isTribe ?? false
    }

    /// Uploads a picture from this Mac and makes it the photo.
    public func uploadPhoto(_ file: URL) async throws {
        try await signedIn().uploadPhoto(file)
    }

    /// Uploads a picture from this Mac for a tribe's image; returns its link.
    public func uploadPicture(_ file: URL) async throws -> String {
        try await signedIn().uploadPicture(file)
    }

    /// Asks for a picture, beside the window.
    public func choosePicture() -> URL? {
        platform.files.open(prompt: "Choose", multiple: false, directories: false, types: [.image])?.first
    }

    /// The twelve words, after the PIN. Nothing here keeps or logs them.
    public func revealWords(pin: String) async throws -> [String] {
        guard let profile else { throw PeelError("no profile") }
        return try await Task.detached { try profile.words(pin: pin) }.value
    }

    /// Records that the words were written down when `answers` (typed back,
    /// by position) match `words`, the account's own as shown. Throws
    /// `Engine.Failure.wrongWords` naming the positions that differ.
    public func confirmWords(_ answers: [Int: String], of words: [String]) async throws {
        try await signedIn().confirmWords(answers, mnemonic: words.joined(separator: " "))
        wordsConfirmed = true
    }

    /// What the account holds, for Forget on the lock screen: the open
    /// account's balance, or before it opens the one last stored.
    public func balanceBeforeForget() async -> UInt64? {
        if engine != nil { return balanceMsat }
        guard let profile else { return nil }
        return await Task.detached { profile.storedBalanceMsat() }.value
    }

    /// Reseals the words under a new PIN, typed twice.
    public func changePIN(from oldPIN: String, to newPIN: String, confirmation: String) async throws {
        guard let profile else { throw PeelError("no profile") }
        guard newPIN == confirmation else { throw PeelError("The new PINs don't match.") }
        try await Task.detached { try profile.changePIN(from: oldPIN, to: newPIN) }.value
    }

    public func setPINTimeout(hours: Int) async throws {
        try await signedIn().setPINTimeout(hours: hours)
        pinTimeoutHours = hours
    }

    /// Asks for the PIN again if the timeout has passed. Called when the app
    /// comes to the front, and every 30 seconds by `lockWhenIdle`.
    /// Peel came to the front: the lock if it is due, then what may have
    /// changed elsewhere meanwhile.
    public func becameActive() {
        Diagnostics.setForeground(true)
        lockIfDue()
        // Asked first, so the open chat's `read` goes after the ask and its
        // answer is not applied over it.
        Task {
            await engine?.refreshReadsAndMutes()
            markSelectedChatRead()
        }
        Task { await engine?.refreshPreferences() }
        Task { await notifier.refreshPermission() }
        checkOwnMessageStatus()
    }

    /// Asks the server, in the background, what became of the open chat's own
    /// messages it has not confirmed, so their bolts settle (rate-limited by the engine).
    private func checkOwnMessageStatus() {
        guard let chat = selectedChat else { return }
        Task { await engine?.checkOwnMessageStatus(in: chat) }
    }

    public func lockIfDue() {
        guard isLockDue else { return }
        platform.pasteboard.clearSecret()
        notifier.removeAllDelivered()
        phase = .locked
    }

    /// Peel has gone unused for the PIN timeout, though it may not have
    /// locked yet; notifications already say nothing.
    public var isLockDue: Bool {
        guard phase == .ready, profile?.requiresPIN == true, pinTimeoutHours > 0, let lastActiveAt else { return false }
        return Date.now.timeIntervalSince(lastActiveAt) > Double(pinTimeoutHours) * 3600
    }

    /// The person used Peel (a key, a click, a scroll in its windows). Once
    /// the lock is due, using it no longer puts the lock off.
    public func noteActivity() {
        guard phase == .ready, !isLockDue else { return }
        lastActiveAt = .now
    }

    /// Locks once Peel has gone unused for the PIN timeout, also while it
    /// stays in front (audit F7), until the task is cancelled.
    public func lockWhenIdle() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(30))
            lockIfDue()
        }
    }

    /// Peel is quitting: what notifications said must not outlive a PIN.
    public func willTerminate() {
        Diagnostics.markCleanExit()
        agentHost?.stop()
        platform.pasteboard.clearSecret()
        if profile?.requiresPIN == true { notifier.removeAllDelivered() }
    }

    /// Creates an account from an invite and returns its twelve words, to show
    /// once. The app opens when the user confirms they wrote them down.
    public func createAccount(invite input: String, name: String, pin: String) async throws -> [String] {
        guard let profile else { throw PeelError("no profile") }
        try PIN.validate(pin)
        guard let invite = try? Engine.parseInvite(input) else {
            throw PeelError("That doesn't look like a Sphinx invite.")
        }
        // Face ID left by an account forgotten part-way would hold its PIN.
        try? profile.biometrics?.turnOff()
        let created = try await Account.signup(profile, invite: invite, alias: name, pin: pin)
        await attach(created.engine)
        return Engine.words(in: created.mnemonic)
    }

    /// Brings an account back from its twelve words, then pulls contacts and
    /// history in the background; `restoreProgress` follows it.
    public func restoreAccount(words: [String], pin: String) async throws {
        guard let profile else { throw PeelError("no profile") }
        try PIN.validate(pin)
        let mnemonic = words.joined(separator: " ")
        try? profile.biometrics?.turnOff()
        let engine = try await Account.restore(profile, mnemonic: mnemonic, pin: pin)
        // Reset before the engine starts, so its first progress events are kept.
        restoreProgress = RestoreProgress()
        await attach(engine)
    }

    /// Resume after history stalled: the engine picks it up where it stands,
    /// or says why not (`historyFailed`).
    public func resumeHistory() async {
        try? await engine?.resumeHistory()
    }

    /// Opens the main window, from onboarding or the lock screen.
    public func enterApp() {
        lastActiveAt = .now
        phase = .ready
        Task { await notifier.refreshPermission() }
    }

    // MARK: Notifications

    /// Whether Peel is the app in front, where the open chat is being read.
    public var isFrontmost: Bool { platform.presence.isFrontmost }

    /// Asks the system for permission, after the offer explained it.
    public func enableNotifications() async {
        await notifier.requestPermission()
    }

    public func dismissNotificationOffer() {
        notifier.dismissOffer()
    }

    public func openNotificationSettings() {
        platform.presence.openNotificationSettings()
    }

    /// Off: notifications say only "New message".
    public func setNotificationShowsText(_ shows: Bool) async throws {
        try await signedIn().setNotificationShowsText(shows)
        notifier.showsText = shows
    }

    public func setNotificationStyle(_ style: NotificationPolicy.Style) async throws {
        try await signedIn().setNotificationStyle(style)
        notifier.style = style
    }

    public func setNotificationSound(_ name: String) async throws {
        try await signedIn().setNotificationSound(name)
        notifier.sound = name
    }

    /// A click on a notification: Peel to the front with that chat open,
    /// at the message it was for, or Payments for sats received.
    public func openFromNotification(_ chat: String, messageID: Int64?) {
        platform.presence.activate()
        guard phase == .ready || phase == .locked else { return }
        if chat == Notifier.paymentsThread {
            destination = .payments
        } else if chat == Notifier.agentThread {
            destination = .agent
        } else if let message = messageID.flatMap({ try? engine?.storage.message(id: $0) }), message.chat == chat {
            focus(on: message)
        } else {
            destination = .chat(chat)
        }
    }

    /// Opens a message's chat (with `inThread`, its thread panel) scrolled to
    /// it, lit for a moment. One older than the newest 200 opens a window
    /// from just before it; one deleted since opens the chat with a notice.
    /// Takes precedence over "New messages".
    public func focus(on message: Message, inThread: Bool = false) {
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
           let limit = try? storage.timelineLimit(reaching: current), limit > Storage.pageSize,
           let start = try? storage.timelineStart(reaching: current) {
            // Before `focus`, so the list now showing never sees it.
            timelineWindow = (start, Storage.pageSize)
            if !opening { observeMessages() }
        }
        focus = FocusTarget(message: current, inThread: inThread)
        if opening { destination = .chat(chat) }
        if inThread { openThread(of: current) }
    }

    /// A jump `list` could not make (`ChatListController.jump`): in the
    /// chat's list, to the message's thread when one folds it away; else,
    /// unless a window with it is coming, the request is given up.
    public func jumpMissed(_ message: Message, in list: ComposerID, _ outcome: JumpOutcome) {
        if list.thread == nil, message.threadUUID != nil {
            focus(on: message, inThread: true)
        } else if outcome == .notLoaded, focus?.message.uuid == message.uuid {
            focus = nil
        }
    }

    /// Whether the open chat's timeline has a row for `message`: its own, or
    /// a collapsed thread's that it is the original of or a reply in.
    private func timelineShows(_ message: Message) -> Bool {
        timeline.messages.contains { $0.id == message.id }
            || message.uuid.map { timeline.threads[$0] != nil } ?? false
            || message.threadUUID.map { timeline.threads[$0] != nil } ?? false
    }

    /// The chat's list is at its bottom: a window short of the newest takes
    /// the next 200 below, keeping what is drawn; one that reaches it goes
    /// back to the newest 200, so later changes re-read only those.
    public func chatListAtBottom() {
        // Back at the newest after older pages: every change re-reads only
        // the newest page again (the rows above go until scrolled to).
        if timelineWindow == nil, newestLimit > Storage.pageSize {
            newestLimit = Storage.pageSize
            observeMessages(keepingRows: true)
        }
        guard var window = timelineWindow else { return }
        if timelineReachesNewest { return showNewest() }
        window.limit += Storage.pageSize
        timelineWindow = window
        observeMessages(keepingRows: true)
    }

    /// A page of older messages above the open chat's newest (the
    /// iPhone's list asks as it nears its top), keeping what is drawn.
    public func loadOlder() {
        guard mayHaveOlder else { return }
        newestLimit += Storage.pageSize
        loadingOlder = true
        observeMessages(keepingRows: true)
    }

    /// The open chat's newest messages, leaving a window for a jump.
    public func showNewest() {
        guard timelineWindow != nil else { return }
        timelineWindow = nil
        // The list made again with them opens at the newest.
        if let chat = selectedChat { listAnchors[.chat(chat)] = .newest }
        observeMessages()
    }

    /// Where the list of `list`'s rows stood when last still, if it has been shown.
    public func anchor(of list: ComposerID) -> ListAnchor? {
        listAnchors[list]
    }

    /// The list of `list`'s rows came to rest at `anchor`. The chat's own
    /// list at its newest has read past "New messages".
    public func keep(_ anchor: ListAnchor, of list: ComposerID) {
        listAnchors[list] = anchor
        if anchor == .newest, !newMessagesReached, case .chat(let chat) = list, newMessages?.chat == chat {
            newMessagesReached = true
        }
    }

    /// Whether a list of `chat`'s rows made now opens at "New messages":
    /// not once the chat's list has stood at its newest since it was placed.
    public func opensAtNewMessages(in chat: String) -> Bool {
        newMessages?.chat == chat && newMessages?.after != nil && !newMessagesReached
    }

    public func resend(_ message: Message) async {
        guard let id = message.id else { return }
        await attempt("send again", in: message.chat) { try await $0.resend(messageID: id) }
    }

    /// Deletes a message for everyone; a refusal shows in its chat.
    public func delete(_ message: Message) async {
        guard let id = message.id else { return }
        await attempt("delete", in: message.chat) { try await $0.deleteMessage(id: id) }
    }

    public func discard(_ message: Message) async {
        guard let id = message.id else { return }
        await attempt("discard", in: message.chat) { try await $0.discard(messageID: id) }
    }

    /// Runs an action on one chat; a failure shows above that chat's
    /// composer. Returns whether it succeeded.
    @discardableResult
    public func attempt(_ what: String, in chat: String, _ action: (Engine) async throws -> Void) async -> Bool {
        guard let engine else { return false }
        conversationNotices[chat] = nil
        do {
            try await action(engine)
            return true
        } catch {
            conversationNotices[chat] = PeelError.noted(error, couldNot: what)
            return false
        }
    }

    public func dismissNotice(in chat: String) {
        conversationNotices[chat] = nil
    }

    public func setMute(_ chat: String, _ level: MuteLevel) async {
        await attempt("change notifications", in: chat) { try await $0.setMute(chat, level: level) }
    }

    /// The connection panel's action: ping online, skip the retry wait offline.
    public func checkConnection() async {
        guard !checkingConnection, connection != .connecting, let engine else { return }
        checkingConnection = true
        defer { checkingConnection = false }
        if connection == .connected {
            _ = await engine.checkConnection()
        } else {
            await engine.reconnectNow()
        }
    }

    public func reconnectNow() async {
        await engine?.reconnectNow()
    }

    /// Pull to refresh: not connected, reconnect now and wait up to five
    /// seconds for it; connected, catch up from where history stands,
    /// unless history is already being asked for (a restore or a
    /// catch-up running), which asking again would only repeat.
    public func refresh() async {
        Diagnostics.setAction(.sync)
        defer { Diagnostics.setAction(.other) }
        guard connection == .connected else {
            await reconnectNow()
            for _ in 0..<20 where connection != .connected && !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
            }
            return
        }
        guard let engine, await !engine.isSyncingHistory else { return }
        await resumeHistory()
    }

    /// Marks the open chat read while the window is in front, so a message that
    /// arrives while you look at it never shows as unread.
    public func markSelectedChatRead() {
        guard let chat = selectedChat else { return }
        noteNewMessages(in: chat)
        guard isFrontmost, phase == .ready, keepsUnread != chat else { return }
        notifier.removeDelivered(in: [chat])
        // Behind, not only unread: the official apps count what Peel does not.
        guard let engine, let state = readStates[chat], state.isBehind || state.isNew else { return }
        Task {
            do {
                try await engine.markRead(chat)
            } catch {
                conversationNotices[chat] = PeelError.noted(error, couldNot: "mark as read")
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
    public func markUnread(_ chat: String, from message: Message? = nil) async {
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
    public func reachedBottom(of chat: String) {
        guard keepsUnread == chat else { return }
        keepsUnread = nil
        markSelectedChatRead()
    }

    /// Sending reads the chat (the server moves its marker too); "New
    /// messages" has done its job.
    public func sent(in chat: String) {
        if keepsUnread == chat { keepsUnread = nil }
        // What you sent is at the newest, which a jump's window may stop short of.
        if chat == selectedChat { showNewest() }
        // The sent message's row rebuilds the rest without it.
        if newMessages?.chat == chat { newMessages = (chat, nil) }
    }

    /// What a tribe link points to, to show before paying to join.
    public func previewTribe(_ link: String) async throws -> TribeInfo {
        guard let engine else { throw PeelError("not signed in") }
        return try await engine.tribeInfo(link: link)
    }

    /// Reads a tribe linked in a message for its card, once per link
    /// (`Engine.linkedTribeInfo`: only from the account's own tribes host).
    /// `again` reads a failed one again.
    public func loadLinkedTribe(_ link: TribeLink, again: Bool = false) async {
        guard let engine, linkedTribes[link] == nil || again && linkedTribes[link]?.problem != nil else { return }
        // A long scroll through shared links stays bounded.
        if linkedTribes.count >= 200 { linkedTribes = linkedTribes.filter { $0.value == .loading } }
        linkedTribes[link] = .loading
        let read: LinkedTribe
        do {
            read = try await engine.linkedTribeInfo(link).map(LinkedTribe.loaded) ?? .elsewhere
        } catch Engine.Failure.tribeDeleted {
            read = .deleted
        } catch {
            read = .failed(PeelError.noted(error))
        }
        // Not for an account switched to meanwhile.
        if self.engine === engine { linkedTribes[link] = read }
    }

    /// Joins a tribe from its link, paying only the price shown, through the
    /// engine's payment checks, and opens it.
    public func joinTribe(_ link: String, agreedJoinMsat: UInt64, confirmedMsat: UInt64?) async -> PaymentOutcome {
        Diagnostics.setAction(.tribeJoin)
        defer { Diagnostics.setAction(.other) }
        return await pay("join tribe") {
            let tribe = try await $0.joinTribe(link: link, agreedJoinMsat: agreedJoinMsat, confirmedMsat: confirmedMsat)
            destination = .chat(tribe.pubkey)
        }
    }

    public func tribeMembers(_ pubkey: String) async throws -> TribeMembers {
        let members = try await signedIn().tribeMembers(pubkey)
        knownMembers[pubkey] = members
        return members
    }

    /// A tribe's members for a link card's count: read again each time for
    /// a member (who has posted, stored here), but asked of the tribes
    /// server only once a session for the owner, and never twice at once.
    public func loadKnownMembers(_ pubkey: String) async {
        guard knownMembers[pubkey] == nil || tribes[pubkey]?.isOwner != true,
              readingMembers.insert(pubkey).inserted else { return }
        defer { readingMembers.remove(pubkey) }
        _ = try? await tribeMembers(pubkey)
    }

    /// Creates a tribe owned by this account and opens it.
    public func createTribe(_ settings: TribeSettings) async throws {
        let tribe = try await signedIn().createTribe(settings)
        destination = .chat(tribe.pubkey)
    }

    public func tribeSettings(_ pubkey: String) async throws -> TribeSettings {
        try await signedIn().tribeSettings(pubkey)
    }

    public func updateTribe(_ pubkey: String, _ settings: TribeSettings) async throws {
        try await signedIn().updateTribe(pubkey, settings: settings)
    }

    public func tribeDetails(_ pubkey: String) async throws -> TribeDetails {
        try await signedIn().tribeDetails(pubkey)
    }

    /// How you appear in one tribe; nil or empty is your account's own.
    public func setTribeIdentity(_ pubkey: String, alias: String?, photoURL: String?) async throws {
        try await signedIn().setTribeIdentity(pubkey, alias: alias, photoURL: photoURL)
    }

    public func deleteTribe(_ pubkey: String) async throws {
        try await signedIn().deleteTribe(pubkey)
        if selectedChat == pubkey { destination = nil }
    }

    public func kick(_ member: String, from pubkey: String) async throws {
        try await signedIn().kickMember(member, from: pubkey)
    }

    public func answerJoinRequest(in pubkey: String, _ request: Engine.JoinRequest, approve: Bool) async throws {
        try await signedIn().answerJoinRequest(in: pubkey, request, approve: approve)
    }

    /// Answers a request shown in the open tribe; a failure shows above its
    /// composer. Returns whether the answer went out.
    public func answerJoinRequest(_ message: Message, approve: Bool) async -> Bool {
        guard let uuid = message.uuid else { return false }
        return await attempt(approve ? "approve" : "decline", in: message.chat) {
            try await $0.answerJoinRequest(in: message.chat, .message(uuid: uuid), approve: approve)
        }
    }

    /// Pins a message (by uuid) for every member, or unpins with nil.
    public func pin(_ uuid: String?, in pubkey: String) async {
        await attempt(uuid == nil ? "unpin" : "pin", in: pubkey) { try await $0.pinMessage(uuid, in: pubkey) }
    }

    /// Who can be @mentioned in a tribe, read off the main thread.
    public func mentionCandidates(in pubkey: String) async -> [TribeMember] {
        guard let storage = engine?.storage else { return [] }
        return await Task.detached { (try? storage.mentionCandidates(in: pubkey)) ?? [] }.value
    }

    /// Tribe messages that mention this account, newest first, as they change.
    /// Followed only while the Mentions list is open.
    public func mentionUpdates() -> (some AsyncSequence<[Message], any Error>)? {
        engine?.storage.mentions()
    }

    /// This account's key, which names it on a tribe's member list.
    public var myPubkey: String? {
        myContactInfo?.split(separator: "_").first.map(String.init)
    }

    /// What a mention of you (a gold chip) looks like in `chat`
    /// (`ownMentionAliases`).
    public func mentionAliases(in chat: String) -> Set<String> {
        tribeMentionAliases[chat] ?? plainMentionAliases
    }

    private func refreshMentionAliases() {
        guard let name = myAlias?.nilIfEmpty else {
            (tribeMentionAliases, plainMentionAliases) = ([:], [])
            return
        }
        let own = tribes.values.filter { $0.myAlias != nil }.map(\.pubkey)
        tribeMentionAliases = Dictionary(uniqueKeysWithValues: Set(echoedAliases.keys).union(own).map { chat in
            (chat, ownMentionAliases(name: tribes[chat]?.myAlias ?? name, echoed: echoedAliases[chat] ?? []))
        })
        plainMentionAliases = ownMentionAliases(name: name, echoed: [])
    }

    // MARK: Person colours (direction D)

    /// Yours, by your key everywhere, as the official apps key their own
    /// messages. Every other colour comes from `hue(pubkey:alias:inTribe:)`.
    public private(set) var myHue = PersonHue(pubkey: "", alias: nil, inTribe: false)

    /// Someone in a boost, a thread or a call: you, or who they said they
    /// are (a tribe member by alias, or the contact, whose key is the chat's).
    public func avatar(fromMe: Bool, alias: String?, photoURL: String?, chat: String, inTribe: Bool) -> Sender {
        fromMe ? me(in: chat) : Sender(alias: alias, photoURL: photoURL, hue: hue(pubkey: chat, alias: alias, inTribe: inTribe))
    }

    public func hue(of member: TribeMember) -> PersonHue {
        hue(pubkey: member.pubkey, alias: member.alias, inTribe: true)
    }

    /// Who a payment was with (`counterpart`, when anyone is known).
    public func hue(of payment: PaymentItem) -> PersonHue {
        hue(pubkey: payment.chat, alias: payment.counterpart, inTribe: payment.isTribe)
    }

    /// Someone known by their key: a contact, or a tribe member (by alias).
    public func hue(pubkey: String?, alias: String?, inTribe: Bool) -> PersonHue {
        if let pubkey, pubkey == myPubkey { return myHue }
        return PersonHue(pubkey: pubkey ?? "", alias: alias, inTribe: inTribe)
    }

    public func signedIn() throws -> Engine {
        guard let engine else { throw PeelError("not signed in") }
        return engine
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
        agentHost?.close(in: self)
        platform.pasteboard.clearSecret()
        // Players are keyed by message id, which the next account reuses.
        platform.playback.closeFullScreen()
        platform.playback.stop()
        conversations = []
        agentContact = nil
        tribes = [:]
        linkedTribes = [:]
        knownMembers = [:]
        invites = [:]
        pendingInvites = []
        focus = nil
        destination = nil
        accountPage = .profile
        searchQuery = ""
        timeline = .empty
        openThread = nil
        threads = []
        replyTargets = [:]
        // Peel's own pasted or promised files: in a tray, or under a failed upload.
        (pendingFiles.values.joined() + attachmentHandles.values.compactMap(\.localFile))
            .forEach { IncomingFiles.discard($0) }
        pendingFiles = [:]
        attachmentPrices = [:]
        composerFocus = [:]
        dropTarget = nil
        viewer = nil
        attachmentHandles = [:]
        drafts = [:]
        chatRows = []
        threadRows = []
        readStates = [:]
        conversationNotices = [:]
        notice = nil
        connection = .offline(retryIn: nil)
        connectionError = nil
        reconnectAt = nil
        showingConnection = false
        restoreProgress = RestoreProgress()
        myAlias = nil
        myPhotoURL = nil
        myContactInfo = nil
        echoedAliases = [:]
        refreshMentionAliases()
        myServer = nil
        calls.reset()
        money.reset()
        balanceMsat = nil
        wordsConfirmed = true
        waitingMsat = 0
        paymentConfirmationMsat = Engine.defaultPaymentConfirmationMsat
        moneyInFlight = []
        boostAmountMsat = Engine.defaultBoostAmountMsat
        boostToConfirm = nil
        savedLayout = ChatSections.Layout()
        sidebarLayout = savedLayout
        senderZoneCache = [:]
        lastActiveAt = nil
        notifier.reset()
    }

    private func attach(_ engine: Engine) async {
        // An error from before this account opened no longer applies.
        notice = nil
        self.engine = engine
        let storage = engine.storage
        let settings = await engine.settings()
        myAlias = settings.alias.nilIfEmpty
        myPhotoURL = settings.photoURL
        myContactInfo = settings.contactInfo
        echoedAliases = settings.echoedAliases
        refreshMentionAliases()
        myServer = settings.server
        calls.attach(engine, server: settings.callServer)
        pinTimeoutHours = settings.pinTimeoutHours ?? UserDefaults.standard.integer(forKey: "pinTimeoutHours")
        balanceMsat = settings.balanceMsat
        wordsConfirmed = settings.wordsConfirmed ?? false
        paymentConfirmationMsat = settings.paymentConfirmationMsat ?? Engine.defaultPaymentConfirmationMsat
        boostAmountMsat = settings.boostAmountMsat ?? Engine.defaultBoostAmountMsat
        savedLayout = settings.sidebarLayout ?? ChatSections.Layout()
        sidebarLayout = savedLayout
        connection = settings.connection
        restoreProgress.restoring = settings.restoring
        // Forgotten while loading.
        guard self.engine === engine else { return }
        if let profile { agentHost?.open(profile, engine: engine, in: self) }
        // With no agent here (the phone), the agent's DM is still the agent
        // chat: the agent is this account's own, from the same words.
        if agentHost == nil, let agent = try? await engine.agentPubkey(), self.engine === engine { agentContact = agent }
        if let handler = agentHost?.deviceRequests(for: engine) { await engine.answerDeviceRequests(with: handler) }
        notifier.style = settings.notificationStyle ?? .default
        notifier.sound = settings.notificationSound ?? ""
        notifier.attach(storage, showsText: settings.notificationShowsText ?? false)
        // A notification clicked on the lock screen chose the chat before there was an engine.
        if selectedChat != nil { observeMessages() }
        accountTasks = [
            Task { await self.observeConversations(storage) },
            Task { await self.observeTribes(storage) },
            Task { await self.observeInvites(storage) },
            Task { await self.observeWaiting(storage) },
            Task { await self.observeReadStates(storage) },
            Task { await self.observeThreads(storage) },
            Task { await self.observeRecentCalls(storage) },
            Task { await self.consumeEvents(engine) },
        ]
        await engine.start()
    }

    private func consumeEvents(_ engine: Engine) async {
        for await event in engine.events where !Task.isCancelled {
            switch event {
            case .connection(let state):
                connection = state
                if state == .connected {
                    connectionError = nil
                    if notice != nil, notice == serverCheckNotice { notice = nil }
                }
                if case .offline(let seconds?) = state {
                    reconnectAt = .now.addingTimeInterval(TimeInterval(seconds))
                } else {
                    reconnectAt = nil
                }
            case .conversationError(let chat, let message):
                Diagnostics.note(errorKind: .engine)
                conversationNotices[chat] = PeelError.problem(message)
            case .connectionError(let message):
                Diagnostics.note(errorKind: .connection)
                connectionError = PeelError.problem(message)
            case .registered(let contactInfo):
                myContactInfo = contactInfo
                // Your key keys your colour.
                rebuildRows()
            case .balance(let msat):
                balanceMsat = msat
            case .coreError(let message):
                Diagnostics.note(errorKind: .core)
                notice = PeelError.problem(message)
            case .serverCheckError(let message):
                Diagnostics.note(errorKind: .server)
                notice = PeelError.problem(message)
                serverCheckNotice = notice
            case .history(let phase, let reached, let end):
                switch phase {
                case .contacts: restoreProgress.contacts = .init(reached: reached, end: end)
                case .messages: restoreProgress.messages = .init(reached: reached, end: end)
                }
                checkOwnMessageStatus()
            case .historyResumed(let restart):
                if restoreProgress.paused != nil { restoreProgress.outcome = nil }
                if restart { (restoreProgress.contacts, restoreProgress.messages) = (nil, nil) }
            case .historyDone:
                restoreProgress.restoring = false
                restoreProgress.outcome = .finished
                notifier.historyEnded()
                // A safety net: a missed `.profile` must not leave the header stale.
                let settings = await engine.settings()
                myAlias = settings.alias.nilIfEmpty
                myPhotoURL = settings.photoURL
                rebuildRows()
            case .profile(let alias, let photoURL):
                myAlias = alias.nilIfEmpty
                myPhotoURL = photoURL
                refreshMentionAliases()
                rebuildRows()
            case .echoedAliases(let echoed):
                echoedAliases = echoed
                refreshMentionAliases()
            case .historyFailed(let reason):
                // Not the end of the first sync: what Resume brings in is not notified.
                restoreProgress.outcome = .failed(PeelError.problem(reason))
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
            case .contactAdded(let message):
                notifier.contactAdded(message)
            case .preferencesChanged:
                // The time zones are read where they are shown.
                let settings = await engine.settings()
                guard self.engine === engine else { break }
                paymentConfirmationMsat = settings.paymentConfirmationMsat ?? Engine.defaultPaymentConfirmationMsat
                boostAmountMsat = settings.boostAmountMsat ?? Engine.defaultBoostAmountMsat
            case .sendStatus:
                break
            }
        }
    }

    private func observeConversations(_ storage: Storage) async {
        do {
            for try await rows in storage.conversations() where !Task.isCancelled {
                // Rows carry the contact's name and photo, and whether it is a
                // tribe; not its preview, which every new message moves (the
                // timeline's own emission rebuilds for those).
                let open = { (rows: [Conversation]) in rows.first { $0.chat == self.selectedChat } }
                let (old, new) = (open(conversations), open(rows))
                let changed = old?.alias != new?.alias || old?.photoURL != new?.photoURL || old?.isTribe != new?.isTribe
                conversations = rows
                if changed { rebuildRows() }
                followAgentChat()
                if destination == nil, platform.opensFirstChat, let first = rows.first {
                    destination = .chat(first.chat)
                }
            }
        } catch {
            if !Task.isCancelled { notice = PeelError.noted(error, couldNot: "load the chats") }
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
            if !Task.isCancelled { notice = PeelError.noted(error, couldNot: "load unread counts") }
        }
    }

    private func observeTribes(_ storage: Storage) async {
        do {
            for try await records in storage.tribesByPubkey() where !Task.isCancelled {
                let before = selectedChat.map(me(in:))
                let renamed = records.mapValues(\.myAlias) != tribes.mapValues(\.myAlias)
                tribes = records
                if renamed { refreshMentionAliases() }
                // Your own rows in the open tribe show how you appear there.
                if selectedChat.map(me(in:)) != before { rebuildRows() }
            }
        } catch {
            if !Task.isCancelled { notice = PeelError.noted(error, couldNot: "load tribes") }
        }
    }

    private func observeWaiting(_ storage: Storage) async {
        do {
            for try await msat in storage.waitingUpdates() where !Task.isCancelled {
                waitingMsat = msat
            }
        } catch {
            if !Task.isCancelled { notice = PeelError.noted(error, couldNot: "load waiting payments") }
        }
    }

    private func observeInvites(_ storage: Storage) async {
        do {
            for try await list in storage.invites() where !Task.isCancelled {
                invites = Dictionary(list.map { ($0.code, $0) }, uniquingKeysWith: { first, _ in first })
                pendingInvites = list.filter(\.isPending)
            }
        } catch {
            if !Task.isCancelled { notice = PeelError.noted(error, couldNot: "load invites") }
        }
    }

    /// Follows the open chat's messages and, for a tribe, its pinned message,
    /// which a pin, an edit or a delete can change.
    /// `keepingRows`: the same chat's window grew, so what is drawn stays
    /// until the longer one comes.
    private func observeMessages(keepingRows: Bool = false) {
        messagesTask?.cancel()
        if !keepingRows {
            pinTask?.cancel()
            timeline = .empty
            chatRows = []
            loadedChat = nil
            pinnedMessage = nil
        }
        guard let storage = engine?.storage, let chat = selectedChat else { return }
        let window = timelineWindow
        let limit = window?.limit ?? newestLimit
        TimelineLog.log("\(TimelineLog.tag(chat)) timeline reset, limit \(limit)")
        messagesTask = Task {
            do {
                for try await timeline in storage.timeline(
                    in: chat, from: window?.start, limit: limit
                ) where !Task.isCancelled {
                    TimelineLog.log("\(TimelineLog.tag(chat)) timeline loaded: \(timeline.messages.count) messages, "
                        + "\(timeline.threads.count) threads, limit \(limit)")
                    self.timeline = timeline
                    loadingOlder = false
                    rebuildChatRows()
                    if loadedChat != chat { loadedChat = chat }
                }
            } catch {
                guard !Task.isCancelled else { return }
                notice = PeelError.noted(error, couldNot: "load this chat's messages")
                // Its list shows, empty, rather than nothing at all.
                if loadedChat != chat { loadedChat = chat }
            }
        }
        // The same chat's pin, still followed.
        guard !keepingRows else { return }
        pinTask = Task {
            do {
                for try await pinned in storage.pinnedMessage(in: chat) where !Task.isCancelled {
                    pinnedMessage = pinned
                }
            } catch {
                if !Task.isCancelled { notice = PeelError.noted(error, couldNot: "load the pinned message") }
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
                if !Task.isCancelled { notice = PeelError.noted(error, couldNot: "load the thread") }
            }
        }
    }

    private func observeRecentCalls(_ storage: Storage) async {
        do { try await calls.observeRecent(storage) } catch {
            if !Task.isCancelled { notice = PeelError.noted(error, couldNot: "load recent calls") }
        }
    }

    private func observeThreads(_ storage: Storage) async {
        do {
            for try await rows in storage.threads() where !Task.isCancelled {
                threads = rows
            }
        } catch {
            if !Task.isCancelled { notice = PeelError.noted(error, couldNot: "load threads") }
        }
    }
}

/// What a tribe linked in a message is, as its card last read it
/// (`AppModel.loadLinkedTribe`).
public enum LinkedTribe: Equatable, Sendable {
    case loading
    case loaded(TribeInfo)
    /// Listed on a host other than the account's own: not read.
    case elsewhere
    case deleted
    case failed(String)

    public var info: TribeInfo? {
        if case .loaded(let info) = self { info } else { nil }
    }

    public var problem: String? {
        if case .failed(let problem) = self { problem } else { nil }
    }
}

/// Where a Connect panel was opened from, so it opens beside that button:
/// the chat's card, its DM's composer place, the Account page's provider
/// or key, or Automations.
public enum AgentConnectSource: Hashable, Sendable {
    case chat, dm, account, accountKey, automations
}

private extension AppModel.Destination {
    var chat: String? {
        if case .chat(let chat) = self { chat } else { nil }
    }
}
