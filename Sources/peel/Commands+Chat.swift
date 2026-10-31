import Foundation
import PeelAgent
import PeelCore

extension Invocation {
    /// Runs `command` if it is a chat command: messages, attachments, threads,
    /// read state, mutes, time zones, `listen`. False if it is not one.
    mutating func chat(_ command: String) async throws -> Bool {
        switch command {
        case "send":
            guard let pubkey = arguments.next(), !arguments.isEmpty else {
                throw PeelError("send needs a pubkey and some text")
            }
            let session = try await Session(load())
            // Offline, the send is still recorded, as failed, so it can be retried.
            await session.connectIfPossible(insecure: insecure)
            try await session.engine.sendText(
                arguments.rest().joined(separator: " "), to: pubkey, replyTo: replyTo, inThread: inThread, metadata: metadata
            )
            try await session.finish(after: wait)

        case "send-control":
            guard let pubkey = arguments.next(), let json = arguments.next(), !arguments.isEmpty else {
                throw PeelError("send-control needs a pubkey, an envelope and some text")
            }
            guard let envelope = try? JSONDecoder().decode(ControlEnvelope.self, from: Data(json.utf8)),
                  envelope.isReadable else {
                throw PeelError("the envelope is not one this Peel writes")
            }
            let session = try await Session(load())
            await session.connectIfPossible(insecure: insecure)
            try await session.engine.sendControl(envelope, text: arguments.rest().joined(separator: " "), to: pubkey)
            try await session.finish(after: wait)

        case "send-file":
            guard let pubkey = arguments.next(), !arguments.isEmpty else {
                throw PeelError("send-file needs a pubkey and a file")
            }
            let files = arguments.rest().map { URL(fileURLWithPath: $0) }
            let session = try await Session(load())
            await session.connectIfPossible(insecure: insecure)
            let price = try priceOption.map { text in
                guard let sats = UInt64(text), sats > 0 else { throw PeelError("--price needs a whole number of sats") }
                return sats
            }
            let sent = await session.engine.sendAttachments(
                files, text: note ?? "", to: pubkey, replyTo: replyTo, inThread: inThread, priceSats: price
            )
            var refused: [String] = []
            for (file, result) in sent.results {
                switch result {
                case .success(let id): print("attachment row \(id)")
                case .failure(let error): refused.append("\(file.lastPathComponent): \(PeelError.readable(error))")
                }
            }
            try await session.finish(after: wait)
            if !refused.isEmpty { throw PeelError("could not send " + refused.joined(separator: "; ")) }

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
            let storage = try readOnlyStorage()
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
            let storage = try readOnlyStorage()
            for try await thread in storage.thread(uuid, in: chat) {
                print("original: \(thread.original.map(Session.line) ?? "not stored")")
                for row in thread.messages {
                    Session.printRow(row, parents: thread.parents)
                }
                break
            }

        case "threads":
            let storage = try readOnlyStorage()
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
                return true
            }
            let session = try await Session(load()).connect(insecure: insecure)
            try await confirming(confirmed) { try await session.engine.resend(messageID: id, confirmedMsat: $0) }
            try await session.finish(after: wait)

        case "unread":
            let storage = try readOnlyStorage()
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
                return true
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

        case "listen":
            let session = try await Session(load())
            await session.engine.answerDeviceRequests(with: DeviceReads(storage: session.engine.storage, myAlias: { await session.engine.myAlias }).handler)
            await session.engine.start(allowUntrustedCertificate: insecure)
            await session.printer.value

        case "device-agent":
            let engine = try await load()
            if let pubkey = arguments.next() {
                try await engine.setDeviceAgent(pubkey == "off" ? nil : pubkey)
            }
            print(await engine.deviceAgent ?? "off")

        default:
            return false
        }
        return true
    }
}
