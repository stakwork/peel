import Foundation
import Sphinxrs
import Synchronization
import Testing
@testable import PeelCore
@testable import PeelTestSupport

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

/// Which of several sends at once a write belongs to.
private enum Sending {
    @TaskLocal static var label = ""
}

/// A write the closing connection cut short: it may have left.
private let cutShort = PeelError("the write was cut short")

/// A connection that takes every write, and the writes it took.
private func recordingTransport() -> (Transport, Writes) {
    cutTransport(accepting: .max, then: cutShort)
}

/// One of ours still pending, numbered for its uuid and its tag ("t1"),
/// sent `minutesAgo`: a payment of 1 sat, or what a tribe message paid
/// (`msat`).
private func pending(_ n: Int, type: Int, minutesAgo: Int64, chat: String = keyG, msat: Int64? = nil) -> Message {
    .fixture(
        uuid: uuid(n), type: type, chat: chat, fromMe: true, body: #"{"content":""}"#, content: "",
        msat: msat ?? (type == MessageType.directPayment ? 1_000 : nil),
        timestamp: Date.now.millisecondsSince1970 - minutesAgo * 60_000, tag: "t\(n)",
        status: Message.Delivery.pending.rawValue
    )
}

/// What money and history do when the connection goes: a payment or an
/// invite whose publish never left is failed at once and may be made again;
/// one that may have left stays pending, never offered again, until the
/// server says; a signup whose register may have left keeps its words; and
/// a history run waits for the next connection instead of failing.
struct ConnectionDropTests {
    let profile = TempProfile()

    /// Runs `body` on a registered engine with a balance, on `transport`
    /// (by default `goneTransport()`), and disconnects after, which shuts
    /// the transport's client down. A `tribe` is joined, at its price.
    private func withEngine(
        balanceMsat: UInt64? = 1_000_000, contact: String? = nil, tribe: Tribe? = nil,
        transport: Transport = goneTransport(), _ body: (Engine, Storage) async throws -> Void
    ) async throws {
        var setup = Storage.Commit()
        setup.settings[.balanceMsat] = balanceMsat.map(String.init)
        let storage = try registeredStorage(profile, contact: contact, setup)
        if let tribe {
            try storage.save([tribe])
            var joined = Storage.Commit()
            joined.state = registeredState.merging(contact.map { coreContact($0, contactKey: key3G) } ?? [:]) { $1 }
                .merging(coreContact(tribe.pubkey, contactKey: nil)) { $1 }
            _ = try storage.apply(joined)
        }
        try await withTestEngine(storage, on: transport) { try await body($0, storage) }
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
        let (transport, writes) = recordingTransport()
        try await withEngine(contact: keyG, tribe: Tribe(pubkey: key2G), transport: transport) { engine, storage throws in
            _ = try storage.apply(Storage.Commit(messages: [
                (pending(1, type: MessageType.directPayment, minutesAgo: 31), false, nil),
                (pending(2, type: MessageType.directPayment, minutesAgo: 5), false, nil),
                (pending(3, type: MessageType.text, minutesAgo: 31), false, nil),
                (pending(4, type: MessageType.directPayment, minutesAgo: 31), false, nil),
                // The fifth paid a tribe's price.
                (pending(5, type: MessageType.text, minutesAgo: 31, chat: key2G, msat: 3_000), false, nil),
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
            #expect(try delivery(5) == Message.Delivery.failed.rawValue)
        }
    }

    /// A tribe text pays the tribe's price (at least 3 sats), so one cut
    /// short waits like a payment: pending, never offered for Retry, and
    /// asked about as money until the server says.
    @Test func aPricedTribeTextCutShortStaysPendingAndIsNotRetried() async throws {
        let (transport, writes) = cutTransport(accepting: 0, then: cutShort)
        try await withEngine(tribe: Tribe(pubkey: key2G), transport: transport) { engine, storage throws in
            let tag = try #require(try await engine.sendText("hello all", to: key2G))
            #expect(writes.count >= 1)
            let row = try #require(try rows(profile, "SELECT id FROM message WHERE tag = '\(tag)'").first)
            let stored = try #require(try storage.message(id: row["id"]))
            #expect(stored.msat == 3_000)
            #expect(stored.delivery == .pending)
            #expect(!stored.isRetryable(now: .now.addingTimeInterval(3600)))
            #expect(try storage.pendingSendTags(textBefore: 0).contains { $0.tag == tag && $0.movesMoney })
        }
    }

    /// A tribe text unconfirmed past the usual wait may have paid and
    /// posted: Retry refuses it and sends nothing.
    @Test func aPricedTribeTextUnconfirmedPastTheWaitIsNotSentAgain() async throws {
        let (transport, writes) = recordingTransport()
        try await withEngine(tribe: Tribe(pubkey: key2G), transport: transport) { engine, storage throws in
            let sent = pending(1, type: MessageType.text, minutesAgo: 1, chat: key2G, msat: 3_000)
            _ = try storage.apply(Storage.Commit(messages: [(sent, false, nil)]))
            let id = try #require(try storage.message(uuid: uuid(1), in: key2G)?.id)
            await #expect(throws: Engine.Failure.notRetryable) { try await engine.resend(messageID: id) }
            #expect(writes.count == 0)
            #expect(try storage.message(id: id)?.tag == "t1")
        }
    }

    /// A tribe text that failed when it carried no sats (here a row from
    /// before the tribe charged), sent again now the tribe does: the row
    /// takes the sats of the send that took it over, so one cut short may
    /// have paid and is never offered for Retry again.
    @Test func aRetriedTribeTextTakesTheSatsItNowCarries() async throws {
        let (transport, writes) = cutTransport(accepting: 0, then: cutShort)
        try await withEngine(tribe: Tribe(pubkey: key2G), transport: transport) { engine, storage throws in
            var free = pending(1, type: MessageType.text, minutesAgo: 1, chat: key2G)
            free.status = Message.Delivery.failed.rawValue
            _ = try storage.apply(Storage.Commit(messages: [(free, false, nil)]))
            let id = try #require(try storage.message(uuid: uuid(1), in: key2G)?.id)
            #expect(try storage.message(id: id)?.msat == nil)
            _ = try await engine.resend(messageID: id)
            #expect(writes.count >= 1)
            let row = try #require(try storage.message(id: id))
            #expect(row.msat == 3_000)
            #expect(row.delivery == .pending)
            #expect(row.mayHavePaid)
            #expect(!row.isRetryable(now: .now.addingTimeInterval(3600)))
            await #expect(throws: Engine.Failure.notRetryable) { try await engine.resend(messageID: id) }
        }
    }

    /// An attachment of ours to a tribe, uploaded and waiting for its first
    /// send as `sendAttachment` leaves it: pending, no uuid or tag yet, and
    /// already carrying the tribe's price; or, with `sent`, that send taken.
    /// Stored; returns the row and its id.
    private func uploadedDraft(
        in storage: Storage, sent: (uuid: String, tag: String)? = nil
    ) throws -> (row: Message, id: Int64) {
        var draft = Message.fixture(
            uuid: sent?.uuid, type: MessageType.attachment, chat: key2G, fromMe: true,
            body: #"{"content":"","mediaKey":"k","mediaToken":"t"}"#, content: "", msat: 3_000,
            timestamp: Date.now.millisecondsSince1970 - 60_000, tag: sent?.tag,
            status: Message.Delivery.pending.rawValue
        )
        draft.mediaType = "image/jpeg"
        draft.upload = Message.Upload.done.rawValue
        let row = try #require(try storage.apply(Storage.Commit(messages: [(draft, false, nil)])).stored.first)
        return (row, try #require(row.id))
    }

    /// A tribe attachment's first send takes over its draft, which already
    /// carries the price, so the server's status and the tribe's copy find it.
    @Test func aTribeAttachmentsFirstSendTakesOverItsDraft() async throws {
        let (transport, _) = recordingTransport()
        try await withEngine(tribe: Tribe(pubkey: key2G), transport: transport) { engine, storage throws in
            let (draft, id) = try uploadedDraft(in: storage)
            let tag = try #require(try await engine.uploadAndDeliver(draft))
            let row = try #require(try storage.message(id: id))
            #expect(row.tag == tag)
            #expect(row.uuid != nil)
            #expect(row.delivery == .pending)
        }
    }

    /// A tribe attachment whose first send is refused before it leaves
    /// (here the owner has not let this account in yet) has no tag: it
    /// never paid, so past the usual wait it may go again or be discarded,
    /// rather than wait for a server that never had it.
    @Test func aTribeAttachmentThatNeverLeftMayGoAgain() async throws {
        let (transport, writes) = recordingTransport()
        try await withEngine(tribe: Tribe(pubkey: key2G, status: .pending), transport: transport) { engine, storage throws in
            let (draft, id) = try uploadedDraft(in: storage)
            await #expect(throws: Engine.Failure.awaitingApproval) { try await engine.uploadAndDeliver(draft) }
            let row = try #require(try storage.message(id: id))
            #expect(row.tag == nil)
            #expect(row.isRetryable())
            #expect(writes.count == 0)
        }
    }

    /// A send takes over only a row that may still go: one that went
    /// meanwhile (here a tribe attachment already sent and unconfirmed, as
    /// a Retry finds it once its upload is done) is refused before anything
    /// is published, so the losing Retry pays nothing.
    @Test func aSendWhoseRowWentMeanwhileIsNotPublished() async throws {
        let (transport, writes) = recordingTransport()
        try await withEngine(tribe: Tribe(pubkey: key2G), transport: transport) { engine, storage throws in
            let (sent, id) = try uploadedDraft(in: storage, sent: (uuid(1), "t1"))
            await #expect(throws: PeelError.self) { try await engine.uploadAndDeliver(sent) }
            #expect(writes.count == 0)
            let row = try #require(try storage.message(id: id))
            #expect(row.tag == "t1")
            #expect(row.delivery == .pending)
        }
    }

    /// Only what carried sats waits: a direct message's text cut short is
    /// failed at once, for Retry.
    @Test func aTextCutShortFails() async throws {
        let (transport, _) = cutTransport(accepting: 0, then: cutShort)
        try await withEngine(contact: keyG, transport: transport) { engine, storage throws in
            let tag = try #require(try await engine.sendText("lunch?", to: keyG))
            let row = try #require(try rows(profile, "SELECT id FROM message WHERE tag = '\(tag)'").first)
            let stored = try #require(try storage.message(id: row["id"]))
            #expect(stored.delivery == .failed)
        }
    }

    /// Two long messages sent at once: each one's fragments leave together,
    /// so the server gives them consecutive indices and the official apps
    /// can put each back together from one page of history.
    @Test func longMessagesSentAtOnceDoNotInterleave() async throws {
        let sends = Mutex<[String]>([])
        let transport = Transport(publishing: { _, _ in
            sends.withLock { $0.append(Sending.label) }
            // A slow write, so a send waiting its turn would get in between.
            try await Task.sleep(for: .milliseconds(2))
        })
        let long = String(repeating: "word ", count: 600)
        try await withEngine(contact: keyG, transport: transport) { engine, _ throws in
            async let a = Sending.$label.withValue("a") { try await engine.sendText(long, to: keyG) }
            async let b = Sending.$label.withValue("b") { try await engine.sendText(long, to: keyG) }
            _ = try await (a, b)
        }
        let order = sends.withLock { $0 }
        // Both long enough to split, each in one run.
        #expect(order.filter { $0 == "a" }.count > 1)
        #expect(order.filter { $0 == "a" }.count == order.filter { $0 == "b" }.count)
        #expect(zip(order, order.dropFirst()).filter { $0 != $1 }.count == 1)
    }

    /// An invoice payment cut short stays pending, and paying it again is
    /// refused as pending rather than sent twice.
    @Test func anInvoicePaymentCutShortIsNotPaidAgain() async throws {
        let invoice = try madeInvoice()
        let bolt11 = invoice.bolt11
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

    /// A signup whose register never left (the connection had gone) leaves
    /// nothing behind: the server never saw the invite, and the person can
    /// sign up again.
    @Test func aSignupWhoseRegisterNeverLeftLeavesNothing() async throws {
        let account = Profile(developmentAt: profile.url)
        let invite = Engine.Invite(
            code: String(repeating: "ab", count: 32), server: nil, inviterContactInfo: nil, inviterAlias: nil
        )
        let (gone, writes) = cutTransport(accepting: 0, then: Engine.Failure.notConnected)
        await #expect(throws: Engine.Failure.notConnected) {
            try await Engine.$connectingForTesting.withValue(gone) {
                try await Account.signup(
                    account, invite: invite, alias: "Dana", pin: "", server: ServerAddress("mqtt://127.0.0.1:1")
                )
            }
        }
        #expect(writes.topics.withLock(\.first)?.contains("/register/") == true)
        #expect(!account.hasAccount)
    }

    /// A signup whose connection went after its register keeps the words:
    /// the server redeems the invite as it registers the account, before it
    /// answers, so the account may hold the invite's sats (bug hunt N2).
    /// The next connect registers with the invite again, for a server that
    /// never got the first; once one is confirmed, no connect names it.
    @Test func aSignupCutShortAfterItsRegisterKeepsTheWords() async throws {
        let account = Profile(developmentAt: profile.url)
        let code = String(repeating: "ab", count: 32)
        let invite = Engine.Invite(code: code, server: nil, inviterContactInfo: nil, inviterAlias: nil)
        let (cut, signupWrites) = cutTransport(accepting: 1, then: cutShort)
        let created = try? await Engine.$connectingForTesting.withValue(cut) {
            try await Account.signup(
                account, invite: invite, alias: "Dana", pin: "", server: ServerAddress("mqtt://127.0.0.1:1")
            )
        }
        #expect(signupWrites.topics.withLock(\.first)?.hasSuffix("/register/\(code)") == true)
        #expect(account.hasAccount)
        #expect(try account.loadMnemonic(pin: "") == created?.mnemonic)
        let engine = try #require(created?.engine)
        #expect(await !engine.isRegistered)

        /// The server's answer to a register: the account, registered.
        func registeredReply() -> RunReturn {
            var reply = coreResult()
            reply.stateMp = StateCodec.encode(registeredState)
            reply.myContactInfo = "\(keyG)_\(key3G)_1"
            return reply
        }
        /// The register a connect makes, answered once it has gone if `answered`.
        func register(answered: Bool) async throws -> String? {
            let writes = Writes()
            let open = Transport(publishing: { topic, _ in writes.topics.withLock { $0.append(topic) } })
            try await Engine.$connectingForTesting.withValue(open) {
                let connecting = Task { try await engine.connect() }
                for _ in 0..<200 where writes.count == 0 {
                    try await Task.sleep(for: .milliseconds(10))
                }
                if answered {
                    let followUps = try await engine.commit(registeredReply(), time: "1", expectedSender: nil)
                    try await engine.complete(registeredReply(), followUps)
                }
                try await connecting.value
            }
            await engine.disconnect()
            return writes.topics.withLock { $0.first { $0.contains("/register") } }
        }
        #expect(try await register(answered: true)?.hasSuffix("/register/\(code)") == true)
        #expect(await engine.isRegistered)
        #expect(try await engine.storedInvite() == nil)
        #expect(try await register(answered: false)?.hasSuffix("/register") == true)
    }

    /// A new account adds whoever invited it once it is online, at most
    /// once: the invite is forgotten as the key exchange starts, and kept
    /// for the next connection only when nothing of that exchange left.
    @Test(arguments: [true, false]) func aNewAccountAddsItsInviterAtMostOnce(nothingLeft: Bool) async throws {
        let transport = nothingLeft ? goneTransport() : cutTransport(accepting: 0, then: cutShort).0
        try await withEngine(transport: transport) { engine, _ throws in
            let invite = Engine.Invite(
                code: String(repeating: "ab", count: 32), server: nil,
                inviterContactInfo: "\(keyG)_\(key3G)_9", inviterAlias: "Alice"
            )
            try await engine.storeInvite(invite)
            await engine.addInviterIfPending()?.value
            // The key exchange began: the core holds the contact it is with.
            #expect(await Engine.contact(keyG, in: engine.state) != nil)
            #expect(try await engine.storedInvite() == (nothingLeft ? invite : nil))
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

    /// Resume after a stall (`resumeHistory`, what coming online also does)
    /// asks the server again: a restore for its counts, its plan starting
    /// over (which the app's progress follows), a catch-up for the page
    /// where history stands.
    @Test(arguments: [true, false]) func resumeAfterAStallAsksTheServerAgain(restoring: Bool) async throws {
        let (transport, writes) = recordingTransport()
        try await withEngine(transport: transport) { engine, _ throws in
            await engine.stall(HistoryCursor.Run(phase: .messages, next: 5, end: 10), restoring: restoring)
            #expect(await !engine.isSyncingHistory)
            let before = writes.count
            try await engine.resumeHistory()
            #expect(writes.count == before + 1)
            #expect(await engine.isSyncingHistory)
            #expect(await engine.history.awaitingCounts == restoring)
            await engine.close()
            var restarts: [Bool] = []
            for await case .historyResumed(let restart) in engine.events { restarts.append(restart) }
            #expect(restarts == [restoring])
        }
    }

    /// Coming online with a page in flight (the connection went before its
    /// answer) asks for that page again, and a restore does not start over.
    @Test func resumeWithAPageInFlightAsksForItAgain() async throws {
        let (transport, writes) = recordingTransport()
        try await withEngine(transport: transport) { engine, _ throws in
            _ = await engine.awaitPage(of: HistoryCursor.Run(phase: .messages, next: 5, end: 10))
            await engine.setRestoring(true)
            let before = writes.count
            try await engine.resumeHistory()
            #expect(writes.count == before + 1)
            #expect(await engine.history.active?.next == 5)
            #expect(await !engine.history.awaitingCounts)
            await engine.close()
            var restarts: [Bool] = []
            for await case .historyResumed(let restart) in engine.events { restarts.append(restart) }
            #expect(restarts == [false])
        }
    }

    /// An ask that does not leave pauses history again, so Resume is
    /// offered for it, rather than leaving a restore waiting on counts it
    /// never asked for.
    @Test func aResumeThatCannotSendPausesAgain() async throws {
        let (transport, _) = cutTransport(accepting: 0, then: cutShort)
        try await withEngine(transport: transport) { engine, _ throws in
            await engine.stall(HistoryCursor.Run(phase: .messages, next: 5, end: 10), restoring: true)
            await #expect(throws: (any Error).self) { try await engine.resumeHistory() }
            #expect(await !engine.isSyncingHistory)
            await engine.close()
            var failures = 0
            for await case .historyFailed in engine.events { failures += 1 }
            #expect(failures == 1)
        }
    }
}

private extension Engine {
    func setRestoring(_ value: Bool) { restoring = value }

    /// A run whose page never came: its watchdog gave up on it.
    func stall(_ run: HistoryCursor.Run, restoring: Bool) {
        self.restoring = restoring
        _ = history.start([run])
        _ = history.stalled(at: run.next)
    }

    /// As `request` leaves it: a run in flight and its watchdog waiting.
    func awaitPage(of run: HistoryCursor.Run) -> Task<Void, Never> {
        _ = history.start([run])
        let watchdog = Task { _ = try? await Task.sleep(for: .seconds(60)) }
        historyWatchdog = watchdog
        return watchdog
    }
}
