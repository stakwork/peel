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
        // A tribe's own alias set, changed or cleared rechecks that tribe alone.
        let renamed = MentionScan(sent: "Tom_Smith", echoed: scan.echoed, own: ["02a": "Tommy"])
        #expect(renamed.chats(changedSince: scan) == ["02a"])
        #expect(scan.chats(changedSince: renamed) == ["02a"])
        #expect(MentionScan(stored: try #require(renamed.stored)) == renamed)
        // Scans stored before own aliases read as none.
        #expect(MentionScan(stored: #"{"sent":"Tom_Smith","echoed":{}}"#) == MentionScan(sent: "Tom_Smith", echoed: [:]))
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
        // In a tribe with its own alias, that alias names this account.
        try storage.rescanMentions(sent: "Tom_Smith", echoed: [:], own: ["02t1": "tom_smith_2"])
        #expect(try flagged() == [uuid(2), uuid(5), uuid(8)])
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
        let fields = try TribeSettings(name: "New", tags: ["Tech"]).fields(over: record)
        #expect(fields["name"] as? String == "New")
        #expect(fields["tags"] as? [String] == ["Tech"])
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
             "pin":"uuid1","member_count":42}
            """#
        let info = try JSONDecoder().decode(TribeInfo.self, from: Data(json.utf8))
        #expect(info.pin == "uuid1")
        #expect(info.memberCount == 42)
        #expect(info.settings == TribeSettings(
            name: "Club", summary: "About", photoURL: "https://x/p.png", pricePerMessageMsat: 2000,
            priceToJoinMsat: 5000, escrowMsat: 1000, escrowMillis: 7_200_000, isPrivate: true, unlisted: false
        ))
    }

    /// Tags go as the official apps send them (names in a `tags` list) and
    /// come back from the registry into the form as they were, with the
    /// details the registry alone knows.
    @Test func tagsAndDetailsRoundTripThroughTheRegistry() throws {
        let sent = try TribeSettings(name: "Club", tags: [" Bitcoin ", "Tech", "", "Bitcoin"]).validated()
        #expect(sent.tags == ["Bitcoin", "Tech"])
        let fields = try sent.fields(over: ["tags": ["Music"], "member_count": 7, "created": 1_700_000_000_000])
        #expect(fields["tags"] as? [String] == ["Bitcoin", "Tech"])
        #expect(fields["member_count"] as? Int == 7)
        #expect(fields["created"] as? Int == 1_700_000_000_000)

        var record = fields
        record["pubkey"] = "02ab"
        record["owner_alias"] = "ann"
        let info = try JSONDecoder().decode(TribeInfo.self, from: JSONSerialization.data(withJSONObject: record))
        #expect(info.settings.tags == ["Bitcoin", "Tech"])
        #expect(info.ownerAlias == "ann")
        #expect(info.memberCount == 7)
        #expect(info.created == Date(timeIntervalSince1970: 1_700_000_000))
        let bare = try JSONDecoder().decode(TribeInfo.self, from: Data(#"{"pubkey":"02ab","name":"Club","created":0}"#.utf8))
        #expect(bare.settings.tags.isEmpty)
        #expect(bare.created == nil)
    }

    /// How this account appears in a tribe is kept per tribe, sent there in
    /// place of the account's (as a tribe alias), and survives a restart.
    @Test func aTribeAliasAndPhotoAreKeptAndSentThere() async throws {
        let profile = TempProfile()
        let storage = try profile.storage()
        try storage.save([Tribe(pubkey: "02t1"), Tribe(pubkey: "02t2", left: true)])
        let engine = try testEngine(storage)
        let set = try await engine.setTribeIdentity("02t1", alias: " Tom in Club ", photoURL: " https://x/me.png ")
        #expect(set.myAlias == "Tom in Club")
        #expect(set.myPhotoURL == "https://x/me.png")
        #expect(set.sentAlias(account: "Tom Smith") == "Tom_in_Club")
        #expect(set.sentPhoto(account: "https://x/account.png") == "https://x/me.png")
        #expect(Tribe(pubkey: "02t3").sentAlias(account: "Tom Smith") == "Tom_Smith")
        #expect(Tribe(pubkey: "02t3").sentPhoto(account: "https://x/account.png") == "https://x/account.png")
        await #expect(throws: Engine.Failure.photoNotHTTPS) {
            try await engine.setTribeIdentity("02t1", alias: nil, photoURL: "http://x/me.png")
        }
        await #expect(throws: Engine.Failure.notInTribe) { try await engine.setTribeIdentity("02t2", alias: "x", photoURL: nil) }
        await #expect(throws: Engine.Failure.notInTribe) { try await engine.setTribeIdentity("02t9", alias: "x", photoURL: nil) }
        #expect(try storage.tribes().first { $0.pubkey == "02t1" }?.myAlias == "Tom in Club")
        // Empty is the account's own again.
        let cleared = try await engine.setTribeIdentity("02t1", alias: "  ", photoURL: "")
        #expect(cleared.myAlias == nil && cleared.myPhotoURL == nil)
        #expect(try storage.tribes().first { $0.pubkey == "02t1" }?.myPhotoURL == nil)
        await engine.close()
    }

    @Test func anImageTheTribeAlreadyHasIsKeptWhateverItsScheme() throws {
        let settings = TribeSettings(name: "Club", photoURL: "http://x/p.png")
        #expect(try settings.validated(currentImage: "http://x/p.png").photoURL == "http://x/p.png")
        #expect(throws: Engine.Failure.tribeImageNotHTTPS) { try settings.validated(currentImage: "https://x/other.png") }
    }

    @Test func thePinnedMessageIsReadFromStorageHoweverOld() async throws {
        let profile = TempProfile()
        let storage = try profile.storage()
        var tribe = Tribe(pubkey: "02t1")
        try storage.save([tribe])
        _ = try storage.apply(Storage.Commit(messages: (1...Storage.pageSize + 50).map { (text($0, chat: "02t1"), false, nil) }))
        #expect(try await first(storage.pinnedMessage(in: "02t1")) == .some(nil))

        tribe.pin = uuid(1)
        // Another tribe pinning the same uuid finds nothing of its own.
        try storage.save([tribe, Tribe(pubkey: "02t2", pin: uuid(1))])
        for try await timeline in storage.timeline(in: "02t1") {
            #expect(!timeline.messages.contains { $0.uuid == uuid(1) })
            break
        }
        #expect(try await first(storage.pinnedMessage(in: "02t1"))??.content == "m1")
        #expect(try await first(storage.pinnedMessage(in: "02t2")) == .some(nil))
    }

    private func first(_ values: some AsyncSequence<Message?, any Error>) async throws -> Message?? {
        for try await value in values { return value }
        return nil
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

    /// What a member is shown is what the engine sends: the 3-sat and 1-sat
    /// floors, the escrow on top, and the owner's price kept apart.
    @Test func pricesShownAreWhatMembersPay() throws {
        func info(_ fields: String) throws -> TribeInfo {
            try JSONDecoder().decode(TribeInfo.self, from: Data(#"{"pubkey":"02ab","name":"Club"\#(fields)}"#.utf8))
        }
        let free = try info("")
        #expect(free.joinPrice == TribePrice(msat: 1_000, reason: .minimum))
        #expect(free.joinPrice.described == "1 sat, the minimum")
        #expect(free.messagePrice.described == "3 sats, the minimum")

        let priced = try info(#","price_to_join":10000,"price_per_message":2000"#)
        #expect(priced.joinPrice.described == "10 sats")
        #expect(priced.messagePrice.described == "3 sats, the minimum")
        #expect(priced.pricePerMessage == 2000)

        let escrow = try info(#","price_to_join":500,"price_per_message":20000,"escrow_amount":5000"#)
        #expect(escrow.joinPrice == TribePrice(msat: 500, reason: nil))
        #expect(escrow.messagePrice.described == "25 sats, including 5 sats escrow")
        #expect(TribePrice.message(pricePerMessage: 2000, escrow: 1000).reason == .escrow(1000))
        #expect(TribePrice.message(pricePerMessage: 0, escrow: 5000).described == "5 sats, all of it escrow")

        // Sub-sat prices read as sent, not rounded down.
        #expect(escrow.joinPrice.described == "0.5 sats")
        let fractional = TribePrice.message(pricePerMessage: 2500, escrow: 1000)
        #expect(fractional.msat == 3500)
        #expect(fractional.described == "3.5 sats, including 1 sat escrow")
        #expect(TribePrice.message(pricePerMessage: 2600, escrow: 500).described == "3.1 sats, including 0.5 sats escrow")

        // The engine's amounts are these prices, from the registry, the stored tribe and the owner's form.
        for record in [free, priced, escrow] {
            #expect(record.joinAmountMsat == record.joinPrice.msat)
            #expect(record.messageAmountMsat == record.messagePrice.msat)
            var tribe = Tribe(pubkey: "02ab")
            tribe.update(from: record, trustingPrivacy: true)
            #expect(tribe.messagePrice == record.messagePrice)
            #expect(tribe.messageAmountMsat == record.messageAmountMsat)
            #expect(record.settings.joinPrice == record.joinPrice)
            #expect(record.settings.messagePrice == record.messagePrice)
        }
    }
}
