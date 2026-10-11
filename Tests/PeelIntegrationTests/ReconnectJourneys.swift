import Foundation
import GRDB
import Testing
@testable import PeelCore

extension Journeys {
    /// What a dropped connection does to sends: recent messages that move
    /// no money go again by themselves when it comes back, once; payments
    /// and old messages wait for Retry; a connection that stops answering
    /// is noticed, and Retry on it says so.
    @Suite struct Reconnects {
        /// Alice is on the wire tap and keeps connected, as the app does;
        /// Bob is not on the tap.
        private func contacts() async throws -> (alice: Person, bob: Person) {
            let alice = try await Person.create("alice", throughTap: true)
            let bob = try await Person.create("bob")
            try await Bank.shared.give(1_000, to: alice)
            try await alice.engine.addContact(code: try bob.contactInfo)
            try await eventually("Alice and Bob to be contacts") {
                try alice.isReadyContact(bob) && bob.isReadyContact(alice)
            }
            await alice.engine.start()
            return (alice, bob)
        }

        @Test func aRecentTextGoesAgainByItselfButNeverAPaymentOrAnOldText() async throws {
            let (alice, bob) = try await contacts()
            let bobKey = try bob.pubkey
            let bobBalance = try await bob.settledBalance() ?? 0

            try await Stack.shared.tap(.down)
            try await eventually("Alice to see the connection go") { await alice.engine.connection != .connected }
            let text = "sent on the train \(UUID().uuidString)"
            let old = "sent two hours ago \(UUID().uuidString)"
            try await alice.engine.sendText(text, to: bobKey)
            try await alice.engine.sendText(old, to: bobKey)
            try await alice.engine.sendPayment(to: bobKey, amountMsat: 10_000, confirmedMsat: 10_000)
            let failed = try alice.messages(in: bobKey).filter { $0.fromMe && $0.delivery == .failed }
            #expect(failed.count == 3)
            let oldID = try #require(failed.first { $0.content == old }?.id)
            let paymentID = try #require(failed.first { $0.type == MessageType.directPayment }?.id)
            let twoHoursAgo = Date.now.addingTimeInterval(-2 * 60 * 60).millisecondsSince1970
            try await alice.storage.pool.write { db in
                try db.execute(sql: "UPDATE message SET timestamp = ? WHERE id = ?", arguments: [twoHoursAgo, oldID])
            }

            try await Stack.shared.tap(.up)
            try await eventually("Alice's text to go by itself", timeout: .seconds(60)) {
                try alice.messages(in: bobKey).first { $0.content == text }?.delivery == .delivered
            }
            try await eventually("Bob to receive it") { try bob.messages(in: alice.pubkey).contains { $0.content == text } }
            // Long enough for a second copy, or the others, to have come.
            try await Task.sleep(for: .seconds(5))
            #expect(try bob.messages(in: alice.pubkey).filter { $0.content == text }.count == 1)
            #expect(try !bob.messages(in: alice.pubkey).contains { $0.content == old })
            #expect(try alice.storage.message(id: paymentID)?.delivery == .failed)
            #expect(try alice.storage.message(id: oldID)?.delivery == .failed)
            #expect(try await bob.settledBalance() == bobBalance)

            // Retry by hand after the reconnect: the old text goes.
            try await alice.engine.resend(messageID: oldID)
            try await eventually("Bob to receive the retried text") {
                try bob.messages(in: alice.pubkey).contains { $0.content == old }
            }
            try await eventually("the retried text to be delivered") {
                try alice.storage.message(id: oldID)?.delivery == .delivered
            }

            await alice.close()
            await bob.close()
        }

        @Test func aConnectionThatStopsAnsweringIsNoticedAndRetrySaysSo() async throws {
            let (alice, bob) = try await contacts()
            let bobKey = try bob.pubkey

            // The keep-alive notices a dead connection by itself.
            try await Stack.shared.tap(.freeze)
            let frozeAt = ContinuousClock.now
            try await eventually("the keep-alive to notice", timeout: .seconds(30)) {
                await alice.engine.connection != .connected
            }
            #expect(ContinuousClock.now - frozeAt <= Engine.keepAliveInterval + Engine.pingTimeout + .seconds(2))
            try await Stack.shared.tap(.thaw)
            try await eventually("Alice to reconnect", timeout: .seconds(60)) { await alice.engine.connection == .connected }

            // Retry on a connection that looks connected but is dead.
            try await Stack.shared.tap(.freeze)
            let text = "into the tunnel \(UUID().uuidString)"
            try await alice.engine.sendText(text, to: bobKey)
            let row = try #require(try alice.messages(in: bobKey).first { $0.content == text })
            let id = try #require(row.id)
            #expect(row.delivery == .pending)
            #expect(await alice.engine.connection == .connected)
            // Unconfirmed past the timeout (Retry is offered) and past the
            // in-flight limit (a reconnect may send it again).
            let past = Date.now.addingTimeInterval(-Message.inFlightLimit - 5).millisecondsSince1970
            try await alice.storage.pool.write { db in
                try db.execute(sql: "UPDATE message SET timestamp = ? WHERE id = ?", arguments: [past, id])
            }
            let retried = ContinuousClock.now
            await #expect(throws: Engine.Failure.connectionDropped) { try await alice.engine.resend(messageID: id) }
            #expect(ContinuousClock.now - retried <= Engine.pingTimeout + .seconds(2))
            #expect(await alice.engine.connection != .connected)

            // Back: the message gets there, by the copy the tap held (a real
            // link that comes back does the same) or by the reconnect.
            try await Stack.shared.tap(.thaw)
            try await eventually("the text to be delivered", timeout: .seconds(60)) {
                try alice.storage.message(id: id)?.delivery == .delivered
            }
            try await eventually("Bob to receive it") { try bob.messages(in: alice.pubkey).contains { $0.content == text } }

            await alice.close()
            await bob.close()
        }

        /// A send can fail here after it left (the connection going mid-publish,
        /// `.unknown`, marks a text failed). The reconnect asks the server about
        /// it, its records name it, and it is not sent again.
        @Test func aFailedTextTheServerGotIsNotSentAgain() async throws {
            let (alice, bob) = try await contacts()
            let bobKey = try bob.pubkey
            let text = "left before the line went \(UUID().uuidString)"
            try await alice.engine.sendText(text, to: bobKey)
            try await eventually("Bob to receive it") { try bob.messages(in: alice.pubkey).contains { $0.content == text } }
            let id = try #require(try alice.messages(in: bobKey).first { $0.content == text }?.id)
            try await eventually("the server to confirm it") { try alice.storage.message(id: id)?.delivery == .delivered }
            // As `deliver` marks a send whose publish was cut short.
            try await alice.storage.pool.write { db in
                try db.execute(sql: "UPDATE message SET status = 'FAILED' WHERE id = ?", arguments: [id])
            }
            #expect(try alice.storage.message(id: id)?.isAutoResendable() == true)

            try await Stack.shared.tap(.down)
            try await eventually("Alice to see the connection go") { await alice.engine.connection != .connected }
            try await Stack.shared.tap(.up)
            try await eventually("Alice to reconnect", timeout: .seconds(60)) { await alice.engine.connection == .connected }
            // Only the server's record of it brings it back to delivered.
            try await eventually("its record to land", timeout: .seconds(20)) {
                try alice.storage.message(id: id)?.delivery == .delivered
            }
            // Past the records wait: anything the reconnect would send has gone.
            try await Task.sleep(for: Engine.recordsWait)
            #expect(try bob.messages(in: alice.pubkey).filter { $0.content == text }.count == 1)
            #expect(try alice.storage.message(id: id)?.autoResentAt == nil)

            await alice.close()
            await bob.close()
        }

        /// Sent again by a reconnect and failed again, a message is never sent
        /// by itself a second time, even after a relaunch within the hour.
        @Test func aRelaunchNeverSendsItAgain() async throws {
            let (alice, bob) = try await contacts()
            let bobKey = try bob.pubkey
            try await Stack.shared.tap(.down)
            try await eventually("Alice to see the connection go") { await alice.engine.connection != .connected }
            let text = "sent once by the reconnect \(UUID().uuidString)"
            try await alice.engine.sendText(text, to: bobKey)
            let id = try #require(try alice.messages(in: bobKey).first { $0.content == text }?.id)
            try await Stack.shared.tap(.up)
            try await eventually("the reconnect to send it", timeout: .seconds(60)) {
                try alice.storage.message(id: id)?.delivery == .delivered
            }
            #expect(try alice.storage.message(id: id)?.autoResentAt != nil)
            // As if that send had failed and never left: no tag for the
            // server to know it by, so only the stored mark holds it back.
            try await alice.storage.pool.write { db in
                try db.execute(sql: "UPDATE message SET status = 'FAILED', tag = NULL WHERE id = ?", arguments: [id])
            }

            await alice.engine.close()
            let relaunched = try await alice.relaunched()
            await relaunched.engine.start()
            try await Task.sleep(for: Engine.recordsWait + .seconds(3))
            #expect(try relaunched.storage.message(id: id)?.delivery == .failed)
            #expect(try bob.messages(in: relaunched.pubkey).filter { $0.content == text }.count == 1)

            await relaunched.close()
            await bob.close()
        }
    }
}
