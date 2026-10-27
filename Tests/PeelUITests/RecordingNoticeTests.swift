import Testing
@testable import PeelUI

/// The words a call shows when its recording starts and stops.
struct RecordingNoticeTests {
    @Test func aCallNeverRecordedSaysNothing() {
        var notice = RecordingNotice()
        #expect(notice.update(false) == nil)
        #expect(notice.update(false) == nil)
    }

    @Test func startingTellsEveryoneOnce() {
        var notice = RecordingNotice()
        #expect(notice.update(true) == RecordingNotice.started)
        #expect(notice.update(true) == nil)
    }

    @Test func stoppingSaysSoOnce() {
        var notice = RecordingNotice()
        _ = notice.update(true)
        #expect(notice.update(false) == RecordingNotice.ended)
        #expect(notice.update(false) == nil)
    }

    @Test func aSecondRecordingIsToldAgain() {
        var notice = RecordingNotice()
        _ = notice.update(true)
        _ = notice.update(false)
        #expect(notice.update(true) == RecordingNotice.started)
    }
}
