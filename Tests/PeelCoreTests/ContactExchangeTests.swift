import Foundation
import Sphinxrs
import Synchronization
import Testing
@testable import PeelCore
@testable import PeelTestSupport

struct ContactExchangeTests {
    /// A malicious exchange may claim any amount. Nothing the old core
    /// proposes (including its paid reply) may leave before the real amount
    /// is checked, and no contact, message or persisted clock is committed.
    @Test(arguments: [nil, [:], ["5": UInt64(0)], ["5": 2_999], ["6": 5_000]] as [[String: UInt64]?])
    func anUnpaidOrUnderpaidExchangeDoesNothing(arrived: [String: UInt64]?) async throws {
        let profile = TempProfile()
        let storage = try registeredStorage(profile)
        let writes = Mutex<[String]>([])
        let transport = Transport(publishing: { topic, _ in writes.withLock { $0.append(topic) } })
        try await withTestEngine(storage, on: transport) { engine in
            let before = try storage.loadCoreState()
            let clock = try storage.value(for: .clock)
            try await engine.exchange(arrived: arrived) {
                coreResult(
                    settle: "settle", register: "register", newChildIdx: 7,
                    asyncpay: "paid-reply", topics: ["ping", "contact-record"],
                    msgs: [.fixture(type: UInt8(MessageType.contactKey), uuid: "keyx", index: "5",
                                    sender: sender(keyG), msat: UInt64.max)],
                    state: before.merging(coreContact(keyG, contactKey: key3G)) { $1 }
                )
            }
            #expect(writes.withLock { $0.isEmpty })
            #expect(try storage.loadCoreState() == before)
            #expect(await engine.state == before)
            #expect(try storage.value(for: .clock) == clock)
            #expect(try storage.message(uuid: "keyx", in: keyG) == nil)
        }
    }

    /// The same boundary admits a genuine funded exchange, at the exact
    /// minimum as well as the normal 5 sats; it keeps the capped amount.
    @Test(arguments: [UInt64(3_000), UInt64(5_000)])
    func aFundedExchangeIsKept(received: UInt64) async throws {
        let profile = TempProfile()
        let storage = try registeredStorage(profile)
        let engine = try testEngine(storage)
        try await engine.exchange(arrived: ["5": received]) {
            coreResult(
                msgs: [.fixture(type: UInt8(MessageType.contactKey), uuid: "keyx", index: "5",
                                sender: sender(keyG), msat: UInt64.max)],
                state: registeredState.merging(coreContact(keyG, contactKey: key3G)) { $1 }
            )
        }
        #expect(try storage.message(uuid: "keyx", in: keyG)?.msat == Int64(received))
        #expect(await engine.isContact(keyG))
    }
}

private extension Engine {
    func exchange(arrived: [String: UInt64]?, _ result: () -> RunReturn) async throws {
        try await run(arrived: arrived, live: true) { _, _ in result() }
    }
}
