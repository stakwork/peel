import SwiftUI
import PeelCore
import PeelUI

// MARK: - The screen

/// Payments (Tom, 2026-11-27; the board's "Payments as a column"): the
/// history as a column beside the rail, as the chat list is on Chats, and
/// beside it the wallet: the balance with Deposit and Withdraw, whose forms
/// open as a card under them (`PaneStyle.card`), or a payment's details
/// when one is picked. Older pages load as the list scrolls; ⌃⌘S puts the
/// list away; an invoice dropped on the window opens Withdraw.
struct PaymentsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.appearsActive) private var appearsActive
    /// MainView's: where the page's header starts when it starts at the rail.
    @Environment(\.headerLeadingInset) private var pageInset
    /// The chat list's width, so the column's edge holds still going between them.
    @AppStorage("sidebarWidth") private var columnWidth: Double = 260
    /// The list put away (⌃⌘S, `ColumnToggle`): the wallet full width.
    @AppStorage("paymentsListHidden") private var listHidden = false

    enum Pane: Equatable {
        case detail(String)
        case receive
        case pay
    }

    @State private var feed: PaymentsFeed
    @State private var pane: Pane?
    /// What Withdraw holds, kept while it is closed and reopened.
    @State private var invoiceText = ""
    init(model: AppModel) {
        _feed = State(initialValue: PaymentsFeed(model: model))
    }

    private var items: [PaymentItem] { feed.items }

    var body: some View {
        HStack(spacing: 0) {
            if !listHidden {
                VStack(spacing: 0) {
                    ColumnHeader(title: String(localized: "Payments")) { EmptyView() }
                    list
                }
                .frame(width: columnWidth)
                .background(Theme.sidebar)
                PaneDivider(width: $columnWidth, range: 220...420, standard: 260, growsTo: .trailing)
            }
            Group {
                if case .detail(let id) = pane {
                    detail(id)
                } else {
                    wallet
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .environment(\.headerLeadingInset, listHidden ? pageInset : 0)
        }
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

    /// The balance, Deposit and Withdraw, and the open one's form under them.
    private var wallet: some View {
        VStack(spacing: 0) {
            DetailHeader(title: String(localized: "Wallet"))
            ScrollView {
                VStack(spacing: Theme.Space.lg) {
                    VStack(spacing: 4) {
                        Text("Balance")
                            .font(Theme.font(12))
                            .foregroundStyle(Theme.tertiaryText)
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(model.money.shownMsat.map { Sats.number(msat: $0) } ?? "–")
                                .font(Theme.font(44, .bold))
                                .monospacedDigit()
                            Text("sats")
                                .font(Theme.font(18, .medium))
                                .foregroundStyle(Theme.secondaryText)
                        }
                    }
                    HStack(spacing: Theme.Space.sm) {
                        WalletButton(title: String(localized: "Deposit"), systemImage: "arrow.down", primary: true,
                                     open: pane == .receive) { pane = pane == .receive ? nil : .receive }
                        WalletButton(title: String(localized: "Withdraw"), systemImage: "arrow.up", primary: false,
                                     open: pane == .pay) { pane = pane == .pay ? nil : .pay }
                    }
                    Group {
                        if pane == .receive {
                            ReceivePane { pane = nil }
                        } else if pane == .pay {
                            PayInvoicePane(text: $invoiceText, history: items, show: { pane = .detail($0) },
                                           receive: { pane = .receive }) { pane = nil }
                        }
                    }
                    .environment(\.paneStyle, .card)
                }
                .frame(maxWidth: 440)
                .padding(.top, 70)
                .padding(.bottom, Theme.Space.xl)
                .frame(maxWidth: .infinity)
            }
        }
    }

    /// A payment picked in the list, beside it; its close goes back to the wallet.
    @ViewBuilder private func detail(_ id: String) -> some View {
        if let item = items.first(where: { $0.id == id }) {
            PaymentDetailPane(item: item) { pane = nil }
        } else {
            PaneFrame(title: String(localized: "Payment"), close: { pane = nil }) {
                Text("This payment is gone.")
                    .font(Theme.font(13))
                    .foregroundStyle(Theme.secondaryText)
            }
        }
    }

    @ViewBuilder private var list: some View {
        if items.isEmpty {
            EmptyState(feed.problem ?? (model.connection == .connected ? String(localized: "No payments yet.") : String(localized: "Not connected.")))
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    let sections = Dictionary(grouping: items) { PaymentSection($0.date) }
                    ForEach(PaymentSection.allCases, id: \.self) { section in
                        if let rows = sections[section] {
                            SectionHeader(section.title)
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
                            Text(feed.loadingOlder ? String(localized: "Loading older payments") : feed.problem ?? "")
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
                LinearGradient(colors: [Theme.sidebar.opacity(0), Theme.sidebar], startPoint: .top, endPoint: .bottom)
                    .frame(height: 28)
                    .allowsHitTesting(false)
            }
        }
    }
}

/// Deposit and Withdraw under the balance: Deposit filled, Withdraw
/// outlined, each ringed while its form is open below.
private struct WalletButton: View {
    let title: String
    let systemImage: String
    let primary: Bool
    let open: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .frame(minWidth: 120)
        }
        .buttonStyle(.peel(primary ? .primary : .outline))
        .overlay {
            if open {
                RoundedRectangle(cornerRadius: Theme.Radius.control + 3, style: .continuous)
                    .strokeBorder(Theme.accent.opacity(0.5), lineWidth: 3)
                    .padding(-3)
                    .allowsHitTesting(false)
            }
        }
    }
}
