import Foundation
import PeelCore

// A development harness for PeelCore. It keeps the mnemonic in a plain file so
// it can run unattended, which is only acceptable for throwaway accounts.

@main
struct PeelCommand {
    static let usage = """
        usage: peel [options] <command>

          init                        new account with no invite (local test server; needs --server)
          signup <invite|->           new account from an invite link ("-" reads it from stdin)
          restore                     existing account; reads the twelve words from stdin
          whoami                      this account's contact info and balance
          contacts                    contacts known to the core
          add <contact-info> [name]   start a key exchange with a contact
          send <pubkey> <text>        send a text message to a contact or a tribe
          listen                      stay connected, reconnecting as needed, and print what arrives
          messages <pubkey>           the newest stored messages of a contact or a tribe, with row ids and delivery
          resend <id>                 send an undelivered message again
          discard <id>                drop an undelivered message
          unread                      unread counts and mute levels by chat
          read <pubkey>               mark a chat read up to its newest message
          mute <pubkey> <0|1|2>       notify for all, mentions only, or nothing

          tribes                      tribes this account is in
          tribe-join <link>           join from a sphinx.chat://?action=tribeV2 link
          tribe-members <pubkey>      a tribe's members (the full list only for its owner)
          tribe-leave <pubkey>        leave a tribe
          tribe-create <name>         create a tribe owned by this account on its tribes server
                                      (--description, --price-per-message, --price-to-join in sats)

        options:
          --profile <name>    which local account to use (default: default)
          --server <host:port>  override the server (init, signup, restore; later runs reuse it)
          --network <bitcoin|regtest>   for init, signup and restore
          --alias <name>      the name others see (default: the profile name)
          --wait <seconds>    how long to stay connected after a command (default: 5)
          --insecure          accept an untrusted TLS certificate
          --tribe-host <host:port>  the account's tribes server (init, signup and restore take it from
                              the config otherwise; later runs reuse it)
        """

    static func main() async {
        setvbuf(stdout, nil, _IOLBF, 0)
        umask(0o077)
        do {
            try await run()
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            exit(1)
        }
    }

    static func run() async throws {
        var arguments = Arguments(CommandLine.arguments.dropFirst())
        let profile = try Profile(name: arguments.option("--profile") ?? "default", kind: .development)
        let server = try arguments.option("--server").map { text in
            guard let address = ServerAddress(text) else { throw PeelError("cannot read server address \(text)") }
            return address
        }
        let network = arguments.option("--network") ?? "bitcoin"
        let alias = arguments.option("--alias") ?? profile.name
        let wait = arguments.option("--wait").flatMap { Int($0) } ?? 5
        let insecure = arguments.flag("--insecure")
        let tribeHost = arguments.option("--tribe-host")
        let description = arguments.option("--description")
        let pricePerMessage = try arguments.option("--price-per-message").map(msat(sats:)) ?? 0
        let priceToJoin = try arguments.option("--price-to-join").map(msat(sats:)) ?? 0
        guard let command = arguments.next() else {
            print(usage)
            return
        }
        func load() async throws -> Engine {
            try await Account.load(profile, server: server, tribeHost: tribeHost)
        }

        switch command {
        case "init":
            guard let server else { throw PeelError("init needs --server host:port") }
            let created = try await Account.create(
                profile, alias: alias, pin: "", network: network, server: server, tribeHost: tribeHost
            )
            try await Session(created.engine).connect(insecure: insecure).finish(after: wait)

        case "signup":
            guard let text = arguments.next() else { throw PeelError("signup needs an invite link, or - for stdin") }
            let invite = try Engine.parseInvite(text == "-" ? readLine() ?? "" : text)
            let created = try await Account.signup(
                profile, invite: invite, alias: alias, pin: "", network: network, server: server,
                tribeHost: tribeHost, allowUntrustedCertificate: insecure
            )
            print("account created in \(profile.directory.path)")
            try await Session(created.engine).finish(after: wait)

        case "restore":
            print("twelve words:")
            let engine = try await Account.restore(
                profile, mnemonic: readLine() ?? "", alias: alias, pin: "", network: network, server: server,
                tribeHost: tribeHost
            )
            let session = try await Session(engine).connect(insecure: insecure)
            // The engine fetches contacts and history itself once online.
            while await session.engine.isSyncingHistory {
                try await Task.sleep(for: .milliseconds(300))
            }
            try await session.finish(after: wait)

        case "whoami":
            let storage = try Storage(directory: profile.directory, readOnly: true)
            print("contact info: \(try storage.value(for: .contactInfo) ?? "not registered yet")")
            print("balance: \(try storage.value(for: .balanceMsat).flatMap { UInt64($0) }.map { "\($0 / 1000) sats" } ?? "unknown")")
            print("server: \(try storage.value(for: .server) ?? "none")")

        case "contacts":
            let storage = try Storage(directory: profile.directory, readOnly: true)
            for contact in try Engine.contacts(in: storage) {
                print("\(contact.pubkey)  \(contact.contactKey == nil ? "pending" : "ready")")
            }

        case "add":
            guard let info = arguments.next() else { throw PeelError("add needs contact info") }
            let session = try await Session(load()).connect(insecure: insecure)
            try await session.engine.addContact(info, alias: arguments.next())
            try await session.finish(after: wait)

        case "send":
            guard let pubkey = arguments.next(), !arguments.isEmpty else {
                throw PeelError("send needs a pubkey and some text")
            }
            let session = try await Session(load())
            // Offline, the send is still recorded, as failed, so it can be retried.
            do {
                _ = try await session.connect(insecure: insecure)
            } catch {
                print("not connected: \(error)")
            }
            try await session.engine.sendText(arguments.rest().joined(separator: " "), to: pubkey)
            try await session.finish(after: wait)

        case "messages":
            guard let chat = arguments.next() else { throw PeelError("messages needs a pubkey") }
            let storage = try Storage(directory: profile.directory, readOnly: true)
            for try await rows in storage.messages(in: chat) {
                for row in rows {
                    let index = row.serverIndex.map(String.init) ?? "-"
                    let delivery = row.delivery.map { " [\($0)]" } ?? ""
                    print("\(row.id ?? 0)  #\(index)  \(Session.line(row))\(delivery)")
                }
                break
            }

        case "resend", "discard":
            guard let id = arguments.next().flatMap({ Int64($0) }) else { throw PeelError("\(command) needs a message id") }
            if command == "discard" {
                try await load().discard(messageID: id)
                print("discarded \(id)")
                return
            }
            let session = try await Session(load()).connect(insecure: insecure)
            try await session.engine.resend(messageID: id)
            try await session.finish(after: wait)

        case "unread":
            let storage = try Storage(directory: profile.directory, readOnly: true)
            for try await states in storage.readStates() {
                for state in states.values.sorted(by: { $0.chat < $1.chat }) {
                    print("\(state.chat)  unread \(state.unread)  mute \(state.mute)")
                }
                break
            }

        case "read", "mute":
            guard let pubkey = arguments.next() else { throw PeelError("\(command) needs a pubkey") }
            let session = try await Session(load()).connect(insecure: insecure)
            if command == "read" {
                try await session.engine.markRead(pubkey)
            } else {
                guard let level = arguments.next().flatMap({ Int($0) }).flatMap(MuteLevel.init(rawValue:)) else {
                    throw PeelError("mute needs a level: 0, 1 or 2")
                }
                try await session.engine.setMute(pubkey, level: level)
            }
            try await session.finish(after: wait)

        case "tribes":
            let storage = try Storage(directory: profile.directory, readOnly: true)
            for tribe in try storage.tribes() {
                let flags = [tribe.isOwner ? "owner" : nil, tribe.left ? "left" : nil].compactMap { $0 }
                print("\(tribe.pubkey)  #\(tribe.displayName)  \(tribe.messageAmountMsat / 1000) sats/msg"
                    + (flags.isEmpty ? "" : "  (\(flags.joined(separator: ", ")))"))
                if let link = tribe.link { print("  \(link)") }
            }

        case "tribe-join":
            guard let link = arguments.next() else { throw PeelError("tribe-join needs a tribe link") }
            let session = try await Session(load()).connect(insecure: insecure)
            let tribe = try await session.engine.joinTribe(link: link)
            print("joined #\(tribe.displayName) \(tribe.pubkey)")
            try await session.finish(after: wait)

        case "tribe-members":
            guard let pubkey = arguments.next() else { throw PeelError("tribe-members needs a tribe pubkey") }
            let session = try await Session(load()).connect(insecure: insecure)
            let list = try await session.engine.tribeMembers(pubkey)
            print(list.complete ? "members:" : "seen posting (only the owner gets the full list):")
            for member in list.members {
                print("  \(member.alias)\(member.pending ? " (pending)" : "")  \(member.pubkey ?? "")")
            }
            try await session.finish(after: 0)

        case "tribe-leave":
            guard let pubkey = arguments.next() else { throw PeelError("tribe-leave needs a tribe pubkey") }
            let session = try await Session(load()).connect(insecure: insecure)
            try await session.engine.leaveTribe(pubkey)
            print("left \(pubkey)")
            try await session.finish(after: wait)

        case "tribe-create":
            guard !arguments.isEmpty else { throw PeelError("tribe-create needs a name") }
            let session = try await Session(load()).connect(insecure: insecure)
            let tribe = try await session.engine.createTribe(NewTribe(
                name: arguments.rest().joined(separator: " "), summary: description,
                pricePerMessageMsat: pricePerMessage, priceToJoinMsat: priceToJoin
            ))
            print("created #\(tribe.displayName) \(tribe.pubkey)")
            if let link = tribe.link { print(link) }
            try await session.finish(after: wait)

        case "listen":
            let session = try await Session(load())
            await session.engine.start(allowUntrustedCertificate: insecure)
            await session.printer.value

        default:
            throw PeelError("unknown command \(command)\n\(usage)")
        }
    }
}

/// An engine with its events printed as they arrive.
struct Session {
    let engine: Engine
    let printer: Task<Void, Never>

    init(_ engine: Engine) {
        self.engine = engine
        printer = Task {
            for await event in engine.events {
                print(Session.describe(event))
            }
        }
    }

    func connect(insecure: Bool) async throws -> Session {
        try await engine.connect(allowUntrustedCertificate: insecure)
        return self
    }

    func finish(after seconds: Int) async throws {
        try await Task.sleep(for: .seconds(seconds))
        await engine.disconnect()
    }

    static func describe(_ event: Engine.Event) -> String {
        switch event {
        case .connection(let state):
            state.label.lowercased()
        case .registered(let contactInfo):
            "registered: \(contactInfo ?? "contact info not known yet")"
        case .balance(let msat):
            "balance: \(msat / 1000) sats"
        case .message(let message):
            "\(message.fromMe ? "->" : "<-") \(message.chat.prefix(12))  \(line(message))"
        case .sendStatus(let tag, let status):
            "send \(status) \(tag?.prefix(12) ?? "")"
        case .history(let phase, let reached, let end):
            "history \(phase): \(reached) of \(end.map(String.init) ?? "?")"
        case .historyDone:
            "history complete"
        case .historyFailed(let reason):
            "history failed: \(reason)"
        case .conversationError(let chat, let message):
            "error in \(chat.prefix(12)): \(message)"
        case .connectionError(let message):
            "connecting: \(message)"
        case .coreError(let message):
            "core error: \(message)"
        }
    }
}

extension Session {
    /// Who sent a message, its type unless text, and what it says.
    static func line(_ message: Message) -> String {
        let who = message.fromMe ? "me" : message.senderAlias ?? String(message.chat.prefix(12))
        let kind = message.type == MessageType.text ? "" : " type \(message.type)"
        return "\(who)\(kind): \(message.content ?? "")"
    }
}

/// Whole sats from the command line, in msat.
func msat(sats text: String) throws -> UInt64 {
    guard let sats = UInt64(text), case let (msat, false) = sats.multipliedReportingOverflow(by: 1000),
          msat <= UInt64(Int64.max) else {
        throw PeelError("\(text) is not a number of sats")
    }
    return msat
}

struct Arguments {
    private var items: [String]

    init(_ items: some Sequence<String>) { self.items = Array(items) }

    var isEmpty: Bool { items.isEmpty }

    mutating func next() -> String? {
        items.isEmpty ? nil : items.removeFirst()
    }

    mutating func rest() -> [String] {
        defer { items = [] }
        return items
    }

    mutating func option(_ name: String) -> String? {
        guard let index = items.firstIndex(of: name), index + 1 < items.count else { return nil }
        defer { items.removeSubrange(index...index + 1) }
        return items[index + 1]
    }

    mutating func flag(_ name: String) -> Bool {
        guard let index = items.firstIndex(of: name) else { return false }
        items.remove(at: index)
        return true
    }
}
