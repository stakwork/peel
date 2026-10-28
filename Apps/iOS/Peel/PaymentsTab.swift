import PeelCore
import PeelUI
import SwiftUI

/// Payments (docs/design/iphone.md, screen 6): the large title, the balance,
/// Receive and Send, then the history by day, newest first. Older pages load
/// as the list nears its end (`PaymentPaging`, as on the Mac); pull to
/// refresh asks the server for what is new. Payments received since it was
/// last shown are lit once, with a success haptic when one lands while it is
/// open. A row pushes its detail.
struct PaymentsTab: View {
    @Environment(AppModel.self) private var model
    @Environment(PhoneRouter.self) private var router
    @Environment(\.scenePhase) private var scenePhase

    enum Sheet: String, Identifiable {
        case receive, send
        var id: String { rawValue }
    }

    @State private var feed: PaymentsFeed
    @State private var sheet: Sheet?

    init(model: AppModel) {
        _feed = State(initialValue: PaymentsFeed(model: model))
    }

    private var items: [PaymentItem] { feed.items }

    var body: some View {
        @Bindable var router = router
        NavigationStack(path: $router.payments) {
            List {
                Section {
                    BalanceHeader(receive: { sheet = .receive }, send: { sheet = .send })
                        .listRowInsets(EdgeInsets(top: 0, leading: Theme.phoneGutter, bottom: Theme.Space.sm, trailing: Theme.phoneGutter))
                        .listRowSeparator(.hidden)
                }
                .phoneRows()
                history
            }
            .phoneList()
            .scrollEdges()
            .refreshable { await feed.refresh() }
            .onCallBannerInset()
            .navigationTitle("Payments")
            .navigationDestination(for: PaymentsRoute.self) { route in
                switch route {
                case .payment(let id): PaymentDetailScreen(item: items.first { $0.id == id })
                }
            }
        }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .receive: ReceiveSheet()
            case .send: SendSheet(history: items, receive: { self.sheet = .receive })
            }
        }
        .task(id: feed.paging.limit) { await feed.follow() }
        .task(id: feed.refreshTrigger) { await feed.refreshSoon() }
        // Seen only while Payments is on screen and Peel in front: until
        // then the tab keeps its "+350" and the notification stays.
        .onChange(of: !model.money.unseen.isEmpty && showing, initial: true) { _, seeing in
            if seeing { feed.seeArrivals() }
        }
        .sensoryFeedback(.success, trigger: model.money.arrivals) { _, _ in showing }
    }

    private var showing: Bool { router.tab == .payments && scenePhase == .active }

    /// The days, newest first, each under its heading.
    @ViewBuilder private var history: some View {
        if items.isEmpty {
            Section {
                Text(feed.problem ?? (model.connection == .connected ? "No payments yet." : "Not connected."))
                    .phoneFont(.row)
                    .foregroundStyle(Theme.tertiaryText)
                    .padding(.vertical, Theme.Space.lg)
                    .listRowSeparator(.hidden)
            }
            .phoneRows()
        } else {
            ForEach(days, id: \.day) { group in
                Section {
                    ForEach(group.items) { item in
                        NavigationLink(value: PaymentsRoute.payment(item.id)) {
                            PaymentRow(item: item)
                        }
                        .listRowBackground(feed.lit.contains(item.id) ? Theme.confirmed.opacity(0.14) : Theme.background)
                        .onAppear { if item.id == items.last?.id { Task { await feed.loadOlder() } } }
                    }
                } header: {
                    PhoneSectionHeader(Formatting.dayHeading(group.day))
                }
                .phoneRows()
            }
            if feed.loadingOlder || (feed.problem != nil && feed.paging.hasMore) {
                Section {
                    HStack(spacing: Theme.Space.sm) {
                        if feed.loadingOlder { ProgressView() }
                        Text(feed.loadingOlder ? "Loading older payments" : feed.problem ?? "")
                            .phoneFont(.secondary)
                            .foregroundStyle(Theme.tertiaryText)
                    }
                    .listRowSeparator(.hidden)
                }
                .phoneRows()
            }
        }
    }

    /// The items by calendar day, in the list's order (newest first).
    private var days: [(day: Date, items: [PaymentItem])] {
        let calendar = Calendar.current
        var days: [(day: Date, items: [PaymentItem])] = []
        for item in items {
            let day = calendar.startOfDay(for: item.date)
            if days.last?.day == day { days[days.count - 1].items.append(item) } else { days.append((day, [item])) }
        }
        return days
    }
}

/// "Balance", the amount (40 bold, tabular) with "sats", what is waiting on
/// people offline, then Receive (outline, left) and Send (filled, right).
struct BalanceHeader: View {
    @Environment(AppModel.self) private var model
    @ScaledMetric(relativeTo: .largeTitle) private var amountSize: CGFloat = 40
    @ScaledMetric(relativeTo: .body) private var buttonHeight: CGFloat = 48
    let receive: () -> Void
    let send: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.lg) {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text("Balance")
                    .phoneFont(.secondary)
                    .foregroundStyle(Theme.tertiaryText)
                BigAmount(amount: model.balanceMsat.map { Sats.number(msat: $0) } ?? "–", size: amountSize,
                          unitSize: amountSize * 17 / 40, spacing: 6)
                    .foregroundStyle(Theme.text)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Balance")
                    .accessibilityValue(model.balanceMsat.map { Sats.format(msat: $0) } ?? "not known yet")
                if model.waitingMsat > 0 {
                    Text("\(Sats.format(msat: model.waitingMsat)) waiting for people to come online")
                        .phoneFont(.secondary)
                        .monospacedDigit()
                        .foregroundStyle(Theme.tertiaryText)
                }
            }
            HStack(spacing: 10) {
                Button(action: receive) {
                    Label("Receive", systemImage: "arrow.down").frame(maxWidth: .infinity, minHeight: buttonHeight)
                }
                .buttonStyle(.peel(.outline, size: .touch))
                Button(action: send) {
                    Label("Send", systemImage: "arrow.up").frame(maxWidth: .infinity, minHeight: buttonHeight)
                }
                .buttonStyle(.peel(.primary, size: .touch))
            }
        }
        .padding(.top, Theme.Space.sm)
    }
}

/// One payment (the Mac's `PaymentListRow`, as the board draws it): the
/// bolt on a soft orange circle (a clock on grey while it waits), who or
/// what, the note under it, and the signed amount over the time, both
/// tabular. Received is green with "+"; pending grey, failed struck
/// through, never red. At accessibility sizes the amount goes under.
struct PaymentRow: View {
    let item: PaymentItem
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .body) private var amountSize: CGFloat = 15
    @ScaledMetric(relativeTo: .body) private var icon: CGFloat = 36

    var body: some View {
        HStack(spacing: Theme.Space.md) {
            mark
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    words
                    amount(alignment: .leading)
                }
                Spacer(minLength: 0)
            } else {
                words
                Spacer(minLength: Theme.Space.sm)
                amount(alignment: .trailing)
            }
        }
        .padding(.vertical, 5)
        .frame(minHeight: Theme.touchTarget)
        .accessibilityElement(children: .combine)
    }

    private var waiting: Bool { item.status == .pending || item.status == .unsettled }

    private var mark: some View {
        Image(systemName: waiting ? "clock" : "bolt.fill")
            .font(.system(size: icon * 0.42, weight: .semibold))
            .foregroundStyle(waiting ? Theme.secondaryText : Theme.attention)
            .frame(width: icon, height: icon)
            .background(waiting ? Theme.fieldFill : Theme.attention.opacity(0.14), in: Circle())
            .accessibilityHidden(true)
    }

    private var words: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.title)
                .phoneFont(PhoneFont(size: 15, weight: .semibold, style: .body))
                .foregroundStyle(waiting ? Theme.secondaryText : Theme.text)
                .lineLimit(1)
            Text(item.subtitle)
                .phoneFont(.secondary)
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
        }
    }

    private func amount(alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 2) {
            SignedAmount(msat: item.amountMsat, incoming: item.incoming, status: item.status, size: amountSize)
                .fixedSize()
            Text(item.timeWithStatus(Formatting.time(item.date)))
                .phoneFont(.time)
                .monospacedDigit()
                .foregroundStyle(Theme.tertiaryText)
                .fixedSize()
        }
    }
}
