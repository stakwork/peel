import SwiftUI
import PeelCore

// MARK: - Model

extension AppModel {
    /// The payment history as it is fetched and joined, newest first.
    func paymentHistoryUpdates(limit: Int) -> (some AsyncSequence<[PaymentItem], any Error>)? {
        engine?.storage.paymentHistory(limit: limit)
    }

    /// Fetches the page of the server's history older than what is stored.
    /// Returns how many rows came: fewer than a page means the end.
    func fetchOlderPayments() async throws -> Int {
        try await signedIn().fetchOlderPaymentHistory()
    }

    /// Fetches what is new in the server's history since the last fetch.
    func refreshPaymentHistory() async throws {
        try await signedIn().refreshPaymentHistory()
    }

    func createInvoice(amountMsat: UInt64, memo: String) async throws -> InvoiceRecord {
        try await signedIn().createInvoice(amountMsat: amountMsat, memo: memo.trimmed)
    }

    func invoiceUpdates(_ paymentHash: String, incoming: Bool) -> (some AsyncSequence<InvoiceRecord?, any Error>)? {
        engine?.storage.invoiceUpdates(paymentHash: paymentHash, incoming: incoming)
    }

    /// What stops paying this invoice, by the engine's own rules, and when
    /// it was paid (here or from another device) when that is what stops
    /// it. These are storage reads, so they run off the main actor.
    func invoiceProblem(_ invoice: Invoice) async -> (problem: Engine.Failure?, paidAt: Date?) {
        guard let engine else { return (nil, nil) }
        return await Task.detached {
            let problem = (try? engine.invoiceProblem(invoice)) ?? nil
            guard problem == .invoiceAlreadyPaid,
                  case .paid(let at)? = try? engine.storage.paidState(paymentHash: invoice.paymentHash) else { return (problem, nil) }
            return (problem, at)
        }.value
    }

    func payInvoice(_ invoice: Invoice, confirmedMsat: UInt64?) async -> PaymentOutcome {
        await pay("invoice \(invoice.paymentHash)") {
            _ = try await $0.payInvoice(invoice.bolt11, confirmedMsat: confirmedMsat)
        }
    }

    /// Pays someone's request in their chat.
    func payRequest(_ message: Message, invoice: Invoice, confirmedMsat: UInt64?) async -> PaymentOutcome {
        guard let id = message.id else { return .refused("This request cannot be paid.") }
        return await pay("invoice \(invoice.paymentHash)") {
            _ = try await $0.payRequest(messageID: id, confirmedMsat: confirmedMsat)
        }
    }

    func requestPayment(from chat: String, amountMsat: UInt64, memo: String) async throws {
        _ = try await signedIn().requestPayment(from: chat, amountMsat: amountMsat, memo: memo.trimmed)
    }

    /// A contact's name for a node key, when the key is a contact's.
    func contactName(_ pubkey: String) -> String? {
        conversations.first { !$0.isTribe && $0.chat == pubkey }?.name
    }
}

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
                DetailHeader(title: "Payments", subtitle: "Amounts in sats", leading: { EmptyView() }) {
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
                problem = PeelError.readable(error)
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
            problem = PeelError.readable(error)
        }
    }

    @ViewBuilder private var list: some View {
        if items.isEmpty {
            Text(problem ?? (model.connection == .connected ? "Payments you send and receive show up here."
                : "Payments show up here once Peel is connected."))
                .font(Theme.font(14))
                .foregroundStyle(Theme.secondaryText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    let sections = Dictionary(grouping: items) { PaymentSection($0.date) }
                    ForEach(PaymentSection.allCases, id: \.self) { section in
                        if let rows = sections[section] {
                            Text(section.rawValue)
                                .font(Theme.font(12, .semibold))
                                .foregroundStyle(Theme.secondaryText)
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

/// The small bordered buttons in the Payments header; lit while their pane is open.
private struct HeaderAction: View {
    let title: String
    let systemImage: String
    let active: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .semibold))
                Text(title)
            }
            .font(Theme.font(13))
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(active || hovering ? Theme.hover : .clear, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.divider))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
