import Foundation
import Sphinxrs
import Testing
@testable import PeelCore

/// A core result with only the publish fields set.
private func result(
    settle: String? = nil, register: String? = nil, newChildIdx: UInt64? = nil,
    asyncpay: String? = nil, topics: [String] = []
) -> RunReturn {
    RunReturn(
        msgs: [], msgsTotal: nil, msgsCounts: nil, subscriptionTopics: [],
        settleTopic: settle, settlePayload: settle.map { _ in Data([1]) },
        asyncpayTopic: asyncpay, asyncpayPayload: asyncpay.map { _ in Data([2]) },
        registerTopic: register, registerPayload: register.map { _ in Data() },
        topics: topics, payloads: topics.map { _ in Data([3]) },
        stateMp: nil, stateToDelete: [], newBalance: nil, myContactInfo: nil, sentStatus: nil,
        settledStatus: nil, registerResponse: nil, asyncpayTag: nil, error: nil, newTribe: nil,
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
    /// then pay the confirmation, send it, and send our own contact record.
    @Test func whatFollowsTheRegisterOfANewKeyWaits() {
        let plan = Engine.publishPlan(result(
            settle: "settle", register: "register", newChildIdx: 7,
            asyncpay: "asyncpay", topics: ["send", "sendself"]
        ))
        #expect(topics(plan.now) == ["settle", "register"])
        #expect(topics(plan.later) == ["asyncpay", "send", "sendself"])
    }

    /// Registering the account key on connect needs no wait.
    @Test func registerWithoutNewChildPublishesAtOnce() {
        let plan = Engine.publishPlan(result(register: "register", topics: ["balance"]))
        #expect(topics(plan.now) == ["register", "balance"])
        #expect(plan.later.isEmpty)
    }

    @Test func noRegisterPublishesAtOnce() {
        let plan = Engine.publishPlan(result(asyncpay: "asyncpay", topics: ["send"]))
        #expect(topics(plan.now) == ["asyncpay", "send"])
        #expect(plan.later.isEmpty)
    }
}
