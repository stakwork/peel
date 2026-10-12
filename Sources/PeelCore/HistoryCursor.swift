import Foundation

/// The history machine without the network: the run in flight, the runs
/// queued behind it, whether a restore is waiting for the server's counts,
/// and where history stands. The engine asks for the pages it names and
/// feeds it each page, and each message that comes live (`Engine+History`).
struct HistoryCursor: Equatable {
    /// A history fetch: which kind, the next index to ask for, and where it
    /// ends (unknown until the server says).
    struct Run: Equatable {
        var phase: Engine.HistoryPhase
        var next: UInt64
        var end: UInt64?
    }

    /// How far a page moved its run, as the `.history` event reports it.
    struct Progress: Equatable {
        let phase: Engine.HistoryPhase
        let reached: UInt64
        let end: UInt64?
    }

    /// What follows a page: ask for this run's next page (the same run
    /// moved on, or the next one queued), or history has ended.
    enum Step: Equatable {
        case request(Run)
        case ended
    }

    /// A page taken: how far it moved its run, and what follows.
    typealias Page = (progress: Progress?, step: Step)

    private(set) var active: Run?
    private(set) var queued: [Run] = []
    /// Where history stands, and the next catch-up starts: every message
    /// below this server index has been handled, by a page of history or
    /// as it came live (`Setting.historyFrom`).
    var from: UInt64 = 0
    /// Indices handled as they came live above a gap at `from`, held until
    /// it fills. Only in memory: after a relaunch the catch-up fetches them
    /// again.
    private(set) var liveAbove: Set<UInt64> = []
    /// Past any real server index: a page or live message claiming one is
    /// the server's mistake, and moves nothing.
    private static let pastAnyIndex = UInt64(Int64.max)
    /// `getMsgsCounts` was asked for a restore and not yet answered.
    var awaitingCounts = false

    var isSyncing: Bool { awaitingCounts || active != nil || !queued.isEmpty }

    /// A restore: contacts first (one message per contact key, from which
    /// the core recreates each contact), then every message from the
    /// beginning. Empty when the server holds nothing.
    static func plan(_ counts: Engine.MessageCounts) -> [Run] {
        var runs: [Run] = []
        if counts.firstForEachKey > 0 {
            runs.append(Run(phase: .contacts, next: 0, end: counts.firstForEachKeyHighestIndex))
        }
        if counts.total > 0 {
            runs.append(Run(phase: .messages, next: 0, end: counts.totalHighestIndex))
        }
        return runs
    }

    /// Starts the first of `runs` and queues the rest, or queues them all
    /// behind the run in flight: all batch replies look alike, so two runs
    /// can never be in the air at once. The run to ask for now, if any.
    mutating func start(_ runs: [Run]) -> Run? {
        guard active == nil, let first = runs.first else {
            queued += runs
            return nil
        }
        active = first
        queued += runs.dropFirst()
        return first
    }

    /// Takes a page: the server indices of its messages (every one the
    /// server sent, read or not), and the total only history pages carry.
    /// Each page moves the run past its highest index; an empty page ends
    /// it. A page behind the cursor is a duplicate or a stale reply (pages
    /// carry no request ID) and is ignored. Nil with no run in flight, or
    /// for a page ignored. A messages page that starts no further than
    /// `from` moves it; a contacts page skips messages.
    mutating func advance(indices: [UInt64], total: UInt64?) -> Page? {
        guard var run = active else { return nil }
        run.end = run.end ?? total
        guard let reached = indices.max(), reached < Self.pastAnyIndex else {
            return (nil, finish())
        }
        guard reached >= run.next else { return nil }
        if run.phase == .messages, run.next <= from {
            from = max(from, reached + 1)
            liveAbove = liveAbove.filter { $0 >= from }
            takeLive()
        }
        run.next = reached + 1
        let progress = Progress(phase: run.phase, reached: reached, end: run.end)
        if let end = run.end, run.next > end {
            return (progress, finish())
        }
        active = run
        return (progress, .request(run))
    }

    /// A message handled as it came live, at server index `index`: `from`
    /// moves past it once every index below it is in.
    mutating func cameLive(_ index: UInt64) {
        guard index >= from, index < Self.pastAnyIndex else { return }
        liveAbove.insert(index)
        takeLive()
    }

    /// No page came for the run whose next index was `expected`: drops it
    /// and the queue, and returns it. Nil when that run has since moved on
    /// or ended.
    mutating func stalled(at expected: UInt64) -> Run? {
        guard let run = active, run.next == expected else { return nil }
        active = nil
        queued = []
        return run
    }

    /// `from` moved over the live indices that start at it.
    private mutating func takeLive() {
        while liveAbove.remove(from) != nil { from += 1 }
    }

    private mutating func finish() -> Step {
        active = nil
        guard !queued.isEmpty else { return .ended }
        let next = queued.removeFirst()
        active = next
        return .request(next)
    }
}
