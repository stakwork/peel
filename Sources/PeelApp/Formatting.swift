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

    /// A count and its noun: "1 reply", "5 replies", "1,200 members". The
    /// plural is the noun with an "s" unless given; `shown` replaces the
    /// number ("99+ new messages", "500+ matches").
    static func count(_ count: Int, _ one: String, _ many: String? = nil, shown: String? = nil) -> String {
        "\(shown ?? count.formatted()) \(count == 1 ? one : many ?? one + "s")"
    }

    /// "1 reply", "5 replies".
    static func replies(_ count: Int) -> String {
        Self.count(count, "reply", "replies")
    }

    /// "1 person", "5 people".
    static func people(_ count: Int) -> String {
        Self.count(count, "person", "people")
    }

    /// A time of day, "14:32" (or "14:32:05"), in the user's format; in
    /// `zone` for someone else's local time.
    static func time(_ date: Date, in zone: TimeZone = .current, seconds: Bool = false) -> String {
        var style = Date.FormatStyle.dateTime.hour().minute()
        if seconds { style = style.second() }
        style.timeZone = zone
        return date.formatted(style)
    }

    /// A day, "2 Oct 2025": when a tribe was created, a contact added.
    static func date(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.abbreviated).year())
    }

    /// A day and a time, "2 Oct, 14:32", with the year when it is not this
    /// one: when an invite was made, an invoice runs out, a mention.
    static func dateAndTime(_ date: Date, now: Date = .now) -> String {
        let style = Date.FormatStyle.dateTime.day().month(.abbreviated).hour().minute()
        let sameYear = Calendar.current.isDate(date, equalTo: now, toGranularity: .year)
        return date.formatted(sameYear ? style : style.year())
    }

    /// A moment in full, "Monday 5 October 2026 at 14:32:05", for a
    /// payment's facts; seconds only when they matter.
    static func moment(_ date: Date, seconds: Bool = false) -> String {
        let style = Date.FormatStyle.dateTime.weekday(.wide).day().month(.wide).year().hour().minute()
        return date.formatted(seconds ? style.second() : style)
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
        case 0: return "today at \(time(date))"
        case 1: return "yesterday at \(time(date))"
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
        Calendar.current.isDateInToday(date) ? time(date) : dateAndTime(date)
    }

    /// A row's time within its section: "14:22" today and yesterday, "Mon
    /// 08:00" this week, "30 Sep" before.
    static func paymentTime(_ date: Date, in section: PaymentSection) -> String {
        switch section {
        case .today, .yesterday: time(date)
        case .thisWeek: date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
        case .earlier: date.formatted(.dateTime.day().month(.abbreviated))
        }
    }
}
