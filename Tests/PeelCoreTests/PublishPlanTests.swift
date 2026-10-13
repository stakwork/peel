import Foundation
import Sphinxrs
import Testing
@testable import PeelCore

private func topics(_ publishes: [Engine.Publish]) -> [String] {
    publishes.map(\.topic)
}

struct PublishPlanTests {
    /// Answering a key exchange: settle the payment and register the new key,
    /// then pay the confirmation, then send it and our own contact record.
    @Test func whatFollowsTheRegisterOfANewKeyWaits() {
        let plan = Engine.publishPlan(coreResult(
            settle: "settle", register: "register", newChildIdx: 7,
            asyncpay: "asyncpay", topics: ["send", "sendself"]
        ))
        #expect(topics(plan.now) == ["settle", "register"])
        #expect(topics(plan.later) == ["asyncpay"])
        #expect(topics(plan.afterPay) == ["send", "sendself"])
    }

    /// A tribe join: a new key and no async pay, so nothing waits on one.
    @Test func withoutAnAsyncPayNothingWaitsForIt() {
        let plan = Engine.publishPlan(coreResult(register: "register", newChildIdx: 7, topics: ["join"]))
        #expect(topics(plan.now) == ["register"])
        #expect(topics(plan.later) == ["join"])
        #expect(plan.afterPay.isEmpty)
    }

    /// Registering the account key on connect needs no wait.
    @Test func registerWithoutNewChildPublishesAtOnce() {
        let plan = Engine.publishPlan(coreResult(register: "register", topics: ["balance"]))
        #expect(topics(plan.now) == ["register", "balance"])
        #expect(plan.later.isEmpty && plan.afterPay.isEmpty)
    }

    /// A payment to a person: the async pay at once, the ping and our own
    /// copy once the server has taken it (payments review F9).
    @Test func thePingWaitsForTheAsyncPay() {
        let plan = Engine.publishPlan(coreResult(asyncpay: "asyncpay", topics: ["ping", "sendself"]))
        #expect(topics(plan.now) == ["asyncpay"])
        #expect(plan.later.isEmpty)
        #expect(topics(plan.afterPay) == ["ping", "sendself"])
    }

    @Test func noAsyncPayPublishesAtOnce() {
        let plan = Engine.publishPlan(coreResult(topics: ["send"]))
        #expect(topics(plan.now) == ["send"])
        #expect(plan.later.isEmpty && plan.afterPay.isEmpty)
    }

    /// The server's answer to an async pay counts only for a send waiting
    /// on that tag; one nobody waits for is not kept.
    @Test func theServersAnswerMarksOnlyAWaitedAsyncPay() async throws {
        let profile = TempProfile()
        let engine = try testEngine(profile.storage())
        await engine.awaitAsyncPay("aa")
        _ = try await engine.commit(coreResult(asyncpayTag: "bb"), time: "1", expectedSender: nil)
        #expect(await engine.money.asyncPays == ["aa": false])
        _ = try await engine.commit(coreResult(asyncpayTag: "aa"), time: "2", expectedSender: nil)
        #expect(await engine.money.asyncPays == ["aa": true])
    }
}

private extension Engine {
    func awaitAsyncPay(_ tag: String) { money.asyncPays[tag] = false }
}
