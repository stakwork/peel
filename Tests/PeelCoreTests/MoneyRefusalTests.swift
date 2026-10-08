import Foundation
import Testing
@testable import PeelCore

/// A contact the core has finished the key exchange with, and a tribe.
private let person = keyG
private let tribe = key2G

private let longNote = String(repeating: "x", count: 600)

/// The refusals the engine makes before any core call: the balance, the
/// confirmation threshold, what may be boosted or paid, and the note's room.
/// A payment that passes them all goes to `deliver`, which refuses a body
/// that would be split before calling the core; the tests that need to see
/// a payment pass use a note (or a photo URL) too long for that, so nothing
/// is ever sent. The refused cases carry the long note too, so a note
/// check moved ahead of the money checks would fail them.
struct MoneyRefusalTests {
    let profile = TempProfile()

    private func ownPayment(
        _ n: Int, type: Int = MessageType.directPayment, chat: String = person, on parent: Int? = nil,
        status: Message.Delivery = .failed, msat: Int64
    ) -> Message {
        let reply = parent.map { #","replyUuid":"\#(uuid($0))""# } ?? ""
        return .fixture(
            uuid: uuid(n), type: type, chat: chat, fromMe: true, body: #"{"content":""\#(reply)}"#, content: "",
            timestamp: Int64(n) * 1_000, tag: "t\(n)", status: status.rawValue, replyUUID: parent.map(uuid),
            amountMsat: msat
        )
    }

    /// An engine on a temp profile with `person` in the core's state and
    /// `tribes` stored; `balanceMsat` nil is a balance never reported.
    private func engine(
        balanceMsat: UInt64? = 1_000_000, tribes: [Tribe] = [], messages: [Message] = [],
        settings: [Setting: String] = [:]
    ) throws -> (Engine, Storage) {
        let storage = try profile.storage()
        try storage.save(tribes)
        var settings = settings
        settings[.balanceMsat] = balanceMsat.map(String.init)
        _ = try storage.apply(Storage.Commit(
            state: coreContact(person, contactKey: key3G), settings: settings, contacts: [(person, true)],
            messages: messages.map { ($0, false, nil) }
        ))
        return (try testEngine(storage), storage)
    }

    private func id(_ n: Int, in chat: String = person, _ storage: Storage) throws -> Int64 {
        try #require(try storage.message(uuid: uuid(n), in: chat)?.id)
    }

    /// The fixture record reads back through the core as a person, so a
    /// change in the core's format shows here first.
    @Test func theContactFixtureIsAPersonToTheCore() throws {
        let storage = try profile.storage()
        _ = try storage.apply(Storage.Commit(
            state: coreContact(person, contactKey: key3G).merging(coreContact(tribe, contactKey: nil)) { $1 }
        ))
        let contacts = try Engine.contacts(in: storage)
        #expect(contacts.first { $0.pubkey == person }?.contactKey == key3G)
        #expect(contacts.contains { $0.pubkey == tribe && $0.contactKey == nil })
    }

    // MARK: Payments

    @Test func aPaymentWaitsForTheBalance() async throws {
        let (engine, _) = try engine(balanceMsat: nil)
        await #expect(throws: Engine.Failure.balanceUnknown) {
            try await engine.sendPayment(to: person, amountMsat: 1, text: longNote)
        }
    }

    @Test func aPaymentIsRefusedOverTheBalanceAndAtZero() async throws {
        let (engine, _) = try engine(balanceMsat: 50_000)
        await #expect(throws: Engine.Failure.insufficientBalance) {
            try await engine.sendPayment(to: person, amountMsat: 50_001, text: longNote)
        }
        await #expect(throws: Engine.Failure.invalidAmount) {
            try await engine.sendPayment(to: person, amountMsat: 0, text: longNote)
        }
        // The whole balance is allowed.
        await #expect(throws: Engine.Failure.noteTooLong) {
            try await engine.sendPayment(to: person, amountMsat: 50_000, text: longNote)
        }
    }

    @Test func aPaymentToATribeIsRefused() async throws {
        let (engine, _) = try engine(tribes: [Tribe(pubkey: tribe)])
        await #expect(throws: Engine.Failure.paymentToTribe) {
            try await engine.sendPayment(to: tribe, amountMsat: 1, text: longNote)
        }
    }

    @Test func aPaymentOverTheThresholdAsksForExactlyItsAmount() async throws {
        let (engine, _) = try engine()
        let over = Engine.defaultPaymentConfirmationMsat + 1
        await #expect(throws: Engine.Failure.needsConfirmation(amountMsat: over)) {
            try await engine.sendPayment(to: person, amountMsat: over, text: longNote)
        }
        await #expect(throws: Engine.Failure.needsConfirmation(amountMsat: over)) {
            try await engine.sendPayment(to: person, amountMsat: over, text: longNote, confirmedMsat: over - 1)
        }
        await #expect(throws: Engine.Failure.noteTooLong) {
            try await engine.sendPayment(to: person, amountMsat: over, text: longNote, confirmedMsat: over)
        }
        // 0 asks for every payment.
        try await engine.setPaymentConfirmation(msat: 0)
        await #expect(throws: Engine.Failure.needsConfirmation(amountMsat: 1)) {
            try await engine.sendPayment(to: person, amountMsat: 1, text: longNote)
        }
    }

    @Test func aNoteThatWouldBeSplitIsRefused() async throws {
        let (engine, _) = try engine()
        await #expect(throws: Engine.Failure.noteTooLong) {
            try await engine.sendPayment(to: person, amountMsat: 1_000, text: longNote)
        }
    }

    // MARK: Boosts

    @Test func onlySomeoneElsesTextCanBeBoosted() async throws {
        let (engine, storage) = try engine(messages: [
            text(1, chat: person, fromMe: true), ownPayment(2, status: .delivered, msat: 1_000),
        ])
        for id in [try id(1, storage), try id(2, storage), 999] {
            await #expect(throws: Engine.Failure.notBoostable) { try await engine.boost(messageID: id, amountMsat: 1_000) }
        }
    }

    @Test func aBoostWaitsForTheBalance() async throws {
        let (engine, storage) = try engine(balanceMsat: nil, messages: [text(1, chat: person)])
        let id = try id(1, storage)
        await #expect(throws: Engine.Failure.balanceUnknown) { try await engine.boost(messageID: id, amountMsat: 1) }
        await #expect(throws: Engine.Failure.balanceUnknown) { try await engine.quickBoost(messageID: id) }
        await #expect(throws: Engine.Failure.invalidAmount) { try await engine.boost(messageID: id, amountMsat: 0) }
    }

    @Test func aBoostIsRefusedOverTheBalance() async throws {
        let (engine, storage) = try engine(
            balanceMsat: Engine.defaultBoostAmountMsat - 1, messages: [text(1, chat: person)]
        )
        let id = try id(1, storage)
        await #expect(throws: Engine.Failure.insufficientBalance) {
            try await engine.boost(messageID: id, amountMsat: Engine.defaultBoostAmountMsat)
        }
        await #expect(throws: Engine.Failure.insufficientBalance) { try await engine.quickBoost(messageID: id) }
    }

    /// In a tribe the boost also pays the tribe's price, and both the
    /// balance and the confirmation are for that total.
    @Test func aTribeBoostCountsTheTribesPrice() async throws {
        let priced = Tribe(pubkey: tribe, pricePerMessageMsat: 2_000, escrowMsat: 1_000)
        let (engine, storage) = try engine(balanceMsat: 10_000, tribes: [priced], messages: [text(1, chat: tribe)])
        let id = try id(1, in: tribe, storage)
        await #expect(throws: Engine.Failure.insufficientBalance) {
            try await engine.boost(messageID: id, amountMsat: 8_000)
        }
        // A tip too large to add to the price is refused, not wrapped.
        await #expect(throws: Engine.Failure.insufficientBalance) {
            try await engine.boost(messageID: id, amountMsat: .max)
        }
        try await engine.setPaymentConfirmation(msat: 5_000)
        await #expect(throws: Engine.Failure.needsConfirmation(amountMsat: 7_000)) {
            try await engine.boost(messageID: id, amountMsat: 4_000)
        }
        // Confirming the tip alone does not cover the total.
        await #expect(throws: Engine.Failure.needsConfirmation(amountMsat: 7_000)) {
            try await engine.boost(messageID: id, amountMsat: 4_000, confirmedMsat: 4_000)
        }
    }

    @Test(arguments: [
        (Tribe(pubkey: tribe, status: .pending), Engine.Failure.awaitingApproval),
        (Tribe(pubkey: tribe, status: .removed), .notInTribe),
        (Tribe(pubkey: tribe, status: .deleted), .notInTribe),
        (Tribe(pubkey: tribe, left: true), .notInTribe),
    ])
    func aBoostNeedsATribeThatTakesMessages(tribe: Tribe, failure: Engine.Failure) async throws {
        let (engine, storage) = try engine(tribes: [tribe], messages: [text(1, chat: tribe.pubkey)])
        let id = try id(1, in: tribe.pubkey, storage)
        await #expect(throws: failure) { try await engine.boost(messageID: id, amountMsat: 1_000) }
    }

    /// Any boost of ours on a message, a failed one included, makes a tap a
    /// no-op that checks nothing.
    @Test func aMessageIsQuickBoostedOnce() async throws {
        let (engine, storage) = try engine(balanceMsat: nil, messages: [
            text(1, chat: person), ownPayment(2, type: MessageType.boost, on: 1, msat: 100_000),
        ])
        #expect(try await engine.quickBoost(messageID: try id(1, storage)) == nil)
    }

    /// A one-tap boost never asks, even with "Always confirm": its amount
    /// was confirmed when saved. A photo URL too long for any payment stops
    /// it in `deliver`, past the money checks.
    @Test func aQuickBoostIsNotHeldToTheThreshold() async throws {
        let (engine, storage) = try engine(
            messages: [text(1, chat: person)],
            settings: [.paymentConfirmationMsat: "0", .photoURL: "https://" + String(repeating: "p", count: 600)]
        )
        let id = try id(1, storage)
        await #expect(throws: Engine.Failure.noteTooLong) { try await engine.quickBoost(messageID: id) }
    }

    // MARK: The boost amount

    @Test func theBoostAmountIsConfirmedLikeAPayment() async throws {
        let (engine, _) = try engine()
        #expect(try await engine.boostAmountMsat() == Engine.defaultBoostAmountMsat)
        await #expect(throws: Engine.Failure.invalidAmount) { try await engine.setBoostAmount(msat: 0) }
        let over = Engine.defaultPaymentConfirmationMsat + 1
        await #expect(throws: Engine.Failure.needsConfirmation(amountMsat: over)) {
            try await engine.setBoostAmount(msat: over)
        }
        await #expect(throws: Engine.Failure.needsConfirmation(amountMsat: over)) {
            try await engine.setBoostAmount(msat: over, confirmedMsat: over + 1)
        }
        #expect(try await engine.boostAmountMsat() == Engine.defaultBoostAmountMsat)
        try await engine.setBoostAmount(msat: over, confirmedMsat: over)
        #expect(try await engine.boostAmountMsat() == over)
        try await engine.setBoostAmount(msat: 21_000)
        #expect(try await engine.boostAmountMsat() == 21_000)
        try await engine.setPaymentConfirmation(msat: 0)
        await #expect(throws: Engine.Failure.needsConfirmation(amountMsat: 1)) { try await engine.setBoostAmount(msat: 1) }
    }

    // MARK: Retrying a payment

    @Test func onlyAFailedPaymentIsRetried() async throws {
        let (engine, storage) = try engine(messages: [
            ownPayment(1, status: .pending, msat: 1_000), ownPayment(2, status: .unsettled, msat: 1_000),
            ownPayment(3, status: .delivered, msat: 1_000),
        ])
        for n in 1...3 {
            let id = try id(n, storage)
            await #expect(throws: Engine.Failure.notRetryable) { try await engine.resend(messageID: id) }
        }
    }

    @Test func aRetriedPaymentIsCheckedLikeANewOne() async throws {
        let over = Int64(Engine.defaultPaymentConfirmationMsat) + 1
        let (engine, storage) = try engine(balanceMsat: 50_000, messages: [
            ownPayment(1, msat: 50_001), ownPayment(2, msat: over),
            // A boost whose message is ours (or was deleted since) is never paid.
            text(3, chat: person, fromMe: true), ownPayment(4, type: MessageType.boost, on: 3, msat: 1_000),
        ])
        let first = try id(1, storage)
        await #expect(throws: Engine.Failure.insufficientBalance) { try await engine.resend(messageID: first) }
        let boost = try id(4, storage)
        await #expect(throws: Engine.Failure.notBoostable) { try await engine.resend(messageID: boost) }
        try storage.set("100000000", for: .balanceMsat)
        let second = try id(2, storage)
        await #expect(throws: Engine.Failure.needsConfirmation(amountMsat: UInt64(over))) {
            try await engine.resend(messageID: second)
        }
    }

    @Test func aRetriedTribeBoostMustStillCoverThePrice() async throws {
        let raised = Tribe(pubkey: tribe, pricePerMessageMsat: 5_000)
        let (engine, storage) = try engine(tribes: [raised], messages: [
            text(1, chat: tribe), ownPayment(2, type: MessageType.boost, chat: tribe, on: 1, msat: 4_000),
        ])
        let id = try id(2, in: tribe, storage)
        let error = await #expect(throws: PeelError.self) { try await engine.resend(messageID: id) }
        #expect(error?.description.contains("charges more") == true)
    }

    // MARK: Invoices

    @Test func anInvoiceThatCannotBePaidIsRefusedFirst() async throws {
        let (engine, _) = try engine(balanceMsat: nil)
        await #expect(throws: Engine.Failure.invoiceExpired) { try await engine.payInvoice(coffee) }
        await #expect(throws: Engine.Failure.invoiceWithoutAmount) { try await engine.payInvoice(donation) }
    }

    @Test func onlySomeoneElsesRequestIsPaidFromItsChat() async throws {
        let (engine, storage) = try engine(messages: [
            text(1, chat: person), request(fromMe: true, id: 2, chat: person),
        ])
        for n in [1, 2] {
            let id = try id(n, storage)
            let error = await #expect(throws: PeelError.self) { try await engine.payRequest(messageID: id) }
            #expect(error?.description == "that is not someone's payment request")
        }
    }
}
