import SwiftUI
import PeelCore
import PeelUI

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

    @State private var feed: PaymentsFeed
    @State private var pane: Pane?
    /// What the Pay pane holds, kept while it is closed and reopened.
    @State private var invoiceText = ""
    init(model: AppModel) {
        _feed = State(initialValue: PaymentsFeed(model: model))
    }

    private var items: [PaymentItem] { feed.items }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                DetailHeader(title: "Payments",
                             subtitle: model.waitingMsat > 0 ? "\(Sats.format(msat: model.waitingMsat)) waiting" : nil,
                             leading: { EmptyView() }) {
                    HStack(spacing: Theme.Space.sm) {
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
        .task(id: feed.paging.limit) { await feed.follow() }
        .task(id: feed.refreshTrigger) { await feed.refreshSoon() }
        // Seen only once the window is in front: until then the row keeps
        // its "+350" and the notification stays.
        .onChange(of: model.money.unseen.isEmpty == false && appearsActive, initial: true) { _, seeing in
            if seeing { feed.seeArrivals() }
        }
        .dropDestination(for: String.self) { texts, _ in
            guard let text = texts.first, (try? Invoice(text)) != nil else { return false }
            invoiceText = text.trimmed
            pane = .pay
            return true
        }
        .onExitCommand { pane = nil }
    }

    @ViewBuilder private var list: some View {
        if items.isEmpty {
            EmptyState(feed.problem ?? (model.connection == .connected ? "No payments yet." : "Not connected."))
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    let sections = Dictionary(grouping: items) { PaymentSection($0.date) }
                    ForEach(PaymentSection.allCases, id: \.self) { section in
                        if let rows = sections[section] {
                            SectionHeader(section.rawValue)
                                .padding(.horizontal, Theme.Space.md)
                                .padding(.top, 18)
                                .padding(.bottom, 6)
                            ForEach(rows) { item in
                                PaymentListRow(item: item, section: section, selected: pane == .detail(item.id),
                                               lit: feed.lit.contains(item.id)) {
                                    pane = pane == .detail(item.id) ? nil : .detail(item.id)
                                }
                                .onAppear { if item.id == items.last?.id { Task { await feed.loadOlder() } } }
                            }
                        }
                    }
                    if feed.loadingOlder || (feed.problem != nil && feed.paging.hasMore) {
                        HStack(spacing: Theme.Space.sm) {
                            if feed.loadingOlder { ProgressView().controlSize(.small) }
                            Text(feed.loadingOlder ? "Loading older payments" : feed.problem ?? "")
                                .muted()
                        }
                        .padding(Theme.Space.md)
                    }
                }
                .frame(maxWidth: 720, alignment: .leading)
                .padding(.horizontal, Theme.Space.sm)
                .padding(.bottom, Theme.Space.lg)
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
                    Text("This payment is gone.")
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
