import Foundation
import Testing
@testable import PeelCore

@Suite struct CallHandoffTests {
    private let mine = CallHandoff(seed: "seed-a")
    private let earlier = Date(timeIntervalSince1970: 1_000)
    private let later = Date(timeIntervalSince1970: 2_000)

    private func leaves(
        _ data: Data, room: String = "room-1", sender: String = "tom-2", senderJoinedAt: Date? = nil,
        me: String = "tom-1", myJoinedAt: Date? = nil
    ) -> Bool {
        mine.shouldLeave(data, room: room, sender: sender, senderJoinedAt: senderJoinedAt, me: me, myJoinedAt: myJoinedAt)
    }

    @Test func aNewerDeviceOnTheAccountTakesTheCall() {
        let phone = CallHandoff(seed: "seed-a").announcement(room: "room-1", identity: "tom-2")
        #expect(leaves(phone, senderJoinedAt: later, myJoinedAt: earlier))
        // Join times unknown: the sender has only just announced.
        #expect(leaves(phone))
        #expect(leaves(phone, senderJoinedAt: later))
    }

    @Test func aStayAnnouncementNeverMakesAnEarlierDeviceLeave() {
        let stay = mine.announcement(room: "room-1", identity: "tom-2", stay: true)
        #expect(!leaves(stay, senderJoinedAt: later, myJoinedAt: earlier))
        #expect(!leaves(stay))
        // The plain one from the same device still does.
        let plain = mine.announcement(room: "room-1", identity: "tom-2")
        #expect(leaves(plain, senderJoinedAt: later, myJoinedAt: earlier))
    }

    @Test func anotherDeviceOfTheAccountIsToldFromAnyoneElse() {
        let other = mine.announcement(room: "room-1", identity: "tom-2")
        #expect(mine.isOtherDevice(other, room: "room-1", sender: "tom-2", me: "tom-1"))
        // Not itself, not a replay under another identity or room, not another account.
        #expect(!mine.isOtherDevice(other, room: "room-1", sender: "tom-1", me: "tom-1"))
        #expect(!mine.isOtherDevice(other, room: "room-1", sender: "eve-3", me: "tom-1"))
        #expect(!mine.isOtherDevice(other, room: "room-2", sender: "tom-2", me: "tom-1"))
        let stranger = CallHandoff(seed: "seed-b").announcement(room: "room-1", identity: "tom-2")
        #expect(!mine.isOtherDevice(stranger, room: "room-1", sender: "tom-2", me: "tom-1"))
        // A stay announcement is not a plain one.
        let stay = mine.announcement(room: "room-1", identity: "tom-2", stay: true)
        #expect(!mine.isOtherDevice(stay, room: "room-1", sender: "tom-2", me: "tom-1"))
    }

    @Test func anOlderDeviceDoesNot() {
        let phone = mine.announcement(room: "room-1", identity: "tom-2")
        #expect(!leaves(phone, senderJoinedAt: earlier, myJoinedAt: later))
    }

    @Test func twoJoiningAtOnceLeaveOnlyOne() {
        let a = mine.announcement(room: "room-1", identity: "tom-a")
        let b = mine.announcement(room: "room-1", identity: "tom-b")
        let aLeaves = leaves(b, sender: "tom-b", senderJoinedAt: later, me: "tom-a", myJoinedAt: later)
        let bLeaves = leaves(a, sender: "tom-a", senderJoinedAt: later, me: "tom-b", myJoinedAt: later)
        #expect(aLeaves != bLeaves)
    }

    @Test func aReplayUnderAnotherIdentityOrRoomIsRefused() {
        let phone = mine.announcement(room: "room-1", identity: "tom-2")
        #expect(!leaves(phone, sender: "eve-3"))
        #expect(!leaves(phone, room: "room-2"))
        // Its own announcement, echoed back.
        #expect(!leaves(mine.announcement(room: "room-1", identity: "tom-1"), sender: "tom-1"))
    }

    @Test func anotherAccountOrGarbageIsRefused() {
        #expect(!leaves(CallHandoff(seed: "seed-b").announcement(room: "room-1", identity: "tom-2")))
        #expect(!leaves(Data("not a mac".utf8)))
        #expect(!leaves(Data()))
    }
}
