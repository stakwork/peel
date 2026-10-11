import Foundation
import Sphinxrs
import Testing
@testable import PeelCore

/// What money and history do when the connection goes: a payment or an
/// invite whose publish never left is failed at once and may be made again,
/// and a history run waits for the next connection instead of failing.
struct ConnectionDropTests {
    let profile = TempProfile()

    /// Runs `body` on a registered engine with a balance, on `goneTransport()`,
    /// and disconnects after, which shuts the transport's client down.
    private func withEngine(
        balanceMsat: UInt64? = 1_000_000, contact: String? = nil, _ body: (Engine, Storage) async throws -> Void
    ) async throws {
        let storage = try profile.storage()
        var settings: [Setting: String] = [.server: "mqtt://127.0.0.1:1"]
        settings[.balanceMsat] = balanceMsat.map(String.init)
        let state = registeredState.merging(contact.map { coreContact($0, contactKey: key3G) } ?? [:]) { $1 }
        _ = try storage.apply(Storage.Commit(
            state: state, settings: settings, contacts: contact.map { [($0, true)] }
        ))
        let engine = try testEngine(storage)
        await engine.useTransportForTesting(goneTransport())
        do {
            try await body(engine, storage)
        } catch {
            await engine.disconnect()
            throw error
        }
        await engine.disconnect()
    }

    /// An invoice for 10 sats from another account, valid for an hour.
    private func someoneElsesInvoice() throws -> String {
        let seed = try Sphinxrs.mnemonicToSeed(
            mnemonic: "legal winner thank year wave sausage worth useful legal winner thank yellow"
        )
        let made = try Sphinxrs.makeInvoice(
            seed: seed, uniqueTime: String(Date().millisecondsSince1970), state: StateCodec.encode(registeredState),
            amtMsat: 10_000, description: "test"
        )
        return try #require(made.invoice)
    }

    @Test func anInvoicePaymentThatNeverLeftFailsAndCanBePaidAgain() async throws {
        let bolt11 = try someoneElsesInvoice()
        let invoice = try Invoice(bolt11)
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
