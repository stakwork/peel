import Foundation
import Testing
@testable import PeelCore
@testable import PeelTestSupport

/// Refusals surface as `Engine.Failure` cases, so the app, the CLI or an
/// agent can match them, and keep their words for `PeelError.readable`.
struct EngineFailureTests {
    let profile = TempProfile()

    private func engine(tribes: [Tribe] = []) throws -> Engine {
        let storage = try profile.storage()
        try storage.save(tribes)
        return try testEngine(storage)
    }

    @Test func tribeRefusalsAreTyped() async throws {
        let engine = try engine(tribes: [Tribe(pubkey: key2G, isOwner: true)])
        await #expect(throws: Engine.Failure.ownerCannotLeave) { try await engine.leaveTribe(key2G) }
        await #expect(throws: Engine.Failure.notAMemberKey) { try await engine.kickMember("ann", from: key2G) }
    }

    @Test func aTribeThatIsGoneIsRemovedWithoutSending() async throws {
        // A deleted tribe of our own: removed from Peel, offline, nothing sent.
        let engine = try engine(tribes: [Tribe(pubkey: key2G, isOwner: true, status: .deleted)])
        try await engine.leaveTribe(key2G)
        #expect(await engine.tribes[key2G]?.left == true)
        await #expect(throws: Engine.Failure.notInTribe) { try await engine.leaveTribe(key2G) }
    }

    @Test func settingRefusalsAreTyped() async throws {
        let engine = try engine()
        await #expect(throws: Engine.Failure.emptyName) { try await engine.setAlias("  ") }
        await #expect(throws: Engine.Failure.photoNotHTTPS) { try await engine.setPhotoURL("http://x/p.png") }
        #expect(throws: Engine.Failure.unreadableCallServer("a b")) { try CallLink.new(server: "a b", audioOnly: true) }
    }

    @Test func theWordsAreKeptWithoutCLIFlags() {
        #expect(PeelError.readable(Engine.Failure.alreadyAnswered) == "that request has already been answered")
        #expect(PeelError.readable(Engine.Failure.tribePriceRose(boost: false))
            == "this tribe now charges more per message; send it as a new message")
        #expect(Engine.Failure.noMemesServer.description == "this account has no memes server for attachments")
        #expect(Engine.Failure.noCallServer.description == "this account has no call server")
    }
}
