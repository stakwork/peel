import Foundation
import PeelCore

extension Invocation {
    /// Runs `command` if it is a money command: boosts, payments, history,
    /// invoices and requests. False if it is not one.
    mutating func money(_ command: String) async throws -> Bool {
        switch command {
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
            let storage = try readOnlyStorage()
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
            let storage = try readOnlyStorage()
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

        default:
            return false
        }
        return true
    }
}

/// An amount in sats from the command line, as msat.
func satsArgument(_ text: String) throws -> UInt64 {
    guard let msat = Sats.msat(text) else { throw PeelError("the amount must be a whole number of sats above zero") }
    return msat
}
