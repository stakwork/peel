import Foundation
import GRDB
import Sphinxrs
import Synchronization
import Testing
@testable import PeelCore
@testable import PeelTestSupport

/// The writes a transport took, in order.
private final class Taken: Sendable {
    let topics = Mutex<[String]>([])
    var count: Int { topics.withLock(\.count) }
}

/// The engine a transport answers for, once it is made.
private final class EngineBox: Sendable {
    let engine = Mutex<Engine?>(nil)
}

/// A connection that takes every write; with `answer`, the server's answer
/// to an async pay is committed as the first write leaves, as the mixer
/// would send it (so a send does not wait out `asyncPaySettle`).
private func takingTransport(answer box: EngineBox? = nil, storage: Storage? = nil) -> (Transport, Taken) {
    let taken = Taken()
    let transport = Transport(publishing: { topic, _ in
        let first = taken.topics.withLock { topics in
            topics.append(topic)
            return topics.count == 1
        }
        if first, let engine = box?.engine.withLock({ $0 }),
           let hash = try? storage?.walletRecords(connection: nil).first?.paymentHash,
           let tag = (try? storage?.keysend(paymentHash: hash)?.tag)
            ?? (try? storage?.invoice(paymentHash: hash, incoming: false)?.tag) {
            Task { _ = try? await engine.commit(coreResult(asyncpayTag: tag), time: "1", expectedSender: nil) }
        }
    })
    return (transport, taken)
}

/// A send's live status from the mixer, as the core reports it.
private func sentStatus(tag: String, status: String, preimage: String? = nil, message: String? = nil) -> String {
    var fields = [#""tag":"\#(tag)""#, #""status":"\#(status)""#]
    if let preimage { fields.append(#""preimage":"\#(preimage)""#) }
    if let message { fields.append(#""message":"\#(message)""#) }
    return "{\(fields.joined(separator: ","))}"
}

/// strut's vectors' first preimage and its hash.
private let preimage = String(repeating: "0", count: 64)
private let preimageHash = "66687aadf862bd776c8fc18b8e9f8e20089714856ee233b3902a591d0d5f2925"

/// The engine's side of the app wallet (docs/app-wallet.md): the preimage
/// kept, a keysend through the real core, the budget counted in the
/// payment's own write, the state of each payment from the server's live
/// word, its records and its history, and the connection's tag.
struct WalletEngineTests {
    let profile = TempProfile()
    static let tag = Engine.WalletTag(connection: "app:/bench", app: "/bench")

    private func keysendRow(
        _ n: Int, status: InvoiceRecord.Status = .pending, amount: Int64 = 10_000, async: Bool = true,
        hash: String? = nil, connection: String? = "app:/bench", minutesAgo: Int64 = 1
    ) -> KeysendRecord {
        KeysendRecord(
            paymentHash: hash ?? uuid(1000 + n), tag: "k\(n)", pubkey: keyG, routeHint: async ? "\(key3G)_1" : nil,
            async: async, amountMsat: amount, createdAt: Date.now.millisecondsSince1970 - minutesAgo * 60_000,
            status: status, connection: connection, app: connection == nil ? nil : "/bench"
        )
    }

    private func storage(balance: UInt64 = 1_000_000, keysends: [KeysendRecord] = []) throws -> Storage {
        var commit = Storage.Commit()
        commit.settings[.balanceMsat] = String(balance)
        let storage = try registeredStorage(profile, contact: nil, commit)
        var rows = Storage.Commit()
        rows.keysends = keysends
        _ = try storage.apply(rows)
        return storage
    }

    // MARK: The preimage

    /// The preimage the mixer sends with a COMPLETE is kept on the payment
    /// its tag names, and only when it proves the payment; a page is never
    /// handed one that does not.
    @Test func aCompleteKeepsItsPreimageOnlyWhenItProvesThePayment() async throws {
        let storage = try storage(keysends: [keysendRow(1, hash: preimageHash), keysendRow(2)])
        var invoice = Storage.Commit()
        invoice.invoices = [InvoiceRecord(
            paymentHash: preimageHash, incoming: false, bolt11: "lnbc1", amountMsat: 1_000, memo: "", payee: keyG,
            createdAt: 1, status: .pending, tag: "i1"
        )]
        _ = try storage.apply(invoice)
        let engine = try testEngine(storage)
        _ = try await engine.commit(coreResult(sentStatus: sentStatus(tag: "k1", status: "COMPLETE", preimage: preimage)),
                                    time: "1", expectedSender: nil)
        // A preimage that hashes to something else proves nothing.
        _ = try await engine.commit(coreResult(sentStatus: sentStatus(tag: "k2", status: "COMPLETE", preimage: preimage)),
                                    time: "2", expectedSender: nil)
        _ = try await engine.commit(coreResult(sentStatus: sentStatus(tag: "i1", status: "COMPLETE", preimage: preimage)),
                                    time: "3", expectedSender: nil)
        let k1 = try #require(try storage.keysend(tag: "k1"))
        #expect(k1.status == .paid && k1.preimage == preimage && k1.paidAt != nil)
        let k2 = try #require(try storage.keysend(tag: "k2"))
        #expect(k2.status == .paid && k2.preimage == nil)
        #expect(try storage.invoice(paymentHash: preimageHash, incoming: false)?.preimage == preimage)
        // Settled with its proof, the record says so; without, it is no proven payment.
        let records = try storage.walletRecords(connection: "app:/bench")
        #expect(records.first { $0.paymentHash == preimageHash }?.provenSettled == true)
        #expect(records.first { $0.paymentHash == uuid(1002) }?.provenSettled == false)
        #expect(records.first { $0.paymentHash == uuid(1002) }?.payment.objectValue["state"] == .string("pending"))
    }

    /// A FAILED moves a keysend as it moves every send, with the server's
    /// reason; a PENDING leaves it unsettled, never failed.
    @Test func aKeysendMovesByTheServersWord() async throws {
        let storage = try storage(keysends: [keysendRow(1), keysendRow(2)])
        let engine = try testEngine(storage)
        _ = try await engine.commit(coreResult(sentStatus: sentStatus(tag: "k1", status: "FAILED", message: "no route")),
                                    time: "1", expectedSender: nil)
        _ = try await engine.commit(coreResult(sentStatus: sentStatus(tag: "k2", status: "PENDING")),
                                    time: "2", expectedSender: nil)
        #expect(try storage.keysend(tag: "k1")?.status == .failed)
        #expect(try storage.keysend(tag: "k1")?.error == "no route")
        #expect(try storage.keysend(tag: "k2")?.status == .unsettled)
        let records = try storage.walletRecords(connection: "app:/bench")
        #expect(records.first { $0.paymentHash == uuid(1001) }?.failureReason == "no route")
        #expect(records.first { $0.paymentHash == uuid(1002) }?.state == .pending)
        // A failure after it settled never moves it back.
        _ = try await engine.commit(coreResult(sentStatus: sentStatus(tag: "k2", status: "COMPLETE")), time: "3", expectedSender: nil)
        _ = try await engine.commit(coreResult(sentStatus: sentStatus(tag: "k2", status: "FAILED")), time: "4", expectedSender: nil)
        #expect(try storage.keysend(tag: "k2")?.status == .paid)
    }

    /// The history settles or fails a keysend left open, by its payment
    /// hash; settled there, it has no preimage, and its fee is what left
    /// beyond its amount plus the asynchronous way's ping.
    @Test func theHistorySettlesAKeysend() throws {
        let storage = try storage(keysends: [keysendRow(1), keysendRow(2), keysendRow(3, async: false)])
        var page = Storage.Commit()
        page.payments = PaymentRecord.decode("""
            [{"amt_msat":10010,"rhash":"\(uuid(1001))","ts":5000},
             {"amt_msat":10000,"rhash":"\(uuid(1002))","ts":5000,"error":"timed out"},
             {"amt_msat":10000,"rhash":"\(uuid(1003))","ts":5000}]
            """)
        _ = try storage.apply(page)
        let records = try storage.walletRecords(connection: "app:/bench")
        let settled = try #require(records.first { $0.paymentHash == uuid(1001) })
        #expect(settled.state == .settled && settled.preimage == nil && settled.settledAt == 5)
        #expect(settled.feesMsat == Int64(10 + 1_000))
        let failed = try #require(records.first { $0.paymentHash == uuid(1002) })
        #expect(failed.state == .failed && failed.failureReason == "timed out")
        #expect(records.first { $0.paymentHash == uuid(1003) }?.feesMsat == 0)
    }

    /// An app's keysend waits like any send to someone offline: sent the
    /// asynchronous way it holds sats back until it settles; the server
    /// is asked about it on connect; the history reaches back for it.
    @Test func anOpenKeysendIsWaitingAndAskedAbout() throws {
        let storage = try storage(keysends: [keysendRow(1), keysendRow(2, async: false), keysendRow(3, status: .unsettled)])
        #expect(try storage.waitingMsat() == 10_000)
        #expect(try storage.spendableMsat() == 990_000)
        let tags = try storage.pendingSendTags(textBefore: .max).map(\.tag)
        #expect(tags.contains("k1") && tags.contains("k2") && !tags.contains("k3"))
        #expect(try storage.oldestOpenSend(since: 0) != nil)
    }

    // MARK: The budget

    /// The budget is counted in the payment's own write: one that does not
    /// fit is refused and nothing is written; pending counts, failed does
    /// not; the person's approval counts without a limit.
    @Test func theBudgetIsCountedInThePaymentsOwnWrite() throws {
        let storage = try storage(keysends: [keysendRow(1, amount: 6_000), keysendRow(2, status: .failed, amount: 50_000)])
        let within = WalletBudget.Guard(limitMsat: 10_000, since: 0)
        var over = Storage.Commit()
        over.keysends = [keysendRow(3, amount: 5_000)]
        over.walletBudget = ("app:/bench", 5_000, within)
        #expect(throws: Engine.Failure.overBudget) { try storage.apply(over) }
        #expect(try storage.keysend(tag: "k3") == nil)
        var fits = Storage.Commit()
        fits.keysends = [keysendRow(4, amount: 4_000)]
        fits.walletBudget = ("app:/bench", 4_000, within)
        _ = try storage.apply(fits)
        var approved = Storage.Commit()
        approved.keysends = [keysendRow(5, amount: 90_000)]
        approved.walletBudget = ("app:/bench", 90_000, WalletBudget.Guard(limitMsat: nil, since: 0))
        _ = try storage.apply(approved)
        let used = WalletBudget.used(try storage.walletRecords(connection: "app:/bench").compactMap(\.entry), since: 0)
        #expect(used == 100_000)
        // Another connection's payments are not counted.
        var other = Storage.Commit()
        other.keysends = [keysendRow(6, amount: 1_000, connection: "app:acme/shop")]
        other.walletBudget = ("app:acme/shop", 1_000, WalletBudget.Guard(limitMsat: 1_000, since: 0))
        _ = try storage.apply(other)
    }

    // MARK: A keysend through the core

    /// A keysend to a Sphinx address goes through the real core the
    /// asynchronous way: written pending with its tag, connection and app
    /// before anything is published, published, and holding its sats.
    @Test func aKeysendGoesThroughTheCore() async throws {
        let storage = try storage()
        let box = EngineBox()
        let (transport, taken) = takingTransport(answer: box, storage: storage)
        try await withTestEngine(storage, on: transport) { live in
            box.engine.withLock { $0 = live }
            let record = try await live.keysend(
                to: keyG, amountMsat: 20_000, routeHint: "\(key3G)_1", data: Data("hi".utf8), for: Self.tag
            )
            #expect(record.status == .pending && record.async && record.connection == "app:/bench" && record.app == "/bench")
            #expect(record.amountMsat == 20_000 && record.paymentHash.isHash)
            #expect(taken.count >= 1)
            #expect(try storage.waitingMsat() == 20_000)
            #expect(try storage.walletRecords(connection: "app:/bench").first?.state == .pending)
        }
    }

    /// Refused before the core: over the balance (with its reserve), to
    /// this account, a key that is no key, a hint that is not Sphinx's; and
    /// over budget, after the core but before anything is written or sent.
    @Test func aKeysendIsRefusedBeforeAnythingMoves() async throws {
        let storage = try storage(balance: 20_000, keysends: [keysendRow(1, amount: 9_000)])
        let (transport, taken) = takingTransport()
        try await withTestEngine(storage, on: transport) { engine in
            await #expect(throws: Engine.Failure.insufficientBalance) {
                try await engine.keysend(to: keyG, amountMsat: 1_000, routeHint: "\(key3G)_1", for: Self.tag)
            }
            try storage.set("1000000", for: .balanceMsat)
            await #expect(throws: Engine.Failure.notANodeKey) {
                try await engine.keysend(to: "nobody", amountMsat: 1_000, for: Self.tag)
            }
            await #expect(throws: Engine.Failure.notANodeKey) {
                try await engine.keysend(to: keyG, amountMsat: 1_000, routeHint: "\(key3G):1", for: Self.tag)
            }
            await #expect(throws: Engine.Failure.keysendToSelf) {
                try await engine.keysend(to: engine.accountKey, amountMsat: 1_000, for: Self.tag)
            }
            var tight = Self.tag
            tight.budget = WalletBudget.Guard(limitMsat: 10_000, since: 0)
            await #expect(throws: Engine.Failure.overBudget) {
                try await engine.keysend(to: keyG, amountMsat: 2_000, routeHint: "\(key3G)_1", for: tight)
            }
            #expect(taken.count == 0)
            #expect(try storage.walletRecords(connection: "app:/bench").count == 1)
        }
    }

    /// A keysend whose publish never left failed at once: nothing moved,
    /// so the budget is refunded.
    @Test func aKeysendThatNeverLeftFailsAndIsRefunded() async throws {
        let storage = try storage()
        try await withTestEngine(storage, on: goneTransport()) { engine in
            await #expect(throws: Engine.Failure.notConnected) {
                try await engine.keysend(to: keyG, amountMsat: 2_000, routeHint: "\(key3G)_1", for: Self.tag)
            }
            let record = try #require(try storage.walletRecords(connection: "app:/bench").first)
            #expect(record.state == .failed)
            #expect(WalletBudget.used([record.entry].compactMap { $0 }, since: 0) == 0)
        }
    }

    // MARK: Invoices

    /// An app's invoice is paid without the person's threshold, and tagged.
    @Test func anAppsInvoiceIsPaidUnaskedAndTagged() async throws {
        let invoice = try madeInvoice(msat: 50_000)
        let storage = try storage()
        try await engineIgnoringThreshold(storage) { engine in
            try await engine.setPaymentConfirmation(msat: 0)
            await #expect(throws: Engine.Failure.needsConfirmation(amountMsat: 50_000)) {
                try await engine.payInvoice(invoice.bolt11)
            }
            let record = try await engine.payInvoice(invoice, for: Self.tag)
            #expect(record.connection == "app:/bench" && record.app == "/bench" && record.status == .pending)
            let wallet = try #require(try storage.walletRecords(connection: "app:/bench").first)
            #expect(wallet.paymentType == .bolt11 && wallet.invoice == invoice.bolt11 && wallet.amountMsat == 50_000)
        }
    }

    private func engineIgnoringThreshold(_ storage: Storage, _ body: (Engine) async throws -> Void) async throws {
        let box = EngineBox()
        let (transport, _) = takingTransport(answer: box, storage: storage)
        try await withTestEngine(storage, on: transport) { engine in
            box.engine.withLock { $0 = engine }
            try await body(engine)
        }
    }

    // MARK: The state stream

    /// Each move of an app's transaction to settled or failed is told once,
    /// whichever way it came; what stood before the first read is not.
    @Test func theStateStreamTellsEachMoveOnce() async throws {
        let storage = try storage(keysends: [keysendRow(1, hash: preimageHash), keysendRow(2), keysendRow(3, status: .paid)])
        let engine = try testEngine(storage)
        let updates = EngineWallet(engine: engine).updates()
        let told = Mutex<[WalletRecord]>([])
        let watching = Task { for await record in updates { told.withLock { $0.append(record) } } }
        try await Task.sleep(for: .milliseconds(100))
        _ = try await engine.commit(coreResult(sentStatus: sentStatus(tag: "k1", status: "COMPLETE", preimage: preimage)),
                                    time: "1", expectedSender: nil)
        var page = Storage.Commit()
        page.payments = PaymentRecord.decode(#"[{"amt_msat":10000,"rhash":"\#(uuid(1002))","ts":5000,"error":"gone"}]"#)
        _ = try storage.apply(page)
        // The same again moves nothing.
        _ = try await engine.commit(coreResult(sentStatus: sentStatus(tag: "k1", status: "COMPLETE", preimage: preimage)),
                                    time: "2", expectedSender: nil)
        try await Task.sleep(for: .milliseconds(300))
        watching.cancel()
        let moves = told.withLock { $0 }
        #expect(moves.map(\.paymentHash) == [preimageHash, uuid(1002)])
        #expect(moves.first?.preimage == preimage && moves.first?.state == .settled)
        #expect(moves.last?.state == .failed)
    }

    /// The engine's refusals read as the contract's codes.
    @Test func engineRefusalsAreWalletErrors() {
        #expect(EngineWallet.walletError(.insufficientBalance).code == .insufficientBalance)
        #expect(EngineWallet.walletError(.overBudget).code == .quotaExceeded)
        #expect(EngineWallet.walletError(.invoiceExpired).code == .paymentFailed)
        #expect(EngineWallet.walletError(.invoiceWithoutAmount).code == .notImplemented)
        #expect(EngineWallet.walletError(.notConnected).message == "Not connected to the server.")
    }
}
