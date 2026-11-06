import Foundation

/// When Peel may tell the server that everything is read (`readAll`, to reset
/// a badge count the mixer kept too high), without it becoming a habit.
///
/// The rule: **at most once per app session (process), and not more than
/// once in 30 minutes** across sessions, the last time kept in
/// `UserDefaults` under `key`. A stored time in the future (the clock moved
/// back) does not hold it off. The caller asks only once the local unread
/// count is 0 and the reads have loaded; the gate decides nothing about that.
public struct ReadAllGate: Sendable {
    /// The least time between two `readAll`s.
    public static let interval: TimeInterval = 30 * 60
    /// Where the last time is kept (`UserDefaults`).
    public static let key = "PeelLastReadAll"

    private(set) var last: Date?
    private var claimedThisSession = false

    public init(last: Date? = nil) {
        self.last = last
    }

    /// The gate as the defaults left it.
    public init(defaults: UserDefaults) {
        self.init(last: defaults.object(forKey: Self.key) as? Date)
    }

    /// Whether a `readAll` may be sent now. Does not count it.
    public func allows(now: Date) -> Bool {
        guard !claimedThisSession else { return false }
        guard let last, last <= now else { return true }
        return now.timeIntervalSince(last) >= Self.interval
    }

    /// Takes the one `readAll` this session and this half hour, if allowed:
    /// true means send it. Kept in `defaults` when given.
    public mutating func claim(now: Date, defaults: UserDefaults? = nil) -> Bool {
        guard allows(now: now) else { return false }
        claimedThisSession = true
        last = now
        defaults?.set(now, forKey: Self.key)
        return true
    }
}
