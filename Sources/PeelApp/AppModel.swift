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
        case threads, mentions, payments
        case chat(String)
    }

    var phase: Phase = .loading
    var connection: Engine.ConnectionState = .offline(retryIn: nil)
    var conversations: [Conversation] = []
    var messages: [Message] = []
    var destination: Destination? {
        didSet {
            if selectedChat != oldValue?.chat { observeMessages() }
            markSelectedChatRead()
        }
    }
    var searchQuery = ""
    var myAlias: String?
    var myContactInfo: String?
    var balanceMsat: UInt64?
    var notice: String?
    /// The latest error that belongs to a conversation, shown inside it.
    var conversationNotices: [String: String] = [:]
    /// Unread counts and mute levels by chat.
    var readStates: [String: ChatReadState] = [:]
    /// Why the last attempt to connect failed; cleared once connected.
    var connectionError: String?
    /// When the engine will next try to reconnect, for a live countdown.
    var reconnectAt: Date?
    var restoreProgress = RestoreProgress()

    /// The app's own account keeps its words in the Keychain. Launching with
    /// `-profile <name>` opens a development profile instead, whose words sit in
    /// a plain file; the window says so.
    private(set) var profile: Profile?
    private var engine: Engine?
    private var messagesTask: Task<Void, Never>?
    /// When the PIN was last entered. The PIN itself is never kept.
    private var unlockedAt: Date?

    /// Hours after which the app asks for the PIN again when it comes to the
    /// front; 0 means only at launch. Set with
    /// `defaults write dev.peel.mac pinTimeoutHours <hours>` until Profile has it.
    private var pinTimeoutHours: Int { UserDefaults.standard.integer(forKey: "pinTimeoutHours") }

    init() {
        do {
            if let development = UserDefaults.standard.string(forKey: "profile") {
                profile = try Profile(name: development, kind: .development)
            } else {
                profile = try Profile(name: "default", kind: .app)
            }
        } catch {
            notice = "\(error)"
        }
    }

    var usesFileSecrets: Bool { profile?.kind == .development }

    var selectedChat: String? { destination?.chat }

    /// Direct messages matching the sidebar search.
    var filteredConversations: [Conversation] {
        let query = searchQuery.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return conversations }
        return conversations.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var selectedConversation: Conversation? {
        conversations.first { $0.chat == selectedChat }
    }

    func start() async {
        guard phase == .loading, let profile else { return }
        guard profile.hasAccount else {
            phase = .onboarding
            return
        }
        guard !profile.requiresPIN else {
            phase = .locked
            return
        }
        do {
            try await open(profile, pin: "")
            enterApp()
        } catch {
            notice = "\(error)"
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
    func forgetAccount() async throws {
        guard let profile else { return }
        await engine?.disconnect()
        engine = nil
        try profile.delete()
        conversations = []
        messages = []
        destination = nil
        phase = .onboarding
    }

    /// Asks for the PIN again if the timeout has passed. Called when the app
    /// comes to the front.
    func lockIfDue() {
        guard phase == .ready, profile?.requiresPIN == true, pinTimeoutHours > 0,
              let unlockedAt, Date.now.timeIntervalSince(unlockedAt) > Double(pinTimeoutHours) * 3600 else { return }
        phase = .locked
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
    }

    func send(_ text: String) async {
        guard let chat = selectedChat else { return }
        await attempt("send", in: chat) { try await $0.sendText(text, to: chat) }
    }

    func resend(_ message: Message) async {
        guard let id = message.id else { return }
        await attempt("send again", in: message.chat) { try await $0.resend(messageID: id) }
    }

    func discard(_ message: Message) async {
        guard let id = message.id else { return }
        await attempt("discard", in: message.chat) { try await $0.discard(messageID: id) }
    }

    /// Runs an action on one chat; a failure shows above that chat's composer.
    private func attempt(_ what: String, in chat: String, _ action: (Engine) async throws -> Void) async {
        guard let engine else { return }
        conversationNotices[chat] = nil
        do {
            try await action(engine)
        } catch {
            conversationNotices[chat] = "Could not \(what): \(error)"
        }
    }

    func dismissNotice(in chat: String) {
        conversationNotices[chat] = nil
    }

    func setMuted(_ chat: String, _ muted: Bool) async {
        await attempt(muted ? "mute" : "unmute", in: chat) { try await $0.setMute(chat, level: muted ? .muted : .all) }
    }

    func reconnectNow() async {
        await engine?.reconnectNow()
    }

    /// Marks the open chat read while the window is in front, so a message that
    /// arrives while you look at it never shows as unread.
    func markSelectedChatRead() {
        #if os(macOS)
        guard NSApplication.shared.isActive else { return }
        #endif
        guard phase == .ready, let engine, let chat = selectedChat, (readStates[chat]?.unread ?? 0) > 0 else { return }
        Task {
            do {
                try await engine.markRead(chat)
            } catch {
                conversationNotices[chat] = "Could not mark as read: \(error)"
            }
        }
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

    private func attach(_ engine: Engine) async {
        self.engine = engine
        let storage = engine.storage
        myAlias = try? storage.value(for: .alias)
        myContactInfo = try? storage.value(for: .contactInfo)
        balanceMsat = try? storage.value(for: .balanceMsat).flatMap { UInt64($0) }
        connection = await engine.connection
        Task { await self.observeConversations(storage) }
        Task { await self.observeReadStates(storage) }
        Task { await self.consumeEvents(engine) }
        await engine.start()
    }

    private func consumeEvents(_ engine: Engine) async {
        for await event in engine.events {
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
            case .historyFailed(let reason):
                restoreProgress.outcome = .failed(reason)
            case .message, .sendStatus:
                break
            }
        }
    }

    private func observeConversations(_ storage: Storage) async {
        do {
            for try await rows in storage.conversations() {
                conversations = rows
                if destination == nil, let first = rows.first {
                    destination = .chat(first.chat)
                }
            }
        } catch {
            notice = "\(error)"
        }
    }

    private func observeReadStates(_ storage: Storage) async {
        do {
            for try await states in storage.readStates() {
                readStates = states
                markSelectedChatRead()
            }
        } catch {
            notice = "\(error)"
        }
    }

    private func observeMessages() {
        messagesTask?.cancel()
        messages = []
        guard let storage = engine?.storage, let chat = selectedChat else { return }
        messagesTask = Task {
            do {
                for try await rows in storage.messages(in: chat) {
                    messages = rows
                }
            } catch {
                if !Task.isCancelled { notice = "\(error)" }
            }
        }
    }
}

private extension AppModel.Destination {
    var chat: String? {
        if case .chat(let chat) = self { chat } else { nil }
    }
}
