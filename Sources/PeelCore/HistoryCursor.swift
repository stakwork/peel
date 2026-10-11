import Foundation

/// The history machine without the network: the run in flight, the runs
/// queued behind it, and whether a restore is waiting for the server's
/// counts. The engine asks for the pages it names and feeds it each one
/// (`Engine+History`).
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

    private(set) var active: Run?
    private(set) var queued: [Run] = []
    /// The highest server index history has been fetched through with no
    /// gap (`Setting.historyIndex`): a catch-up starts after it. Only a
    /// messages run that started there moves it, never a live message.
    var through: UInt64?
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
    /// for a page ignored.
    mutating func advance(indices: [UInt64], total: UInt64?) -> (progress: Progress?, step: Step)? {
        guard var run = active else { return nil }
        run.end = run.end ?? total
        guard let reached = indices.max(), reached < UInt64(Int64.max) else {
            return (nil, finish())
        }
        guard reached >= run.next else { return nil }
        if run.phase == .messages, run.next <= through.map({ $0 + 1 }) ?? 0 {
            through = max(through ?? reached, reached)
        }
        run.next = reached + 1
        let progress = Progress(phase: run.phase, reached: reached, end: run.end)
        if let end = run.end, run.next > end {
            return (progress, finish())
        }
        active = run
        return (progress, .request(run))
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

    private mutating func finish() -> Step {
        active = nil
        guard !queued.isEmpty else { return .ended }
        let next = queued.removeFirst()
        active = next
        return .request(next)
    }
}
