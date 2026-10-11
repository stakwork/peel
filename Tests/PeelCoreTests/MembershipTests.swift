import Foundation
import Sphinxrs
import Testing
@testable import PeelCore

private let tribeKey = key2G

/// One tribe message and what it should do to the tribe's record.
struct MembershipCase: Sendable, CustomTestStringConvertible {
    let testDescription: String
    var tribe = Tribe(pubkey: tribeKey)
    let type: Int
    var fromMe = false
    var alias: String? = "x"
    /// The role the tribes server stamped on it: 0 when the owner sent it.
    var role: Int?
    var replaying = false
    /// Nil when nothing changes.
    let expected: Tribe?

    func message() -> Message {
        .fixture(uuid: uuid(1), type: type, chat: tribeKey, fromMe: fromMe, sender: sender(alias: alias, role: role))
    }
}

/// What the tribe calls this account.
private let ourAlias = "me"

private func tribe(
    isOwner: Bool = false, left: Bool = false, status: Tribe.Status = .active
) -> Tribe {
    Tribe(pubkey: tribeKey, isOwner: isOwner, left: left, status: status)
}

struct MembershipTests {
    @Test(arguments: [
        // Our own join says we are in, and a role 0 message that we own it;
        // our leave and request count only when sent here (`isReplay`).
        MembershipCase(testDescription: "our join replayed on a restore rejoins", tribe: tribe(left: true, status: .removed),
                       type: MessageType.groupJoin, fromMe: true, replaying: true, expected: tribe()),
        MembershipCase(testDescription: "a join of ours that arrives live changes nothing",
                       tribe: tribe(left: true, status: .removed), type: MessageType.groupJoin, fromMe: true, expected: nil),
        MembershipCase(testDescription: "our join with role 0 makes us owner", tribe: tribe(left: true),
                       type: MessageType.groupJoin, fromMe: true, role: 0, replaying: true, expected: tribe(isOwner: true)),
        MembershipCase(testDescription: "our text with role 0 makes us owner",
                       type: MessageType.text, fromMe: true, role: 0, expected: tribe(isOwner: true)),
        MembershipCase(testDescription: "our text with another role changes nothing",
                       type: MessageType.text, fromMe: true, role: 1, expected: nil),
        MembershipCase(testDescription: "a request of ours that arrives changes nothing", tribe: tribe(isOwner: true),
                       type: MessageType.memberRequest, fromMe: true, expected: nil),
        MembershipCase(testDescription: "a leave of ours that arrives changes nothing",
                       type: MessageType.groupLeave, fromMe: true, expected: nil),
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
        // Only the owner's approval of us lets us in: it names the approved member by alias.
        MembershipCase(testDescription: "the owner's approval lets a pending member in", tribe: tribe(status: .pending),
                       type: MessageType.memberApprove, alias: ourAlias, role: 0, expected: tribe()),
        MembershipCase(testDescription: "the owner's approval lets a declined member in", tribe: tribe(status: .rejected),
                       type: MessageType.memberApprove, alias: ourAlias, role: 0, expected: tribe()),
        MembershipCase(testDescription: "the owner's approval lets a removed member back", tribe: tribe(status: .removed),
                       type: MessageType.memberApprove, alias: ourAlias, role: 0, expected: tribe()),
        MembershipCase(testDescription: "an approval of our name made unique lets us in", tribe: tribe(status: .pending),
                       type: MessageType.memberApprove, alias: ourAlias + "_2", role: 0, expected: tribe()),
        MembershipCase(testDescription: "an approval of us without a role is ignored", tribe: tribe(status: .removed),
                       type: MessageType.memberApprove, alias: ourAlias, expected: nil),
        MembershipCase(testDescription: "an approval of us from a member is ignored", tribe: tribe(status: .removed),
                       type: MessageType.memberApprove, alias: ourAlias, role: 1, expected: nil),
        MembershipCase(testDescription: "another member's approval leaves a removed member out",
                       tribe: tribe(status: .removed), type: MessageType.memberApprove, role: 0, expected: nil),
        MembershipCase(testDescription: "another member's approval leaves a pending member waiting",
                       tribe: tribe(status: .pending), type: MessageType.memberApprove, role: 0, expected: nil),
        MembershipCase(testDescription: "an approval without an alias changes nothing", tribe: tribe(status: .pending),
                       type: MessageType.memberApprove, alias: nil, role: 0, expected: nil),
        MembershipCase(testDescription: "another member's join leaves a removed member out", tribe: tribe(status: .removed),
                       type: MessageType.groupJoin, expected: nil),
        MembershipCase(testDescription: "a join, even naming us, never lets a declined member in", tribe: tribe(status: .rejected),
                       type: MessageType.groupJoin, alias: ourAlias, role: 0, expected: nil),
        MembershipCase(testDescription: "an approval of us changes nothing for the owner", tribe: tribe(isOwner: true),
                       type: MessageType.memberApprove, alias: ourAlias, role: 0, expected: nil),
        MembershipCase(testDescription: "a join does not bring back a deleted tribe", tribe: tribe(status: .deleted),
                       type: MessageType.groupJoin, expected: nil),
        MembershipCase(testDescription: "a join changes nothing for an active member",
                       type: MessageType.groupJoin, expected: nil),
        MembershipCase(testDescription: "someone else's role 0 text does not make us owner",
                       type: MessageType.text, role: 0, expected: nil),
    ])
    func membershipAfterAMessage(_ test: MembershipCase) {
        let changed = Engine.membership(after: test.message(), in: test.tribe, sent: ourAlias, echoed: [], replaying: test.replaying)
        #expect(changed == test.expected)
    }

    /// What we send, its `_2`, and what the tribe echoed; once it echoed
    /// `me_2`, the plain `me` is someone else's.
    @Test func whichApprovalsNameUs() {
        #expect(approvalNamesUs("me", sent: "me", echoed: []))
        #expect(approvalNamesUs("me_2", sent: "me", echoed: []))
        #expect(approvalNamesUs("old", sent: "me", echoed: ["old"]))
        #expect(!approvalNamesUs("old_2", sent: "me", echoed: ["old"]))
        #expect(!approvalNamesUs("me", sent: "me", echoed: ["me_2"]))
        #expect(!approvalNamesUs("you", sent: "me", echoed: []))
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

/// Our encrypted tag opens as ours whoever sends it, and the tribes server
/// forwards it to every member: a member can post it again. The first copy
/// with a tag is ours; a later one under another uuid is dropped before it
/// can change the tribe, the timeline, payments or our aliases.
struct ReplayedTagTests {
    let profile = TempProfile()

    /// A tribe's forward, as the core returns one it took for ours by `tag`
    /// (or, `to` a person, our own copy, signed by `signer`).
    private func forward(
        _ n: Int, type: Int = MessageType.text, tag: String? = "aa", original: Int? = nil, alias: String = ourAlias,
        to chat: String = tribeKey, signer: String = tribeKey, words: String? = nil
    ) -> Msg {
        let originalUuid = original.map { #","originalUuid":"\#(uuid($0))""# } ?? ""
        // A forward keeps the words of the message it forwards.
        return Msg(
            message: #"{"content":"\#(words ?? "m\(original ?? n)")"\#(originalUuid)}"#, type: UInt8(type), uuid: uuid(n), tag: tag, index: String(n),
            sender: sender(signer, alias: alias), msat: nil, timestamp: UInt64(n) * 1_000, sentTo: chat, fromMe: true,
            paymentHash: nil, error: nil
        )
    }

    private func setUp(_ ours: Message? = nil) throws -> (Storage, Engine) {
        let storage = try profile.storage()
        _ = try storage.apply(Storage.Commit(messages: ours.map { [($0, false, nil)] } ?? [], tribes: [tribe()]))
        return (storage, try testEngine(storage))
    }

    private func stored(_ storage: Storage) throws -> [Message] {
        try storage.pool.read { db in
            try Message.fetchAll(db, sql: "SELECT * FROM message WHERE chat = ? ORDER BY id", arguments: [tribeKey])
        }
    }

    /// Our send comes back from the tribe and takes over its row; a member's
    /// leave, text and boost with the same tag change nothing, and the
    /// cursor moves past them.
    @Test func aMembersReplayOfOurTagIsDropped() async throws {
        let sent = Message.fixture(uuid: uuid(1), chat: tribeKey, fromMe: true, content: "m1", tag: "aa")
        let (storage, engine) = try setUp(sent)
        _ = try await engine.commit(coreResult(msgs: [
            forward(2, original: 1),
            forward(3, type: MessageType.groupLeave, original: 9, alias: "eve"),
            forward(4, original: 8, alias: "eve"),
            forward(5, type: MessageType.boost, original: 7, alias: "eve"),
            // The member chooses `originalUuid`: naming our row is no pass.
            forward(6, type: MessageType.groupLeave, original: 2, alias: "eve"),
        ]), time: "1", expectedSender: nil)
        let rows = try stored(storage)
        #expect(rows.map(\.uuid) == [uuid(2)])
        #expect(rows.first?.serverIndex == 2)
        #expect(await engine.tribes[tribeKey]?.left == false)
        #expect(await engine.echoedAliases[tribeKey] == [ourAlias])
        #expect(await engine.droppedIndex == 6)
        // The same forward again, as history brings it, is still ours.
        _ = try await engine.commit(coreResult(msgs: [forward(2, original: 1)]), time: "2", expectedSender: nil)
        // In a later call: a replay naming our row (taken over now) with its
        // type and words, and one under our row's own uuid at another
        // index, as a chunk's sender chooses it.
        var chunk = forward(2, alias: "eve")
        chunk.index = "8"
        _ = try await engine.commit(coreResult(msgs: [forward(7, original: 2, alias: "eve", words: "m1")]), time: "3", expectedSender: nil)
        _ = try await engine.commit(coreResult(msgs: [chunk]), time: "4", expectedSender: nil)
        let after = try stored(storage)
        #expect(after.map(\.uuid) == [uuid(2)] && after.first?.serverIndex == 2 && after.first?.content == "m1")
        #expect(await engine.echoedAliases[tribeKey] == [ourAlias])
        #expect(await engine.droppedIndex == 8)
    }

    /// A restore or another device holds no row of ours: the first copy
    /// with a tag wins, also against a replay later in the same page.
    @Test func theFirstCopyWithATagIsOurs() async throws {
        let (storage, engine) = try setUp()
        _ = try await engine.commit(coreResult(msgs: [
            forward(2, original: 1),
            forward(3, type: MessageType.groupLeave, original: 9, alias: "eve"),
            forward(4, type: MessageType.groupLeave, original: 2, alias: "eve"),
        ]), time: "1", expectedSender: nil)
        #expect(try stored(storage).map(\.uuid) == [uuid(2)])
        #expect(await engine.tribes[tribeKey]?.left == false)
    }

    /// A copy naming our unsent row, of its type but not its words (a
    /// member racing our own forward), is not it; nor is a chunk under the
    /// row's own uuid with other words.
    @Test func aCopyWithOtherWordsTakesOverNothing() async throws {
        let sent = Message.fixture(uuid: uuid(1), chat: tribeKey, fromMe: true, content: "m1", tag: "aa")
        let (storage, engine) = try setUp(sent)
        _ = try await engine.commit(coreResult(msgs: [forward(3, original: 1, alias: "eve", words: "other")]), time: "1", expectedSender: nil)
        _ = try await engine.commit(coreResult(msgs: [forward(1, alias: "eve", words: "other")]), time: "2", expectedSender: nil)
        let rows = try stored(storage)
        #expect(rows.map(\.uuid) == [uuid(1)] && rows.first?.serverIndex == nil)
        #expect(await engine.echoedAliases[tribeKey] == nil)
    }

    /// Our send the tribe never brings back (a purchase goes to the seller
    /// alone) keeps no server index: a copy naming it is ours only with
    /// its type and words.
    @Test func aSendTheTribeNeverReturnsExcusesNoOtherCopy() async throws {
        let (storage, engine) = try setUp(.fixture(
            uuid: uuid(1), type: MessageType.purchase, chat: tribeKey, fromMe: true, content: nil, tag: "aa"
        ))
        _ = try await engine.commit(coreResult(msgs: [
            forward(2, original: 1, alias: "eve"), forward(3, type: MessageType.boost, original: 1, alias: "eve"),
        ]), time: "1", expectedSender: nil)
        #expect(try stored(storage).map(\.uuid) == [uuid(1)])
    }

    /// A tag copied from a DM we sent is held by that message, even when
    /// the replay names it as the row it takes over.
    @Test func aTagFromOurDirectMessageIsAReplay() async throws {
        let (storage, engine) = try setUp(.fixture(uuid: uuid(1), chat: dm, fromMe: true, tag: "aa"))
        _ = try await engine.commit(coreResult(msgs: [
            forward(2, original: 9, alias: "eve"), forward(3, original: 1, alias: "eve"),
        ]), time: "1", expectedSender: nil)
        #expect(try stored(storage).isEmpty)
    }

    /// Our DM send's echo and its history copy keep the send's uuid and tag
    /// (here a chat the core does not hold as a person, as `isReplay` sees
    /// one before a restore's contacts; a person's is left to the signer).
    @Test func ourDirectMessagesEchoIsKept() async throws {
        let (storage, engine) = try setUp(.fixture(uuid: uuid(1), chat: dm, fromMe: true, content: "m1", tag: "aa"))
        let echo = forward(1, to: dm, signer: keyG)
        _ = try await engine.commit(coreResult(msgs: [echo, echo]), time: "1", expectedSender: nil)
        let row = try #require(try storage.message(uuid: uuid(1), in: dm))
        #expect(row.serverIndex == 1)
        #expect(await engine.droppedIndex == -1)
    }

    /// What the tribes server itself makes ours by date carries no tag.
    @Test func anUntaggedCopyIsKept() async throws {
        let (storage, engine) = try setUp()
        _ = try await engine.commit(coreResult(msgs: [forward(2, tag: nil), forward(3, tag: nil)]), time: "1", expectedSender: nil)
        #expect(try stored(storage).map(\.uuid) == [uuid(2), uuid(3)])
    }
}
