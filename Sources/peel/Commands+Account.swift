import Foundation
import PeelCore

extension Invocation {
    /// Runs `command` if it is an account command: create and restore, who and
    /// what this account is, contacts. False if it is not one.
    mutating func account(_ command: String) async throws -> Bool {
        switch command {
        case "init":
            guard let server else { throw PeelError("init needs --server host:port") }
            let created = try await Account.create(
                profile, alias: alias, pin: "", network: network, server: server, tribeHost: tribeHost,
                memesHost: memesHost
            )
            try await Session(withPhoto(created.engine)).connect(insecure: insecure).finish(after: wait)

        case "signup":
            guard let text = arguments.next() else { throw PeelError("signup needs an invite link, or - for stdin") }
            let invite = try Engine.parseInvite(text == "-" ? readLine() ?? "" : text)
            let created = try await Account.signup(
                profile, invite: invite, alias: alias, pin: "", network: network, server: server,
                tribeHost: tribeHost, memesHost: memesHost, allowUntrustedCertificate: insecure
            )
            print("account created in \(profile.directory.path)")
            try await Session(withPhoto(created.engine)).finish(after: wait)

        case "restore":
            print("twelve words:")
            let engine = try await Account.restore(
                profile, mnemonic: readLine() ?? "", alias: alias, pin: "", network: network, server: server,
                tribeHost: tribeHost, memesHost: memesHost
            )
            let session = try await Session(withPhoto(engine)).connect(insecure: insecure)
            // The engine fetches contacts and history itself once online.
            while await session.engine.isSyncingHistory {
                try await Task.sleep(for: .milliseconds(300))
            }
            try await session.finish(after: wait)

        case "whoami":
            let storage = try readOnlyStorage()
            print("contact info: \(try storage.value(for: .contactInfo) ?? "not registered yet")")
            print("balance: \(try storage.balanceMsat().map { "\(Sats.format(msat: $0)) (\($0) msat)" } ?? "unknown")")
            print("server: \(try storage.value(for: .server) ?? "none")")
            print("name: \(try storage.value(for: .alias) ?? "")")
            print("photo: \(try storage.value(for: .photoURL).flatMap(\.nilIfEmpty) ?? "none")")

        case "rename":
            guard !arguments.isEmpty else { throw PeelError("rename needs a name") }
            let engine = try await load()
            try await engine.setAlias(arguments.rest().joined(separator: " "))
            print("name: \(await engine.myAlias)")

        case "upload-photo":
            guard let path = arguments.next() else { throw PeelError("upload-photo needs a picture") }
            let engine = try await load()
            print("photo: \(try await engine.uploadPhoto(URL(fileURLWithPath: path)))")

        case "contacts":
            let storage = try readOnlyStorage()
            for contact in try Engine.contacts(in: storage) {
                print("\(contact.pubkey)  \(contact.contactKey == nil ? "pending" : "ready")")
            }

        case "add":
            guard let info = arguments.next() else { throw PeelError("add needs contact info") }
            let session = try await Session(load()).connect(insecure: insecure)
            try await session.engine.addContact(info, alias: arguments.next())
            try await session.finish(after: wait)

        default:
            return false
        }
        return true
    }
}
