import Foundation
import Testing
@testable import PeelCore

struct CallStartTests {
    /// The earliest join wins, and a later sighting never moves it later,
    /// even once the first to join has left.
    @Test func theEarliestJoinIsKept() {
        let t = Date(timeIntervalSince1970: 1_000)
        let early = t.addingTimeInterval(-60)
        #expect(CallStart.earliest(nil, [nil, nil]) == nil)
        #expect(CallStart.earliest(nil, [t, nil, early]) == early)
        #expect(CallStart.earliest(early, [t]) == early)
        #expect(CallStart.earliest(t, [early]) == early)
    }
}
