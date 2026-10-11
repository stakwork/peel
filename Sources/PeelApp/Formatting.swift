import Foundation
import PeelCore

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

enum Formatting {
    static func dayHeading(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }

    /// "1 reply", "5 replies".
    static func replies(_ count: Int) -> String {
        count == 1 ? "1 reply" : "\(count) replies"
    }

    /// "1 person", "5 people".
    static func people(_ count: Int) -> String {
        count == 1 ? "1 person" : "\(count) people"
    }

    /// How long ago, as Slack writes it: "just now", "5 min ago", "today at
    /// 14:32", "yesterday at 09:10", "3 days ago", "2 Oct", "2 Oct 2025"
    /// (times and dates in the user's format). Everything is measured from
    /// `now`, in calendar days, so midnight and DST changes count right.
    static func relative(_ date: Date, now: Date = .now) -> String {
        let seconds = now.timeIntervalSince(date)
        // A few minutes of clock skew between devices reads as now; further
        // ahead, the time or date it claims.
        if seconds > -300 && seconds < 60 { return "just now" }
        if seconds >= 60 && seconds < 3600 { return "\(Int(seconds / 60)) min ago" }
        let calendar = Calendar.current
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date),
                                           to: calendar.startOfDay(for: now)).day ?? 0
        switch days {
        case 0: return "today at \(date.formatted(.dateTime.hour().minute()))"
        case 1: return "yesterday at \(date.formatted(.dateTime.hour().minute()))"
        case 2..<7: return "\(days) days ago"
        default:
            let style = Date.FormatStyle.dateTime.day().month(.abbreviated)
            let sameYear = calendar.isDate(date, equalTo: now, toGranularity: .year)
            return date.formatted(sameYear ? style : style.year())
        }
    }

    /// "02f7…c3a1": a key or hash, its ends only.
    static func shortKey(_ key: String) -> String {
        key.count > 12 ? "\(key.prefix(6))…\(key.suffix(4))" : key
    }

    /// A time beside a payment: as in the list, by how long ago it was.
    static func when(_ date: Date) -> String {
        paymentTime(date, in: PaymentSection(date))
    }

    /// When an invoice runs out: "14:22" today, else "15 Oct, 14:22" (the
    /// server's invoices last a week).
    static func expiry(_ date: Date) -> String {
        Calendar.current.isDateInToday(date)
            ? date.formatted(.dateTime.hour().minute())
            : date.formatted(.dateTime.day().month(.abbreviated).hour().minute())
    }

    /// A row's time within its section: "14:22" today and yesterday, "Mon
    /// 08:00" this week, "30 Sep" before.
    static func paymentTime(_ date: Date, in section: PaymentSection) -> String {
        switch section {
        case .today, .yesterday: date.formatted(.dateTime.hour().minute())
        case .thisWeek: date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
        case .earlier: date.formatted(.dateTime.day().month(.abbreviated))
        }
    }
}
