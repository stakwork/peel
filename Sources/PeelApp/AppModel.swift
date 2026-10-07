import Foundation
import Observation
import PeelCore

/// Everything the windows show, kept current from the engine and storage.
@MainActor @Observable
final class AppModel {
    enum Phase { case loading, onboarding, ready }

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

    /// The app's own account keeps its words in the Keychain. Launching with
    /// `-profile <name>` opens a development profile instead, whose words sit in
    /// a plain file; the window says so.
    private(set) var profile: Profile?
    private var engine: Engine?
    private var messagesTask: Task<Void, Never>?

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
        do {
            // Loading an account derives keys and opens the database; keep it off the main thread.
            let engine = try await Task.detached { try await Account.load(profile) }.value
            await attach(engine)
        } catch {
            notice = "\(error)"
            phase = .onboarding
        }
    }

    /// Creates an account from an invite link. Twelve words are refused on
    /// purpose: the app has no Keychain storage yet, and a real account's words
    /// must never land in the plain file the development profiles use.
    func join(_ input: String, name: String) async throws {
        guard let profile else { return }
        guard let invite = try? Engine.parseInvite(input) else {
            throw PeelError("Only an invite link works for now. Restoring from twelve words arrives with Keychain storage.")
        }
        await attach(try await Account.signup(profile, invite: invite, alias: name))
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

    private func attach(_ engine: Engine) async {
        self.engine = engine
        let storage = engine.storage
        myAlias = try? storage.value(for: .alias)
        myContactInfo = try? storage.value(for: .contactInfo)
        balanceMsat = try? storage.value(for: .balanceMsat).flatMap { UInt64($0) }
        connection = await engine.connection
        Task { await self.observeConversations(storage) }
        Task { await self.consumeEvents(engine) }
        phase = .ready
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
            case .message, .sendStatus, .history:
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
