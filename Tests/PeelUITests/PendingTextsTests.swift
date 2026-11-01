import Testing
@testable import PeelUI

struct PendingTextsTests {
    @Test func trimsAndRefusesEmpty() {
        var queue = PendingTexts()
        #expect(!queue.add("  \n "))
        #expect(queue.add("  hello \n"))
        #expect(queue.next() == "hello")
        #expect(queue.next() == nil)
    }

    @Test func keepsOrderAndDropsOldestPastLimit() {
        var queue = PendingTexts()
        for n in 1...(PendingTexts.limit + 2) { queue.add("m\(n)") }
        #expect(queue.count == PendingTexts.limit)
        #expect(queue.next() == "m3")
    }
}
