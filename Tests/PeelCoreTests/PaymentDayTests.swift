import Foundation
import Testing
@testable import PeelCore

/// The iPhone's history by day: one section per day, newest first, however
/// the rows come.
struct PaymentDayTests {
    private func item(_ id: String, daysAgo: Int, hour: Int) -> PaymentItem {
        let calendar = Calendar.current
        let day = calendar.date(byAdding: .day, value: -daysAgo, to: calendar.startOfDay(for: .now))!
        let date = calendar.date(byAdding: .hour, value: hour, to: day)!
        return PaymentItem(id: id, kind: .payment, incoming: true, amountMsat: 1_000,
                           timestamp: Int64(date.timeIntervalSince1970 * 1000), status: .complete)
    }

    @Test func aDayIsOneSectionEvenWhenItsRowsAreApart() {
        // A pending payment of yesterday listed first, before today's.
        let rows = [item("pending", daysAgo: 1, hour: 9), item("a", daysAgo: 0, hour: 10),
                    item("b", daysAgo: 1, hour: 20), item("c", daysAgo: 3, hour: 8)]
        let days = PaymentDay.group(rows)
        #expect(days.map { $0.items.map(\.id) } == [["a"], ["pending", "b"], ["c"]])
        #expect(days.map(\.day) == days.map(\.day).sorted(by: >))
    }
}
