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

/// Whether this session has caught up with the server's history, and what
/// it knew when the catch-up began: `readAll` marks undelivered messages as
/// read, so it may only follow a catch-up that finished without error or
/// stall, and only if no message came in meanwhile. Pure; `Engine` drives it.
public struct CatchUpTracker: Sendable, Equatable {
    /// History is fully fetched on this connection.
    public private(set) var isCaughtUp = false
    /// The highest server index stored when this catch-up began.
    public private(set) var startIndex: Int64?

    public init() {}

    /// A catch-up begins (or resumes: the first start is kept, so a stall
    /// and a Resume still count from where it began).
    public mutating func begin(highestIndex: Int64?) {
        if isCaughtUp || startIndex == nil { startIndex = highestIndex ?? -1 }
        isCaughtUp = false
    }

    /// The last page was committed without error.
    public mutating func finish() { isCaughtUp = true }

    /// The connection ended: the next one starts over.
    public mutating func reset() { self = CatchUpTracker() }

    /// Whether `readAll` may be sent now: caught up, not fetching, nothing
    /// stored beyond what the catch-up began with, and nothing unread.
    public func allowsReadAll(syncing: Bool, highestIndex: Int64?, unread: Int) -> Bool {
        guard isCaughtUp, !syncing, unread == 0, let startIndex else { return false }
        return (highestIndex ?? -1) <= startIndex
    }
}
