import Foundation
import Testing
@testable import PeelCore

/// The PIN kept between unlocks: given back while the timeout has not run
/// out, removed once it has, never kept for "When Peel opens", and following
/// a PIN or timeout change.
struct RememberedPINTests {
    private final class Item: SecretItem, @unchecked Sendable {
        var data: Data?
        func read() throws -> Data? { data }
        func write(_ data: Data) throws { self.data = data }
        func delete() throws { data = nil }
    }

    private let item = Item()
    private var remembered: RememberedPIN { RememberedPIN(item: item) }
    private let start = Date(timeIntervalSince1970: 1_000_000)

    @Test func givenBackWithinTheTimeoutAndRemovedPastIt() {
        remembered.keep("123456", activeAt: start, timeoutHours: 4)
        #expect(remembered.pin(at: start + 4 * 3600) == "123456")
        #expect(remembered.pin(at: start + 4 * 3600 + 1) == nil)
        #expect(item.data == nil)
        #expect(remembered.pin(at: start) == nil)
    }

    @Test func everyOpenKeepsNothingAndNeverKeepsItForGood() {
        remembered.keep("123456", activeAt: start, timeoutHours: 0)
        #expect(item.data == nil)
        remembered.keep("123456", activeAt: start, timeoutHours: PINTimeout.never)
        #expect(remembered.pin(at: start + 365 * 86_400) == "123456")
    }

    @Test func useMovesTheTimeoutOn() {
        remembered.keep("123456", activeAt: start, timeoutHours: 1)
        remembered.touch(activeAt: start + 3000)
        #expect(remembered.pin(at: start + 3000 + 3600) == "123456")
    }

    @Test func touchingKeepsNothingNew() {
        remembered.touch(activeAt: start)
        #expect(item.data == nil)
    }

    @Test func aTimeoutChangeIsKeptAndEveryOpenRemovesIt() {
        remembered.keep("123456", activeAt: start, timeoutHours: 1)
        remembered.timeoutChanged(to: 12)
        #expect(remembered.pin(at: start + 11 * 3600) == "123456")
        remembered.timeoutChanged(to: 0)
        #expect(item.data == nil)
    }

    @Test func aPINChangeReplacesAKeptOneOnly() {
        remembered.pinChanged(to: "222222")
        #expect(item.data == nil)
        remembered.keep("123456", activeAt: start, timeoutHours: 4)
        remembered.pinChanged(to: "222222")
        #expect(remembered.pin(at: start) == "222222")
    }

    @Test func aClockSetBackCountsAsNoTimePassed() {
        remembered.keep("123456", activeAt: start, timeoutHours: 1)
        #expect(remembered.pin(at: start - 86_400) == "123456")
    }

    @Test func garbageInTheItemIsNoPIN() {
        item.data = Data("not json".utf8)
        #expect(remembered.pin(at: start) == nil)
    }
}
