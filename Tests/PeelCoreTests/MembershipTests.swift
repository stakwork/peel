import Foundation
import Testing
@testable import PeelCore

private let tribeKey = key2G

/// One tribe message and what it should do to the tribe's record.
struct MembershipCase: Sendable, CustomTestStringConvertible {
    let testDescription: String
    var tribe = Tribe(pubkey: tribeKey)
    let type: Int
    var fromMe = false
    /// The role the tribes server stamped on it: 0 when the owner sent it.
    var role: Int?
    var replaying = false
    /// Nil when nothing changes.
    let expected: Tribe?

    func message() -> Message {
        .fixture(uuid: uuid(1), type: type, chat: tribeKey, fromMe: fromMe, sender: sender(alias: "x", role: role))
    }
}

private func tribe(
    isOwner: Bool = false, left: Bool = false, status: Tribe.Status = .active
) -> Tribe {
    Tribe(pubkey: tribeKey, isOwner: isOwner, left: left, status: status)
}

struct MembershipTests {
    @Test(arguments: [
        // Our own messages say whether we are in, and a role 0 one that we own it.
        MembershipCase(testDescription: "our join rejoins", tribe: tribe(left: true, status: .removed),
                       type: MessageType.groupJoin, fromMe: true, expected: tribe()),
        MembershipCase(testDescription: "our join with role 0 makes us owner", tribe: tribe(left: true),
                       type: MessageType.groupJoin, fromMe: true, role: 0, expected: tribe(isOwner: true)),
        MembershipCase(testDescription: "our text with role 0 makes us owner",
                       type: MessageType.text, fromMe: true, role: 0, expected: tribe(isOwner: true)),
        MembershipCase(testDescription: "our text with another role changes nothing",
                       type: MessageType.text, fromMe: true, role: 1, expected: nil),
        MembershipCase(testDescription: "our request makes us pending", tribe: tribe(left: true),
                       type: MessageType.memberRequest, fromMe: true, expected: tribe(status: .pending)),
        MembershipCase(testDescription: "our leave leaves",
                       type: MessageType.groupLeave, fromMe: true, expected: tribe(left: true)),
        MembershipCase(testDescription: "our leave when left changes nothing", tribe: tribe(left: true),
                       type: MessageType.groupLeave, fromMe: true, expected: nil),

        // The owner's decisions count only with the owner's role.
        MembershipCase(testDescription: "a kick without a role is ignored",
                       type: MessageType.groupKick, expected: nil),
        MembershipCase(testDescription: "a kick from a member is ignored",
                       type: MessageType.groupKick, role: 1, expected: nil),
        MembershipCase(testDescription: "the owner's kick removes us",
                       type: MessageType.groupKick, role: 0, expected: tribe(status: .removed)),
        MembershipCase(testDescription: "a rejection without a role is ignored", tribe: tribe(status: .pending),
                       type: MessageType.memberReject, expected: nil),
        MembershipCase(testDescription: "the owner's rejection declines us", tribe: tribe(status: .pending),
                       type: MessageType.memberReject, role: 0, expected: tribe(status: .rejected)),
        MembershipCase(testDescription: "a deletion without a role is ignored",
                       type: MessageType.tribeDelete, expected: nil),
        MembershipCase(testDescription: "a deletion from a member is ignored",
                       type: MessageType.tribeDelete, role: 2, expected: nil),
        MembershipCase(testDescription: "the owner's deletion keeps the tribe to show it",
                       type: MessageType.tribeDelete, role: 0, expected: tribe(status: .deleted)),
        MembershipCase(testDescription: "a deletion heard on a restore leaves the tribe",
                       type: MessageType.tribeDelete, role: 0, replaying: true,
                       expected: tribe(left: true, status: .deleted)),
        MembershipCase(testDescription: "a deletion reaches the owner too", tribe: tribe(isOwner: true),
                       type: MessageType.tribeDelete, role: 0, expected: tribe(isOwner: true, status: .deleted)),

        // The owner is told of every member's kick and rejection: not about us.
        MembershipCase(testDescription: "the owner is not removed by a kick", tribe: tribe(isOwner: true),
                       type: MessageType.groupKick, role: 0, expected: nil),
        MembershipCase(testDescription: "the owner is not declined by a rejection", tribe: tribe(isOwner: true),
                       type: MessageType.memberReject, role: 0, expected: nil),

        // Approvals and joins reach a waiting, declined or removed member only once let in.
        MembershipCase(testDescription: "an approval lets a pending member in", tribe: tribe(status: .pending),
                       type: MessageType.memberApprove, role: 0, expected: tribe()),
        MembershipCase(testDescription: "a join lets a declined member in", tribe: tribe(status: .rejected),
                       type: MessageType.groupJoin, expected: tribe()),
        // Not asserted: a removed member is made active again by any join
        // or approval, with no owner's role needed, unlike a kick. On a
        // restore or out-of-order history another member's join after our
        // kick would reopen the tribe. Left for a separate fix.
        MembershipCase(testDescription: "a join does not bring back a deleted tribe", tribe: tribe(status: .deleted),
                       type: MessageType.groupJoin, expected: nil),
        MembershipCase(testDescription: "a join changes nothing for an active member",
                       type: MessageType.groupJoin, expected: nil),
        MembershipCase(testDescription: "someone else's role 0 text does not make us owner",
                       type: MessageType.text, role: 0, expected: nil),
    ])
    func membershipAfterAMessage(_ test: MembershipCase) {
        #expect(Engine.membership(after: test.message(), in: test.tribe, replaying: test.replaying) == test.expected)
    }
}

private let ownHost = "tribes.example.com"
private let person = keyG
/// The core holds the tribe as a contact with no contact key, and the person with one.
private let coreState = coreContact(tribeKey, contactKey: nil).merging(coreContact(person, contactKey: key3G)) { $1 }

/// `Engine.discoveredTribe`: which chats a forwarded join names as a tribe,
/// and that its host is kept only when it is the account's own tribes server.
struct DiscoveredTribeTests {
    let profile = TempProfile()

    private func engine(tribeHost: String?) throws -> Engine {
        let storage = try profile.storage()
        if let tribeHost { try storage.set(tribeHost, for: .tribeHost) }
        return try testEngine(storage)
    }

    private func join(chat: String = tribeKey, host: String?, fromMe: Bool = false) -> Message {
        .fixture(uuid: uuid(1), type: MessageType.groupJoin, chat: chat, fromMe: fromMe, sender: sender(alias: "x", host: host))
    }

    private func discovered(
        _ message: Message, trustSender: Bool = true, by engine: Engine, state: [String: Data] = coreState
    ) async throws -> (Tribe?, Set<String>) {
        var notTribes: Set<String> = []
        let found = try await engine.discoveredTribe(message, trustSender: trustSender, state: state, notTribes: &notTribes)
        return (found, notTribes)
    }

    @Test func ourOwnTribesServerIsKeptAsTheHost() async throws {
        let (found, notTribes) = try await discovered(join(host: ownHost), by: engine(tribeHost: ownHost))
        #expect(found == Tribe(pubkey: tribeKey, host: ownHost))
        #expect(notTribes.isEmpty)
    }

    /// Only an exact match is trusted; with no tribes server, nothing is.
    @Test(arguments: [
        ("evil.example.com", ownHost), ("tribes.example.com:443", ownHost), ("TRIBES.example.com", ownHost),
        (ownHost, nil),
    ] as [(String, String?)])
    func anyOtherHostIsDropped(host: String, tribeHost: String?) async throws {
        let (found, _) = try await discovered(join(host: host), by: engine(tribeHost: tribeHost))
        #expect(found == Tribe(pubkey: tribeKey, host: nil))
    }

    @Test func anUntrustedSenderNamesNoTribeButOurOwnJoinDoes() async throws {
        let engine = try engine(tribeHost: ownHost)
        let (untrusted, _) = try await discovered(join(host: ownHost), trustSender: false, by: engine)
        #expect(untrusted == nil)
        let (ours, _) = try await discovered(join(host: ownHost, fromMe: true), trustSender: false, by: engine)
        #expect(ours == Tribe(pubkey: tribeKey, host: ownHost))
    }

    @Test(arguments: [nil, ""])
    func aJoinWithoutAHostNamesNoTribe(host: String?) async throws {
        let (found, _) = try await discovered(join(host: host), by: engine(tribeHost: ownHost))
        #expect(found == nil)
    }

    @Test func aChatTheCoreDoesNotKnowIsNoTribe() async throws {
        let (found, notTribes) = try await discovered(join(host: ownHost), by: engine(tribeHost: ownHost), state: [:])
        #expect(found == nil)
        #expect(notTribes.isEmpty)
    }

    /// People always have a contact key; the chat is remembered as not a tribe.
    @Test func aPersonIsNoTribe() async throws {
        let (found, notTribes) = try await discovered(join(chat: person, host: ownHost), by: engine(tribeHost: ownHost))
        #expect(found == nil)
        #expect(notTribes == [person])
    }
}
