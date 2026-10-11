import Foundation
import PeelCore

extension Invocation {
    /// Runs `command` if it is an account command: create and restore, who and
    /// what this account is, its contacts. False if it is not one.
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

        case "prefs":
            let storage = try readOnlyStorage()
            for row in try storage.preferenceRows() {
                let chat = row.identifier == Preferences.accountWide ? "" : "  \(row.identifier.prefix(12))"
                let when = row.updatedAt > 0
                    ? Date(timeIntervalSince1970: row.updatedAt).formatted(.iso8601) : "from before sync"
                print("\(row.key)\(chat)  \(row.value)  \(when)  \(row.followsAccount ? "account" : "this device")")
            }

        case "prefs-sync":
            let engine = try await load()
            if dryRun {
                // Keys and chats only: a value never leaves the engine here.
                let plan = try await engine.previewPreferences()
                print(plan.found ? "file found" : "no file yet: a sync would start one")
                for item in plan.applied { print("would apply   \(item.key) \(item.identifier.prefix(12))") }
                for item in plan.uploaded { print("would upload  \(item.key) \(item.identifier.prefix(12))") }
                if plan.applied.isEmpty, plan.uploaded.isEmpty { print("nothing to do") }
            } else {
                let sync = try await engine.syncPreferences()
                print("applied \(sync.applied) from the preferences file; \(sync.uploaded ? "uploaded it" : "nothing to upload")")
            }

        case "pref":
            guard let name = arguments.next() else { throw PeelError("pref needs a name: \(Self.prefNames)") }
            let value = arguments.next()
            let engine = try await load()
            switch name {
            case "confirm-over":
                if let value { try await engine.setPaymentConfirmation(msat: value == "0" ? 0 : try satsArgument(value)) }
                print("confirm payments over: \(Sats.format(msat: try await engine.paymentConfirmationMsat()))")
            case "time-zone":
                if let value { try await engine.setTimeZone(value == "auto" ? nil : value) }
                print("time zone: \(try await engine.chosenTimeZone() ?? "auto (this Mac's)")")
            case "pin-timeout":
                if let value {
                    guard let hours = Int(value), hours >= 0 else { throw PeelError("pin-timeout takes hours, 0 for only at launch") }
                    try await engine.setPINTimeout(hours: hours)
                }
                print("PIN timeout: \(try await engine.pinTimeoutHours().map { "\($0) hours" } ?? "not set")")
            case "notification-text":
                if let value { try await engine.setNotificationShowsText(yesNo(value)) }
                print("notification text: \(try await engine.notificationShowsText() ? "yes" : "no")")
            default:
                throw PeelError("unknown preference \(name); one of: \(Self.prefNames)")
            }

        case "contacts":
            let storage = try readOnlyStorage()
            for contact in try Engine.contacts(in: storage) {
                print("\(contact.pubkey)  \(contact.contactKey == nil ? "pending" : "ready")")
            }

        default:
            return false
        }
        return true
    }

    static let prefNames = "confirm-over <sats, 0 for every payment>, time-zone <IANA name|auto>, "
        + "pin-timeout <hours, 0 for only at launch>, notification-text <yes|no>"
}
