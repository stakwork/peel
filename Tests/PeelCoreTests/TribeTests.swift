import Foundation
import Testing
@testable import PeelCore

struct TribeTests {
    @Test func mentionsMatchWholeWordsExactly() {
        #expect(mentions("hi @ann welcome", alias: "ann"))
        #expect(mentions("@ann", alias: "ann"))
        #expect(mentions("line one\n@ann", alias: "ann"))
        #expect(!mentions("hi @anna", alias: "ann"))
        #expect(!mentions("hi @Ann", alias: "ann"))
        #expect(!mentions("mail ann@example.com", alias: "ann"))
        #expect(!mentions("hi ann", alias: "ann"))
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
        #expect(throws: PeelError.self) { try TribeSettings(name: "  ").validated() }
        #expect(throws: PeelError.self) { try TribeSettings(name: "Club", photoURL: "http://x/p.png").validated() }
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

    @Test func amountsAreExactInTheSmallerUnit() throws {
        #expect(try amount("", unit: 1000, of: "price") == 0)
        #expect(try amount("3", unit: 1000, of: "price") == 3000)
        #expect(try amount("1.5", unit: 1000, of: "price") == 1500)
        #expect(try amount("0.5", unit: 3_600_000, of: "time") == 1_800_000)
        #expect(throws: PeelError.self) { try amount("0.0001", unit: 1000, of: "price") }
        #expect(throws: PeelError.self) { try amount("-1", unit: 1000, of: "price") }
        #expect(throws: PeelError.self) { try amount("1.2.3", unit: 1000, of: "price") }
        #expect(throws: PeelError.self) { try amount("1e3", unit: 1000, of: "price") }
        #expect(throws: PeelError.self) { try amount("99999999999999999", unit: 1000, of: "price") }
    }

    @Test func anImageTheTribeAlreadyHasIsKeptWhateverItsScheme() throws {
        let settings = TribeSettings(name: "Club", photoURL: "http://x/p.png")
        #expect(try settings.validated(currentImage: "http://x/p.png").photoURL == "http://x/p.png")
        #expect(throws: PeelError.self) { try settings.validated(currentImage: "https://x/other.png") }
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
