import Foundation
import PeelCore

// A development harness for PeelCore. It keeps the mnemonic in a plain file so
// it can run unattended, which is only acceptable for throwaway accounts. The
// app stores the mnemonic in the Keychain instead.

@main
struct PeelCommand {
    static let usage = """
        usage: peel [options] <command>

          init                        new account with no invite (local test server)
          signup <invite>             new account from an invite code
          whoami                      this account's contact info and balance
          contacts                    contacts known to the core
          add <contact-info> [name]   start a key exchange with a contact
          send <pubkey> <text>        send a text message
          listen                      stay connected and print what arrives

        options:
          --profile <name>    which local account to use (default: default)
          --server <host:port>
          --network <bitcoin|regtest>
          --alias <name>      the name others see
          --wait <seconds>    how long to stay connected after a command (default: 5)
          --insecure          accept an untrusted TLS certificate
        """

    static func main() async {
        setvbuf(stdout, nil, _IOLBF, 0)
        do {
            try await run()
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            exit(1)
        }
    }

    static func run() async throws {
        var arguments = Arguments(CommandLine.arguments.dropFirst())
        let profile = Profile(name: arguments.option("--profile") ?? "default")
        var options = Options(
            server: arguments.option("--server"),
            network: arguments.option("--network") ?? "bitcoin",
            alias: arguments.option("--alias"),
            wait: arguments.option("--wait").flatMap { Int($0) } ?? 5,
            insecure: arguments.flag("--insecure")
        )
        guard let command = arguments.next() else {
            print(usage)
            return
        }

        switch command {
        case "init":
            try profile.save(mnemonic: Engine.generateMnemonic())
            let session = try await Session(profile: profile, options: options)
            try await session.finish(after: options.wait)

        case "signup":
            guard let text = arguments.next() else { throw CommandError("signup needs an invite code") }
            let invite = try Engine.parseInvite(text)
            options.server = options.server ?? invite.server
            try profile.save(mnemonic: Engine.generateMnemonic())
            print("mnemonic saved to \(profile.mnemonicFile.path)")
            let session = try await Session(profile: profile, options: options, inviteCode: invite.code)
            if let inviter = invite.inviterContactInfo {
                try await session.engine.addContact(inviter, alias: invite.inviterAlias, inviteCode: invite.code)
            }
            try await session.finish(after: options.wait)

        case "whoami":
            let storage = try Storage(directory: profile.directory)
            print("contact info: \(try storage.value(for: .contactInfo) ?? "not registered yet")")
            print("balance: \(try storage.value(for: .balanceMsat).flatMap { UInt64($0) }.map { "\($0 / 1000) sats" } ?? "unknown")")
            print("server: \(try storage.value(for: .server) ?? "none")")

        case "contacts":
            let engine = try Engine(
                mnemonic: profile.loadMnemonic(), storage: Storage(directory: profile.directory), network: options.network
            )
            for contact in try await engine.contacts() {
                print("\(contact.pubkey)  \(contact.contactKey == nil ? "pending" : "ready")")
            }

        case "add":
            guard let info = arguments.next() else { throw CommandError("add needs contact info") }
            let session = try await Session(profile: profile, options: options)
            try await session.engine.addContact(info, alias: arguments.next())
            try await session.finish(after: options.wait)

        case "send":
            guard let pubkey = arguments.next(), !arguments.isEmpty else {
                throw CommandError("send needs a pubkey and some text")
            }
            let session = try await Session(profile: profile, options: options)
            try await session.engine.sendText(arguments.rest().joined(separator: " "), to: pubkey)
            try await session.finish(after: options.wait)

        case "listen":
            let session = try await Session(profile: profile, options: options)
            await session.printer.value

        default:
            throw CommandError("unknown command \(command)\n\(usage)")
        }
    }
}

struct Options {
    var server: String?
    var network: String
    var alias: String?
    var wait: Int
    var insecure: Bool
}

struct CommandError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// A connected, registered account with its events printed as they arrive.
struct Session {
    let engine: Engine
    let printer: Task<Void, Never>

    init(profile: Profile, options: Options, inviteCode: String? = nil) async throws {
        let storage = try Storage(directory: profile.directory)
        let engine = try Engine(mnemonic: profile.loadMnemonic(), storage: storage, network: options.network)
        if let alias = options.alias {
            try await engine.setAlias(alias)
        }
        guard let server = try options.server ?? storage.value(for: .server) else {
            throw CommandError("no server known for this profile; pass --server host:port")
        }
        guard let address = ServerAddress(server) else {
            throw CommandError("cannot read server address \(server)")
        }
        self.engine = engine
        printer = Task {
            for await event in engine.events {
                print(Session.describe(event))
                if case .disconnected = event { break }
            }
        }
        try await engine.connect(to: address, inviteCode: inviteCode, allowUntrustedCertificate: options.insecure)
        try storage.set(server, for: .server)
        try await engine.waitUntilRegistered()
    }

    func finish(after seconds: Int) async throws {
        try await Task.sleep(for: .seconds(seconds))
        await engine.disconnect()
    }

    static func describe(_ event: Engine.Event) -> String {
        switch event {
        case .registered(let contactInfo):
            "registered: \(contactInfo ?? "contact info not known yet")"
        case .balance(let msat):
            "balance: \(msat / 1000) sats"
        case .message(let message):
            "\(message.fromMe ? "->" : "<-") \(message.chat.prefix(12)) type \(message.type): \(message.content ?? "")"
        case .sendStatus(let tag, let status):
            "send \(status) \(tag?.prefix(12) ?? "")"
        case .coreError(let message):
            "core error: \(message)"
        case .disconnected:
            "disconnected"
        }
    }
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
