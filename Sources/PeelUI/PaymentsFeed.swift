import Foundation
import Observation
import PeelCore
import SwiftUI

/// What the Payments screen shows, on the Mac and the iPhone: the stored
/// history, newest first, followed at `paging.limit`; its older pages as
/// the list's end comes into view; the newest page asked for again when
/// the balance moves or the connection comes back; and the payments
/// received since it was last seen, lit once as their rows appear.
///
///     .task(id: feed.paging.limit) { await feed.follow() }
///     .task(id: feed.refreshTrigger) { await feed.refreshSoon() }
///     row.onAppear { if row is last { Task { await feed.loadOlder() } } }
@MainActor @Observable
public final class PaymentsFeed {
    public private(set) var items: [PaymentItem] = []
    public private(set) var paging = PaymentPaging()
    public private(set) var loadingOlder = false
    public private(set) var problem: String?
    /// Rows just received, tinted for a moment the first time they show.
    public private(set) var lit: Set<String> = []

    @ObservationIgnored private let model: AppModel
    /// Received since Payments was last seen, lit once its row is in the list.
    @ObservationIgnored private var toLight: [Receipt] = []

    public init(model: AppModel) {
        self.model = model
    }

    /// Follows the stored history at the current limit, until cancelled.
    public func follow() async {
        do {
            guard let updates = model.paymentHistoryUpdates(limit: paging.limit) else { return }
            for try await rows in updates {
                items = rows
                lightArrived()
            }
        } catch {
            problem = PeelError.problem(error, couldNot: "load payments")
        }
    }

    /// What asks for the newest page again: the connection and the balance.
    public struct RefreshTrigger: Equatable {
        let connected: Bool
        let balanceMsat: UInt64?
    }

    public var refreshTrigger: RefreshTrigger {
        RefreshTrigger(connected: model.connection == .connected, balanceMsat: model.balanceMsat)
    }

    /// The trigger moved: connecting brings the balance a moment later, so
    /// changes within half a second make one refresh. Once begun, a fetch
    /// is never cancelled: the server's answer names no request, so a
    /// dropped one could be taken as the next fetch's answer.
    public func refreshSoon() async {
        guard (try? await Task.sleep(for: .milliseconds(500))) != nil else { return }
        Task { await refresh() }
    }

    /// The newest page again (also a pull to refresh). Waited for in a task
    /// of its own, so it is never cancelled once begun.
    public func refresh() async {
        await Task { [model] in
            guard model.connection == .connected else { return }
            do {
                try await model.refreshPaymentHistory()
                self.problem = nil
            } catch {
                // Another fetch is running, or the server is slow: the next change asks again.
            }
        }.value
    }

    /// The end of the list is in view: a page more of what is stored,
    /// offline too, and while connected the server's next older page,
    /// which fills the raised limit as it is stored.
    public func loadOlder() async {
        paging.reachedEnd(showing: items.count)
        guard paging.hasMore, !loadingOlder, model.connection == .connected else { return }
        loadingOlder = true
        defer { loadingOlder = false }
        do {
            paging.fetched(try await model.fetchOlderPayments())
        } catch {
            problem = PeelError.problem(error, couldNot: "load older payments")
        }
    }

    /// Payments is in front: what was received since it was last seen is
    /// no longer unseen, its notifications go, and its rows light once.
    public func seeArrivals() {
        guard !model.money.unseen.isEmpty else { return }
        toLight += model.money.takeUnseen()
        model.notifier.removeDelivered(in: [Notifier.paymentsThread])
        lightArrived()
    }

    /// Lights the rows of payments received since Payments was last seen,
    /// once each, fading as the list settles (as a jump to a message does).
    private func lightArrived() {
        guard !toLight.isEmpty else { return }
        var rows: Set<String> = []
        toLight.removeAll { receipt in
            guard let item = items.first(where: receipt.matches) else { return false }
            rows.insert(item.id)
            return true
        }
        guard !rows.isEmpty else { return }
        lit.formUnion(rows)
        Task {
            try? await Task.sleep(for: .seconds(0.4))
            withAnimation(.easeOut(duration: 1.5)) { lit.subtract(rows) }
        }
    }
}
