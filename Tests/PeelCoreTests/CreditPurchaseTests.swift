import CryptoKit
import Foundation
import Testing
@testable import PeelCore
@testable import PeelTestSupport

/// Buying a visitor's credit through the host (`buy_credit`, strut's
/// specs/WALLET.md §1.2; docs/app-wallet.md, "Buying credit"): strut's
/// vectors (what may be bought, and how strut's UI reads the answer), and
/// the host's guard, sheet, single payment, status and withdrawal.
struct CreditPurchaseTests {
    let profile = TempProfile()
    /// The profile's storage, opened once (a profile takes one process's lock).
    let storage: Storage
    static let now: Int64 = 1_793_800_000
    static let origin = WalletScope.origin("https://shop.example.com")
    static let remote = WalletScope.remote(seller: URL(string: "https://shop.example.com/lab")!, name: "voxel")
    /// A preimage, and the hash the purchase's invoice names.
    static let preimage = String(repeating: "42", count: 32)
    static let hash = SHA256.hash(data: Data(hexString: preimage)!).map { String(format: "%02x", $0) }.joined()

    init() throws { storage = try profile.storage() }

    // MARK: strut's vectors

    @Test func theCreditVectorsAreThere() {
        #expect(WalletVectors.list("credit_purchases").count == 16)
        #expect(WalletVectors.list("credit_replies").count == 15)
    }

    /// What may be bought, as strut's `creditPurchaseProblems` reads it.
    @Test(arguments: WalletVectors.list("credit_purchases").indices)
    func aPurchaseAsStrutReadsIt(_ index: Int) {
        let vector = WalletVectors.list("credit_purchases")[index]
        let problems = CreditPurchase.problems(vector["purchase"] ?? .null)
        #expect(problems.isEmpty == (vector["valid"] == .bool(true)), "\(WalletVectors.name(vector)): \(problems)")
    }

    /// The reader below is strut's `readCreditReply`, held to its vectors,
    /// so the host's own answers can be read as strut's UI reads them.
    @Test(arguments: WalletVectors.list("credit_replies").indices)
    func aReplyAsStrutReadsIt(_ index: Int) throws {
        let vector = WalletVectors.list("credit_replies")[index]
        let hash = try #require(vector["payment_hash"]?.string)
        let read = Self.read(vector["reply"], hash)
        #expect(read.outcome == vector["outcome"]?.string, "\(WalletVectors.name(vector))")
        #expect(read.code == vector["code"]?.string, "\(WalletVectors.name(vector))")
        #expect(read.preimage == vector["preimage"]?.string, "\(WalletVectors.name(vector))")
    }

    // MARK: The guard

    /// Only a stranger's public app Peel opened buys credit: its own strut's
    /// pages and an org's are no visitor's.
    @Test func onlyAVisitorsPageBuysCredit() async throws {
        let wallet = ScriptedWallet(), person = ScriptedPerson()
        let host = try host(wallet)
        for scope in [WalletScope.org(peer: "acme"), .app(peer: nil, name: "voxel")] {
            let reply = await host.handle(buy(), from: caller(person, scope: scope))
            #expect(code(reply) == "RESTRICTED")
            #expect(code(await host.handle(status(Self.hash), from: caller(person, scope: scope))) == "RESTRICTED")
        }
        #expect(person.takeShown().isEmpty && wallet.calls.isEmpty)
    }

    /// Nothing the seller says is paid before Peel's own reading of it: a
    /// purchase strut would refuse, another seller than the page's (the
    /// Mac), an invoice that is not the one described or has ended, one the
    /// wallet cannot pay, and no tap in the page first. None asks the person.
    @Test func whatIsNeverPaidOrAsked() async throws {
        let wallet = ScriptedWallet(), person = ScriptedPerson()
        let host = try host(wallet)
        var bad = purchase().objectValue
        bad["amount"] = .int(1)
        #expect(code(await host.handle(buy(.object(bad)), from: caller(person))) == "BAD_REQUEST")
        let elsewhere = buy(purchase(seller: "https://other.example.com"))
        #expect(code(await host.handle(elsewhere, from: caller(person, scope: Self.remote))) == "BAD_REQUEST")

        wallet.script(nil, decoded: 249_000_000)
        wallet.decodes(hash: Self.hash, ends: Self.now + 600)
        #expect(code(await host.handle(buy(), from: caller(person))) == "BAD_REQUEST", "another amount")
        wallet.script(nil, decoded: 250_000_000)
        wallet.decodes(hash: String(repeating: "a", count: 64), ends: Self.now + 600)
        #expect(code(await host.handle(buy(), from: caller(person))) == "BAD_REQUEST", "another hash")
        wallet.decodes(hash: Self.hash, ends: Self.now)
        #expect(code(await host.handle(buy(), from: caller(person))) == "BAD_REQUEST", "ended")
        wallet.decodes(hash: Self.hash, ends: Self.now + 600)
        wallet.failNextProblem(WalletError(.insufficientBalance, "not enough"))
        #expect(code(await host.handle(buy(), from: caller(person))) == "INSUFFICIENT_BALANCE")
        wallet.failNextProblem(nil)
        #expect(code(await host.handle(buy(), from: caller(person, acted: false))) == "RESTRICTED")
        #expect(person.takeShown().isEmpty)
        #expect(!wallet.calls.contains("pay"))
    }

    // MARK: The sheet and the payment

    /// The person's yes on Peel's own sheet pays the invoice, once: the
    /// sheet names the server by the host Peel loaded (whatever the page
    /// says), the price as decoded, and the seller's dollars as its own
    /// figure; the answer is what strut's UI reads as paid. The same
    /// purchase again answers that payment with no sheet and no second pay.
    @Test func aYesPaysOnceAndTheAnswerIsPaid() async throws {
        let wallet = ScriptedWallet(), person = ScriptedPerson()
        let host = try host(wallet)
        ready(wallet)
        person.will("approve")
        wallet.script(settled())
        let reply = await host.handle(buy(purchase(seller: "https://elsewhere.example")), from: caller(person))
        #expect(Self.read(reply, Self.hash).outcome == "paid")
        #expect(Self.read(reply, Self.hash).preimage == Self.preimage)
        let sheet = try #require(person.lastCredit)
        #expect(sheet.host == "shop.example.com" && sheet.amountMsat == 250_000_000 && sheet.usd == 250)
        #expect(sheet.title == "Voxel Studio" && sheet.workflow == "acme/voxel/character")
        #expect(sheet.expiresAt == Self.now + 600)
        #expect(try await wallet.records(connection: WalletHost.creditKey(Self.origin)).count == 1)

        #expect(person.takeShown() == ["credit"])
        let again = await host.handle(buy(), from: caller(person, acted: false))
        #expect(Self.read(again, Self.hash).outcome == "paid")
        #expect(person.takeShown().isEmpty)
        #expect(wallet.calls.filter { $0 == "pay" }.count == 1)
    }

    /// A payment sent that has not settled is pending, never the QR again;
    /// its status is told until it moves, to this page only.
    @Test func aPendingPaymentAndItsStatus() async throws {
        let wallet = ScriptedWallet(), person = ScriptedPerson()
        let host = try host(wallet)
        ready(wallet)
        person.will("approve")
        wallet.script(pending())
        #expect(Self.read(await host.handle(buy(), from: caller(person)), Self.hash).outcome == "pending")
        #expect(Self.read(await host.handle(status(Self.hash), from: caller(person)), Self.hash).outcome == "pending")
        wallet.event(.object(["notification_type": .string("payment_sent"), "notification": settled().objectValue["result"]!]))
        #expect(Self.read(await host.handle(status(Self.hash), from: caller(person)), Self.hash).outcome == "paid")
        // Another page, and a hash never paid: nothing of either.
        #expect(code(await host.handle(status(Self.hash), from: caller(person, scope: Self.remote))) == "NOT_FOUND")
        #expect(code(await host.handle(status(String(repeating: "b", count: 64)), from: caller(person))) == "NOT_FOUND")
    }

    /// A decline pays nothing; strut's UI shows its QR code.
    @Test func aDeclinePaysNothing() async throws {
        let wallet = ScriptedWallet(), person = ScriptedPerson()
        let host = try host(wallet)
        ready(wallet)
        person.will("decline")
        let reply = await host.handle(buy(), from: caller(person))
        #expect(Self.read(reply, Self.hash).outcome == "fallback" && code(reply) == "USER_REJECTED")
        #expect(!wallet.calls.contains("pay"))
    }

    /// The page may take its sheet down (`buy_credit_cancel`): a decline,
    /// nothing paid. Another page's cancel, or one for another invoice,
    /// leaves it up; and the sheet comes down by itself when the invoice ends.
    @Test func thePageWithdrawsItsSheetAndTheInvoiceEndsIt() async throws {
        let wallet = ScriptedWallet(), person = ScriptedPerson(absent: true)
        let host = try host(wallet)
        ready(wallet)
        let message = buy(), from = caller(person)
        let asking = Task { await host.handle(message, from: from) }
        for _ in 0..<1000 where person.lastCredit == nil { try await Task.sleep(for: .milliseconds(5)) }
        try #require(person.lastCredit != nil, "the sheet never opened")
        #expect(await host.handle(cancel(Self.hash), from: caller(person, scope: Self.remote)) == .object(["result": .object([:])]))
        #expect(await host.handle(cancel(String(repeating: "b", count: 64)), from: caller(person)) == .object(["result": .object([:])]))
        try await Task.sleep(for: .milliseconds(50))
        #expect(!asking.isCancelled)
        _ = await host.handle(cancel(Self.hash), from: caller(person))
        #expect(code(await asking.value) == "USER_REJECTED")
        #expect(!wallet.calls.contains("pay"))

        wallet.decodes(hash: Self.hash, ends: Self.now + 1)
        #expect(code(await host.handle(buy(), from: caller(person))) == "RESTRICTED")
        #expect(!wallet.calls.contains("pay"))
    }

    // MARK: Helpers

    func host(_ wallet: ScriptedWallet) throws -> WalletHost {
        WalletHost(storage: storage, wallet: wallet, now: { Self.now }, nowMs: { Self.now * 1000 }, sheetTimeout: .seconds(60))
    }

    func caller(_ person: ScriptedPerson, acted: Bool = true, scope: WalletScope = origin) -> WalletCaller {
        WalletCaller(scope: scope, place: "shop.example.com", personActed: acted, person: person)
    }

    /// The decoder reads the purchase's invoice as described, ending in ten
    /// minutes; the wallet is not to be asked to pay until a test says so.
    func ready(_ wallet: ScriptedWallet) {
        wallet.script(nil, decoded: 250_000_000)
        wallet.decodes(hash: Self.hash, ends: Self.now + 600)
    }

    /// strut's first valid purchase, for this test's hash.
    func purchase(seller: String = "https://shop.example.com/lab") -> JSONValue {
        var p = WalletVectors.list("credit_purchases")[0]["purchase"]?.objectValue ?? [:]
        p["payment_hash"] = .string(Self.hash)
        p["seller"] = .string(seller)
        p["expires_at"] = .int(Self.now + 600)
        return .object(p)
    }

    func buy(_ purchase: JSONValue? = nil) -> JSONValue {
        .object(["v": .int(1), "op": .string("buy_credit"), "purchase": purchase ?? self.purchase()])
    }

    func status(_ hash: String) -> JSONValue {
        .object(["v": .int(1), "op": .string("buy_credit_status"), "payment_hash": .string(hash)])
    }

    func cancel(_ hash: String) -> JSONValue {
        .object(["v": .int(1), "op": .string("buy_credit_cancel"), "payment_hash": .string(hash)])
    }

    func settled() -> JSONValue {
        .object(["result": .object([
            "transaction_id": .string(Self.hash), "state": .string("settled"), "payment_hash": .string(Self.hash),
            "amount": .int(250_000_000), "fees_paid": .int(0), "preimage": .string(Self.preimage),
            "created_at": .int(Self.now), "settled_at": .int(Self.now),
        ])])
    }

    func pending() -> JSONValue {
        .object(["result": .object([
            "transaction_id": .string(Self.hash), "state": .string("pending"), "payment_hash": .string(Self.hash),
            "amount": .int(250_000_000), "created_at": .int(Self.now),
        ])])
    }

    func code(_ reply: JSONValue) -> String? {
        reply.objectValue["error"]?.objectValue["data"]?.objectValue["code"]?.string
    }

    /// strut's `readCreditReply` (kit/src/wallet/protocol.ts): `paid` with
    /// the preimage that proves it, `pending` once sent, `fallback` with a
    /// code when nothing was.
    static func read(_ reply: JSONValue?, _ hash: String) -> (outcome: String, code: String?, preimage: String?) {
        let fallback = { (code: String) in ("fallback", Optional(code), String?.none) }
        guard case .object(let r)? = reply else { return fallback("INTERNAL") }
        if let error = r["error"] {
            let code = error.objectValue["data"]?.objectValue["code"]?.string
            return fallback(code.flatMap(WalletErrorCode.init).map(\.rawValue) ?? "OTHER")
        }
        guard let result = r["result"] else { return fallback("INTERNAL") }
        let pay = result.objectValue
        guard case .object = result, pay["payment_hash"]?.string == hash.lowercased() else { return fallback("INTERNAL") }
        if pay["state"] == .string("failed") { return fallback("PAYMENT_FAILED") }
        guard pay["state"] == .string("settled") || pay["state"] == .string("pending") else { return fallback("INTERNAL") }
        if pay["state"] == .string("pending") || !WalletProtocol.resultProblems(.payInvoice, result).isEmpty {
            return ("pending", nil, nil)
        }
        let preimage = pay["preimage"]?.string ?? ""
        return WalletProtocol.verifyPreimage(preimage, paymentHash: hash) ? ("paid", nil, preimage.lowercased()) : ("pending", nil, nil)
    }
}
