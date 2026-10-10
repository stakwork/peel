import Foundation
import Sphinxrs
import Testing
@testable import PeelCore

/// A core result with only the publish fields set.
private func result(
    settle: String? = nil, register: String? = nil, newChildIdx: UInt64? = nil,
    asyncpay: String? = nil, topics: [String] = [], asyncpayTag: String? = nil
) -> RunReturn {
    RunReturn(
        msgs: [], msgsTotal: nil, msgsCounts: nil, subscriptionTopics: [],
        settleTopic: settle, settlePayload: settle.map { _ in Data([1]) },
        asyncpayTopic: asyncpay, asyncpayPayload: asyncpay.map { _ in Data([2]) },
        registerTopic: register, registerPayload: register.map { _ in Data() },
        topics: topics, payloads: topics.map { _ in Data([3]) },
        stateMp: nil, stateToDelete: [], newBalance: nil, myContactInfo: nil, sentStatus: nil,
        settledStatus: nil, registerResponse: nil, asyncpayTag: asyncpayTag, error: nil, newTribe: nil,
        tribeMembers: nil, newInvite: nil, inviterContactInfo: nil, inviterAlias: nil, initialTribe: nil,
        lspHost: nil, invoice: nil, route: nil, node: nil, lastRead: nil, muteLevels: nil, payments: nil,
        paymentsTotal: nil, tags: nil, deletedMsgs: nil, newChildIdx: newChildIdx, ping: nil
    )
}

private func topics(_ publishes: [Engine.Publish]) -> [String] {
    publishes.map(\.topic)
}

struct PublishPlanTests {
    /// Answering a key exchange: settle the payment and register the new key,
    /// then pay the confirmation, then send it and our own contact record.
    @Test func whatFollowsTheRegisterOfANewKeyWaits() {
        let plan = Engine.publishPlan(result(
            settle: "settle", register: "register", newChildIdx: 7,
            asyncpay: "asyncpay", topics: ["send", "sendself"]
        ))
        #expect(topics(plan.now) == ["settle", "register"])
        #expect(topics(plan.later) == ["asyncpay"])
        #expect(topics(plan.afterPay) == ["send", "sendself"])
    }

    /// A tribe join: a new key and no async pay, so nothing waits on one.
    @Test func withoutAnAsyncPayNothingWaitsForIt() {
        let plan = Engine.publishPlan(result(register: "register", newChildIdx: 7, topics: ["join"]))
        #expect(topics(plan.now) == ["register"])
        #expect(topics(plan.later) == ["join"])
        #expect(plan.afterPay.isEmpty)
    }

    /// Registering the account key on connect needs no wait.
    @Test func registerWithoutNewChildPublishesAtOnce() {
        let plan = Engine.publishPlan(result(register: "register", topics: ["balance"]))
        #expect(topics(plan.now) == ["register", "balance"])
        #expect(plan.later.isEmpty && plan.afterPay.isEmpty)
    }

    /// A payment to a person: the async pay at once, the ping and our own
    /// copy once the server has taken it (payments review F9).
    @Test func thePingWaitsForTheAsyncPay() {
        let plan = Engine.publishPlan(result(asyncpay: "asyncpay", topics: ["ping", "sendself"]))
        #expect(topics(plan.now) == ["asyncpay"])
        #expect(plan.later.isEmpty)
        #expect(topics(plan.afterPay) == ["ping", "sendself"])
    }

    @Test func noAsyncPayPublishesAtOnce() {
        let plan = Engine.publishPlan(result(topics: ["send"]))
        #expect(topics(plan.now) == ["send"])
        #expect(plan.later.isEmpty && plan.afterPay.isEmpty)
    }

    /// The server's answer to an async pay counts only for a send waiting
    /// on that tag; one nobody waits for is not kept.
    @Test func theServersAnswerMarksOnlyAWaitedAsyncPay() async throws {
        let profile = TempProfile()
        let engine = try testEngine(profile.storage())
        await engine.awaitAsyncPay("aa")
        _ = try await engine.commit(result(asyncpayTag: "bb"), time: "1", expectedSender: nil)
        #expect(await engine.money.asyncPays == ["aa": false])
        _ = try await engine.commit(result(asyncpayTag: "aa"), time: "2", expectedSender: nil)
        #expect(await engine.money.asyncPays == ["aa": true])
    }
}

private extension Engine {
    func awaitAsyncPay(_ tag: String) { money.asyncPays[tag] = false }
}
