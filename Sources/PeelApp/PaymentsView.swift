import SwiftUI
import PeelCore

// MARK: - The screen

/// Payment history in one plain list grouped by time, newest first, with
/// Receive and Pay an invoice in the header. A payment's detail, Receive
/// and Pay open in the pane on the right. Older pages load as the list
/// scrolls; an invoice dropped on the window opens Pay.
struct PaymentsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.appearsActive) private var appearsActive

    enum Pane: Equatable {
        case detail(String)
        case receive
        case pay
    }

    @State private var items: [PaymentItem] = []
    @State private var limit = Int(Engine.paymentPageSize)
    @State private var hasMore = true
    @State private var loadingOlder = false
    @State private var problem: String?
    @State private var pane: Pane?
    /// What the Pay pane holds, kept while it is closed and reopened.
    @State private var invoiceText = ""
    /// Received since Payments was last open, lit once when its row is in the list.
    @State private var toLight: [Receipt] = []
    @State private var lit: Set<String> = []

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                DetailHeader(title: "Payments", subtitle: "Amounts in sats" + (model.waitingText.map { " · \($0)" } ?? ""),
                             leading: { EmptyView() }) {
                    HStack(spacing: 8) {
                        HeaderAction(title: "Receive", systemImage: "arrow.down.left", active: pane == .receive) {
                            pane = pane == .receive ? nil : .receive
                        }
                        HeaderAction(title: "Pay an invoice", systemImage: "arrow.up.right", active: pane == .pay) {
                            pane = pane == .pay ? nil : .pay
                        }
                    }
                }
                list
            }
            .frame(minWidth: 380, maxWidth: .infinity)
            if let pane {
                Theme.divider.frame(width: 1)
                paneView(pane)
                    .frame(width: 360)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .background(Theme.panel)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: pane == nil)
        .task(id: limit) {
            do {
                guard let updates = model.paymentHistoryUpdates(limit: limit) else { return }
                for try await rows in updates {
                    items = rows
                    lightArrived()
                }
            } catch {
                problem = PeelError.problem(error, couldNot: "load payments")
            }
        }
        // Connecting brings the balance a moment later, so changes within
        // half a second make one refresh. Once begun, a fetch is never
        // cancelled: the server's answer names no request, so a dropped one
        // could be taken as the next fetch's answer.
        .task(id: RefreshTrigger(connected: model.connection == .connected, balanceMsat: model.balanceMsat)) {
            guard (try? await Task.sleep(for: .milliseconds(500))) != nil else { return }
            Task { await refresh() }
        }
        // Seen only once the window is in front: until then the row keeps
        // its "+350" and the notification stays.
        .onChange(of: model.money.unseen.isEmpty == false && appearsActive, initial: true) { _, seeing in
            guard seeing else { return }
            toLight += model.money.takeUnseen()
            model.notifier.removeDelivered(in: [Notifier.paymentsThread])
            lightArrived()
        }
        .dropDestination(for: String.self) { texts, _ in
            guard let text = texts.first, (try? Invoice(text)) != nil else { return false }
            invoiceText = text.trimmed
            pane = .pay
            return true
        }
        .onExitCommand { pane = nil }
    }

    private struct RefreshTrigger: Equatable {
        let connected: Bool
        let balanceMsat: UInt64?
    }

    /// The newest page again: the balance moved or the connection came back.
    private func refresh() async {
        guard model.connection == .connected else { return }
        do {
            try await model.refreshPaymentHistory()
            problem = nil
        } catch {
            // Another fetch is running, or the server is slow: the next change asks again.
        }
    }

    /// Lights the rows of payments received since Payments was last open,
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

    /// The end of the list is in view: a page more of what is stored, offline
    /// too, and while connected the server's next older page, which fills
    /// the raised limit as it is stored.
    private func loadOlder() async {
        // At most a page past what shows, so the end of what is stored
        // stops raising it. Not `items.count >= limit`: pings folded into
        // their payments leave a full page a row or two short.
        let page = Int(Engine.paymentPageSize)
        if limit - items.count < page { limit += page }
        guard hasMore, !loadingOlder, model.connection == .connected else { return }
        loadingOlder = true
        defer { loadingOlder = false }
        do {
            let count = try await model.fetchOlderPayments()
            hasMore = count >= page
        } catch {
            problem = PeelError.problem(error, couldNot: "load older payments")
        }
    }

    @ViewBuilder private var list: some View {
        if items.isEmpty {
            EmptyState(problem ?? (model.connection == .connected ? "Payments you send and receive show up here."
                : "Payments show up here once Peel is connected."))
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    let sections = Dictionary(grouping: items) { PaymentSection($0.date) }
                    ForEach(PaymentSection.allCases, id: \.self) { section in
                        if let rows = sections[section] {
                            SectionHeader(section.rawValue)
                                .padding(.horizontal, 12)
                                .padding(.top, 18)
                                .padding(.bottom, 6)
                            ForEach(rows) { item in
                                PaymentListRow(item: item, section: section, selected: pane == .detail(item.id),
                                               lit: lit.contains(item.id)) {
                                    pane = pane == .detail(item.id) ? nil : .detail(item.id)
                                }
                                .onAppear { if item.id == items.last?.id { Task { await loadOlder() } } }
                            }
                        }
                    }
                    if loadingOlder || (problem != nil && hasMore) {
                        HStack(spacing: 8) {
                            if loadingOlder { ProgressView().controlSize(.small) }
                            Text(loadingOlder ? "Loading older payments" : problem ?? "")
                                .font(Theme.font(12))
                                .foregroundStyle(Theme.secondaryText)
                        }
                        .padding(12)
                    }
                }
                .frame(maxWidth: 720, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.bottom, 16)
            }
            .overlay(alignment: .bottom) {
                // More below: the list fades out rather than stopping at an edge.
                LinearGradient(colors: [Theme.background.opacity(0), Theme.background], startPoint: .top, endPoint: .bottom)
                    .frame(height: 28)
                    .allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder private func paneView(_ pane: Pane) -> some View {
        switch pane {
        case .detail(let id):
            if let item = items.first(where: { $0.id == id }) {
                PaymentDetailPane(item: item) { self.pane = nil }
            } else {
                PaneFrame(title: "Payment", close: { self.pane = nil }) {
                    Text("This payment is no longer in the list.")
                        .font(Theme.font(13))
                        .foregroundStyle(Theme.secondaryText)
                }
            }
        case .receive:
            ReceivePane { self.pane = nil }
        case .pay:
            PayInvoicePane(text: $invoiceText, history: items, show: { self.pane = .detail($0) }, receive: {
                self.pane = .receive
            }) { self.pane = nil }
        }
    }
}

/// The small buttons in the Payments header: outline, secondary (lit) while
/// their pane is open.
private struct HeaderAction: View {
    let title: String
    let systemImage: String
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .semibold))
                Text(title)
            }
        }
        .buttonStyle(.peel(active ? .secondary : .outline, size: .sm))
    }
}
