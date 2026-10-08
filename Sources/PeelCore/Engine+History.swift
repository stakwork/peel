import Foundation
import Sphinxrs

extension Engine {
    /// True while a restore or catch-up is still asking the server for history.
    public var isSyncingHistory: Bool {
        awaitingCounts || history != nil || !queuedHistory.isEmpty
    }

    /// Asks the server for messages newer than the newest one stored locally.
    public func syncMessages() async throws {
        // Messages dropped from left tribes are not stored but still count.
        let highest = max(try storage.highestServerIndex() ?? -1, droppedIndex)
        let next = highest < 0 ? 0 : UInt64(highest) + 1
        try await startHistory(HistoryRun(phase: .messages, next: next, end: nil))
    }

    /// Contacts first (one message per contact key, from which the core
    /// recreates each contact), then every message from the beginning.
    func startRestore(_ counts: MessageCounts) async throws {
        var runs: [HistoryRun] = []
        if counts.firstForEachKey > 0 {
            runs.append(HistoryRun(phase: .contacts, next: 0, end: counts.firstForEachKeyHighestIndex))
        }
        if counts.total > 0 {
            runs.append(HistoryRun(phase: .messages, next: 0, end: counts.totalHighestIndex))
        }
        guard let first = runs.first else {
            try await historyEnded()
            return
        }
        queuedHistory.append(contentsOf: runs.dropFirst())
        try await startHistory(first)
    }

    /// Starts a run, or queues it behind the one in flight: all batch replies
    /// look alike, so two runs can never be in the air at once.
    private func startHistory(_ run: HistoryRun) async throws {
        guard history == nil else {
            queuedHistory.append(run)
            return
        }
        history = run
        try await request(run)
    }

    func request(_ run: HistoryRun) async throws {
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
        // A page that never comes ends the run, so nothing waits forever.
        historyWatchdog?.cancel()
        let expected = run.next
        historyWatchdog = Task { [weak self] in
            try? await Task.sleep(for: Self.historyStall)
            guard !Task.isCancelled else { return }
            await self?.historyStalled(at: expected)
        }
    }

    /// History comes a page at a time. Each page moves the cursor past its
    /// highest index; a page that moves it nowhere ends the run, so an
    /// unreadable message cannot cause an endless loop.
    func advanceHistory(with result: RunReturn) async throws {
        guard var run = history else { return }
        run.end = run.end ?? result.msgsTotal
        let reached = result.msgs.compactMap { $0.index.flatMap { UInt64($0) } }.max()
        guard let reached, reached >= run.next, reached < UInt64(Int64.max) else {
            try await finish(run)
            return
        }
        run.next = reached + 1
        emit.yield(.history(phase: run.phase, reached: reached, end: run.end))
        if let end = run.end, run.next > end {
            try await finish(run)
            return
        }
        history = run
        try await request(run)
    }

    private func finish(_ run: HistoryRun) async throws {
        historyWatchdog?.cancel()
        history = nil
        if !queuedHistory.isEmpty {
            try await startHistory(queuedHistory.removeFirst())
        } else {
            try await historyEnded()
        }
    }

    private func historyEnded() async throws {
        if restoring {
            try storage.set("0", for: .needsRestore)
            restoring = false
            recoverOwnPhoto()
            // The first ask came before the restore rebuilt the contacts, and
            // the core drops markers for contacts it does not know.
            try await fetchReadsAndMutes()
        }
        checkMentionsIfNeeded()
        emit.yield(.historyDone)
    }

    /// The server keeps no profile; the account's own photo comes back only
    /// on the messages it sent (its own direct messages; tribes rewrite the
    /// sender). Fills a photo never set on this Mac from the newest of them;
    /// one set or removed here (stored, even empty) wins. Best effort, once
    /// per engine: a failure here must not stop a restore finishing.
    func recoverOwnPhoto() {
        guard !photoRecoveryDone else { return }
        photoRecoveryDone = true
        if (try? storage.value(for: .photoURL)) ?? nil == nil, let photo = try? storage.newestOwnPhotoURL() {
            try? setPhotoURL(photo)
        }
    }

    private func historyStalled(at expected: UInt64) {
        guard let run = history, run.next == expected else { return }
        history = nil
        queuedHistory = []
        emit.yield(.historyFailed("no answer from the server for \(Self.historyStall) while fetching \(run.phase)"))
    }
}
