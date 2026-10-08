import Foundation
import GRDB
import Testing
@testable import PeelCore

struct TribeTests {
    /// Fullwidth hex (`０２…`, `ａ`) is refused here, not later with a vaguer error.
    @Test func aPubkeyIsASCIIHex() {
        #expect(keyG.isPubkey)
        #expect(keyG.uppercased().isPubkey)
        #expect(!("\u{FF10}\u{FF12}" + keyG.dropFirst(2)).isPubkey)
        #expect(!(keyG.dropLast() + "\u{FF41}").isPubkey)
        #expect(!String(keyG.dropLast()).isPubkey)
    }

    @Test func mentionsMatchTheWholeAliasInAnyCase() {
        let me = ["Tom_Smith"]
        #expect(mentions("hi @Tom_Smith welcome", aliases: me))
        #expect(mentions("@Tom_Smith", aliases: me))
        #expect(mentions("line one\n@Tom_Smith", aliases: me))
        #expect(mentions("@tom_smith can you look", aliases: me))
        #expect(mentions("thanks @Tom_Smith, and @ann", aliases: me))
        #expect(mentions("@Tom_Smith: done?", aliases: me))
        #expect(mentions("(cc @Tom_Smith)", aliases: me))
        #expect(mentions("@Tom_Smith's turn", aliases: me))
        #expect(!mentions("hi @Tom_Smithers", aliases: me))
        #expect(!mentions("hi @Tom_Smith_2", aliases: me))
        #expect(!mentions("mail ann@Tom_Smith", aliases: me))
        #expect(!mentions("hi Tom_Smith", aliases: me))
        #expect(!mentions("hi @Tom Smith", aliases: me))
        #expect(!mentions("hi @Tom_Smith", aliases: [String]()))
        #expect(!mentions("hi @", aliases: [""]))
    }

    @Test func mentionsMatchAnyOfTheAliases() {
        let me: Set = ["Tom_Smith", "Tom_Smith_2"]
        #expect(mentions("hi @Tom_Smith_2", aliases: me))
        #expect(mentions("@Tom_Smith_2 and @Tom_Smith", aliases: me))
        #expect(mentions("@Tom_Smith_23 and @Tom_Smith.", aliases: me))
        #expect(!mentions("@Tom_Smith_3", aliases: me))
    }

    @Test func ownAliasesAreTheSentOneAndTheEchoedOnes() {
        #expect(ownTribeAliases(sent: "Tom_Smith", echoed: []) == ["Tom_Smith"])
        // Made unique by the tribes server: the plain alias is another member's.
        #expect(ownTribeAliases(sent: "Tom_Smith", echoed: ["Tom_Smith_2"]) == ["Tom_Smith_2"])
        #expect(ownTribeAliases(sent: "Tom_Smith", echoed: ["Tommy", "Tom_Smith_2"]) == ["Tommy", "Tom_Smith_2"])
        // An earlier name, or one sent from another device, still names this
        // account, and so does a new name not echoed yet.
        #expect(ownTribeAliases(sent: "Tom_Smith", echoed: ["Tom_Smith", "tom"]) == ["Tom_Smith", "tom"])
        #expect(ownTribeAliases(sent: "Thomas", echoed: ["Tom_Smith"]) == ["Tom_Smith", "Thomas"])
    }

    @Test func mentionScanRechecksOnlyWhatChanged() throws {
        let scan = MentionScan(sent: "Tom_Smith", echoed: ["02a": ["Tom_Smith"], "02b": ["Tom_Smith_2"]])
        let stored = try #require(scan.stored)
        #expect(MentionScan(stored: stored) == scan)
        #expect(MentionScan(stored: "Tom_Smith") == nil)
        #expect(scan.chats(changedSince: nil) == nil)
        #expect(scan.chats(changedSince: scan) == [])
        #expect(scan.chats(changedSince: MentionScan(sent: "Tom", echoed: scan.echoed)) == nil)
        let before = MentionScan(sent: "Tom_Smith", echoed: ["02a": ["Tom_Smith"], "02c": ["x"]])
        #expect(scan.chats(changedSince: before) == ["02b", "02c"])
    }

    @Test func echoedAliasesComeFromOwnTribeMessages() throws {
        let profile = TempProfile()
        let storage = try profile.storage()
        try storage.save([Tribe(pubkey: "02t1"), Tribe(pubkey: "02t2")])
        _ = try storage.apply(Storage.Commit(messages: [
            (.fixture(uuid: uuid(1), chat: "02t1", fromMe: true, sender: sender("02t", alias: "Tom_Smith_2")), false, nil),
            (.fixture(uuid: uuid(2), chat: "02t1", fromMe: true, sender: sender("02t", alias: "Tom_Smith")), false, nil),
            (.fixture(uuid: uuid(3), chat: "02t1", fromMe: false, sender: sender("02t", alias: "ann")), false, nil),
            (.fixture(uuid: uuid(4), chat: "02t2", fromMe: true, sender: nil), false, nil),
            (.fixture(uuid: uuid(5), chat: "02dm", fromMe: true, sender: sender("02t", alias: "Tom Smith")), false, nil),
        ]))
        #expect(try storage.echoedOwnAliases() == ["02t1": ["Tom_Smith", "Tom_Smith_2"]])
    }

    @Test func rescanFlagsStoredMentionsByEachTribesAliases() throws {
        let profile = TempProfile()
        let storage = try profile.storage()
        try storage.save([Tribe(pubkey: "02t1"), Tribe(pubkey: "02t2")])
        // In 02t1 the tribes server made this account Tom_Smith_2; 02t2 has no echo yet.
        let messages: [(Message, Bool, String?)] = [
            (.fixture(uuid: uuid(1), chat: "02t1", content: "hi @Tom_Smith, welcome"), false, nil),
            (.fixture(uuid: uuid(2), chat: "02t1", content: "ask @tom_smith_2"), false, nil),
            (.fixture(uuid: uuid(3), chat: "02t2", content: "ask @Tom_Smith_2"), false, nil),
            (.fixture(uuid: uuid(4), chat: "02t2", content: "no mention of Tom_Smith"), false, nil),
            (.fixture(uuid: uuid(5), type: MessageType.attachment, chat: "02t2", content: "@Tom_Smith look"), false, nil),
            (.fixture(uuid: uuid(6), chat: "02dm", content: "@Tom_Smith in a direct message"), false, nil),
            (.fixture(uuid: uuid(7), chat: "02t1", fromMe: true, content: "me @Tom_Smith_2"), false, nil),
            (.fixture(uuid: uuid(8), chat: "02t2", content: "@Tom_Smith: done"), false, nil),
        ]
        _ = try storage.apply(Storage.Commit(messages: messages))
        let flagged = { try rows(profile, "SELECT uuid FROM message WHERE mentionsMe = 1 ORDER BY id").map { $0["uuid"] as String } }
        // Chunks of two, so the scan crosses chunk boundaries.
        try storage.rescanMentions(sent: "Tom_Smith", echoed: ["02t1": ["Tom_Smith_2"]], chunk: 2)
        #expect(try flagged() == [uuid(2), uuid(5), uuid(8)])

        // Idempotent, and a later alias set unflags what no longer names this account.
        try storage.rescanMentions(sent: "Tom_Smith", echoed: ["02t1": ["Tom_Smith_2"]])
        #expect(try flagged() == [uuid(2), uuid(5), uuid(8)])
        // Limited to some tribes, the others are left as they are.
        try storage.rescanMentions(sent: "Thomas", echoed: [:], in: ["02t1"])
        #expect(try flagged() == [uuid(5), uuid(8)])
        try storage.rescanMentions(sent: "Tom_Smith", echoed: [:], in: [])
        #expect(try flagged() == [uuid(5), uuid(8)])
        try storage.rescanMentions(sent: "Tom_Smith", echoed: [:])
        #expect(try flagged() == [uuid(1), uuid(5), uuid(8)])
    }

    @Test func settingsAreSentWithTheOfficialKeysInMsat() throws {
        let settings = TribeSettings(
            name: "Club", summary: "About", photoURL: "https://x/p.png", pricePerMessageMsat: 2000,
            priceToJoinMsat: 5000, escrowMsat: 1000, escrowMillis: 7_200_000, isPrivate: true, unlisted: true
        )
        let fields = try settings.fields()
        #expect(fields["name"] as? String == "Club")
        #expect(fields["description"] as? String == "About")
        #expect(fields["img"] as? String == "https://x/p.png")
        #expect(fields["price_per_message"] as? Int == 2000)
        #expect(fields["price_to_join"] as? Int == 5000)
        #expect(fields["escrow_amount"] as? Int == 1000)
        #expect(fields["escrow_millis"] as? Int == 7_200_000)
        #expect(fields["private"] as? Bool == true)
        #expect(fields["unlisted"] as? Bool == true)
    }

    @Test func anUpdateKeepsWhatPeelDoesNotEditAndClearsWhatWasCleared() throws {
        let record: [String: Any] = [
            "pubkey": "02ab", "name": "Old", "description": "Old about", "img": "https://x/old.png",
            "tags": ["Bitcoin"], "pin": "uuid1", "owner_alias": "ann", "feed_url": "https://x/feed",
        ]
        let fields = try TribeSettings(name: "New").fields(over: record)
        #expect(fields["name"] as? String == "New")
        #expect(fields["tags"] as? [String] == ["Bitcoin"])
        #expect(fields["pin"] as? String == "uuid1")
        #expect(fields["owner_alias"] as? String == "ann")
        #expect(fields["feed_url"] as? String == "https://x/feed")
        #expect(fields["description"] is NSNull)
        #expect(fields["img"] is NSNull)
    }

    @Test func settingsNeedANameAndAnHttpsImage() throws {
        #expect(throws: Engine.Failure.tribeNeedsName) { try TribeSettings(name: "  ").validated() }
        #expect(throws: Engine.Failure.tribeImageNotHTTPS) { try TribeSettings(name: "Club", photoURL: "http://x/p.png").validated() }
        let trimmed = try TribeSettings(name: " Club ", summary: " ", photoURL: "").validated()
        #expect(trimmed.name == "Club")
        #expect(trimmed.summary == nil)
        #expect(trimmed.photoURL == nil)
    }

    @Test func registryRecordGivesEditableSettings() throws {
        let json = #"""
            {"pubkey":"02ab","name":"Club","description":"About","img":"https://x/p.png","price_per_message":2000,
             "price_to_join":5000,"escrow_amount":1000,"escrow_millis":7200000,"private":true,"unlisted":false,
             "pin":"uuid1"}
            """#
        let info = try JSONDecoder().decode(TribeInfo.self, from: Data(json.utf8))
        #expect(info.pin == "uuid1")
        #expect(info.settings == TribeSettings(
            name: "Club", summary: "About", photoURL: "https://x/p.png", pricePerMessageMsat: 2000,
            priceToJoinMsat: 5000, escrowMsat: 1000, escrowMillis: 7_200_000, isPrivate: true, unlisted: false
        ))
    }

    @Test func anImageTheTribeAlreadyHasIsKeptWhateverItsScheme() throws {
        let settings = TribeSettings(name: "Club", photoURL: "http://x/p.png")
        #expect(try settings.validated(currentImage: "http://x/p.png").photoURL == "http://x/p.png")
        #expect(throws: Engine.Failure.tribeImageNotHTTPS) { try settings.validated(currentImage: "https://x/other.png") }
    }

    @Test func onlyAnActiveMemberWhoHasNotLeftCanPost() {
        #expect(Tribe(pubkey: "02ab").canPost)
        #expect(!Tribe(pubkey: "02ab", left: true).canPost)
        for status in [Tribe.Status.pending, .rejected, .removed, .deleted] {
            #expect(!Tribe(pubkey: "02ab", status: status).canPost)
        }
    }

    @Test func mentionsOnlyCountsMentions() {
        let state = ChatReadState(chat: "02ab", unread: 5, mentions: 2, muteLevel: MuteLevel.mentionsOnly.rawValue)
        #expect(state.shownUnread == 2)
        #expect(ChatReadState(chat: "02ab", unread: 5, mentions: 2, muteLevel: 0).shownUnread == 5)
        #expect(ChatReadState(chat: "02ab", unread: 5, mentions: 2, muteLevel: 2).shownUnread == 0)
    }
}
