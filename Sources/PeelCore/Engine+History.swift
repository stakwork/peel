import Foundation
import PeelDiagnostics
import Sphinxrs

extension Engine {
    /// True while a restore or catch-up is still asking the server for history.
    public var isSyncingHistory: Bool { history.isSyncing }

    /// True once history was fetched to the end on this connection without
    /// error or stall; false again on disconnect and when a run starts.
    public var isCaughtUp: Bool { catchUp.isCaughtUp }

    /// Whether `readAll` may be sent now (`CatchUpTracker.allowsReadAll`),
    /// read in one step so nothing moves between the checks.
    public func allowsReadAll(unread: Int) -> Bool {
        catchUp.allowsReadAll(
            syncing: history.isSyncing, highestIndex: try? storage.highestServerIndex(), unread: unread)
    }

    /// Picks history up where it stands; coming online does this, and so
    /// does Resume after a stall. An ask that does not leave pauses history
    /// again (`historyFailed`), so Resume is offered for it.
    public func resumeHistory(reason: DiagnosticEvent.CatchUpReason = .cameOnline) async throws {
        lastHistoryActivity = .now
        catchUpStarted = .now
        catchUpReason = reason
        Diagnostics.recordCatchUp(.start, reason: reason)
        Diagnostics.recordCatchUpCursor(from: history.from, next: history.active?.next ?? history.from, reason: reason)
        catchUp.begin(highestIndex: try? storage.highestServerIndex())
        emit.yield(.historyResumed(restart: history.active == nil && restoring))
        do {
            if let run = history.active {
                try await request(run)
            } else if restoring {
                history.awaitingCounts = true
                try await run { time, state in
                    try Sphinxrs.getMsgsCounts(seed: seed, uniqueTime: time, state: state)
                }
            } else {
                try await syncMessages()
            }
        } catch {
            let cancelled = Task.isCancelled || error is CancellationError
            // A failed ask must never leave a run set that nothing will answer
            // (no watchdog exists for it): the next resume plans again from
            // `history.from`. A restore keeps its run so it resumes.
            if cancelled || !restoring {
                history.abandon()
                stopHistoryWatchdog()
            }
            history.awaitingCounts = false
            if !cancelled { Diagnostics.recordCoreFailure(site: .resumeHistory, kind: reason.rawValue, detail: PeelError.readable(error)) }
            noteCatchUpEnd(cancelled ? .cancel : .abandon, reason: cancelled ? .cancelled : .error)
            emit.yield(.historyFailed(PeelError.readable(error)))
            throw error
        }
    }

    /// Records the end of the catch-up begun by `resumeHistory` (not finished), with its duration.
    func noteCatchUpEnd(_ stage: DiagnosticEvent.CatchUpStage, reason: DiagnosticEvent.CatchUpReason) {
        let took = catchUpStarted.map { ContinuousClock.now - $0 }
        catchUpStarted = nil
        Diagnostics.recordCatchUp(stage, reason: reason, milliseconds: took.map(Self.milliseconds(of:)))
    }

    static func milliseconds(of duration: Duration) -> Int {
        Int(duration.components.seconds * 1_000 + duration.components.attoseconds / 1_000_000_000_000_000)
    }

    /// Gives up the history in flight (nothing will answer it, or the app
    /// left the front), so a later catch-up asks again from where history stands.
    func abandonHistory(reason: DiagnosticEvent.CatchUpReason) {
        guard history.isSyncing else { return }
        history.abandon()
        stopHistoryWatchdog()
        noteCatchUpEnd(.abandon, reason: reason)
    }

    /// Asks the server for every message from where history stands
    /// (`HistoryCursor.from`): a catch-up cut short, by a quit or a stall,
    /// leaves nothing behind.
    public func syncMessages() async throws {
        if let run = history.start([HistoryCursor.Run(phase: .messages, next: history.from, end: nil)]) {
            try await request(run)
        }
    }

    /// Contacts first, then every message from the beginning
    /// (`HistoryCursor.plan`).
    func startRestore(_ counts: MessageCounts) async throws {
        let runs = HistoryCursor.plan(counts)
        guard !runs.isEmpty else {
            try await historyEnded()
            return
        }
        if let first = history.start(runs) {
            try await request(first)
        }
    }

    func request(_ run: HistoryCursor.Run) async throws {
        let asked = transport
        lastHistoryActivity = .now
        do {
            try await self.run { time, state in
                switch run.phase {
                case .contacts:
                    try Sphinxrs.fetchFirstMsgsPerKey(
                        seed: seed, uniqueTime: time, state: state,
                        lastMsgIdx: run.next, limit: Self.historyPageSize, reverse: false
                    )
                case .messages:
                    try Sphinxrs.fetchMsgsBatch(
                        seed: seed, uniqueTime: time, state: state,
                        lastMsgIdx: run.next, limit: Self.historyPageSize, reverse: false
                    )
                }
            }
        } catch {
            // The run was set before this ask and no watchdog is armed for
            // it: left set, it would look in flight for ever. A restore
            // keeps its run, so it resumes.
            if !restoring { history.abandon() }
            throw error
        }
        // Gone while asking: the next connection asks again (`cameOnline`).
        guard let asked, transport === asked else { return }
        // A page that never comes ends the run, so nothing waits forever.
        historyWatchdog?.cancel()
        let expected = run.next
        historyWatchdog = Task { [weak self] in
            try? await Task.sleep(for: Self.historyStall)
            guard !Task.isCancelled else { return }
            await self?.historyStalled(at: expected)
        }
    }

    /// History comes a page at a time; the cursor, moved when the page was
    /// committed (`HistoryCursor.advance`), says what follows each. A page
    /// it ignored never gets here, and leaves the watchdog waiting for the
    /// one asked for.
    func advanceHistory(_ page: HistoryCursor.Page) async throws {
        lastHistoryActivity = .now
        historyPages += 1
        if let progress = page.progress {
            emit.yield(.history(phase: progress.phase, reached: progress.reached, end: progress.end))
        }
        // The page came: its watchdog is done, and a next page gets its own.
        stopHistoryWatchdog()
        switch page.step {
        case .request(let run): try await request(run)
        case .ended: try await historyEnded()
        }
    }

    /// A page of history the core refuses whole, as it does when one message
    /// on it cannot be read (a malformed chunk fails the whole call): the
    /// core is given the page again without the messages it refuses
    /// (`readable`), which the result's error names. History still moves
    /// past the whole page, so one message can neither stop every catch-up
    /// nor take the rest of its page with it. A refusal of no message in
    /// particular (one of an empty page too) is thrown as it came.
    static func readablePart(of page: [Data], refusal: any Error, handle: (Data) throws -> RunReturn) throws -> RunReturn {
        guard var result = try? handle(StateCodec.batch([])) else { throw refusal }
        var kept = readable(page) { (try? handle(StateCodec.batch($0))) == nil }
        // What it reads apart it may still refuse together: then none of it.
        if let read = try? handle(StateCodec.batch(kept)) { result = read } else { kept = [] }
        let left = Set(page.map(StateCodec.index(of:))).subtracting(kept.map(StateCodec.index(of:))).sorted()
        if !left.isEmpty {
            let indices = left.map(String.init).joined(separator: ", ")
            result.error = "skipped messages in history that could not be read (server index \(indices)): \(PeelError.readable(refusal))"
        }
        return result
    }

    /// What of a page the core refused whole it reads: the page in halves,
    /// and each half it refuses in halves again, until each part it refuses
    /// is one message, left out.
    static func readable<Item>(_ refused: [Item], refuses: ([Item]) -> Bool) -> [Item] {
        guard refused.count > 1 else { return [] }
        let middle = refused.count / 2
        return [Array(refused[..<middle]), Array(refused[middle...])].flatMap { refuses($0) ? readable($0, refuses: refuses) : $0 }
    }

    private func historyEnded() async throws {
        if restoring {
            try storage.set("0", for: .needsRestore)
            restoring = false
            // Which tribes the restore left joined, and which left (a tribe missing after a restore).
            traceTribes()
            // The first ask came before the restore rebuilt the contacts, and
            // the core drops markers for contacts it does not know. Best
            // effort: the restore is done, and the next connection asks again.
            do {
                try await fetchReadsAndMutes()
            } catch {
                emit.yield(.coreError("reading restored read markers: \(PeelError.readable(error))"))
            }
            // Our restored sends carry no status (payments review F4): the
            // server's record of each, by its tag, says how it went.
            do {
                try await checkPendingSends()
            } catch {
                emit.yield(.coreError("checking restored payments: \(PeelError.readable(error))"))
            }
        }
        // After a restore the name and photo are recovered from the messages it replayed.
        recoverOwnProfile()
        // What came while away, checked against the server's history.
        reconcileInBackground()
        checkMentionsIfNeeded()
        emit.yield(.historyDone)
        catchUp.finish()
        // Caught up: whatever failed is past.
        catchUpRetries = 0
        noteCoreSuccess()
        // Caught up: nothing is left for the syncing watchdog to bound.
        syncWatchdog?.cancel()
        syncWatchdog = nil
        if let started = catchUpStarted {
            catchUpStarted = nil
            Diagnostics.recordCatchUp(.finish, reason: catchUpReason, milliseconds: Self.milliseconds(of: ContinuousClock.now - started))
        }
        if let connectedAt, !caughtUpNoted {
            caughtUpNoted = true
            let took = ContinuousClock.now - connectedAt
            Diagnostics.recordCaughtUp(milliseconds: Self.milliseconds(of: took))
        }
        emit.yield(.caughtUp)
    }

    /// The server keeps no profile; the account's own name and photo come back
    /// only on the messages it sent (its own direct messages; tribes rewrite
    /// the sender). Fills a name not set on this Mac from the newest of them,
    /// and a photo never set here (stored, even empty, means set or removed
    /// here and wins). Best effort: a failure here must not stop a restore
    /// finishing. Nothing found is not final (a restore's contacts or tribes
    /// may still be coming): it is retried after each history sync and on
    /// start, until the name is stored or found and the photo is too.
    func recoverOwnProfile() {
        guard !profileRecoveryDone else { return }
        var settled = true
        var changed = false
        if ((try? storage.value(for: .alias)) ?? nil)?.isEmpty ?? true {
            if let alias = try? storage.newestOwnAlias(), (try? setAlias(alias)) != nil { changed = true } else { settled = false }
        }
        if ((try? storage.value(for: .photoURL)) ?? nil) == nil {
            if let photo = try? storage.newestOwnPhotoURL(), (try? setPhotoURL(photo)) != nil { changed = true } else { settled = false }
        }
        // Last, with the final pair, so a listener never ends on a stale one.
        if changed { emit.yield(.profile(alias: alias, photoURL: myPhotoURL)) }
        if settled { profileRecoveryDone = true }
    }

    /// A page that never came: history pauses and says so (`historyFailed`,
    /// Resume), and the connection is dropped the way a failed ping drops
    /// it, so it connects again and `cameOnline` asks again by itself: a
    /// silent page usually means a connection that looks alive and is not.
    func historyStalled(at expected: UInt64) async {
        guard let run = history.stalled(at: expected) else { return }
        emit.yield(.historyFailed("no answer from the server for \(Self.historyStall.components.seconds) seconds while fetching \(run.phase)"))
        guard let stalled = transport else { return }
        // This is the watchdog: dropping the connection must not cancel the task doing it.
        historyWatchdog = nil
        Diagnostics.recordStallReconnect()
        await dropOnPurpose(stalled, reason: .stall)
    }
}
