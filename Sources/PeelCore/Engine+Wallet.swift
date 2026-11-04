import Foundation
import Sphinxrs

/// The engine's side of the app wallet (docs/app-wallet.md): a keysend to
/// any node or Sphinx address, an invoice paid or made for an app, each
/// tagged with the wallet connection it went through and counted against
/// that connection's budget in the same commit, and the transactions read
/// back for the wallet host (`WalletHost`, through `EngineWallet`).
extension Engine {
    /// An app's payment or invoice: the wallet connection it goes through
    /// (`WalletConnection.key`), the app (`<peer>/<name>`), and for a
    /// payment the budget it must fit in.
    public struct WalletTag: Sendable, Equatable {
        public var connection: String
        public var app: String
        /// Checked in the commit that writes the payment; nil for an invoice made.
        public var budget: WalletBudget.Guard?

        public init(connection: String, app: String, budget: WalletBudget.Guard? = nil) {
            self.connection = connection
            self.app = app
            self.budget = budget
        }
    }

    /// Sends `amountMsat` to `pubkey` as a keysend, over the core's own
    /// `keysend`: to any node, or with `routeHint` (`<lsp_pubkey>_<scid>`, a
    /// Sphinx address's tail) the asynchronous way, held by the server until
    /// the payee comes online, with a 1-sat ping. `data` rides in the
    /// core's record 13377331, as base64. Checked as every send of ours
    /// (the balance less what waits, less a fee reserve and the ping) but
    /// never against the person's confirmation threshold: an app's
    /// payments are held to their connection's budget instead, in the
    /// commit (`wallet.budget`), which refuses and publishes nothing when it
    /// does not fit. Recorded as pending before anything is published, so
    /// it is never sent twice; the server's word settles it, with its
    /// preimage when it gives one.
    @discardableResult
    public func keysend(
        to pubkey: String, amountMsat: UInt64, routeHint: String? = nil, data: Data? = nil, for wallet: WalletTag
    ) async throws -> KeysendRecord {
        guard amountMsat > 0 else { throw Failure.invalidAmount }
        let pubkey = pubkey.lowercased()
        guard WalletProtocol.isPubkey(pubkey) else { throw Failure.notANodeKey }
        guard pubkey != accountKey else { throw Failure.keysendToSelf }
        if let routeHint {
            let parts = routeHint.split(separator: "_")
            guard parts.count == 2, WalletProtocol.isPubkey(String(parts[0])), UInt64(parts[1]) != nil else {
                throw Failure.notANodeKey
            }
        }
        // The core pays the asynchronous way with a hint that is not legacy (`pk:scid`).
        let async = routeHint != nil
        let reserve = Self.feeReserveMsat(for: amountMsat) + (async ? Self.pingMsat(toTribe: false) : 0)
        try checkPayment(amountMsat, .unasked, reserveMsat: reserve)
        guard transport != nil else { throw Failure.notConnected }

        let time = clock.next()
        let result = try Sphinxrs.keysend(
            seed: seed, uniqueTime: time, to: pubkey, state: StateCodec.encode(state), amtMsat: amountMsat,
            data: data, routeHint: routeHint
        )
        // The payment first; an asynchronous one's ping after it.
        guard let main = result.msgs.first, let tag = main.tag, let hash = main.paymentHash?.lowercased(), hash.isHash else {
            throw Failure.coreReturnedNothing("tag for the payment")
        }
        let record = KeysendRecord(
            paymentHash: hash, tag: tag, pubkey: pubkey, routeHint: routeHint, async: async,
            amountMsat: Int64(clamping: amountMsat), createdAt: Date().millisecondsSince1970, status: .pending,
            connection: wallet.connection, app: wallet.app
        )
        let budget = wallet.budget.map { (wallet.connection, amountMsat, $0) }
        switch try await commitAndPublish(result, time: time, keysends: [record], walletBudget: budget) {
        case .all:
            break
        case .none:
            // Nothing left, so nothing moved: failed now.
            try storage.setStatus(.failed, tag: tag, error: "not connected")
            emit.yield(.sendStatus(tag: tag, status: Message.Delivery.failed.rawValue))
            throw Failure.notConnected
        case .unknown(let error):
            emit.yield(.coreError(Self.mayHaveGone(error)))
        }
        return try storage.keysend(tag: tag) ?? record
    }

    /// Pays an invoice for an app: as `payInvoice`, never asked against the
    /// person's threshold, held to the connection's budget in the commit.
    @discardableResult
    public func payInvoice(_ invoice: Invoice, for wallet: WalletTag) async throws -> InvoiceRecord {
        try await pay(invoice, chat: nil, confirmation: .unasked, wallet: wallet)
    }

    /// Makes an invoice for an app, as `createInvoice`: the server's node
    /// makes it, so it settles while Peel is closed.
    public func createInvoice(amountMsat: UInt64, memo: String, for wallet: WalletTag) async throws -> InvoiceRecord {
        try await serverInvoice(amountMsat: amountMsat, memo: memo, chat: nil, wallet: wallet)
    }

    /// Waits up to `timeout` for the send `tag` names to settle or fail,
    /// for an answer that can say how it went: a payment the server
    /// answers at once (a payee online) is told as settled with its proof.
    /// Returns as soon as it has; a wait that runs out returns too.
    func awaitFinal(tag: String, timeout: Duration) async {
        _ = try? await poll(timeout: timeout, failure: .serverTimedOut) { () -> Bool? in
            let status = (try? storage.keysend(tag: tag)?.status) ?? (try? storage.invoice(tag: tag)?.status)
            return status == .paid || status == .failed ? true : nil
        }
    }
}

extension Storage {
    /// An invoice we pay, by its send's tag.
    func invoice(tag: String) throws -> InvoiceRecord? {
        try pool.read { db in
            try InvoiceRecord.fetchOne(db, sql: "SELECT * FROM invoice WHERE tag = ? AND incoming = 0", arguments: [tag])
        }
    }

    /// The name a ready contact goes by; nil for anyone else.
    public func contactAlias(pubkey: String) throws -> String? {
        try pool.read { db in
            try String.fetchOne(db, sql: "SELECT alias FROM contact WHERE pubkey = ? AND ready = 1", arguments: [pubkey])
        }
    }
}

/// The wallet host's wallet over an engine: Peel's Sphinx account
/// (strut's specs/WALLET.md §6, "Sphinx (Peel)").
public struct EngineWallet: AppWallet {
    public let engine: Engine
    /// How long a payment's answer waits for the server's word before it
    /// is told as pending (and notified later).
    public var settleWait: Duration = .seconds(5)

    public init(engine: Engine) {
        self.engine = engine
    }

    /// The account's network, as the contract names networks.
    public func network() async -> String {
        ["bitcoin", "testnet", "signet", "regtest"].contains(engine.network) ? engine.network : "bitcoin"
    }

    public func decode(invoice text: String) async throws -> WalletInvoice {
        do {
            return WalletInvoice(try Invoice(text))
        } catch {
            throw WalletError(.badRequest, "Peel could not read that invoice.")
        }
    }

    public func problem(paying payment: WalletPayment) async -> WalletError? {
        switch payment {
        case .invoice(let invoice):
            guard let read = try? Invoice(invoice.bolt11) else { return WalletError(.badRequest, "Peel could not read that invoice.") }
            do {
                return try engine.invoiceProblem(read).map(Self.walletError)
            } catch {
                return WalletError(.internal, PeelError.readable(error))
            }
        case .keysend(let pubkey, let amount, let routeHint, _):
            guard let balance = try? engine.storage.spendableMsat() else {
                return WalletError(.other, Engine.Failure.balanceUnknown.description)
            }
            let reserve = Engine.feeReserveMsat(for: UInt64(amount)) + (routeHint != nil ? Engine.pingMsat(toTribe: false) : 0)
            if UInt64(amount) + reserve > balance { return WalletError(.insufficientBalance, Engine.Failure.insufficientBalance.description) }
            if pubkey == engine.accountKey { return Self.walletError(.keysendToSelf) }
            return nil
        }
    }

    public func pay(_ payment: WalletPayment, for tag: Engine.WalletTag) async throws -> WalletRecord {
        let sentTag: String
        let hash: String
        do {
            switch payment {
            case .invoice(let invoice):
                let record = try await engine.payInvoice(try Invoice(invoice.bolt11), for: tag)
                (sentTag, hash) = (record.tag ?? "", record.paymentHash)
            case .keysend(let pubkey, let amount, let routeHint, let data):
                let record = try await engine.keysend(
                    to: pubkey, amountMsat: UInt64(amount), routeHint: routeHint, data: data, for: tag
                )
                (sentTag, hash) = (record.tag, record.paymentHash)
            }
        } catch let failure as Engine.Failure {
            throw Self.walletError(failure)
        } catch let error as WalletError {
            throw error
        } catch {
            throw WalletError(.paymentFailed, PeelError.readable(error))
        }
        if !sentTag.isEmpty { await engine.awaitFinal(tag: sentTag, timeout: settleWait) }
        guard let record = try engine.storage.walletRecords(connection: tag.connection).first(where: {
            $0.paymentHash == hash && $0.direction == .outgoing
        }) else {
            throw WalletError(.internal, "the payment was sent but Peel could not read it back")
        }
        return record
    }

    public func makeInvoice(amountMsat: Int64, description: String, for tag: Engine.WalletTag) async throws -> WalletRecord {
        let record: InvoiceRecord
        do {
            record = try await engine.createInvoice(amountMsat: UInt64(amountMsat), memo: description, for: tag)
        } catch let failure as Engine.Failure {
            throw Self.walletError(failure)
        }
        guard let made = try engine.storage.walletRecords(connection: tag.connection).first(where: {
            $0.paymentHash == record.paymentHash && $0.direction == .incoming
        }) else {
            throw WalletError(.internal, "the invoice was made but Peel could not read it back")
        }
        return made
    }

    public func records(connection: String) async throws -> [WalletRecord] {
        try engine.storage.walletRecords(connection: connection)
    }

    public func balance() async throws -> Int64 {
        guard let balance = try engine.storage.spendableMsat() else {
            throw WalletError(.other, Engine.Failure.balanceUnknown.description)
        }
        return Int64(clamping: balance)
    }

    public func payeeName(_ pubkey: String) async -> String? {
        try? engine.storage.contactAlias(pubkey: pubkey)
    }

    /// Each change of an app's transaction to settled or failed (or an
    /// invoice made to settled or expired), whichever way it came: the
    /// server's live word, its records, its history. The first read is
    /// where it starts; nothing before it is told.
    public func updates() -> AsyncStream<WalletRecord> {
        let storage = engine.storage
        return AsyncStream { continuation in
            let task = Task {
                var known: [String: WalletRecord.State] = [:]
                var first = true
                do {
                    for try await records in storage.walletRecordUpdates() {
                        for record in records {
                            let key = "\(record.connection)|\(record.direction.rawValue)|\(record.transactionID)"
                            let before = known[key]
                            known[key] = record.state
                            if !first, before != record.state, record.state != .pending { continuation.yield(record) }
                        }
                        first = false
                    }
                } catch {}
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// An engine refusal as the contract's error, in the engine's words.
    static func walletError(_ failure: Engine.Failure) -> WalletError {
        let words = failure.description.prefix(1).uppercased() + failure.description.dropFirst() + "."
        switch failure {
        case .insufficientBalance: return WalletError(.insufficientBalance, words)
        case .overBudget: return WalletError(.quotaExceeded, words)
        case .invalidAmount, .notANodeKey, .keysendToSelf, .notAnInvoice, .unreadableInvoice, .memoTooLong:
            return WalletError(.badRequest, words)
        case .invoiceWithoutAmount: return WalletError(.notImplemented, words)
        case .balanceUnknown: return WalletError(.other, words)
        default: return WalletError(.paymentFailed, words)
        }
    }
}

extension WalletInvoice {
    init(_ invoice: Invoice) {
        self.init(
            bolt11: invoice.bolt11, paymentHash: invoice.paymentHash, amountMsat: Int64(clamping: invoice.amountMsat),
            payee: invoice.payee, memo: invoice.memo, expiresAt: invoice.expiresAt.map { Int64($0.timeIntervalSince1970) }
        )
    }
}
