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
          whoami                      this account's contact info, balance, name and photo
          rename <name>               the name others see on messages sent from now on
          upload-photo <picture>      upload a picture to the memes server and make it this account's photo
          contacts                    contacts known to the core
          add <contact-info> [name]   start a key exchange with a contact
          send <pubkey> <text>        send a text message to a contact or a tribe
                                      (--reply <uuid> answers a message, --thread <uuid> posts in its thread)
          listen                      stay connected, reconnecting as needed, and print what arrives
          messages <pubkey>           a chat's main conversation, as the app shows it: row ids, uuids,
                                      delivery, quoted parents and collapsed threads
          thread <pubkey> <uuid>      one thread: its original and its messages
          threads                     threads (tribes and contacts) this account started or wrote in, newest first
          resend <id>                 send an undelivered message again (a failed payment: --yes over
                                      the confirmation threshold)
          discard <id>                drop an undelivered message
          delete <id>                 delete a message for everyone (yours, or any in a tribe you own)
          unread                      unread counts and mute levels by chat
          read <pubkey>               mark a chat read up to its newest message (offline: sent on the next connect)
          mark-unread <pubkey> [index]  mark a chat unread from a message (server index), else from its
                                      newest incoming message
          mute <pubkey> <0|1|2>       notify for all, mentions only, or nothing
          local-time <pubkey> [alias] a contact's local time, or a tribe member's by alias, from the
                                      offset they last sent (within 90 days)
          share-timezone <pubkey> [yes|no]  whether this account's offset goes with what it sends in a
                                      direct message or private tribe (on unless turned off; never in
                                      a public tribe); sets it when given
          send-file <pubkey> <path>   send a file to a contact or a tribe (--text <caption>, --reply, --thread,
                                      --price <sats> to sell it: buyers pay to get its key)
          buy <id>                    buy someone's paid attachment (row id from messages; --yes over the
                                      confirmation threshold); it then downloads like any other
          download <id> <out path>    download and decrypt an attachment to a new file (never opened)

          tribes                      tribes this account is in
          tribe-join <link>           join from a sphinx.chat://?action=tribeV2 link
          tribe-members <pubkey>      a tribe's members (the full list only for its owner)
          tribe-leave <pubkey>        leave a tribe
          tribe-create <name>         create a tribe owned by this account on its tribes server
          tribe-edit <pubkey>         change a tribe this account owns; options left out stay as they are
                                      (both take --name (edit), --description, --image <https url>,
                                      --price-per-message, --price-to-join, --escrow in sats,
                                      --escrow-hours, --private <yes|no>, --unlisted <yes|no>)
          tribe-delete <pubkey>       delete a tribe this account owns
          tribe-approve <pubkey> <request-uuid | member-pubkey [alias]>
          tribe-reject <pubkey> <request-uuid | member-pubkey [alias]>
                                      answer a request to join a private tribe this account owns
          tribe-kick <pubkey> <member-pubkey>   remove a member from a tribe this account owns
          tribe-pin <pubkey> <uuid|-> pin a message in a tribe this account owns ("-" unpins)
          mentions                    tribe messages that mention this account

          boost <id> [sats]           boost someone else's message (row id from messages); in a tribe the
                                      tribe's price per message and escrow are added; without an
                                      amount, the one-tap boost with the account's boost amount,
                                      sent with no confirmation, as in the official apps
          pay <pubkey> <sats>         send sats to a contact in their chat (--text <note>)
                                      (both refuse more than the balance, and over the confirmation
                                      threshold without --yes)
          boost-amount [sats]         what a one-tap boost tips (default 100 sats); sets it when given (--yes over the threshold)
          payments [pubkey]           payments and boosts, in one chat or all, newest first
          history [pages]             fetch the server's payment history (50 rows a page, newest first) and
                                      print it joined to chats, notes and invoices
          invoice <sats> [memo]       make an invoice to receive sats; stays online --wait seconds to settle it
          decode <invoice>            what an invoice asks for, and whether this account paid it
          pay-invoice <invoice>       pay an invoice (--yes over the confirmation threshold); refuses expired,
                                      already paid or pending, own, and over the balance less a fee reserve
          request <pubkey> <sats> [memo]  ask a contact for sats in their chat (an invoice message)
          pay-request <id>            pay someone's request in a chat (row id from messages; --yes as above)

          call-start <pubkey>         start a video call in a contact's chat or a tribe and print its link
                                      (--audio for an audio call)

        options:
          --profile <name>    which development account to use (required; under Peel/dev,
                              never the app's own profile)
          --server <host:port>  override the server (init, signup, restore; later runs reuse it)
          --network <bitcoin|regtest>   for init, signup and restore
          --alias <name>      the name others see (default: the profile name)
          --photo <https url> the photo others see beside this account's messages ("" for none)
          --wait <seconds>    how long to stay connected after a command (default: 5)
          --insecure          accept an untrusted TLS certificate
          --tribe-host <host:port>  the account's tribes server (init, signup and restore take it from
                              the config otherwise; later runs reuse it)
          --memes-host <host:port>  the account's memes server for attachments (default
                              memes.sphinx.chat; later runs reuse it)
          --call-server <host:port>  the account's call server (default chat.sphinx.chat, none on a
                              local test server; later runs reuse it)
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
        // The app's own profile holds the real account; the CLI only ever opens
        // development profiles, and never one called "default" so the two cannot be confused.
        guard let name = arguments.option("--profile"), name.lowercased() != "default" else {
            throw PeelError("pass --profile <name> for a development account; \"default\" is reserved for the app")
        }
        let profile = try Profile(name: name, kind: .development)
        let server = try arguments.option("--server").map { text in
            guard let address = ServerAddress(text) else { throw PeelError("cannot read server address \(text)") }
            return address
        }
        let network = arguments.option("--network") ?? "bitcoin"
        let alias = arguments.option("--alias") ?? profile.name
        let photo = arguments.option("--photo")
        let wait = arguments.option("--wait").flatMap { Int($0) } ?? 5
        let insecure = arguments.flag("--insecure")
        let tribeHost = arguments.option("--tribe-host")
        let tribeOptions = try TribeOptions(&arguments)
        let replyTo = arguments.option("--reply")
        let inThread = arguments.option("--thread")
        let memesHost = arguments.option("--memes-host")
        let note = arguments.option("--text")
        let confirmed = arguments.flag("--yes")
        let priceOption = arguments.option("--price")
        let callServer = arguments.option("--call-server")
        let audioOnly = arguments.flag("--audio")
        guard let command = arguments.next() else {
            print(usage)
            return
        }
        func withPhoto(_ engine: Engine) async throws -> Engine {
            if let photo { try await engine.setPhotoURL(photo) }
            if let callServer { try await engine.setCallServer(callServer) }
            return engine
        }
        func load() async throws -> Engine {
            try await withPhoto(Account.load(profile, server: server, tribeHost: tribeHost, memesHost: memesHost))
        }

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
            let storage = try Storage(directory: profile.directory, readOnly: true)
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
            await session.connectIfPossible(insecure: insecure)
            try await session.engine.sendText(
                arguments.rest().joined(separator: " "), to: pubkey, replyTo: replyTo, inThread: inThread
            )
            try await session.finish(after: wait)

        case "send-file":
            guard let pubkey = arguments.next(), let path = arguments.next() else {
                throw PeelError("send-file needs a pubkey and a file")
            }
            let session = try await Session(load())
            await session.connectIfPossible(insecure: insecure)
            let price = try priceOption.map { text in
                guard let sats = UInt64(text), sats > 0 else { throw PeelError("--price needs a whole number of sats") }
                return sats
            }
            let id = try await session.engine.sendAttachment(
                URL(fileURLWithPath: path), text: note ?? "", to: pubkey, replyTo: replyTo, inThread: inThread,
                priceSats: price
            )
            print("attachment row \(id)")
            try await session.finish(after: wait)

        case "buy":
            guard let id = arguments.next().flatMap({ Int64($0) }) else { throw PeelError("buy needs a message id") }
            let session = try await Session(load()).connect(insecure: insecure)
            try await confirming(confirmed) { try await session.engine.buyAttachment(messageID: id, confirmedMsat: $0) }
            try await session.finish(after: wait)

        case "download":
            guard let id = arguments.next().flatMap({ Int64($0) }), let out = arguments.next() else {
                throw PeelError("download needs a message id and a path to write to")
            }
            guard !FileManager.default.fileExists(atPath: out) else { throw PeelError("\(out) already exists") }
            // A session, so download progress is printed.
            let session = try await Session(load())
            let file = try await session.engine.downloadAttachment(messageID: id)
            // A new file only, quarantined, and never opened: what to do with it is the person's call.
            try UserFiles.copy(file.file, to: URL(fileURLWithPath: out), replacing: false)
            try await Task.sleep(for: .milliseconds(100))
            print("\(file.kind) \(file.size) bytes\(file.fileName.map { " \"\($0)\"" } ?? "")"
                + "\(file.cached ? " (cached)" : "") -> \(out)")

        case "messages":
            guard let chat = arguments.next() else { throw PeelError("messages needs a pubkey") }
            let storage = try Storage(directory: profile.directory, readOnly: true)
            for try await timeline in storage.timeline(in: chat) {
                for row in timeline.messages {
                    Session.printRow(row, parents: timeline.parents)
                    if let boosts = row.uuid.flatMap({ timeline.boosts[$0] }) {
                        let who = boosts.boosts.map { $0.fromMe ? "me" : $0.alias ?? "?" }
                        print("      boosted \(boosts.count)x, \(Sats.format(msat: boosts.totalMsat)), by \(who.joined(separator: ", "))")
                    }
                    if let thread = row.threadUUID.flatMap({ timeline.threads[$0] }) {
                        print("      thread of \(thread.count), \(thread.unread) unread, started by \(Session.line(thread.original))")
                    }
                    if let request = row.id.flatMap({ timeline.requests[$0] }) {
                        let expired = request.invoice?.isExpired() == true ? ", expired" : ""
                        let payee = request.paysRequester || row.fromMe ? "" : ", pays another node"
                        print("      request \(request.state)\(expired)\(payee)")
                    }
                    if let purchase = row.id.flatMap({ timeline.purchases[$0] }) {
                        print("      paid attachment, \(Sats.format(msat: row.attachmentPriceMsat ?? 0)): \(purchase)")
                    }
                }
                break
            }

        case "thread":
            guard let chat = arguments.next(), let uuid = arguments.next() else {
                throw PeelError("thread needs a pubkey and the uuid of the thread's original message")
            }
            let storage = try Storage(directory: profile.directory, readOnly: true)
            for try await thread in storage.thread(uuid, in: chat) {
                print("original: \(thread.original.map(Session.line) ?? "not stored")")
                for row in thread.messages {
                    Session.printRow(row, parents: thread.parents)
                }
                break
            }

        case "threads":
            let storage = try Storage(directory: profile.directory, readOnly: true)
            for try await threads in storage.threads() {
                for thread in threads {
                    print("\(thread.chat.prefix(12))  \(thread.uuid)  \(thread.count) messages, \(thread.unread) unread")
                    print("      \(Session.line(thread.original))")
                }
                break
            }

        case "delete":
            guard let id = arguments.next().flatMap({ Int64($0) }) else { throw PeelError("delete needs a message id") }
            let session = try await Session(load()).connect(insecure: insecure)
            try await session.engine.deleteMessage(id: id)
            print("deleted \(id)")
            try await session.finish(after: wait)

        case "resend", "discard":
            guard let id = arguments.next().flatMap({ Int64($0) }) else { throw PeelError("\(command) needs a message id") }
            if command == "discard" {
                try await load().discard(messageID: id)
                print("discarded \(id)")
                return
            }
            let session = try await Session(load()).connect(insecure: insecure)
            try await confirming(confirmed) { try await session.engine.resend(messageID: id, confirmedMsat: $0) }
            try await session.finish(after: wait)

        case "unread":
            let storage = try Storage(directory: profile.directory, readOnly: true)
            for try await states in storage.readStates() {
                for state in states.values.sorted(by: { $0.chat < $1.chat }) {
                    print("\(state.chat)  unread \(state.unread)  mentions \(state.mentions)  mute \(state.mute)"
                        + "  shown \(state.shownUnread)  last read \(state.lastRead.map(String.init) ?? "none")")
                }
                break
            }

        case "read", "mark-unread":
            // Offline, the marker is kept as pending and sent on the next connect.
            guard let pubkey = arguments.next() else { throw PeelError("\(command) needs a pubkey") }
            let session = try await Session(load())
            await session.connectIfPossible(insecure: insecure)
            if command == "read" {
                try await session.engine.markRead(pubkey)
            } else {
                let index = try arguments.next().map { text in
                    guard let index = Int64(text) else { throw PeelError("mark-unread needs a server index") }
                    return index
                }
                try await session.engine.markUnread(pubkey, fromServerIndex: index)
            }
            try await session.finish(after: wait)

        case "mute":
            guard let pubkey = arguments.next() else { throw PeelError("mute needs a pubkey") }
            let session = try await Session(load()).connect(insecure: insecure)
            guard let level = arguments.next().flatMap({ Int($0) }).flatMap(MuteLevel.init(rawValue:)) else {
                throw PeelError("mute needs a level: 0, 1 or 2")
            }
            try await session.engine.setMute(pubkey, level: level)
            try await session.finish(after: wait)

        case "local-time":
            guard let pubkey = arguments.next() else { throw PeelError("local-time needs a pubkey") }
            let engine = try await load()
            guard let local = try await engine.localTime(of: pubkey, member: arguments.rest().joined(separator: " ").nilIfEmpty) else {
                print("no time zone from them in the last 90 days")
                return
            }
            let time = Date.now.formatted(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: local.zone))
            let hours = Double(local.difference) / 3600
            let difference = hours == 0 ? "same as yours"
                : "\(abs(hours).formatted()) h \(hours > 0 ? "ahead" : "behind")"
            print("\(time) local time · \(difference) · sent \(local.sent) on \(local.seen.formatted())")

        case "share-timezone":
            guard let pubkey = arguments.next() else { throw PeelError("share-timezone needs a pubkey") }
            let engine = try await load()
            if let choice = arguments.next() {
                try await engine.setTimeZoneSharing(yesNo(choice), in: pubkey)
            }
            if let offset = try await engine.offsetShared(in: pubkey) {
                print("sharing \(offset) (\(try await engine.timeZone(for: pubkey).identifier))")
            } else {
                print(try await engine.timeZoneSharing(in: pubkey)
                    ? "never sent here: not a direct message or private tribe" : "not sharing (turned off)")
            }

        case "tribes":
            let storage = try Storage(directory: profile.directory, readOnly: true)
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
            let storage = try Storage(directory: profile.directory, readOnly: true)
            for try await rows in storage.mentions() {
                for row in rows {
                    print("\(row.chat.prefix(12))  #\(row.serverIndex.map(String.init) ?? "-")  \(Session.line(row))")
                }
                break
            }

        case "boost":
            guard let id = arguments.next().flatMap({ Int64($0) }) else { throw PeelError("boost needs a message id") }
            let msat = try arguments.next().map(satsArgument)
            let session = try await Session(load()).connectIfPossible(insecure: insecure)
            if let msat {
                try await confirming(confirmed) {
                    try await session.engine.boost(messageID: id, amountMsat: msat, confirmedMsat: $0)
                }
            } else if try await session.engine.quickBoost(messageID: id) == nil {
                print("already boosted; one-tap boosts a message once")
            }
            try await session.finish(after: wait)

        case "pay":
            guard let pubkey = arguments.next(), let msat = arguments.next().flatMap(Sats.msat) else {
                throw PeelError("pay needs a pubkey and a whole number of sats above zero")
            }
            let session = try await Session(load()).connectIfPossible(insecure: insecure)
            try await confirming(confirmed) {
                try await session.engine.sendPayment(to: pubkey, amountMsat: msat, text: note ?? "", confirmedMsat: $0)
            }
            try await session.finish(after: wait)

        case "boost-amount":
            let engine = try await load()
            if let msat = try arguments.next().map(satsArgument) {
                try await confirming(confirmed) { try await engine.setBoostAmount(msat: msat, confirmedMsat: $0) }
            }
            print("boost amount: \(Sats.format(msat: try await engine.boostAmountMsat()))")

        case "payments":
            let storage = try Storage(directory: profile.directory, readOnly: true)
            for try await rows in storage.payments(in: arguments.next()) {
                for row in rows {
                    let delivery = row.delivery.map { " [\($0)]" } ?? ""
                    print("\(row.id ?? 0)  \(row.chat.prefix(12))  \(Session.line(row))\(delivery)")
                }
                break
            }

        case "history":
            let pages = arguments.next().flatMap { Int($0) } ?? 1
            let session = try await Session(load()).connectIfPossible(insecure: insecure)
            var before: Int64?
            for _ in 0..<max(pages, 1) {
                guard await session.engine.isRegistered else { break }
                let count = try await session.engine.fetchPaymentHistory(before: before)
                print("fetched \(count) rows")
                before = try session.engine.storage.oldestPaymentTimestamp()
                if count < Engine.paymentPageSize { break }
            }
            try await session.finish(after: 0)
            for try await items in session.engine.storage.paymentHistory(limit: Int(Engine.paymentPageSize) * pages) {
                for item in items { print(Session.line(item)) }
                break
            }

        case "invoice":
            guard let msat = arguments.next().flatMap(Sats.msat) else { throw PeelError("invoice needs a whole number of sats above zero") }
            let session = try await Session(load()).connect(insecure: insecure)
            let invoice = try await session.engine.createInvoice(amountMsat: msat, memo: arguments.rest().joined(separator: " "))
            print("invoice \(invoice.paymentHash)")
            print(invoice.bolt11)
            // The server takes the payment even offline; stay online to see it paid. Ctrl-C stops.
            try await session.finish(after: wait)

        case "decode":
            guard let text = arguments.next() else { throw PeelError("decode needs an invoice") }
            let invoice = try Invoice(text)
            print("amount: \(Sats.format(msat: invoice.amountMsat)) (\(invoice.amountMsat) msat)")
            print("payee: \(invoice.payee)")
            print("memo: \(invoice.memo)")
            print("expires: \(invoice.expiresAt.map { "\($0)\(invoice.isExpired() ? " (expired)" : "")" } ?? "never")")
            print("payment hash: \(invoice.paymentHash)")
            let storage = try Storage(directory: profile.directory, readOnly: true)
            print("paid: \(try storage.paidState(paymentHash: invoice.paymentHash).map { "\($0)" } ?? "no")")

        case "pay-invoice":
            guard let text = arguments.next() else { throw PeelError("pay-invoice needs an invoice") }
            let session = try await Session(load()).connect(insecure: insecure)
            try await confirming(confirmed) {
                let paid = try await session.engine.payInvoice(text, confirmedMsat: $0)
                print("paying \(Sats.format(msat: paid.amountMsat)), tag \(paid.tag ?? "-")")
            }
            try await session.finish(after: wait)

        case "request":
            guard let pubkey = arguments.next(), let msat = arguments.next().flatMap(Sats.msat) else {
                throw PeelError("request needs a pubkey and an amount in sats")
            }
            let session = try await Session(load()).connect(insecure: insecure)
            let invoice = try await session.engine.requestPayment(
                from: pubkey, amountMsat: msat, memo: arguments.rest().joined(separator: " ")
            )
            print("requested \(Sats.format(msat: msat)), invoice \(invoice.paymentHash)")
            try await session.finish(after: wait)

        case "pay-request":
            guard let id = arguments.next().flatMap({ Int64($0) }) else { throw PeelError("pay-request needs a message id") }
            let session = try await Session(load()).connect(insecure: insecure)
            try await confirming(confirmed) {
                let paid = try await session.engine.payRequest(messageID: id, confirmedMsat: $0)
                print("paying \(Sats.format(msat: paid.amountMsat)), tag \(paid.tag ?? "-")")
            }
            try await session.finish(after: wait)

        case "call-start":
            guard let pubkey = arguments.next() else { throw PeelError("call-start needs a pubkey") }
            let session = try await Session(load()).connect(insecure: insecure)
            let call = try await session.engine.startCall(in: pubkey, audioOnly: audioOnly)
            print("call: \(call.link.url.absoluteString)")
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
                var text = Session.describe(event)
                if case .message(let message, _) = event {
                    if let link = await engine.callLink(in: message) {
                        text += " [\(link.audioOnly ? "audio" : "video") call, room \(link.room)]"
                    } else if message.type == MessageType.call {
                        text += " [not a call link on this account's call server, or it has none]"
                    }
                }
                print(text)
            }
        }
    }

    func connect(insecure: Bool) async throws -> Session {
        try await engine.connect(allowUntrustedCertificate: insecure)
        return self
    }

    /// Offline, a send is still recorded, as failed, so it can be retried.
    @discardableResult
    func connectIfPossible(insecure: Bool) async -> Session {
        do {
            return try await connect(insecure: insecure)
        } catch {
            print("not connected: \(error)")
            return self
        }
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
            "balance: \(Sats.format(msat: msat))"
        case .message(let message, _):
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
        case .profile(let alias, let photoURL):
            "profile: \(alias), photo \(photoURL ?? "none")"
        case .echoedAliases(let echoed):
            "own tribe aliases: \(echoed.mapValues { $0.sorted() })"
        case .transfer(let id, let direction, let bytes, let total):
            "\(direction) \(id): \(bytes) of \(total) bytes"
        case .moneyReceived(let message):
            "received \(Sats.format(msat: message.amountMsat ?? 0)) in \(message.chat.prefix(12)) (row \(message.id ?? 0))"
        case .invoicePaid(let invoice):
            "invoice paid \(invoice.paymentHash) (\(invoice.status.rawValue), \(Sats.format(msat: invoice.paidMsat ?? 0)))"
        }
    }
}

extension Session {
    /// One stored row: id, server index, uuid, what it says, delivery, and
    /// the message it replies to, if stored.
    static func printRow(_ row: Message, parents: [String: Message]) {
        let index = row.serverIndex.map(String.init) ?? "-"
        let delivery = row.delivery.map { " [\($0)]" } ?? ""
        let mention = row.mentionsMe ? " [mentions me]" : ""
        let deleted = row.deleted ? " [deleted]" : ""
        let tz = row.senderTZ.map { " [tz \($0)\(row.senderTimeZone == nil ? ", unreadable" : "")]" } ?? ""
        print("\(row.id ?? 0)  #\(index)  \(row.uuid ?? "-")  \(line(row))\(delivery)\(mention)\(deleted)\(tz)")
        if let reply = row.replyUUID {
            print("      in reply to \(parents[reply].map(line) ?? "\(reply) (not stored)")")
        }
    }

    /// Who sent a message, its type unless text, and what it says; for a
    /// payment or boost the amount, and the message boosted.
    static func line(_ message: Message) -> String {
        let who = message.fromMe ? "me" : message.senderAlias ?? String(message.chat.prefix(12))
        let kind = switch message.type {
        case MessageType.text: ""
        case MessageType.directPayment: " paid \(Sats.format(msat: message.amountMsat ?? 0))"
        case MessageType.boost: " boosted \(Sats.format(msat: message.amountMsat ?? 0)) on \(message.replyUUID?.prefix(12) ?? "-")"
        case MessageType.invoice: " requested \(Sats.format(msat: message.amountMsat ?? 0))"
        case MessageType.invoicePayment: " paid a request, \(Sats.format(msat: message.amountMsat ?? 0))"
        case MessageType.call: " call"
        default: " type \(message.type)"
        }
        var file = ""
        if let attachment = message.attachmentKind {
            let details = [message.mediaType, message.fileName, message.fileSize.map { "\($0) bytes" },
                           message.uploadState.map { "upload \($0)" }].compactMap { $0 }
            file = " [\(attachment): \(details.joined(separator: ", "))]"
        }
        return "\(who)\(kind)\(file): \(message.content ?? "")"
    }

    /// One line of payment history: when, direction and amount, status,
    /// kind, who, note, and the payment hash.
    static func line(_ item: PaymentItem) -> String {
        let sign = item.incoming ? "+" : "-"
        let status = switch item.status {
        case .complete: ""
        case .pending: " [pending]"
        case .failed: " [failed\(item.error.map { ": \($0)" } ?? "")]"
        }
        let who = item.counterpart ?? (item.kind == .keysend ? "keysend" : "-")
        let place = item.isTribe ? " in #\(item.chatName ?? "")" : ""
        let fee = item.feeMsat.map { " fee \($0) msat" } ?? ""
        let time = item.date.formatted(date: .numeric, time: .standard)
        return "\(time)  \(sign)\(Sats.format(msat: item.amountMsat))\(status)  \(item.kind) \(who)\(place)"
            + "  \(item.note ?? "")\(fee)  \(item.paymentHash?.prefix(12) ?? "-")"
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

    init(_ arguments: inout Arguments) throws {
        name = arguments.option("--name")
        summary = arguments.option("--description")
        photoURL = arguments.option("--image")
        func option(_ name: String, unit: UInt64, of what: String) throws -> UInt64? {
            try arguments.option(name).map { try Sats.parse($0, unit: unit, of: what) }
        }
        pricePerMessage = try option("--price-per-message", unit: 1000, of: "price per message")
        priceToJoin = try option("--price-to-join", unit: 1000, of: "price to join")
        escrow = try option("--escrow", unit: 1000, of: "escrow")
        escrowMillis = try option("--escrow-hours", unit: 3_600_000, of: "escrow time")
        isPrivate = try arguments.option("--private").map(yesNo)
        unlisted = try arguments.option("--unlisted").map(yesNo)
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
        return settings
    }
}

/// An amount in sats from the command line, as msat.
func satsArgument(_ text: String) throws -> UInt64 {
    guard let msat = Sats.msat(text) else { throw PeelError("the amount must be a whole number of sats above zero") }
    return msat
}

/// A payment over the confirmation threshold: with `--yes`, sent again for
/// the amount the engine names (and printed); without, the refusal stands.
func confirming(_ yes: Bool, _ send: (UInt64?) async throws -> Void) async throws {
    do {
        try await send(nil)
    } catch Engine.Failure.needsConfirmation(let msat) where yes {
        print("confirmed \(Sats.format(msat: msat)) (\(msat) msat)")
        try await send(msat)
    }
}

func yesNo(_ text: String) throws -> Bool {
    switch text {
    case "yes": true
    case "no": false
    default: throw PeelError("expected yes or no, not \(text)")
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
