import Foundation
import Observation
import PeelCore

/// Everything the windows show, kept current from the engine and storage.
@MainActor @Observable
final class AppModel {
    enum Phase { case loading, onboarding, ready }

    var phase: Phase = .loading
    var connection: Engine.ConnectionState = .offline(retryIn: nil)
    var conversations: [Conversation] = []
    var messages: [Message] = []
    var selectedChat: String? {
        didSet { if selectedChat != oldValue { observeMessages() } }
    }
    var myContactInfo: String?
    var balanceMsat: UInt64?
    var notice: String?

    /// Which local account to use: launch with `-profile <name>`.
    private(set) var profile: Profile?
    private var engine: Engine?
    private var messagesTask: Task<Void, Never>?

    init() {
        do {
            profile = try Profile(name: UserDefaults.standard.string(forKey: "profile") ?? "default")
        } catch {
            notice = "\(error)"
        }
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

    /// One field takes either an invite link or the twelve words of an account.
    func join(_ input: String, name: String) async throws {
        guard let profile else { return }
        let engine: Engine
        if let invite = try? Engine.parseInvite(input) {
            engine = try await Account.signup(profile, invite: invite, alias: name)
        } else {
            engine = try await Account.restore(profile, mnemonic: input, alias: name)
        }
        await attach(engine)
    }

    func send(_ text: String) async {
        guard let engine, let chat = selectedChat else { return }
        do {
            try await engine.sendText(text, to: chat)
        } catch {
            notice = "Could not send: \(error)"
        }
    }

    private func attach(_ engine: Engine) async {
        self.engine = engine
        let storage = engine.storage
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
            case .message, .sendStatus:
                break
            }
        }
    }

    private func observeConversations(_ storage: Storage) async {
        do {
            for try await rows in storage.conversations() {
                conversations = rows
                if selectedChat == nil {
                    selectedChat = rows.first?.chat
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
