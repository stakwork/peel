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
    private func withEngine(_ body: (Engine, Storage) async throws -> Void) async throws {
        let storage = try profile.storage()
        let settings: [Setting: String] = [.balanceMsat: "1000000", .server: "mqtt://127.0.0.1:1"]
        _ = try storage.apply(Storage.Commit(state: registeredState, settings: settings))
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

    @Test func anInviteThatNeverLeftFails() async throws {
        try await withEngine { engine, storage throws in
            await #expect(throws: Engine.Failure.notConnected) {
                try await engine.makeInvite(amountMsat: 10_000, confirmedMsat: 10_000)
            }
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
            try storage.set(String(Engine.keyExchangeMsat - 1), for: .balanceMsat)
            await #expect(throws: Engine.Failure.insufficientBalance) { try await engine.addContact(code: code) }
            try storage.set(String(Engine.keyExchangeMsat), for: .balanceMsat)
            try await engine.setPaymentConfirmation(msat: 0)
            await #expect(throws: Engine.Failure.needsConfirmation(amountMsat: Engine.keyExchangeMsat)) {
                try await engine.addContact(code: code)
            }
            await #expect(throws: Engine.Failure.notConnected) {
                try await engine.addContact(code: code, confirmedMsat: Engine.keyExchangeMsat)
            }
        }
    }

    /// A page asked for on a connection that went never comes: the run is
    /// kept for the next connection (`cameOnline` asks again), not failed
    /// by its watchdog.
    @Test func aDisconnectKeepsTheHistoryRunAndStopsItsWatchdog() async throws {
        try await withEngine { engine, _ throws in
            let watchdog = await engine.awaitPage(of: Engine.HistoryRun(phase: .messages, next: 5, end: 10))
            await engine.disconnect()
            #expect(watchdog.isCancelled)
            #expect(await engine.history?.next == 5)
            #expect(await engine.isSyncingHistory)
        }
    }
}

private extension Engine {
    /// As `request` leaves it: a run in flight and its watchdog waiting.
    func awaitPage(of run: HistoryRun) -> Task<Void, Never> {
        history = run
        let watchdog = Task { _ = try? await Task.sleep(for: .seconds(60)) }
        historyWatchdog = watchdog
        return watchdog
    }
}
