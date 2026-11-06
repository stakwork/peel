import Testing
@testable import PeelUI

/// The Mac's lease is held only while Peel is in front, open, not locked
/// and online: every other combination ends it.
struct ActiveLeaseTests {
    @Test(arguments: [AppModel.Phase.loading, .locked, .onboarding, .ready])
    func truthTable(phase: AppModel.Phase) {
        for isActive in [true, false] {
            for lockDue in [true, false] {
                for connected in [true, false] {
                    let expected = isActive && phase == .ready && !lockDue && connected
                    #expect(
                        ActiveLease.shouldBeActive(isActive: isActive, phase: phase, lockDue: lockDue, connected: connected)
                            == expected,
                        "active \(isActive), \(phase), lock due \(lockDue), connected \(connected)")
                }
            }
        }
    }

    @Test func onlyTheFullCombinationHoldsIt() {
        #expect(ActiveLease.shouldBeActive(isActive: true, phase: .ready, lockDue: false, connected: true))
        #expect(!ActiveLease.shouldBeActive(isActive: false, phase: .ready, lockDue: false, connected: true))
    }

    @Test func renewsWellInsideTheServersLeaseAndTheCapIsShort() {
        #expect(ActiveLease.interval == .seconds(25))
        #expect(ActiveLease.cap == .seconds(3))
    }
}
