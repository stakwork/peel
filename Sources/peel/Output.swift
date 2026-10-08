import Foundation
import PeelCore

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
            print("not connected: \(PeelError.readable(error))")
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
        case .contactAdded(let message):
            "new contact: \(message.senderAlias ?? "someone") (\(message.chat)) added this account"
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
