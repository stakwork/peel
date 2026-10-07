import Foundation
import Observation
import PeelCore

/// Everything the windows show, kept current from the engine and storage.
@MainActor @Observable
final class AppModel {
    enum Phase { case loading, locked, onboarding, ready }

    /// How far a restore from twelve words has got.
    struct RestoreProgress {
        var contacts: (reached: UInt64, end: UInt64?)?
        var messages: (reached: UInt64, end: UInt64?)?
        var finished = false
        var failure: String?
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
        didSet { if selectedChat != oldValue?.chat { observeMessages() } }
    }
    var searchQuery = ""
    var myAlias: String?
    var myContactInfo: String?
    var balanceMsat: UInt64?
    var notice: String?
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
        // The app's own account is sealed under its PIN; development profiles are not.
        guard profile.kind == .development else {
            phase = .locked
            return
        }
        do {
            try await open(profile, pin: "")
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
            _ = try await Task.detached { try profile.loadMnemonic(pin: pin) }.value
        }
        unlockedAt = .now
        phase = .ready
    }

    /// Asks for the PIN again if the timeout has passed. Called when the app
    /// comes to the front.
    func lockIfDue() {
        guard phase == .ready, profile?.kind == .app, pinTimeoutHours > 0,
              let unlockedAt, Date.now.timeIntervalSince(unlockedAt) > Double(pinTimeoutHours) * 3600 else { return }
        phase = .locked
    }

    /// Creates an account from an invite and returns its twelve words, to show
    /// once. The app opens when the user confirms they wrote them down.
    func createAccount(invite input: String, name: String, pin: String) async throws -> [String] {
        guard let profile else { throw PeelError("no profile") }
        try PIN.validate(pin)
        guard let invite = try? Engine.parseInvite(input.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw PeelError("That doesn't look like a Sphinx invite.")
        }
        let engine = try await Account.signup(profile, invite: invite, alias: name, pin: pin)
        await attach(engine)
        let mnemonic = try await Task.detached { try profile.loadMnemonic(pin: pin) }.value
        return mnemonic.split(separator: " ").map(String.init)
    }

    /// Brings an account back from its twelve words, then pulls contacts and
    /// history in the background; `restoreProgress` follows it.
    func restoreAccount(words: [String], name: String, pin: String) async throws {
        guard let profile else { throw PeelError("no profile") }
        try PIN.validate(pin)
        let mnemonic = words.joined(separator: " ")
        let engine = try await Account.restore(profile, mnemonic: mnemonic, alias: name, pin: pin)
        await attach(engine)
        restoreProgress = RestoreProgress()
        Task { await pullHistory(engine) }
    }

    /// Leaves onboarding for the main window.
    func finishOnboarding() {
        unlockedAt = .now
        phase = .ready
    }

    func send(_ text: String) async {
        guard let engine, let chat = selectedChat else { return }
        do {
            try await engine.sendText(text, to: chat)
        } catch {
            notice = "Could not send: \(error)"
        }
    }

    /// Adds a contact from the contact info they shared.
    func addContact(_ contactInfo: String, alias: String) async throws {
        guard let engine else { return }
        let alias = alias.trimmingCharacters(in: .whitespaces)
        try await engine.addContact(
            contactInfo.trimmingCharacters(in: .whitespacesAndNewlines),
            alias: alias.isEmpty ? nil : alias
        )
    }

    private func open(_ profile: Profile, pin: String) async throws {
        // Loading derives keys and opens the database; keep it off the main thread.
        let engine = try await Task.detached { try await Account.load(profile, pin: pin) }.value
        await attach(engine)
        phase = .ready
    }

    private func pullHistory(_ engine: Engine) async {
        // The core's restore calls need a live connection; the engine keeps
        // reconnecting, so wait for it however long that takes.
        while connection != .connected {
            try? await Task.sleep(for: .milliseconds(300))
        }
        do {
            try await engine.restore()
            restoreProgress.finished = true
        } catch {
            restoreProgress.failure = "\(error)"
        }
    }

    private func attach(_ engine: Engine) async {
        self.engine = engine
        let storage = engine.storage
        myAlias = try? storage.value(for: .alias)
        myContactInfo = try? storage.value(for: .contactInfo)
        balanceMsat = try? storage.value(for: .balanceMsat).flatMap { UInt64($0) }
        connection = await engine.connection
        Task { await self.observeConversations(storage) }
        Task { await self.consumeEvents(engine) }
        await engine.start()
    }

    private func consumeEvents(_ engine: Engine) async {
        for await event in engine.events {
            switch event {
            case .connection(let state):
                connection = state
            case .registered(let contactInfo):
                myContactInfo = contactInfo
            case .balance(let msat):
                balanceMsat = msat
            case .coreError(let message):
                notice = message
            case .history(let phase, let reached, let end):
                switch phase {
                case .contacts: restoreProgress.contacts = (reached, end)
                case .messages: restoreProgress.messages = (reached, end)
                }
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
