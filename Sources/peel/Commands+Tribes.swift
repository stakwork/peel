import Foundation
import PeelCore

extension Invocation {
    /// Runs `command` if it is a tribe command. False if it is not one.
    mutating func tribes(_ command: String) async throws -> Bool {
        switch command {
        case "tribes":
            let storage = try readOnlyStorage()
            for tribe in try storage.tribes() {
                let flags = [
                    tribe.isOwner ? "owner" : nil, tribe.left ? "left" : nil, tribe.isPrivate ? "private" : nil,
                    tribe.status == .active ? nil : "\(tribe.status)", tribe.pin.map { "pin \($0)" },
                ].compactMap { $0 }
                print("\(tribe.pubkey)  #\(tribe.displayName)  \(Sats.format(msat: tribe.messageAmountMsat))/msg"
                    + (flags.isEmpty ? "" : "  (\(flags.joined(separator: ", ")))"))
                if let link = tribe.link { print("  \(link)") }
            }

        case "tribe-join":
            guard let link = arguments.next() else { throw PeelError("tribe-join needs a tribe link") }
            let session = try await Session(load()).connect(insecure: insecure)
            try await confirming(confirmed) {
                let tribe = try await session.engine.joinTribe(link: link, confirmedMsat: $0)
                print("joined #\(tribe.displayName) \(tribe.pubkey)")
            }
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

        case "tribe-info":
            guard let pubkey = arguments.next() else { throw PeelError("tribe-info needs a tribe pubkey") }
            let details = try await load().tribeDetails(pubkey)
            let info = details.info
            func sats(_ msat: Int64?) -> String { Sats.format(msat: UInt64(max(msat ?? 0, 0))) }
            print("#\(info.name)  \(info.isPrivate == true ? "private" : "public")")
            if let summary = info.summary?.nilIfEmpty { print("  \(summary)") }
            print("  owner \(info.ownerAlias ?? "unknown")" + (details.ownerPhotoURL.map { "  \($0)" } ?? ""))
            if let created = info.created { print("  created \(created.formatted(.iso8601))") }
            if let count = info.memberCount { print("  \(count) members") }
            print("  join \(sats(info.priceToJoin)), per message \(sats(info.pricePerMessage)), escrow \(sats(info.escrowAmount))")
            if let tags = info.tags, !tags.isEmpty { print("  tags \(tags.joined(separator: ", "))") }

        case "tribe-alias":
            guard let pubkey = arguments.next() else {
                throw PeelError("tribe-alias needs a tribe pubkey, then a name and a photo url (- for the account's)")
            }
            let engine = try await load()
            guard let current = try engine.storage.tribes().first(where: { $0.pubkey == pubkey }) else {
                throw Engine.Failure.notInTribe
            }
            /// Left out keeps what is set; "-" is the account's own.
            func value(_ given: String?, _ current: String?) -> String? {
                guard let given else { return current }
                return given == "-" ? nil : given
            }
            let alias = value(arguments.next(), current.myAlias)
            let tribe = try await engine.setTribeIdentity(
                pubkey, alias: alias, photoURL: value(arguments.next(), current.myPhotoURL)
            )
            print("in #\(tribe.displayName): \(tribe.myAlias ?? "the account's name")"
                + ", \(tribe.myPhotoURL ?? "the account's photo")")

        case "tribe-leave":
            guard let pubkey = arguments.next() else { throw PeelError("tribe-leave needs a tribe pubkey") }
            let session = try await Session(load()).connect(insecure: insecure)
            try await session.engine.leaveTribe(pubkey)
            print("left \(pubkey)")
            try await session.finish(after: wait)

        case "tribe-create":
            guard !arguments.isEmpty else { throw PeelError("tribe-create needs a name") }
            let session = try await Session(load()).connect(insecure: insecure)
            let tribe = try await session.engine.createTribe(
                tribeOptions.apply(to: TribeSettings(name: arguments.rest().joined(separator: " ")))
            )
            print("created #\(tribe.displayName) \(tribe.pubkey)")
            if let link = tribe.link { print(link) }
            try await session.finish(after: wait)

        case "tribe-edit":
            guard let pubkey = arguments.next() else { throw PeelError("tribe-edit needs a tribe pubkey") }
            let session = try await Session(load()).connect(insecure: insecure)
            let current = try await session.engine.tribeSettings(pubkey)
            let tribe = try await session.engine.updateTribe(pubkey, settings: tribeOptions.apply(to: current))
            print("updated #\(tribe.displayName)")
            try await session.finish(after: 0)

        case "tribe-delete":
            guard let pubkey = arguments.next() else { throw PeelError("tribe-delete needs a tribe pubkey") }
            let session = try await Session(load()).connect(insecure: insecure)
            try await session.engine.deleteTribe(pubkey)
            print("deleted \(pubkey)")
            try await session.finish(after: wait)

        case "tribe-approve", "tribe-reject":
            guard let pubkey = arguments.next(), let who = arguments.next() else {
                throw PeelError("\(command) needs a tribe pubkey and a request uuid or member pubkey")
            }
            let request: Engine.JoinRequest = who.isPubkey
                ? .member(pubkey: who, alias: arguments.next() ?? "") : .message(uuid: who)
            let session = try await Session(load()).connect(insecure: insecure)
            try await session.engine.answerJoinRequest(in: pubkey, request, approve: command == "tribe-approve")
            print(command == "tribe-approve" ? "approved" : "rejected")
            try await session.finish(after: wait)

        case "tribe-kick":
            guard let pubkey = arguments.next(), let member = arguments.next() else {
                throw PeelError("tribe-kick needs a tribe pubkey and a member pubkey")
            }
            let session = try await Session(load()).connect(insecure: insecure)
            try await session.engine.kickMember(member, from: pubkey)
            print("removed \(member)")
            try await session.finish(after: wait)

        case "tribe-pin":
            guard let pubkey = arguments.next(), let uuid = arguments.next() else {
                throw PeelError("tribe-pin needs a tribe pubkey and a message uuid, or - to unpin")
            }
            let session = try await Session(load()).connect(insecure: insecure)
            try await session.engine.pinMessage(uuid == "-" ? nil : uuid, in: pubkey)
            print(uuid == "-" ? "unpinned" : "pinned \(uuid)")
            try await session.finish(after: 0)

        case "mentions":
            let storage = try readOnlyStorage()
            for try await rows in storage.mentions() {
                for row in rows {
                    print("\(row.chat.prefix(12))  #\(row.serverIndex.map(String.init) ?? "-")  \(Session.line(row))")
                }
                break
            }

        default:
            return false
        }
        return true
    }
}

/// The tribe settings given on the command line; each one left out keeps
/// what the tribe has (or the default, for a new tribe).
struct TribeOptions {
    var name: String?
    var summary: String?
    var photoURL: String?
    var pricePerMessage: UInt64?
    var priceToJoin: UInt64?
    var escrow: UInt64?
    var escrowMillis: UInt64?
    var isPrivate: Bool?
    var unlisted: Bool?
    var tags: [String]?

    init(_ arguments: inout Arguments) throws {
        name = arguments.option("--name")
        summary = arguments.option("--description")
        photoURL = arguments.option("--image")
        func option(_ name: String, unit: UInt64, of what: String) throws -> UInt64? {
            try arguments.option(name).map { try Sats.parse($0, unit: unit, of: what) }
        }
        pricePerMessage = try option("--price-per-message", unit: Sats.msatPerSat, of: "price per message")
        priceToJoin = try option("--price-to-join", unit: Sats.msatPerSat, of: "price to join")
        escrow = try option("--escrow", unit: Sats.msatPerSat, of: "escrow")
        escrowMillis = try option("--escrow-hours", unit: Sats.millisecondsPerHour, of: "escrow time")
        isPrivate = try arguments.option("--private").map(yesNo)
        unlisted = try arguments.option("--unlisted").map(yesNo)
        tags = arguments.option("--tags").map { $0.split(separator: ",").map(String.init) }
    }

    func apply(to settings: TribeSettings) -> TribeSettings {
        var settings = settings
        if let name { settings.name = name }
        if let summary { settings.summary = summary }
        if let photoURL { settings.photoURL = photoURL }
        if let pricePerMessage { settings.pricePerMessageMsat = pricePerMessage }
        if let priceToJoin { settings.priceToJoinMsat = priceToJoin }
        if let escrow { settings.escrowMsat = escrow }
        if let escrowMillis { settings.escrowMillis = escrowMillis }
        if let isPrivate { settings.isPrivate = isPrivate }
        if let unlisted { settings.unlisted = unlisted }
        if let tags { settings.tags = tags }
        return settings
    }
}
