import Foundation
import Sphinxrs
import Synchronization
import Testing
@testable import PeelCore

/// The writes a `cutTransport` was asked for, in order, those refused too.
private final class Writes: Sendable {
    let topics = Mutex<[String]>([])
    var count: Int { topics.withLock(\.count) }
}

/// A connection that goes partway through a send: the first `accepted`
/// writes leave, and every one after throws `error`.
private func cutTransport(accepting accepted: Int, then error: any Error & Sendable) -> (Transport, Writes) {
    let writes = Writes()
    let transport = Transport(publishing: { topic, _ in
        let index = writes.topics.withLock { topics in
            topics.append(topic)
            return topics.count - 1
        }
        if index >= accepted { throw error }
    })
    return (transport, writes)
}

/// A write the closing connection cut short: it may have left.
private let cutShort = PeelError("the write was cut short")

/// What money and history do when the connection goes: a payment or an
/// invite whose publish never left is failed at once and may be made again;
/// one that may have left stays pending, never offered again, until the
/// server says; and a history run waits for the next connection instead of failing.
struct ConnectionDropTests {
    let profile = TempProfile()

    /// Runs `body` on a registered engine with a balance, on `transport`
    /// (by default `goneTransport()`), and disconnects after, which shuts
    /// the transport's client down.
    private func withEngine(
        balanceMsat: UInt64? = 1_000_000, contact: String? = nil, transport: Transport = goneTransport(),
        _ body: (Engine, Storage) async throws -> Void
    ) async throws {
        let storage = try profile.storage()
        var settings: [Setting: String] = [.server: "mqtt://127.0.0.1:1"]
        settings[.balanceMsat] = balanceMsat.map(String.init)
        let state = registeredState.merging(contact.map { coreContact($0, contactKey: key3G) } ?? [:]) { $1 }
        _ = try storage.apply(Storage.Commit(
            state: state, settings: settings, contacts: contact.map { [($0, true)] }
        ))
        let engine = try testEngine(storage)
        await engine.useTransportForTesting(transport)
        do {
            try await body(engine, storage)
        } catch {
            await engine.disconnect()
            throw error
        }
        await engine.disconnect()
    }

    @Test func anInvoicePaymentThatNeverLeftFailsAndCanBePaidAgain() async throws {
        let invoice = try madeInvoice()
        let bolt11 = invoice.bolt11
        try await withEngine { engine, storage throws in
            await #expect(throws: Engine.Failure.notConnected) {
                try await engine.payInvoice(bolt11, confirmedMsat: invoice.amountMsat)
            }
            let stored = try #require(try storage.invoice(paymentHash: invoice.paymentHash, incoming: false))
            #expect(stored.status == .failed)
            // Not refused as pending for half an hour.
            #expect(try engine.invoiceProblem(invoice) == nil)
        }
    }

    /// The connection went with the transport still set: the payment never
    /// left, so it is failed at once and may be sent again, not left
    /// pending until the server is asked.
    @Test func aPaymentThatNeverLeftFailsAndCanBeSentAgain() async throws {
        try await withEngine(contact: keyG) { engine, storage throws in
            let tag = try #require(try await engine.sendPayment(to: keyG, amountMsat: 1_000, confirmedMsat: 1_000))
            let row = try #require(try rows(profile, "SELECT id FROM message WHERE tag = '\(tag)'").first)
            let stored = try #require(try storage.message(id: row["id"]))
            #expect(stored.delivery == .failed)
            #expect(stored.isRetryable())
            #expect(try storage.pendingSendTags(textBefore: .max).isEmpty)
        }
    }

    /// A payment whose write was cut short may have gone: it stays pending,
    /// is never offered for Retry, and waits for the server's records.
    @Test func aPaymentCutShortStaysPendingAndIsNotRetried() async throws {
        let (transport, writes) = cutTransport(accepting: 0, then: cutShort)
        try await withEngine(contact: keyG, transport: transport) { engine, storage throws in
            let tag = try #require(try await engine.sendPayment(to: keyG, amountMsat: 1_000, confirmedMsat: 1_000))
            #expect(writes.count >= 1)
            let row = try #require(try rows(profile, "SELECT id FROM message WHERE tag = '\(tag)'").first)
            let stored = try #require(try storage.message(id: row["id"]))
            #expect(stored.delivery == .pending)
            #expect(!stored.isRetryable())
            #expect(try storage.pendingSendTags(textBefore: .max).contains { $0.tag == tag })
        }
    }

    /// The connection going after one of a payment's writes left is not
    /// "nothing left": the payment stays pending like one cut short. Its
    /// async pay leaves and the server takes it; the ping after it finds
    /// the connection gone.
    @Test func aPaymentWhoseConnectionWentAfterAWriteStaysPending() async throws {
        let (transport, writes) = cutTransport(accepting: 1, then: Engine.Failure.notConnected)
        try await withEngine(contact: keyG, transport: transport) { engine, storage throws in
            let sending = Task { try await engine.sendPayment(to: keyG, amountMsat: 1_000, confirmedMsat: 1_000) }
            // The row is written before anything is published; once the
            // async pay has left, the server's answer names its tag.
            var sent: String?
            for _ in 0..<200 where sent == nil || writes.count == 0 {
                sent = try rows(profile, "SELECT tag FROM message WHERE amountMsat IS NOT NULL").first?["tag"]
                try await Task.sleep(for: .milliseconds(10))
            }
            let answered = try #require(sent)
            _ = try await engine.commit(coreResult(asyncpayTag: answered), time: "1", expectedSender: nil)
            let tag = try #require(try await sending.value)
            #expect(tag == sent)
            // One write left and a later one found the connection gone.
            #expect(writes.count == 2)
            let row = try #require(try rows(profile, "SELECT id FROM message WHERE tag = '\(tag)'").first)
            let stored = try #require(try storage.message(id: row["id"]))
            #expect(stored.delivery == .pending)
            #expect(!stored.isRetryable())
        }
    }

    /// Two Retries of one failed payment at once (a double click, or an app
    /// and an agent) send it once: the first marks the row pending before
    /// the second, waiting on the actor, reads it again.
    @Test func aFailedPaymentRetriedTwiceAtOnceGoesOnce() async throws {
        // The send finds the connection gone; any write after is cut short,
        // so a Retry that goes returns at once, pending.
        let writes = Writes()
        let transport = Transport(publishing: { topic, _ in
            let first = writes.topics.withLock { topics in
                topics.append(topic)
                return topics.count == 1
            }
            throw first ? Engine.Failure.notConnected : cutShort
        })
        try await withEngine(contact: keyG, transport: transport) { engine, storage throws in
            let tag = try #require(try await engine.sendPayment(to: keyG, amountMsat: 1_000, confirmedMsat: 1_000))
            let id: Int64 = try #require(try rows(profile, "SELECT id FROM message WHERE tag = '\(tag)'").first?["id"])
            #expect(try storage.message(id: id)?.isRetryable() == true)

            async let first = Result { try await engine.resend(messageID: id, confirmedMsat: 1_000) }
            async let second = Result { try await engine.resend(messageID: id, confirmedMsat: 1_000) }
            let outcomes = await [first, second]
            #expect(outcomes.filter { (try? $0.get()) != nil }.count == 1)
            #expect(outcomes.contains { if case .failure(Engine.Failure.notRetryable) = $0 { true } else { false } })
            // The send's write, and one Retry's.
            #expect(writes.count == 2)
            #expect(try storage.message(id: id)?.delivery == .pending)
        }
    }

    /// On a connect the server is asked about every pending send; a payment
    /// its records do not name is failed (and may be sent again) only once
    /// it is older than `unrecordedPaymentTimeout`: a recent one may not be
    /// recorded yet, and failing it would pay twice.
    @Test func onlyAnOldPaymentTheServerNeverRecordedFails() async throws {
        let now = Date.now.millisecondsSince1970
        func pending(_ n: Int, type: Int, minutesAgo: Int64) -> Message {
            .fixture(
                uuid: uuid(n), type: type, chat: keyG, fromMe: true, body: #"{"content":""}"#, content: "",
                msat: type == MessageType.directPayment ? 1_000 : nil, timestamp: now - minutesAgo * 60_000,
                tag: "t\(n)", status: Message.Delivery.pending.rawValue
            )
        }
        let writes = Writes()
        let transport = Transport(publishing: { topic, _ in writes.topics.withLock { $0.append(topic) } })
        try await withEngine(contact: keyG, transport: transport) { engine, storage throws in
            _ = try storage.apply(Storage.Commit(messages: [
                (pending(1, type: MessageType.directPayment, minutesAgo: 31), false, nil),
                (pending(2, type: MessageType.directPayment, minutesAgo: 5), false, nil),
                (pending(3, type: MessageType.text, minutesAgo: 31), false, nil),
                (pending(4, type: MessageType.directPayment, minutesAgo: 31), false, nil),
            ]))
            try await engine.checkPendingSends()
            #expect(writes.count == 1)
            // The server's records name only the fourth, which went through.
            let records = #"[{"tag":"t4","status":"COMPLETE"}]"#
            _ = try await engine.commit(coreResult(tags: records), time: "1", expectedSender: nil)
            func delivery(_ n: Int) throws -> String? {
                try rows(profile, "SELECT status FROM message WHERE tag = 't\(n)'").first?["status"]
            }
            #expect(try delivery(1) == Message.Delivery.failed.rawValue)
            #expect(try delivery(2) == Message.Delivery.pending.rawValue)
            #expect(try delivery(3) == Message.Delivery.pending.rawValue)
            #expect(try delivery(4) == Message.Delivery.delivered.rawValue)
        }
    }

    /// Only money waits: a text cut short is failed at once, for Retry.
    @Test func aTextCutShortFails() async throws {
        let (transport, _) = cutTransport(accepting: 0, then: cutShort)
        try await withEngine(contact: keyG, transport: transport) { engine, storage throws in
            let tag = try #require(try await engine.sendText("lunch?", to: keyG))
            let row = try #require(try rows(profile, "SELECT id FROM message WHERE tag = '\(tag)'").first)
            let stored = try #require(try storage.message(id: row["id"]))
            #expect(stored.delivery == .failed)
        }
    }

    /// An invoice payment cut short stays pending, and paying it again is
    /// refused as pending rather than sent twice.
    @Test func anInvoicePaymentCutShortIsNotPaidAgain() async throws {
        let bolt11 = try someoneElsesInvoice()
        let invoice = try Invoice(bolt11)
        let (transport, _) = cutTransport(accepting: 0, then: cutShort)
        try await withEngine(transport: transport) { engine, storage throws in
            let record = try await engine.payInvoice(bolt11, confirmedMsat: invoice.amountMsat)
            #expect(record.status == .pending)
            let stored = try #require(try storage.invoice(paymentHash: invoice.paymentHash, incoming: false))
            #expect(stored.status == .pending)
            #expect(try engine.invoiceProblem(invoice) == .invoicePending)
        }
    }

    /// An invite whose funding write was cut short is still sending, not
    /// failed: its sats may be with the server.
    @Test func anInviteCutShortIsStillSending() async throws {
        let (transport, _) = cutTransport(accepting: 0, then: cutShort)
        try await withEngine(transport: transport) { engine, storage throws in
            let invite = try await engine.makeInvite(amountMsat: 10_000, confirmedMsat: 10_000, wait: .zero)
            #expect(invite.status == .sending)
            #expect(try storage.invite(code: invite.code)?.status == .sending)
        }
    }

    /// Stored as sending, then failed when its publish never left; the
    /// same refusal before anything is stored would leave no row.
    @Test func anInviteThatNeverLeftFails() async throws {
        try await withEngine { engine, storage throws in
            await #expect(throws: Engine.Failure.notConnected) {
                try await engine.makeInvite(amountMsat: 10_000, confirmedMsat: 10_000)
            }
            let invite = try #require(try rows(profile, "SELECT status FROM invite").first)
            #expect(invite["status"] as String? == InviteRecord.Status.failed.rawValue)
            #expect(try storage.listPendingInvites().isEmpty)
        }
    }

    /// The key exchange's 5 sats are checked like any payment: the balance,
    /// then the threshold, which asks for exactly that amount; under it
    /// they go with no question. Either way on to the key exchange, which
    /// never left here.
    @Test func addingSomeoneIsCheckedLikeAPayment() async throws {
        try await withEngine { engine, storage throws in
            await #expect(throws: Engine.Failure.notConnected) { try await engine.addContact(code: "\(strangerKey)_\(key3G)_9") }
            let code = "\(keyG)_\(key3G)_9"
            // The key exchange's sats and its ping.
            let needed = Engine.keyExchangeMsat + Engine.pingMsat(toTribe: false)
            try storage.set(String(needed - 1), for: .balanceMsat)
            await #expect(throws: Engine.Failure.contactNeedsSats) { try await engine.addContact(code: code) }
            try storage.set(String(needed), for: .balanceMsat)
            try await engine.setPaymentConfirmation(msat: 0)
            await #expect(throws: Engine.Failure.needsConfirmation(amountMsat: Engine.keyExchangeMsat)) {
                try await engine.addContact(code: code)
            }
            await #expect(throws: Engine.Failure.notConnected) {
                try await engine.addContact(code: code, confirmedMsat: Engine.keyExchangeMsat)
            }
        }
    }

    /// A new account's server sends no balance until it changes: connected
    /// with none yet is 0 sats, so too few to add someone, not "connect first".
    @Test func aNewAccountWithNoBalanceNeedsSatsToAddSomeone() async throws {
        try await withEngine(balanceMsat: nil) { engine, _ throws in
            await #expect(throws: Engine.Failure.contactNeedsSats) { try await engine.addContact(code: "\(keyG)_\(key3G)_9") }
        }
    }

    /// A page asked for on a connection that went never comes: the run is
    /// kept for the next connection (`cameOnline` asks again), not failed
    /// by its watchdog.
    @Test func aDisconnectKeepsTheHistoryRunAndStopsItsWatchdog() async throws {
        try await withEngine { engine, _ throws in
            let watchdog = await engine.awaitPage(of: HistoryCursor.Run(phase: .messages, next: 5, end: 10))
            await engine.disconnect()
            #expect(watchdog.isCancelled)
            #expect(await engine.history.active?.next == 5)
            #expect(await engine.isSyncingHistory)
        }
    }
}

private extension Engine {
    /// As `request` leaves it: a run in flight and its watchdog waiting.
    func awaitPage(of run: HistoryCursor.Run) -> Task<Void, Never> {
        _ = history.start([run])
        let watchdog = Task { _ = try? await Task.sleep(for: .seconds(60)) }
        historyWatchdog = watchdog
        return watchdog
    }
}
