import Foundation
import PeelCore

/// The Mac's "this account is being used here" lease (`Engine.setDeviceActive`,
/// `Platform.sendsActiveLease`): while it holds the server sends the other
/// devices badge-only pushes. The iPhone never runs it. The lease is the
/// server's default length, so it is renewed every `interval` while the
/// person is in front of an unlocked, connected Peel, and ended (best effort,
/// capped at `cap`) when any of that stops.
@MainActor
final class ActiveLease {
    /// How often the lease is renewed while it holds.
    nonisolated static let interval: Duration = .seconds(25)
    /// The most time ending it (or forgetting the account) may wait on the network.
    nonisolated static let cap: Duration = .seconds(3)

    /// Whether the lease should be held: Peel in front (and the Mac awake),
    /// the account open and not locked or about to lock, and online.
    nonisolated static func shouldBeActive(isActive: Bool, phase: AppModel.Phase, lockDue: Bool, connected: Bool) -> Bool {
        isActive && phase == .ready && !lockDue && connected
    }

    /// Peel is in front, as the app last said.
    var isForeground = false
    /// The Mac is asleep.
    var asleep = false
    private var task: Task<Void, Never>?

    var isRunning: Bool { task != nil }

    /// Sends `true` now and every `interval` after, until `stillWanted`
    /// says no (the loop ends; the model ends the lease) or `stop`.
    func start(
        engine: Engine, stillWanted: @escaping @MainActor () -> Bool
    ) {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled, stillWanted() {
                try? await engine.setDeviceActive(true)
                try? await Task.sleep(for: Self.interval)
            }
            if !Task.isCancelled { self?.task = nil }
        }
    }

    /// Ends the renewals.
    func stop() {
        task?.cancel()
        task = nil
    }

    /// `active = false`, best effort and never longer than `cap`.
    nonisolated static func sendInactive(through engine: Engine) async {
        await BestEffort.run(within: cap) { try await engine.setDeviceActive(false) }
    }
}

/// An operation that may not block or fail what follows it.
enum BestEffort {
    /// Runs `operation`, swallowing its error, and gives up after `limit`.
    static func run(within limit: Duration, _ operation: @escaping @Sendable () async throws -> Void) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { try? await operation() }
            group.addTask { try? await Task.sleep(for: limit) }
            await group.next()
            group.cancelAll()
        }
    }
}

extension AppModel {
    /// Works out whether the lease should be held now and starts or ends it.
    /// Called wherever one of its inputs may have changed. Does nothing on a
    /// platform that does not send it.
    func updateActiveLease() {
        guard platform.sendsActiveLease else { return }
        let wanted = leaseWanted
        if wanted, !activeLease.isRunning, let engine {
            activeLease.start(engine: engine) { [weak self] in self?.leaseWanted == true }
        } else if !wanted, activeLease.isRunning {
            activeLease.stop()
            if let engine { Task { await ActiveLease.sendInactive(through: engine) } }
        }
    }

    private var leaseWanted: Bool {
        ActiveLease.shouldBeActive(
            isActive: activeLease.isForeground && !activeLease.asleep, phase: phase, lockDue: isLockDue,
            connected: connection == .connected)
    }

    /// The Mac is going to sleep: the lease ends.
    public func systemWillSleep() {
        activeLease.asleep = true
        updateActiveLease()
    }

    /// The Mac woke: the lease is worked out again.
    public func systemDidWake() {
        activeLease.asleep = false
        updateActiveLease()
    }

    /// Ends the lease for good before the account goes or Peel quits, waiting
    /// at most `ActiveLease.cap`. Not for the main actor to await on quit:
    /// see `willTerminate`.
    func endActiveLease() async {
        guard platform.sendsActiveLease else { return }
        activeLease.stop()
        if let engine { await ActiveLease.sendInactive(through: engine) }
    }

    /// Forget: the push token comes off the server under the app ID it was
    /// registered with, and the lease ends, together within `ActiveLease.cap`,
    /// before the engine closes. Never throws or waits longer.
    func releaseWithServer() async {
        activeLease.stop()
        guard let engine else { return }
        let appID = platform.pushAppID()
        let leased = platform.sendsActiveLease
        await BestEffort.run(within: ActiveLease.cap) {
            if leased { try? await engine.setDeviceActive(false) }
            if let appID { _ = try? await engine.unregisterPush(appID: appID) }
        }
    }

    /// Quit: ends the lease, blocking the main thread for at most
    /// `ActiveLease.cap` so the message leaves before the process does.
    func endActiveLeaseOnQuit() {
        guard platform.sendsActiveLease, activeLease.isRunning, let engine else { return }
        activeLease.stop()
        let done = DispatchSemaphore(value: 0)
        // .userInitiated to match the blocked waiter below (avoids priority inversion).
        Task.detached(priority: .userInitiated) {
            await ActiveLease.sendInactive(through: engine)
            done.signal()
        }
        _ = done.wait(timeout: .now() + 3)
    }

    // MARK: Read all

    /// Once the local unread count is 0, tells the server everything is read
    /// so a badge count the mixer kept too high resets (`ReadAllGate`: once
    /// per session and per 30 minutes). Waits for an open, unlocked, connected
    /// account whose reads have loaded and whose restore is over.
    func markEverythingReadIfClear() {
        guard phase == .ready, !isLockDue, connection == .connected, !restoreProgress.restoring,
            !readStates.isEmpty, unreadCount == 0, let engine,
            readAllGate.allows(now: .now)
        else { return }
        let defaults = UserDefaults.standard
        guard readAllGate.claim(now: .now, defaults: defaults) else { return }
        Task { try? await engine.markEverythingRead() }
    }
}
