import Foundation
import Sphinxrs

extension Engine {
    /// True while a restore or catch-up is still asking the server for history.
    public var isSyncingHistory: Bool { history.isSyncing }

    /// Asks the server for messages newer than the newest one stored locally.
    public func syncMessages() async throws {
        // Messages dropped from left tribes are not stored but still count.
        let highest = max(try storage.highestServerIndex() ?? -1, droppedIndex)
        let next = highest < 0 ? 0 : UInt64(highest) + 1
        if let run = history.start([HistoryCursor.Run(phase: .messages, next: next, end: nil)]) {
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

    /// History comes a page at a time; the cursor says what follows each
    /// (`HistoryCursor.advance`).
    func advanceHistory(with result: RunReturn) async throws {
        let indices = result.msgs.compactMap { $0.index.flatMap { UInt64($0) } }
        guard let page = history.advance(indices: indices, total: result.msgsTotal) else { return }
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

    private func historyEnded() async throws {
        if restoring {
            try storage.set("0", for: .needsRestore)
            restoring = false
            recoverOwnPhoto()
            // The first ask came before the restore rebuilt the contacts, and
            // the core drops markers for contacts it does not know.
            try await fetchReadsAndMutes()
            // Our restored sends carry no status (payments review F4): the
            // server's record of each, by its tag, says how it went.
            do {
                try await checkPendingSends()
            } catch {
                emit.yield(.coreError("checking restored payments: \(PeelError.readable(error))"))
            }
        }
        // What came while away, checked against the server's history.
        reconcileInBackground()
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
        guard let run = history.stalled(at: expected) else { return }
        emit.yield(.historyFailed("no answer from the server for \(Self.historyStall) while fetching \(run.phase)"))
    }
}
