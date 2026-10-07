import Foundation
import Observation
import PeelCore

/// Everything the windows show, kept current from the engine and storage.
@MainActor @Observable
final class AppModel {
    enum Phase { case loading, onboarding, ready }

    enum Connection: Equatable {
        case connecting
        case connected
        case offline(retryIn: Int)

        var label: String {
            switch self {
            case .connecting: "Connecting"
            case .connected: "Connected"
            case .offline(let seconds): "Offline, retrying in \(seconds)s"
            }
        }
    }

    var phase: Phase = .loading
    var connection: Connection = .connecting
    var conversations: [Conversation] = []
    var messages: [Message] = []
    var selectedChat: String? {
        didSet { if selectedChat != oldValue { observeMessages() } }
    }
    var myContactInfo: String?
    var balanceMsat: UInt64?
    var notice: String?

    let profile: Profile
    private var storage: Storage?
    private var engine: Engine?
    private var server: ServerAddress?
    private var tasks: [Task<Void, Never>] = []
    private var messagesTask: Task<Void, Never>?

    init() {
        let arguments = CommandLine.arguments
        let name = arguments.firstIndex(of: "--profile").flatMap { arguments.count > $0 + 1 ? arguments[$0 + 1] : nil }
        profile = Profile(name: name ?? "default")
    }

    var selectedConversation: Conversation? {
        conversations.first { $0.chat == selectedChat }
    }

    func start() async {
        guard phase == .loading else { return }
        guard profile.hasAccount else {
            phase = .onboarding
            return
        }
        do {
            try await open()
        } catch {
            notice = "\(error)"
            phase = .onboarding
        }
    }

    /// Creates a new account from an invite link.
    func signup(invite: String, name: String) async throws {
        let parsed = try Engine.parseInvite(invite)
        guard let host = parsed.server, let address = ServerAddress(host) else {
            throw AppError("The invite does not say which server to use.")
        }
        try profile.save(mnemonic: Engine.generateMnemonic())
        try await open(server: address, name: name, inviteCode: parsed.code)
        if let inviter = parsed.inviterContactInfo {
            try await engine?.addContact(inviter, alias: parsed.inviterAlias, inviteCode: parsed.code)
        }
    }

    /// Opens an existing account from its twelve words. History is not pulled
    /// back yet; only new messages will show.
    func restore(mnemonic: String, name: String) async throws {
        let config = try await ServerConfig.fetch()
        guard let address = ServerAddress(config.defaultLSP) else {
            throw AppError("The server address in the config is unreadable.")
        }
        try profile.save(mnemonic: mnemonic)
        try await open(server: address, name: name)
    }

    func send(_ text: String) async {
        guard let engine, let chat = selectedChat else { return }
        do {
            try await engine.sendText(text, to: chat)
        } catch {
            notice = "Could not send: \(error)"
        }
    }

    private func open(server: ServerAddress? = nil, name: String? = nil, inviteCode: String? = nil) async throws {
        let storage = try Storage(directory: profile.directory)
        let engine = try Engine(mnemonic: profile.loadMnemonic(), storage: storage)
        if let name { try await engine.setAlias(name) }
        if let server {
            try storage.set(server.description, for: .server)
        }
        guard let stored = try storage.value(for: .server), let address = ServerAddress(stored) else {
            throw AppError("This account has no server recorded.")
        }
        self.storage = storage
        self.engine = engine
        self.server = address
        myContactInfo = try storage.value(for: .contactInfo)
        balanceMsat = try storage.value(for: .balanceMsat).flatMap { UInt64($0) }

        tasks.append(Task { await self.observeConversations() })
        tasks.append(Task { await self.consumeEvents() })
        phase = .ready
        await connect(inviteCode: inviteCode)
        if inviteCode != nil {
            try await engine.waitUntilRegistered()
        }
    }

    private func connect(inviteCode: String? = nil) async {
        guard let engine, let server else { return }
        var attempt = 0
        while !Task.isCancelled {
            connection = .connecting
            do {
                try await engine.connect(to: server, inviteCode: inviteCode)
                connection = .connected
                return
            } catch {
                notice = "Connection failed: \(error)"
            }
            attempt += 1
            let delay = min(30, 2 << min(attempt, 4))
            connection = .offline(retryIn: delay)
            try? await Task.sleep(for: .seconds(delay))
        }
    }

    private func consumeEvents() async {
        guard let engine else { return }
        for await event in engine.events {
            switch event {
            case .registered(let contactInfo):
                myContactInfo = contactInfo
            case .balance(let msat):
                balanceMsat = msat
            case .coreError(let message):
                notice = message
            case .disconnected:
                connection = .offline(retryIn: 2)
                Task { await self.connect() }
            case .message, .sendStatus:
                break
            }
        }
    }

    private func observeConversations() async {
        guard let storage else { return }
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
        guard let storage, let chat = selectedChat else { return }
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

struct AppError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
