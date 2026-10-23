import Foundation
@testable import PeelAgent
@testable import PeelTestSupport
import Testing
@testable import PeelCore

extension Journeys {
    /// Peel's bridge (docs/agent-on-strut.md, PR 4) through the real core,
    /// broker and the staged runner, with a stub in strut's place.
    @Suite struct Bridge {
        /// Alice's agent, as the app sets it up (`BundledBridge.setUp`), with
        /// real accounting: its account derived from hers, registered with
        /// her invite (so it has sats to answer), and added as her contact
        /// from the contact info runner gives. Her one key exchange is
        /// answered. Her message to it becomes a strut run of the
        /// orchestrator, with strut's key. Set up again on the same store, it
        /// is the same agent: no second invite, contact or key exchange, with a
        /// fresh store too. Set up after a restore, its unredeemed invite is refunded, and started
        /// on its own it never pays to pair.
        @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: BundledBridge.staged.path)))
        @MainActor
        func theAgentBecomesAContactAndItsMessagesReachStrut() async throws {
            let alice = try await Person.create("alice")
            try await Bank.shared.give(100, to: alice)
            let strut = try await HTTPStub { _ in #"{"runId":"stub"}"# }
            let key = String(repeating: "cd", count: 32)
            let server = try #require(MemoryServer(base: URL(string: "http://127.0.0.1:\(strut.port)")!, key: key))
            let data = Person.directory("alice-bridge")
            let bridge = try #require(BundledBridge(executable: BundledBridge.staged, data: data))
            defer {
                bridge.stop(quietly: true)
                try? BundledBridge.erase(data: data)
                strut.stop()
            }

            let account = try await bridge.setUp(on: alice.engine, beside: server, alias: "Agent", pair: true)
            #expect(account == (try await alice.engine.agentAccount()))
            // Ready when set-up ends: the agent answered the one key exchange.
            #expect(try alice.isReadyContact(pubkey: account.pubkey))
            let invites = try alice.invites()
            #expect(invites.count == 1 && invites.first?.amountMsat == Int64(BundledBridge.inviteMsat))
            // Redeemed: its cancel got no sats back, and it is set aside.
            #expect(invites.first?.status == .cancelled)

            let words = "what did I miss \(UUID().uuidString.prefix(6))"
            try await alice.engine.sendText(words, to: account.pubkey)
            let run = try await eventually("Alice's message to reach strut", timeout: .seconds(30)) {
                strut.requests.first { $0.hasPrefix("POST /workflows/orchestrator/run") && $0.contains(words) }
            }
            #expect(run.contains("Bearer \(key)"))

            bridge.stop()
            #expect(try await bridge.setUp(on: alice.engine, beside: server, alias: "Agent", pair: false) == account)
            #expect(try alice.invites().count == 1)
            #expect(try await alice.engine.contacts().filter { $0.pubkey == account.pubkey }.count == 1)

            // Set up before with another store (another Mac, or a profile on
            // the same words): the contact is used again, nothing is paid.
            bridge.stop()
            try BundledBridge.erase(data: data)
            let kept = try #require(try await alice.settledBalance())
            #expect(try await bridge.setUp(on: alice.engine, beside: server, alias: "Agent", pair: false) == account)
            #expect(try alice.invites().count == 1)
            #expect(try await alice.settledBalance() == kept)

            // This Mac's store gone and the contact removed, as after a
            // restore from the words: the agent's account is registered
            // already, so its new invite is not redeemed and comes back.
            bridge.stop()
            try BundledBridge.erase(data: data)
            try await alice.engine.deleteContact(account.pubkey)
            // Started on its own, it never pays to pair.
            await #expect(throws: BundledBridge.NotSetUp.self) {
                try await bridge.setUp(on: alice.engine, beside: server, alias: "Agent", pair: false)
            }
            #expect(try alice.invites().count == 1)
            bridge.stop()
            let before = try #require(try await alice.settledBalance())
            #expect(try await bridge.setUp(on: alice.engine, beside: server, alias: "Agent", pair: true) == account)
            let second = try #require(try alice.invites().first { $0.code != invites.first?.code })
            #expect(second.status == .cancelled && second.usedBy == nil)
            #expect(try alice.isReadyContact(pubkey: account.pubkey))
            // Only the key exchange's 3 sats: the invite's 10 came back.
            #expect(try await alice.balance(settlingAt: before - 3) == before - 3)

            await alice.close()
        }
    }
}

private extension Person {
    func invites() throws -> [InviteRecord] {
        try storage.pool.read { db in try InviteRecord.fetchAll(db, sql: "SELECT * FROM invite") }
    }
}
