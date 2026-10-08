import Foundation
import PeelCore

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    /// An engine refusal as the start of a sentence.
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

enum Formatting {
    /// An error's words as a sentence: "That is not contact info…".
    static func sentence(_ error: any Error) -> String {
        PeelError.readable(error).capitalizedFirst + "."
    }

    static func dayHeading(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }

    /// "1 reply", "5 replies".
    static func replies(_ count: Int) -> String {
        count == 1 ? "1 reply" : "\(count) replies"
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
}
