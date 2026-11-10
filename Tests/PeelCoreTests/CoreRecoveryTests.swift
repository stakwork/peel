import Foundation
import Sphinxrs
import Synchronization
import Testing
@testable import PeelCore
@testable import PeelTestSupport

/// The index each history request asks from, in order.
private final class Asked: Sendable {
    let since = Mutex<[UInt64]>([])
}

private func recordingTransport() -> (Transport, Asked) {
    struct Request: Decodable { let since: UInt64 }
    let asked = Asked()
    let transport = Transport(publishing: { topic, payload in
        guard topic.hasSuffix("/batch"), let request = try? JSONDecoder().decode(Request.self, from: payload) else { return }
        asked.since.withLock { $0.append(request.since) }
    })
    return (transport, asked)
}

private let theirSeed = String(repeating: "22", count: 32)

private func theirKey() throws -> String {
    try Sphinxrs.pubkeyFromSeed(seed: theirSeed, idx: 1, time: "1000", network: "bitcoin")
}

/// A real text message from them, its onion as the server keeps it.
private func textFromThem(_ content: String) throws -> Data {
    let ours = try Sphinxrs.mnemonicToSeed(mnemonic: abandon.joined(separator: " "))
    let to = try Sphinxrs.pubkeyFromSeed(seed: ours, idx: 1, time: "1000", network: "bitcoin")
    return try Sphinxrs.createOnionMsg(
        seed: theirSeed, idx: 1, time: "1000", network: "bitcoin", hops: #"[{"pubkey":"\#(to)"}]"#,
        json: #"{"type":\#(MessageType.text),"sender":{"pubkey":""},"message":{"content":"\#(content)"}}"#
    )
}

/// A page of history holding `onion` at server index 0.
private func page(_ onion: Data) -> Inbound {
    Inbound(topic: "root/pk/0/res/dev/batch/_/20", payload: batchPage([batchOnion(index: 0, data: onion)]))
}

/// What the engine does when the core fails: reload its state from storage as a launch reads it,
/// retry the page that failed once, count failures and escalate, and keep a catch-up going past
/// the app leaving the front.
struct CoreRecoveryTests {
    let profile = TempProfile()

    private func setUp() throws -> Storage {
        try registeredStorage(profile, contact: try theirKey())
    }

    /// The events an engine emitted, read after it closed.
    private func events(of engine: Engine) async -> [Engine.Event] {
        await engine.close()
        var all: [Engine.Event] = []
        for await event in engine.events { all.append(event) }
        return all
    }

    // MARK: recoverCore

    @Test func recoveringReadsStateHistoryAndContactsBackFromStorage() async throws {
        let storage = try setUp()
        let them = try theirKey()
        let (transport, _) = recordingTransport()
        try await withTestEngine(storage, on: transport) { engine in
            await engine.corruptStateForTesting()
            let corrupted = await engine.state
            #expect(corrupted.isEmpty)
            await engine.recoverCore(reason: .repeated)
            let stored = try storage.loadCoreState()
            let held = await engine.state
            #expect(held == stored)
            let from = await engine.history.from
            let storedFrom = try storage.value(for: .historyFrom)
            #expect(String(from) == storedFrom)
            let contacts = await engine.contactsByChildIndexForTesting
            #expect(contacts == [1: them])
            let alias = await engine.alias
            let storedAlias = try storage.value(for: .alias) ?? ""
            #expect(alias == storedAlias)
        }
    }

    @Test func recoveringNeverMovesTheClockBack() async throws {
        let storage = try setUp()
        let (transport, _) = recordingTransport()
        try await withTestEngine(storage, on: transport) { engine in
            let ahead: UInt64 = 9_000_000_000_000_000
            await engine.setClockForTesting(last: ahead)
            await engine.recoverCore(reason: .repeated)
            let last = await engine.clockLastForTesting
            #expect(last >= ahead)
        }
    }

    // MARK: A page the core refuses

    @Test func aPageThatThrowsOnceIsRetriedOnceAfterRecoveryAndThenSucceeds() async throws {
        let storage = try setUp()
        let (transport, _) = recordingTransport()
        let onion = try textFromThem("retried")
        var recovered = 0
        try await withTestEngine(storage, on: transport) { engine in
            try await engine.syncMessages()
            await engine.setFailingHandlesForTesting(1)
            await engine.receive(page(onion))
            let failures = await engine.consecutiveCoreFailures
            #expect(failures == 0)
            for case .coreRecovered(let reason, let stage) in await events(of: engine) {
                #expect(reason == .pageFailed)
                #expect(stage == .reloadState)
                recovered += 1
            }
        }
        #expect(recovered == 1)
        let kept = try rows(profile, "SELECT content FROM message").map { $0["content"] as String? }
        #expect(kept == ["retried"])
    }

    @Test func aPageThatKeepsFailingIsCountedAndAtTheReloadThresholdTheConnectionIsDropped() async throws {
        let storage = try setUp()
        let (transport, _) = recordingTransport()
        let onion = try textFromThem("never")
        try await withTestEngine(storage, on: transport) { engine in
            try await engine.syncMessages()
            await engine.setFailingHandlesForTesting(100)
            await engine.setConsecutiveCoreFailuresForTesting(Engine.coreFailureReloadThreshold - 1)
            await engine.receive(page(onion))
            let failures = await engine.consecutiveCoreFailures
            #expect(failures == Engine.coreFailureReloadThreshold)
            #expect(await engine.transport == nil)
            #expect(await engine.syncFailing)
        }
    }

    @Test func theCounterResetsWhenAPageIsHandled() async throws {
        let storage = try setUp()
        let (transport, _) = recordingTransport()
        let onion = try textFromThem("fine")
        try await withTestEngine(storage, on: transport) { engine in
            try await engine.syncMessages()
            await engine.setConsecutiveCoreFailuresForTesting(Engine.coreFailureReloadThreshold)
            #expect(await engine.syncFailing)
            await engine.receive(page(onion))
            let failures = await engine.consecutiveCoreFailures
            #expect(failures == 0)
            #expect(await !engine.syncFailing)
        }
    }

    // MARK: Retrying and the background

    @Test func theRetryAndBackgroundConstantsAreWhatTheyAreMeantToBe() {
        #expect(Engine.catchUpRetryDelays == [.seconds(2), .seconds(5), .seconds(15), .seconds(30)])
        #expect(Engine.catchUpRetryDelay(afterRetries: 0) == .seconds(2))
        #expect(Engine.catchUpRetryDelay(afterRetries: 2) == .seconds(15))
        #expect(Engine.catchUpRetryDelay(afterRetries: 40) == .seconds(30))
        #expect(Engine.backgroundCatchUpBound == .seconds(25))
        #expect(Engine.coreFailureReloadThreshold == 3)
    }

    /// A catch-up in flight as the app leaves is kept, abandoned only at the bound, and the next
    /// foreground asks again from the cursor, which did not move.
    @Test func aCatchUpInFlightIsKeptInTheBackgroundUntilTheBound() async throws {
        let storage = try setUp()
        let (transport, asked) = recordingTransport()
        try await withTestEngine(storage, on: transport) { engine in
            await engine.cameOnlineForTesting()
            try await engine.syncMessages()
            let kept = await engine.appLeftForeground(keepingCatchUp: true)
            #expect(kept)
            #expect(await engine.isSyncingHistory)
            #expect(await !engine.unverified)
            await engine.finishBackgroundCatchUp(bound: .milliseconds(200))
            #expect(await !engine.isSyncingHistory)
            #expect(await engine.unverified)
            await engine.catchUpIfIdle(reason: .foreground)
            #expect(await engine.isSyncingHistory)
        }
        #expect(asked.since.withLock { $0 } == [0, 0])
    }

    @Test func expiryAbandonsAKeptCatchUpAtOnce() async throws {
        let storage = try setUp()
        let (transport, _) = recordingTransport()
        try await withTestEngine(storage, on: transport) { engine in
            try await engine.syncMessages()
            _ = await engine.appLeftForeground(keepingCatchUp: true)
            await engine.expireBackgroundCatchUp()
            #expect(await !engine.isSyncingHistory)
        }
    }

    @Test func withoutABackgroundTaskTheCatchUpIsAbandonedAsBefore() async throws {
        let storage = try setUp()
        let (transport, _) = recordingTransport()
        try await withTestEngine(storage, on: transport) { engine in
            try await engine.syncMessages()
            let kept = await engine.appLeftForeground()
            #expect(!kept)
            #expect(await !engine.isSyncingHistory)
        }
    }
}
