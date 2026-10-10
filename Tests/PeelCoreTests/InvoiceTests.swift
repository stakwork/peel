import Foundation
import GRDB
import Sphinxrs
import Testing
@testable import PeelCore

/// A media token as the core writes it, selling for `price` sats when given.
private func token(muid: String = "muid1", price: UInt64? = nil) -> String {
    let host = MediaToken.base64URLEncode(Data("127.0.0.1:8994".utf8))
    let meta = price.map { MediaToken.base64URLEncode(Data("amt=\($0)&ttl=31536000".utf8)) } ?? ""
    return "\(host).\(muid).\(MediaToken.base64URLEncode(Data())).AAAAAA.\(meta).c2ln"
}

private func hash(_ n: Int) -> String { uuid(n) }

struct InvoiceTests {
    let profile = TempProfile()

    // MARK: Reading invoices

    @Test func anInvoiceIsReadFromItsOwnFields() throws {
        let invoice = try Invoice(coffee)
        #expect(invoice.amountMsat == 250_000_000)
        #expect(invoice.payee == coffeePayee)
        #expect(invoice.memo == "1 cup coffee")
        #expect(invoice.paymentHash == coffeeHash)
        #expect(invoice.isExpired())
        #expect(!invoice.isExpired(now: Date(timeIntervalSince1970: 1_496_314_658)))
    }

    @Test func aPastedInvoiceMayCarryAPrefixSpaceAndCapitals() throws {
        let invoice = try Invoice("  lightning:\(coffee.uppercased())\n")
        #expect(invoice.paymentHash == coffeeHash)
        #expect(invoice.bolt11 == coffee)
    }

    @Test func anInvoiceWithoutAnAmountReadsAsZero() throws {
        #expect(try Invoice(donation).amountMsat == 0)
    }

    @Test func anythingElseIsRefused() {
        #expect(throws: Engine.Failure.notAnInvoice) { try Invoice("hello") }
        #expect(throws: (any Error).self) { try Invoice("lnbc1notaninvoice") }
    }

    // MARK: The server's history

    @Test func historyRowsAreCheckedAndTellDirectionByIndex() {
        let json = """
            [{"scid":1,"amt_msat":5000,"rhash":"\(hash(1))","ts":1000,"remote":false,"msg_idx":7},
             {"scid":1,"amt_msat":2000,"rhash":"\(hash(2))","ts":2000,"remote":true,"msg_idx":null,"error":"no route"},
             {"scid":1,"amt_msat":-5,"rhash":"\(hash(3))","ts":3000},
             {"scid":1,"amt_msat":1,"rhash":"short","ts":4000},
             "garbage"]
            """
        let rows = PaymentRecord.decode(json)
        #expect(rows.count == 2)
        #expect(rows[0].incoming && rows[0].msgIndex == 7 && !rows[0].failed)
        #expect(!rows[1].incoming && rows[1].remote && rows[1].failed && rows[1].error == "no route")
        #expect(PaymentRecord.decode("not json").isEmpty)
    }

    @Test func historyJoinsMessagesInvoicesAndPings() async throws {
        let storage = try profile.storage()
        var commit = Storage.Commit(contacts: [(dm, true)])
        // A payment from the contact (by its message index), one of ours (by
        // hash) with its ping, an invoice we paid, and one of ours still pending.
        commit.messages = [
            (.fixture(uuid: uuid(1), serverIndex: 7, type: MessageType.directPayment, chat: dm, content: "lunch",
                      msat: 5000, timestamp: 1000, amountMsat: 5000), false, nil),
            (.fixture(uuid: uuid(2), type: MessageType.directPayment, chat: dm, fromMe: true, content: "rent",
                      timestamp: 2000, paymentHash: hash(2), status: "COMPLETE", amountMsat: 2000), false, nil),
            (.fixture(uuid: uuid(3), type: MessageType.directPayment, chat: dm, fromMe: true, content: "later",
                      timestamp: 9000, tag: "t3", paymentHash: hash(3), status: "PENDING", amountMsat: 3000), false, nil),
        ]
        commit.payments = PaymentRecord.decode("""
            [{"amt_msat":5000,"rhash":"\(hash(1))","ts":1000,"msg_idx":7},
             {"amt_msat":2000,"rhash":"\(hash(2))","ts":2000},
             {"amt_msat":1000,"rhash":"\(hash(9))","ts":2001},
             {"amt_msat":250000010,"rhash":"\(coffeeHash)","ts":3000}]
            """)
        commit.pings = [(hash(9), hash(2))]
        commit.invoices = [InvoiceRecord(
            paymentHash: coffeeHash, incoming: false, bolt11: coffee, amountMsat: 250_000_000, memo: "1 cup coffee",
            payee: coffeePayee, createdAt: 3000, status: .pending, tag: "tc"
        )]
        _ = try storage.apply(commit)
        _ = try storage.apply(Storage.Commit(statuses: [("tc", "COMPLETE")]))

        let items = try #require(try await first(storage.paymentHistory(limit: 50)))
        #expect(items.map(\.paymentHash) == [hash(3), coffeeHash, hash(2), hash(1)])
        let pending = items[0]
        #expect(pending.status == .pending && !pending.incoming && pending.note == "later")
        let coffeeItem = items[1]
        #expect(coffeeItem.kind == .invoice && coffeeItem.status == .complete && coffeeItem.feeMsat == 10)
        #expect(coffeeItem.note == "1 cup coffee" && coffeeItem.counterpart == nil)
        let rent = items[2]
        #expect(rent.kind == .payment && rent.pingMsat == 1000 && rent.counterpart != nil)
        let lunch = items[3]
        #expect(lunch.incoming && lunch.note == "lunch" && lunch.amountMsat == 5000)
    }

    @Test func tribeFeesAndOldPingsAreTiedToWhatTheyPaidFor() async throws {
        let storage = try profile.storage()
        let tribe = "02tribe"
        var commit = Storage.Commit(contacts: [(dm, true)])
        commit.tribes = [Tribe(pubkey: tribe, name: "hive")]
        commit.messages = [
            // Posted here: the fee's hash is kept.
            (.fixture(uuid: uuid(1), chat: tribe, fromMe: true, content: "gm", msat: 3000, timestamp: 1000,
                      paymentHash: hash(1), status: "COMPLETE"), false, nil),
            // Posted here, the server has no row for it: never listed.
            (.fixture(uuid: uuid(2), chat: tribe, fromMe: true, msat: 3000, timestamp: 1500,
                      paymentHash: hash(2), status: "COMPLETE"), false, nil),
            // From another device: the tribe's copies carry no payment.
            (.fixture(uuid: uuid(3), type: MessageType.boost, chat: tribe, fromMe: true, content: nil,
                      timestamp: 20000, amountMsat: 21000), false, nil),
            (.fixture(uuid: uuid(4), chat: tribe, fromMe: true, timestamp: 40000), false, nil),
            // Two posts beside one row: which one paid is unknown.
            (.fixture(uuid: uuid(5), chat: tribe, fromMe: true, timestamp: 60000), false, nil),
            (.fixture(uuid: uuid(6), chat: tribe, fromMe: true, timestamp: 60001), false, nil),
            // A boost to a contact still offline, its ping sent before pings were recorded.
            (.fixture(uuid: uuid(7), type: MessageType.boost, chat: dm, fromMe: true, content: nil, timestamp: 80000,
                      tag: "t7", paymentHash: hash(7), status: "PENDING", amountMsat: 21000), false, nil),
        ]
        commit.payments = PaymentRecord.decode("""
            [{"amt_msat":3000,"rhash":"\(hash(1))","ts":1000},
             {"amt_msat":21000,"rhash":"\(hash(3))","ts":20003},
             {"amt_msat":3000,"rhash":"\(hash(4))","ts":40002},
             {"amt_msat":3000,"rhash":"\(hash(5))","ts":60000},
             {"amt_msat":1000,"rhash":"\(hash(8))","ts":80001}]
            """)
        _ = try storage.apply(commit)

        let items = try #require(try await first(storage.paymentHistory(limit: 50)))
        #expect(items.map(\.paymentHash) == [hash(7), hash(5), hash(4), hash(3), hash(1)])
        let boost = items[0]
        #expect(boost.kind == .boost && boost.status == .pending && boost.pingMsat == 1000)
        #expect(items[1].kind == .keysend && items[1].chat == nil)
        let oldPost = items[2]
        #expect(oldPost.kind == .messageFee && oldPost.message?.uuid == uuid(4))
        let otherDevice = items[3]
        #expect(otherDevice.kind == .boost && otherDevice.isTribe && otherDevice.amountMsat == 21000)
        let fee = items[4]
        #expect(fee.kind == .messageFee && fee.isTribe && fee.chatName == "hive" && fee.note == nil)
        #expect(fee.message?.content == "gm" && fee.status == .complete)
    }

    /// A key exchange's sats (review F6), as the local stack records them:
    /// their half of each exchange joins its row by hash; our half, which
    /// the core reports no hash for, pairs with it by time and amount, with
    /// its ping folded in. Someone adding us (type 10) and our adding them
    /// (their answer, type 11).
    @Test func keyExchangeSatsAreLabelled() async throws {
        let storage = try profile.storage()
        let other = "03other"
        var commit = Storage.Commit(contacts: [(dm, true), (other, true)])
        commit.messages = [
            (.fixture(uuid: uuid(1), serverIndex: 0, type: MessageType.contactKey, chat: dm,
                      msat: 5000, timestamp: 10_000, paymentHash: hash(1)), false, nil),
            (.fixture(uuid: uuid(2), serverIndex: 4, type: MessageType.contactKeyConfirmation, chat: other,
                      msat: 3000, timestamp: 50_900, paymentHash: hash(2)), false, nil),
        ]
        commit.payments = PaymentRecord.decode("""
            [{"amt_msat":5000,"rhash":"\(hash(1))","ts":10020,"msg_idx":0},
             {"amt_msat":1000,"rhash":"\(hash(3))","ts":10800},
             {"amt_msat":3000,"rhash":"\(hash(4))","ts":10900},
             {"amt_msat":1000,"rhash":"\(hash(5))","ts":50000},
             {"amt_msat":5000,"rhash":"\(hash(6))","ts":50080},
             {"amt_msat":3000,"rhash":"\(hash(2))","ts":50900,"msg_idx":4}]
            """)
        _ = try storage.apply(commit)

        let items = try #require(try await first(storage.paymentHistory(limit: 50)))
        #expect(items.allSatisfy { $0.kind == .keyExchange })
        #expect(items.map(\.paymentHash) == [hash(2), hash(6), hash(4), hash(1)])
        #expect(items.map(\.addedThem) == [true, true, false, false])
        #expect(items.map(\.incoming) == [true, false, false, true])
        #expect(items.map(\.pingMsat) == [nil, 1000, 1000, nil])
        #expect(items[0].counterpart == items[1].counterpart && items[2].counterpart == items[3].counterpart)
        #expect(items.allSatisfy { $0.note == nil && $0.status == .complete })
    }

    /// An unsettled payment reads the same in Payments as in the chat
    /// (review F7), not as on its way.
    @Test func anUnsettledPaymentStaysUnsettled() async throws {
        let storage = try profile.storage()
        var commit = Storage.Commit(contacts: [(dm, true)])
        commit.messages = [
            (.fixture(uuid: uuid(1), type: MessageType.directPayment, chat: dm, fromMe: true, timestamp: 1000,
                      tag: "t1", paymentHash: hash(1), status: "UNSETTLED", amountMsat: 2000), false, nil),
        ]
        _ = try storage.apply(commit)
        let items = try #require(try await first(storage.paymentHistory(limit: 50)))
        #expect(items.map(\.status) == [.unsettled])
    }

    // MARK: Paying: never twice

    private func outgoing(_ status: InvoiceRecord.Status, tag: String = "t1") -> InvoiceRecord {
        InvoiceRecord(
            paymentHash: coffeeHash, incoming: false, bolt11: coffee, amountMsat: 250_000_000, memo: "",
            payee: coffeePayee, createdAt: 1, status: status, tag: tag
        )
    }

    @Test func anInvoiceBeingPaidOrPaidIsNeverWrittenOver() throws {
        let storage = try profile.storage()
        var commit = Storage.Commit()
        commit.invoices = [outgoing(.pending)]
        _ = try storage.apply(commit)
        #expect(try storage.paidState(paymentHash: coffeeHash) == .pending)
        // A second payment of it is refused before anything is published.
        commit.invoices = [outgoing(.pending, tag: "t2")]
        #expect(throws: (any Error).self) { try storage.apply(commit) }
        #expect(try storage.invoice(paymentHash: coffeeHash, incoming: false)?.tag == "t1")

        // Failed: nothing moved, so it may be paid again, under the new tag.
        _ = try storage.apply(Storage.Commit(statuses: [("t1", "FAILED")], sendErrors: ["t1": "no route"]))
        let failed = try #require(try storage.invoice(paymentHash: coffeeHash, incoming: false))
        #expect(failed.status == .failed && failed.error == "no route")
        #expect(try storage.paidState(paymentHash: coffeeHash) == nil)
        _ = try storage.apply(commit)
        #expect(try storage.invoice(paymentHash: coffeeHash, incoming: false)?.status == .pending)

        // A status only moves forward: paid stays paid.
        _ = try storage.apply(Storage.Commit(statuses: [("t2", "COMPLETE")]))
        _ = try storage.apply(Storage.Commit(statuses: [("t2", "FAILED")]))
        #expect(try storage.invoice(paymentHash: coffeeHash, incoming: false)?.status == .paid)
        if case .paid? = try storage.paidState(paymentHash: coffeeHash) {} else { Issue.record("not paid") }
    }

    /// The mixer's last word PENDING (held, maybe forever): unsettled, never
    /// paid again, out of the connect-time check, and still able to settle.
    @Test func anUnsettledInvoicePaymentIsNeverPaidAgain() throws {
        let storage = try profile.storage()
        var commit = Storage.Commit()
        commit.invoices = [outgoing(.pending)]
        _ = try storage.apply(commit)
        _ = try storage.apply(Storage.Commit(statuses: [("t1", "UNSETTLED")]))
        #expect(try storage.invoice(paymentHash: coffeeHash, incoming: false)?.status == .unsettled)
        #expect(try storage.paidState(paymentHash: coffeeHash) == .pending)
        #expect(try storage.pendingSendTags(textBefore: .max).isEmpty)
        #expect(throws: (any Error).self) { try storage.apply(commit) }
        _ = try storage.apply(Storage.Commit(statuses: [("t1", "COMPLETE")]))
        #expect(try storage.invoice(paymentHash: coffeeHash, incoming: false)?.status == .paid)
    }

    @Test func aPaymentInTheHistoryFromAnotherDeviceCountsAsPaid() throws {
        let storage = try profile.storage()
        var commit = Storage.Commit()
        commit.payments = PaymentRecord.decode(#"[{"amt_msat":1,"rhash":"\#(coffeeHash)","ts":5}]"#)
        _ = try storage.apply(commit)
        #expect(try storage.paidState(paymentHash: coffeeHash) == .paid(at: Date(millisecondsSince1970: 5)))
        // A failed attempt in the history is not a payment.
        let other = try profile.storage(readOnly: true)
        #expect(try other.paidState(paymentHash: hash(4)) == nil)
    }

    @Test func ourOwnInvoiceIsNeverPaidFromHere() throws {
        let storage = try profile.storage()
        var commit = Storage.Commit()
        commit.invoices = [InvoiceRecord(
            paymentHash: coffeeHash, incoming: true, bolt11: coffee, amountMsat: 250_000_000, memo: "",
            payee: coffeePayee, createdAt: 1, status: .open
        )]
        _ = try storage.apply(commit)
        #expect(try storage.paidState(paymentHash: coffeeHash) == .own)
    }

    /// On another device the invoice table is empty, but our request came
    /// back from history: its invoice is ours, never paid from here.
    /// Theirs is not (payments review F11).
    /// Only for an invoice our own server made: a message the core merely
    /// takes for ours cannot stop paying anyone else's.
    @Test func ourRequestFromHistoryMarksItsInvoiceOurs() throws {
        let seed = try Sphinxrs.mnemonicToSeed(
            mnemonic: "legal winner thank year wave sausage worth useful legal winner thank yellow"
        )
        let bolt11 = try #require(try Sphinxrs.makeInvoice(
            seed: seed, uniqueTime: String(Date().millisecondsSince1970), state: StateCodec.encode(registeredState),
            amtMsat: 10_000, description: "test"
        ).invoice)
        let invoice = try Invoice(bolt11)
        let storage = try profile.storage()
        let engine = try testEngine(storage)
        try storage.set("100000000", for: .balanceMsat)
        func ourRequest(_ n: Int, fromMe: Bool) -> Message {
            .fixture(
                uuid: uuid(n), type: MessageType.invoice, chat: dm, fromMe: fromMe,
                body: #"{"invoice":"\#(bolt11)"}"#, paymentHash: invoice.paymentHash, amountMsat: 10_000
            )
        }
        _ = try storage.apply(Storage.Commit(contacts: [(dm, true)], messages: [(ourRequest(1, fromMe: false), false, nil)]))
        try storage.set("\(keyG)_\(invoice.payee)_1", for: .contactInfo)
        #expect(try engine.invoiceProblem(invoice) == nil)
        _ = try storage.apply(Storage.Commit(messages: [(ourRequest(2, fromMe: true), false, nil)]))
        #expect(try engine.invoiceProblem(invoice) == .ownInvoice)
        // Another server's invoice is paid whatever our messages claim.
        try storage.set("\(keyG)_\(key3G)_1", for: .contactInfo)
        #expect(try engine.invoiceProblem(invoice) == nil)
    }

    /// Any balance change while an invoice made here is open, unexpired,
    /// asks the history; otherwise only a rise does (payments review F11).
    @Test func anOpenInvoiceIsCheckedOnAnyBalanceChange() throws {
        let storage = try profile.storage()
        #expect(try !storage.hasOpenInvoice())
        let expired = InvoiceRecord(
            paymentHash: coffeeHash, incoming: true, bolt11: coffee, amountMsat: 1, memo: "",
            payee: coffeePayee, createdAt: 1, expiresAt: 1_000, status: .open
        )
        var commit = Storage.Commit()
        commit.invoices = [expired]
        _ = try storage.apply(commit)
        #expect(try !storage.hasOpenInvoice())
        var open = expired
        open.paymentHash = hash(2)
        open.expiresAt = Date.now.addingTimeInterval(3600).millisecondsSince1970
        commit.invoices = [open]
        _ = try storage.apply(commit)
        #expect(try storage.hasOpenInvoice())
        _ = try storage.apply(Storage.Commit(settling: [(hash(2), 1)]))
        _ = try storage.apply(Storage.Commit(settled: [(hash(2), 42)]))
        #expect(try !storage.hasOpenInvoice())

        #expect(Engine.balanceCallsForReconcile(2, stored: 1, invoiceOpen: { false }))
        #expect(!Engine.balanceCallsForReconcile(1, stored: 2, invoiceOpen: { false }))
        #expect(Engine.balanceCallsForReconcile(1, stored: 2, invoiceOpen: { true }))
        #expect(!Engine.balanceCallsForReconcile(2, stored: 2, invoiceOpen: { true }))
    }

    @Test func anInvoiceMadeHereIsPaidOnlyOnceTheServerSettles() throws {
        let storage = try profile.storage()
        var commit = Storage.Commit()
        commit.invoices = [InvoiceRecord(
            paymentHash: coffeeHash, incoming: true, bolt11: coffee, amountMsat: 250_000_000, memo: "",
            payee: coffeePayee, createdAt: 1, status: .open
        )]
        _ = try storage.apply(commit)
        _ = try storage.apply(Storage.Commit(settling: [(coffeeHash, 250_000_000)]))
        #expect(try storage.invoice(paymentHash: coffeeHash, incoming: true)?.status == .open)
        _ = try storage.apply(Storage.Commit(settled: [(coffeeHash, 42)]))
        let paid = try #require(try storage.invoice(paymentHash: coffeeHash, incoming: true))
        #expect(paid.status == .paid && paid.paidAt == 42 && paid.paidMsat == 250_000_000)
    }

    /// The core settles whatever arrives for a known hash: 1 sat for a
    /// 250,000-sat invoice is never "paid", nor is an amount not known.
    @Test func anUnderpaidInvoiceIsNeverPaid() async throws {
        let storage = try profile.storage()
        var commit = Storage.Commit(contacts: [(dm, true)], messages: [(request(fromMe: true), false, nil)])
        commit.invoices = [InvoiceRecord(
            paymentHash: coffeeHash, incoming: true, bolt11: coffee, amountMsat: 250_000_000, memo: "",
            payee: coffeePayee, createdAt: 1, status: .open, chat: dm
        )]
        _ = try storage.apply(commit)
        _ = try storage.apply(Storage.Commit(settling: [(coffeeHash, 1000)]))
        _ = try storage.apply(Storage.Commit(settled: [(coffeeHash, 42)]))
        #expect(try storage.invoice(paymentHash: coffeeHash, incoming: true)?.status == .underpaid)
        let state = try await first(storage.timeline(in: dm))?.requests.values.first?.state
        #expect(state == .underpaid(msat: 1000))
    }

    // MARK: Invoices the server makes (`request_invoice`)

    private let issued = Date(timeIntervalSince1970: 1_496_314_658)

    @Test func theServersInvoiceMustBeWhatWasAskedFor() throws {
        let check = { (amount: UInt64, memo: String, server: String, now: Date) in
            try Engine.checkServerInvoice(coffee, amountMsat: amount, memo: memo, server: server, now: now)
        }
        #expect(try check(250_000_000, "1 cup coffee", coffeePayee, issued).paymentHash == coffeeHash)
        // Another node, amount or memo (a late answer to an earlier request), or expired.
        #expect(throws: (any Error).self) { try check(250_000_000, "1 cup coffee", String(repeating: "02", count: 33), issued) }
        #expect(throws: (any Error).self) { try check(250_000_001, "1 cup coffee", coffeePayee, issued) }
        #expect(throws: (any Error).self) { try check(250_000_000, "tea", coffeePayee, issued) }
        #expect(throws: (any Error).self) { try check(250_000_000, "1 cup coffee", coffeePayee, .now) }
    }

    @Test func onlyAnIncomingHistoryRowPaysAnOpenInvoiceOnce() {
        let page = PaymentRecord.decode("""
            [{"amt_msat":250000000,"rhash":"\(coffeeHash)","ts":9,"msg_idx":0},
             {"amt_msat":250000000,"rhash":"\(coffeeHash)","ts":8,"msg_idx":0},
             {"amt_msat":5,"rhash":"\(hash(2))","ts":7},
             {"amt_msat":5,"rhash":"\(hash(3))","ts":6,"msg_idx":0,"error":"failed"},
             {"amt_msat":5,"rhash":"\(hash(4))","ts":5,"msg_idx":0}]
            """)
        let paid = Engine.invoicePayments(in: page, open: [coffeeHash, hash(2), hash(3)])
        #expect(paid.map(\.rhash) == [coffeeHash])
        #expect(paid.first?.ts == 9)
    }

    @Test func theServersHistoryMarksAnInvoiceMadeThereAsPaid() async throws {
        let storage = try profile.storage()
        var commit = Storage.Commit(contacts: [(dm, true)], messages: [(request(fromMe: true), false, nil)])
        commit.invoices = [InvoiceRecord(
            paymentHash: coffeeHash, incoming: true, bolt11: coffee, amountMsat: 250_000_000, memo: "",
            payee: coffeePayee, createdAt: 1, expiresAt: 100, status: .open, chat: dm
        )]
        _ = try storage.apply(commit)
        #expect(try storage.openInvoices(among: [coffeeHash, hash(2)]) == [coffeeHash])
        #expect(try storage.openInvoices(among: []) == [])

        // As `Engine.commit` turns a history page into settles.
        let page = PaymentRecord.decode(#"[{"amt_msat":250000000,"rhash":"\#(coffeeHash)","ts":42,"msg_idx":0}]"#)
        let paid = Engine.invoicePayments(in: page, open: try storage.openInvoices(among: page.map(\.rhash)))
        _ = try storage.apply(Storage.Commit(
            payments: page, settling: paid.map { ($0.rhash, $0.amountMsat) }, settled: paid.map { ($0.rhash, $0.ts) }
        ))
        let record = try #require(try storage.invoice(paymentHash: coffeeHash, incoming: true))
        #expect(record.status == .paid && record.paidAt == 42 && record.paidMsat == 250_000_000)
        #expect(try storage.openInvoices(among: [coffeeHash]).isEmpty)
        let state = try await first(storage.timeline(in: dm))?.requests.values.first?.state
        #expect(state == .paid(at: Date(millisecondsSince1970: 42)))
    }

    @Test func aHistoryRowWithIndexZeroNamesNoMessage() {
        let rows = PaymentRecord.decode(#"[{"amt_msat":5,"rhash":"\#(hash(1))","ts":1,"msg_idx":0}]"#)
        #expect(rows.first?.incoming == true && rows.first?.msgIndex == nil)
    }

    // MARK: Requests in a chat

    @Test func theirRequestFollowsOurPaymentOfIt() async throws {
        let storage = try profile.storage()
        _ = try storage.apply(Storage.Commit(contacts: [(coffeePayee, true)], messages: [(request(fromMe: false), false, nil)]))
        func state() async throws -> PaymentRequest? {
            try await first(storage.timeline(in: coffeePayee))?.requests.values.first
        }
        let open = try #require(try await state())
        #expect(open.state == .open && open.paysRequester && open.invoice?.amountMsat == 250_000_000)
        var commit = Storage.Commit()
        commit.invoices = [outgoing(.pending)]
        _ = try storage.apply(commit)
        #expect(try await state()?.state == .paying)
        _ = try storage.apply(Storage.Commit(statuses: [("t1", "COMPLETE")]))
        if case .paid? = try await state()?.state {} else { Issue.record("not paid") }
    }

    @Test func aRequestWhoseInvoicePaysSomeoneElseSaysSo() async throws {
        let storage = try profile.storage()
        var message = request(fromMe: false)
        message.chat = dm
        _ = try storage.apply(Storage.Commit(contacts: [(dm, true)], messages: [(message, false, nil)]))
        let request = try #require(try await first(storage.timeline(in: dm))?.requests.values.first)
        #expect(!request.paysRequester)
    }

    /// `request_invoice` makes the requester's invoice on their server's
    /// node (the core's record of them) or, on the same server, ours.
    @Test(arguments: [
        (coreContact(keyG, contactKey: key3G, lsp: coffeePayee), nil, true),
        (coreContact(keyG, contactKey: key3G), "\(key2G)_\(coffeePayee)_123", true),
        (coreContact(keyG, contactKey: key3G), "\(key2G)_\(key3G)_123", false),
        (coreContact(key2G, contactKey: key3G, lsp: coffeePayee), nil, false),
        // A tribe (no contact key): anyone there may ask, so no server node counts.
        (coreContact(keyG, contactKey: nil, lsp: coffeePayee), "\(key2G)_\(coffeePayee)_123", false),
    ] as [([String: Data], String?, Bool)])
    func aRequestOnAServerNodePaysTheRequester(state: [String: Data], contactInfo: String?, pays: Bool) async throws {
        let storage = try profile.storage()
        _ = try storage.apply(Storage.Commit(
            state: state, settings: contactInfo.map { [.contactInfo: $0] } ?? [:], contacts: [(keyG, true)],
            messages: [(request(fromMe: false, chat: keyG), false, nil)]
        ))
        let request = try #require(try await first(storage.timeline(in: keyG))?.requests.values.first)
        #expect(request.paysRequester == pays)
    }

    @Test func ourRequestIsPaidByTheirPaymentOfEnoughOnly() async throws {
        let storage = try profile.storage()
        _ = try storage.apply(Storage.Commit(contacts: [(dm, true)], messages: [(request(fromMe: true), false, nil)]))
        func state() async throws -> PaymentRequest.State? {
            try await first(storage.timeline(in: dm))?.requests.values.first?.state
        }
        // A payment message that brought too little does not pay it.
        let short = Message.fixture(uuid: uuid(2), type: MessageType.invoicePayment, chat: dm, content: nil,
                                    msat: 1000, timestamp: 2000, paymentHash: coffeeHash)
        _ = try storage.apply(Storage.Commit(messages: [(short, false, nil)]))
        #expect(try await state() == .open)
        let full = Message.fixture(uuid: uuid(3), type: MessageType.invoicePayment, chat: dm, content: nil,
                                   msat: 250_000_000, timestamp: 3000, paymentHash: coffeeHash)
        _ = try storage.apply(Storage.Commit(messages: [(full, false, nil)]))
        if case .paid? = try await state() {} else { Issue.record("not paid") }
    }

    /// After a restore no invoice is left here and a plain payment brings no
    /// type 3: the server's incoming row for the request's hash pays it,
    /// in part if it brought less (payments review F8).
    @Test func ourRequestIsPaidByTheHistoryAfterARestore() async throws {
        let storage = try profile.storage()
        _ = try storage.apply(Storage.Commit(contacts: [(dm, true)], messages: [(request(fromMe: true), false, nil)]))
        func state() async throws -> PaymentRequest.State? {
            try await first(storage.timeline(in: dm))?.requests.values.first?.state
        }
        func row(_ msat: Int64, ts: Int64) -> PaymentRecord {
            PaymentRecord(rhash: coffeeHash, ts: ts, amountMsat: msat, incoming: true, remote: false)
        }
        _ = try storage.apply(Storage.Commit(payments: [row(1_000, ts: 40)]))
        #expect(try await state() == .underpaid(msat: 1_000))
        _ = try storage.apply(Storage.Commit(payments: [row(250_000_000, ts: 42)]))
        #expect(try await state() == .paid(at: Date(millisecondsSince1970: 42)))
    }

    /// A timeline's requests are read together, by payment hash: each takes
    /// its own side's records, and a payer's type 3 pays ours only in its chat.
    @Test func requestsReadTogetherKeepTheirOwnSide() async throws {
        let storage = try profile.storage()
        let unreadable = Message.fixture(uuid: uuid(3), type: MessageType.invoice, chat: dm,
                                         body: #"{"content":"x","invoice":"lnbc1nope"}"#, content: "x")
        var commit = Storage.Commit(contacts: [(dm, true), (keyG, true)], messages: [
            (request(fromMe: true), false, nil), (request(fromMe: false, id: 2, chat: dm), false, nil),
            (unreadable, false, nil),
            // Enough for ours, but in another chat.
            (.fixture(uuid: uuid(4), type: MessageType.invoicePayment, chat: keyG, content: nil,
                      msat: 250_000_000, timestamp: 2000, paymentHash: coffeeHash), false, nil),
        ])
        commit.invoices = [outgoing(.pending)]
        _ = try storage.apply(commit)
        _ = try storage.apply(Storage.Commit(statuses: [("t1", "FAILED")], sendErrors: ["t1": "no route"]))
        func states() async throws -> [String: PaymentRequest.State] {
            let timeline = try #require(try await first(storage.timeline(in: dm)))
            return Dictionary(uniqueKeysWithValues: timeline.messages.compactMap { message in
                message.id.flatMap { timeline.requests[$0] }.map { (message.uuid ?? "", $0.state) }
            })
        }
        #expect(try await states() == [uuid(1): .open, uuid(2): .failed("no route"), uuid(3): .open])

        // Theirs paid from another device; ours by the payer here.
        _ = try storage.apply(Storage.Commit(
            messages: [(.fixture(uuid: uuid(5), type: MessageType.invoicePayment, chat: dm, content: nil,
                                 msat: 250_000_000, timestamp: 3000, paymentHash: coffeeHash), false, nil)],
            payments: PaymentRecord.decode(#"[{"amt_msat":250000000,"rhash":"\#(coffeeHash)","ts":4000}]"#)
        ))
        #expect(try await states() == [
            uuid(1): .paid(at: Date(millisecondsSince1970: 3000)), uuid(2): .paid(at: Date(millisecondsSince1970: 4000)),
            uuid(3): .open,
        ])
    }

    // MARK: Paid attachments

    /// A timeline's paid attachments are read together: each counts only
    /// the purchases naming its own token.
    @Test func paidAttachmentsReadTogetherKeepTheirOwnToken() async throws {
        let storage = try profile.storage()
        let one = token(muid: "muid1", price: 50), two = token(muid: "muid2", price: 50)
        func attachment(_ n: Int, _ token: String) -> Message {
            .fixture(uuid: uuid(n), type: MessageType.attachment, chat: dm, fromMe: true,
                     body: #"{"mediaToken":"\#(token)","mediaKeyForSelf":"k"}"#, timestamp: Int64(n) * 1000)
        }
        func bought(_ n: Int, _ token: String) -> Message {
            .fixture(uuid: uuid(n), type: MessageType.purchase, chat: dm, body: #"{"mediaToken":"\#(token)"}"#,
                     msat: 50_000, timestamp: Int64(n) * 1000)
        }
        _ = try storage.apply(Storage.Commit(contacts: [(dm, true)], messages: [
            (attachment(1, one), false, nil), (attachment(2, two), false, nil),
            (bought(3, one), false, nil), (bought(4, one), false, nil), (bought(5, two), false, nil),
        ]))
        let timeline = try #require(try await first(storage.timeline(in: dm)))
        let states = Dictionary(uniqueKeysWithValues: timeline.messages.compactMap { message in
            message.id.flatMap { timeline.purchases[$0] }.map { (message.uuid ?? "", $0) }
        })
        #expect(states == [uuid(1): .forSale(purchases: 2), uuid(2): .forSale(purchases: 1)])
    }

    @Test func aTokensPriceIsReadFromItsMeta() {
        #expect(MediaToken(token(price: 200))?.priceSats == 200)
        #expect(MediaToken(token())?.priceSats == nil)
        #expect(Message.fixture(type: MessageType.attachment, body: #"{"mediaToken":"\#(token(price: 3))"}"#)
            .attachmentPriceMsat == 3000)
        #expect(Message.fixture(type: MessageType.attachment, body: #"{"mediaToken":"\#(token())"}"#)
            .attachmentPriceMsat == nil)
    }

    @Test func aPaidAttachmentUnlocksOnlyWithTheSellersKey() async throws {
        let storage = try profile.storage()
        let paidToken = token(price: 200)
        let attachment = Message.fixture(
            uuid: uuid(1), type: MessageType.attachment, chat: dm,
            body: #"{"content":"","mediaToken":"\#(paidToken)","mediaType":"image/jpg"}"#, content: "", timestamp: 1000
        )
        _ = try storage.apply(Storage.Commit(contacts: [(dm, true)], messages: [(attachment, false, nil)]))
        func state() async throws -> PurchaseState? {
            try await first(storage.timeline(in: dm))?.purchases.values.first
        }
        #expect(try await state() == .locked)

        let purchase = Message.fixture(
            uuid: uuid(2), type: MessageType.purchase, chat: dm, fromMe: true,
            body: #"{"content":"","mediaToken":"\#(paidToken)","replyUuid":"\#(uuid(1))"}"#, timestamp: 2000,
            tag: "p1", status: "PENDING", amountMsat: 200_000
        )
        _ = try storage.apply(Storage.Commit(messages: [(purchase, false, nil)]))
        #expect(try await state() == .processing)

        // An answer naming another token, or with no key, unlocks nothing.
        let wrong = Message.fixture(uuid: uuid(3), type: MessageType.purchaseAccept, chat: dm,
                                    body: #"{"mediaToken":"\#(token(muid: "other", price: 200))","mediaKey":"k"}"#)
        let keyless = Message.fixture(uuid: uuid(4), type: MessageType.purchaseAccept, chat: dm,
                                      body: #"{"mediaToken":"\#(paidToken)"}"#)
        _ = try storage.apply(Storage.Commit(messages: [(wrong, false, nil), (keyless, false, nil)]))
        #expect(try await state() == .processing)
        #expect(try storage.purchasedKey(for: attachment) == nil)

        let accept = Message.fixture(uuid: uuid(5), type: MessageType.purchaseAccept, chat: dm,
                                     body: #"{"mediaToken":"\#(paidToken)","mediaKey":"thekey"}"#, timestamp: 3000)
        _ = try storage.apply(Storage.Commit(messages: [(accept, false, nil)]))
        #expect(try await state() == .unlocked)
        let stored = try #require(try storage.message(uuid: uuid(1), in: dm))
        #expect(try storage.purchasedKey(for: stored) == "thekey")
    }

    @Test func aRefusedPurchaseReadsAsDenied() async throws {
        let storage = try profile.storage()
        let paidToken = token(price: 50)
        let attachment = Message.fixture(uuid: uuid(1), type: MessageType.attachment, chat: dm,
                                         body: #"{"mediaToken":"\#(paidToken)"}"#, timestamp: 1000)
        let purchase = Message.fixture(uuid: uuid(2), type: MessageType.purchase, chat: dm, fromMe: true,
                                       body: #"{"mediaToken":"\#(paidToken)"}"#, timestamp: 2000, status: "COMPLETE")
        let deny = Message.fixture(uuid: uuid(3), type: MessageType.purchaseDeny, chat: dm,
                                   body: #"{"mediaToken":"\#(paidToken)"}"#, msat: 50_000, timestamp: 3000)
        _ = try storage.apply(Storage.Commit(contacts: [(dm, true)], messages: [
            (attachment, false, nil), (purchase, false, nil), (deny, false, nil),
        ]))
        #expect(try await first(storage.timeline(in: dm))?.purchases.values.first == .denied)
    }

    @Test func ourOwnPaidAttachmentCountsItsPurchases() async throws {
        let storage = try profile.storage()
        let paidToken = token(price: 50)
        let ours = Message.fixture(uuid: uuid(1), type: MessageType.attachment, chat: dm, fromMe: true,
                                   body: #"{"mediaToken":"\#(paidToken)","mediaKeyForSelf":"k"}"#, timestamp: 1000)
        let bought = Message.fixture(uuid: uuid(2), type: MessageType.purchase, chat: dm,
                                     body: #"{"mediaToken":"\#(paidToken)"}"#, msat: 50_000, timestamp: 2000)
        _ = try storage.apply(Storage.Commit(contacts: [(dm, true)], messages: [(ours, false, nil), (bought, false, nil)]))
        #expect(try await first(storage.timeline(in: dm))?.purchases.values.first == .forSale(purchases: 1))
        let purchase = try #require(try storage.message(uuid: uuid(2), in: dm))
        #expect(try !storage.isAnswered(purchase: purchase, token: paidToken))
        let answer = Message.fixture(uuid: uuid(3), type: MessageType.purchaseAccept, chat: dm, fromMe: true,
                                     body: #"{"mediaToken":"\#(paidToken)","mediaKey":"k"}"#, timestamp: 2500)
        _ = try storage.apply(Storage.Commit(messages: [(answer, false, nil)]))
        #expect(try storage.isAnswered(purchase: purchase, token: paidToken))
    }
}
