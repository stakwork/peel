import SwiftUI
import PeelCore
#if os(macOS)
import AppKit
#endif

// MARK: - Model

extension AppModel {
    /// The payment history as it is fetched and joined, newest first.
    func paymentHistoryUpdates(limit: Int) -> (some AsyncSequence<[PaymentItem], any Error>)? {
        engine?.storage.paymentHistory(limit: limit)
    }

    /// Fetches the page of the server's history older than what is stored.
    /// Returns how many rows came: fewer than a page means the end.
    func fetchOlderPayments() async throws -> Int {
        let engine = try signedIn()
        return try await engine.fetchPaymentHistory(before: engine.storage.oldestPaymentTimestamp())
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

extension Formatting {
    /// "02f7…c3a1": a key or hash, its ends only.
    static func shortKey(_ key: String) -> String {
        key.count > 12 ? "\(key.prefix(6))…\(key.suffix(4))" : key
    }

    /// A time beside a payment: as in the list, by how long ago it was.
    static func when(_ date: Date) -> String {
        paymentTime(date, in: PaymentSection(date))
    }

    /// When an invoice runs out: "14:22" today, else "15 Oct, 14:22" (the
    /// server's invoices last a week).
    static func expiry(_ date: Date) -> String {
        Calendar.current.isDateInToday(date)
            ? date.formatted(.dateTime.hour().minute())
            : date.formatted(.dateTime.day().month(.abbreviated).hour().minute())
    }

    /// A row's time within its section: "14:22" today and yesterday, "Mon
    /// 08:00" this week, "30 Sep" before.
    static func paymentTime(_ date: Date, in section: PaymentSection) -> String {
        switch section {
        case .today, .yesterday: date.formatted(.dateTime.hour().minute())
        case .thisWeek: date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
        case .earlier: date.formatted(.dateTime.day().month(.abbreviated))
        }
    }
}

/// The list's groups, by relative time.
enum PaymentSection: String, CaseIterable {
    case today = "Today"
    case yesterday = "Yesterday"
    case thisWeek = "Earlier this week"
    case earlier = "Earlier"

    init(_ date: Date, now: Date = .now) {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            self = .today
        } else if calendar.isDateInYesterday(date) {
            self = .yesterday
        } else if calendar.isDate(date, equalTo: now, toGranularity: .weekOfYear), date < now {
            self = .thisWeek
        } else {
            self = .earlier
        }
    }
}

extension PaymentItem {
    /// The row's name: who, or what it was when nobody is known.
    var title: String {
        if let counterpart { return counterpart }
        switch kind {
        case .invoice: return incoming ? "Invoice paid" : "Lightning invoice"
        case .keysend: return "Keysend"
        case .payment, .boost, .purchase, .messageFee: return chatName ?? "Someone"
        }
    }

    private var isRefund: Bool { message?.type == MessageType.purchaseDeny }

    /// The one line under the name.
    var subtitle: String {
        if status == .failed, let error { return error }
        if kind == .boost { return isTribe ? "Boost in #\(chatName ?? "")" : "Boost" }
        if let note { return note }
        switch kind {
        case .keysend: return incoming ? "Received, not tied to a chat" : "Sent, not tied to a chat"
        case .invoice:
            return invoice.map { incoming ? "Your invoice" : "To \(Formatting.shortKey($0.payee))" } ?? "Invoice"
        case .payment, .boost: return isTribe ? "In #\(chatName ?? "")" : "Payment"
        case .purchase:
            if isRefund { return incoming ? "Refund for an attachment you tried to buy" : "Refund of a purchase" }
            return incoming ? "Bought your paid attachment" : "Unlocked a paid attachment"
        case .messageFee:
            let tribe = "#\(chatName ?? "")"
            switch message?.type {
            case MessageType.groupJoin: return "Joined \(tribe)"
            case MessageType.memberRequest: return "Asked to join \(tribe)"
            default: return "Message fee in \(tribe)"
            }
        }
    }

    /// "Boost received", "Payment sent".
    var headline: String {
        let what = switch kind {
        case .boost: "Boost"
        case .payment: "Payment"
        case .invoice: "Invoice payment"
        case .keysend: "Keysend"
        case .purchase: isRefund ? "Refund" : "Purchase"
        case .messageFee: "Message fee"
        }
        return "\(what) \(incoming ? "received" : status == .pending ? "on its way" : "sent")"
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

/// A right-hand pane: its title, a close button, and what it holds.
private struct PaneFrame<Content: View>: View {
    let title: String
    let close: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            DetailHeader(title: title, leading: { EmptyView() }) {
                HeaderButton(systemImage: "xmark", help: "Close (Escape)", action: close)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    content
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

// MARK: - Rows

/// The amount as banking apps show it: "+500" received (green), "−2,000"
/// sent in the text colour; the sign carries direction, not colour alone.
/// Pending reads grey, failed struck through.
struct SignedAmount: View {
    let msat: Int64
    let incoming: Bool
    var status: PaymentItem.Status = .complete
    var size: CGFloat = 14

    var body: some View {
        Text(Sats.signed(msat: msat, incoming: incoming))
        .strikethrough(status == .failed)
        .font(Theme.font(size, .semibold))
        .monospacedDigit()
        .foregroundStyle(status != .complete ? Theme.secondaryText : incoming ? Theme.confirmed : Theme.text)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }

    private var label: String {
        let amount = Sats.format(msat: msat)
        switch status {
        case .complete: return "\(incoming ? "Received" : "Sent") \(amount)"
        case .pending: return "\(incoming ? "Receiving" : "Sending") \(amount), pending"
        case .failed: return "\(incoming ? "Receipt" : "Send") of \(amount) failed"
        }
    }
}

private extension AppModel {
    /// The counterpart's colour, or the text colour when nobody is known.
    func nameColour(of payment: PaymentItem) -> Color {
        payment.counterpart == nil ? Theme.text : hue(of: payment).name
    }
}

/// Who a payment was with: their photo, or for nobody known a dashed ring with a bolt.
private struct PaymentAvatar: View {
    @Environment(AppModel.self) private var model
    let item: PaymentItem
    let size: CGFloat

    var body: some View {
        if let name = item.counterpart {
            Avatar(name: name, url: item.counterpartPhotoURL, size: size, hue: model.hue(of: item))
        } else {
            Image(systemName: "bolt")
                .font(.system(size: size * 0.45))
                .foregroundStyle(Theme.secondaryText)
                .frame(width: size, height: size)
                .overlay(Circle().strokeBorder(Theme.secondaryText.opacity(0.6), style: StrokeStyle(lineWidth: 1.5, dash: [3, 2])))
        }
    }
}

private struct PaymentListRow: View {
    @Environment(AppModel.self) private var model
    let item: PaymentItem
    let section: PaymentSection
    let selected: Bool
    /// Just received, shown for the first time.
    var lit = false
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                PaymentAvatar(item: item, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(Theme.font(14, .semibold))
                        .foregroundStyle(model.nameColour(of: item))
                    Text(item.subtitle)
                        .font(Theme.font(12.5))
                        .foregroundStyle(Theme.secondaryText)
                }
                .lineLimit(1)
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 2) {
                    SignedAmount(msat: item.amountMsat, incoming: item.incoming, status: item.status)
                    Text(time)
                        .font(Theme.font(12))
                        .monospacedDigit()
                        .foregroundStyle(Theme.secondaryText)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                selected ? Theme.accent.opacity(0.14) : lit ? Theme.confirmed.opacity(0.14) : hovering ? Theme.hover : .clear,
                in: RoundedRectangle(cornerRadius: 8)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private var time: String {
        let time = Formatting.paymentTime(item.date, in: section)
        switch item.status {
        case .complete: return time
        case .pending: return "Pending · \(time)"
        case .failed: return "Failed · \(time)"
        }
    }
}

// MARK: - A payment's detail

private struct PaymentDetailPane: View {
    @Environment(AppModel.self) private var model
    let item: PaymentItem
    let close: () -> Void

    var body: some View {
        PaneFrame(title: "Payment", close: close) {
            VStack(alignment: .leading, spacing: 6) {
                Text(item.headline)
                    .font(Theme.font(12.5))
                    .foregroundStyle(Theme.secondaryText)
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(Sats.signed(msat: item.amountMsat, incoming: item.incoming))
                        .font(Theme.font(32, .bold))
                        .strikethrough(item.status == .failed)
                        .foregroundStyle(item.status != .complete ? Theme.secondaryText
                            : item.incoming ? Theme.confirmed : Theme.text)
                    Text("sats")
                        .font(Theme.font(15))
                        .foregroundStyle(Theme.secondaryText)
                }
                .monospacedDigit()
            }
            who
            if let quoted {
                VStack(alignment: .leading, spacing: 8) {
                    Text(quoted.label)
                        .font(Theme.font(12))
                        .foregroundStyle(Theme.secondaryText)
                    QuotedMessage(message: quoted.message)
                }
            } else if let note = item.note {
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.kind == .invoice ? "Memo" : "Note")
                        .font(Theme.font(12))
                        .foregroundStyle(Theme.secondaryText)
                    Text(note)
                        .font(Theme.font(13.5))
                        .textSelection(.enabled)
                }
            }
            if let chat = item.chat {
                Button {
                    model.destination = .chat(chat)
                } label: {
                    HStack(spacing: 4) {
                        Text(item.isTribe ? "Open in #\(item.chatName ?? "")" : "Open chat with \(item.chatName ?? "them")")
                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                    }
                    .font(Theme.font(13))
                    .foregroundStyle(Theme.link)
                }
                .buttonStyle(.plain)
            }
            KeyValues(rows: facts)
        }
    }

    @ViewBuilder private var who: some View {
        HStack(spacing: 10) {
            PaymentAvatar(item: item, size: 36)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(Theme.font(14, .semibold))
                    .foregroundStyle(model.nameColour(of: item))
                Text(context)
                    .font(Theme.font(12))
                    .foregroundStyle(Theme.secondaryText)
            }
            .lineLimit(1)
        }
    }

    private var context: String {
        if item.isTribe { return item.counterpart == nil ? "In #\(item.chatName ?? "")" : "Member of #\(item.chatName ?? "")" }
        if item.chat != nil { return "Contact" }
        if let invoice = item.invoice, !invoice.incoming {
            return "To \(Formatting.shortKey(invoice.payee)), not a contact"
        }
        return "Not tied to a contact"
    }

    /// The message a boost was for, or the one a fee was for.
    private var quoted: (label: String, message: Message)? {
        if let boosted = item.boosted { return (item.incoming ? "Boosted your message" : "You boosted", boosted) }
        if item.kind == .messageFee, let message = item.message { return ("Your message", message) }
        return nil
    }

    private var pendingStatus: String {
        item.isToContact ? "Waiting for \(item.chatName ?? "them") to come online" : "Pending: not confirmed by the server yet"
    }

    private var facts: [KeyValues.Row] {
        var rows: [KeyValues.Row] = []
        switch item.status {
        case .complete:
            rows.append(.init(key: "Status", value: item.incoming ? "Received" : "Settled", symbol: "checkmark", tint: Theme.confirmed))
        case .pending:
            rows.append(.init(key: "Status", value: pendingStatus, symbol: "clock"))
        case .failed:
            rows.append(.init(key: "Status", value: "Failed\(item.error.map { ": \($0)" } ?? ""), nothing was sent", symbol: "xmark"))
        }
        rows.append(.init(key: "When", value: item.date.formatted(
            .dateTime.weekday(.wide).day().month(.wide).hour().minute().second()
        )))
        rows.append(.init(key: "Amount", value: "\(Sats.format(msat: item.amountMsat)) · \(item.amountMsat.formatted()) msat"))
        if let fee = item.feeMsat {
            rows.append(.init(key: "Routing fee", value: fee == 0 ? "None" : Sats.format(msat: fee)))
        }
        if let ping = item.pingMsat {
            rows.append(.init(key: "Ping", value: "\(Sats.format(msat: ping)), sent with it to reach them"))
        }
        if let hash = item.paymentHash {
            rows.append(.init(key: "Payment hash", value: Formatting.shortKey(hash), monospaced: true, copy: hash))
        }
        return rows
    }
}

/// A message quoted in a pane: who, when, and its text.
private struct QuotedMessage: View {
    @Environment(AppModel.self) private var model
    let message: Message

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            let sender = model.sender(of: message)
            (Text(sender.name).fontWeight(.semibold).foregroundColor(sender.hue.name)
                + Text(" · \(Formatting.when(message.date))"))
                .font(Theme.font(12))
                .monospacedDigit()
                .foregroundStyle(Theme.secondaryText)
            Text(message.preview)
                .font(Theme.font(13.5))
                .lineSpacing(3)
                .lineLimit(6)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.quote, in: RoundedRectangle(cornerRadius: 10))
    }
}

/// Facts in two columns: the name on the left, the value (with an icon, or
/// a Copy button) on the right.
struct KeyValues: View {
    struct Row: Identifiable {
        let key: String
        let value: String
        var symbol: String?
        var tint: Color?
        var monospaced = false
        /// Text a Copy button beside the value puts on the clipboard.
        var copy: String?
        var id: String { key }
    }

    let rows: [Row]

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
            ForEach(rows) { row in
                GridRow {
                    Text(row.key)
                        .foregroundStyle(Theme.secondaryText)
                        .gridColumnAlignment(.leading)
                    HStack(spacing: 6) {
                        if let symbol = row.symbol {
                            Image(systemName: symbol)
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(row.tint ?? Theme.secondaryText)
                        }
                        Text(row.value)
                            .font(row.monospaced ? .system(size: 12, design: .monospaced) : Theme.font(13))
                            .monospacedDigit()
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        if let copy = row.copy {
                            CopyButton("Copy", text: copy).buttonStyle(GhostButtonStyle())
                        }
                    }
                }
            }
        }
        .font(Theme.font(13))
    }
}



/// An amber note: something blocks the next step. Never red: nothing was lost.
private struct AttentionNote<Actions: View>: View {
    let title: String
    let detail: String
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 14))
                .foregroundStyle(Theme.attention)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(Theme.font(13, .semibold))
                Text(detail)
                    .font(Theme.font(13))
                    .monospacedDigit()
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                actions
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Theme.attention.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.attention.opacity(0.28)))
    }
}

extension AttentionNote where Actions == EmptyView {
    init(title: String, detail: String) {
        self.init(title: title, detail: detail, actions: { EmptyView() })
    }
}

/// A text link inside a pane or note.
private struct PaneLink: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(Theme.font(13))
            .foregroundStyle(Theme.link)
    }
}

// MARK: - Receive

/// Receive: an amount (required) and a memo make an invoice, which the
/// server's node writes; shown as a QR code with Copy and a countdown to its
/// expiry. It turns to Paid once the server's history shows the payment.
private struct ReceivePane: View {
    @Environment(AppModel.self) private var model
    let close: () -> Void

    @State private var amount = ""
    @State private var memo = ""
    @State private var invoice: InvoiceRecord?
    @State private var working = false
    @State private var problem: String?

    var body: some View {
        PaneFrame(title: "Receive", close: close) {
            if let invoice, invoice.status == .paid || invoice.status == .underpaid {
                paid(invoice)
            } else if let invoice {
                waiting(invoice)
            } else {
                form
            }
        }
        .task(id: invoice?.paymentHash) {
            guard let hash = invoice?.paymentHash, let updates = model.invoiceUpdates(hash, incoming: true) else { return }
            do {
                for try await record in updates {
                    if let record { invoice = record }
                }
            } catch {
                problem = PeelError.readable(error)
            }
        }
    }

    @ViewBuilder private var form: some View {
        let amountMsat = Sats.msat(amount)
        VStack(alignment: .leading, spacing: 5) {
            Text("Amount").font(Theme.font(12.5)).foregroundStyle(Theme.secondaryText)
            SatsField(placeholder: "Amount", text: $amount)
            Text("Lightning invoices from Peel name an amount; the payer cannot choose one.")
                .font(Theme.font(12))
                .foregroundStyle(Theme.secondaryText)
        }
        VStack(alignment: .leading, spacing: 5) {
            Text("Memo").font(Theme.font(12.5)).foregroundStyle(Theme.secondaryText)
            TextField("What it's for (optional)", text: $memo)
                .textFieldStyle(.plain)
                .font(Theme.font(13))
                .fieldBoxed()
        }
        FormFooter(problem: problem) {
            Button {
                guard let amountMsat else { return }
                Task { await create(amountMsat) }
            } label: {
                Text(amountMsat.map { "Create invoice for \(Sats.format(msat: $0))" } ?? "Create invoice")
                    .buttonProgress(working)
            }
            .buttonStyle(GhostButtonStyle(prominent: true))
            .keyboardShortcut(.defaultAction)
            .disabled(amountMsat == nil || working)
        }
    }

    private func create(_ msat: UInt64) async {
        working = true
        defer { working = false }
        do {
            invoice = try await model.createInvoice(amountMsat: msat, memo: memo)
            problem = nil
        } catch {
            problem = PeelError.readable(error)
        }
    }

    @ViewBuilder private func waiting(_ invoice: InvoiceRecord) -> some View {
        VStack(spacing: 12) {
            if let code = QRCode.image(invoice.bolt11.uppercased()) {
                Image(decorative: code, scale: 1)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 196, height: 196)
                    .padding(12)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityLabel("QR code of the invoice")
            }
            Text("\(invoice.bolt11.prefix(16))…\(invoice.bolt11.suffix(12))")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Theme.secondaryText)
                .textSelection(.enabled)
            HStack(spacing: 8) {
                CopyButton("Copy invoice", text: invoice.bolt11)
                    .buttonStyle(GhostButtonStyle(prominent: true))
                CopyButton("Copy QR image", systemImage: "qrcode") { QRCode.copyImage(invoice.bolt11.uppercased()) }
                    .buttonStyle(GhostButtonStyle())
            }
        }
        .frame(maxWidth: .infinity)
        HStack(spacing: 7) {
            Text(Sats.format(msat: invoice.amountMsat)).font(Theme.font(15, .semibold)).monospacedDigit()
            if !invoice.memo.isEmpty {
                Text(invoice.memo).font(Theme.font(13)).foregroundStyle(Theme.secondaryText).lineLimit(2)
            }
        }
        WaitingStatus(invoice: invoice) { self.invoice = nil }
    }

    @ViewBuilder private func paid(_ invoice: InvoiceRecord) -> some View {
        let full = invoice.status == .paid
        VStack(spacing: 12) {
            Image(systemName: full ? "checkmark" : "exclamationmark")
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(full ? Theme.confirmed : Theme.attention)
                .frame(width: 64, height: 64)
                .background((full ? Theme.confirmed : Theme.attention).opacity(0.14), in: Circle())
            Text(full ? "Paid" : "Partly paid").font(Theme.font(20, .bold))
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(invoice.paidMsat.map { Sats.signed(msat: $0, incoming: true) } ?? "Amount not known")
                    .font(Theme.font(32, .bold))
                    .foregroundStyle(full ? Theme.confirmed : Theme.text)
                Text("sats").font(Theme.font(15)).foregroundStyle(Theme.secondaryText)
            }
            .monospacedDigit()
            if !invoice.memo.isEmpty { Text(invoice.memo).font(Theme.font(14)) }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 24)
        Theme.divider.frame(height: 1)
        KeyValues(rows: [
            .init(key: "Received", value: (invoice.paid ?? .now).formatted(.dateTime.hour().minute().second())),
            .init(key: "Invoice for", value: Sats.format(msat: invoice.amountMsat)),
        ])
        HStack(spacing: 8) {
            Button { close() } label: { Text("Done").frame(maxWidth: .infinity) }
                .buttonStyle(GhostButtonStyle())
            Button {
                self.invoice = nil
                amount = ""
                memo = ""
            } label: { Text("New invoice").frame(maxWidth: .infinity) }
                .buttonStyle(GhostButtonStyle(prominent: true))
        }
    }
}

/// "Waiting for payment · Expires in 59:41", with a bar running down; once
/// it runs out, an amber note and a new invoice.
private struct WaitingStatus: View {
    let invoice: InvoiceRecord
    let renew: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let left = invoice.expires.map { $0.timeIntervalSince(context.date) } ?? .infinity
            if left <= 0 {
                AttentionNote(
                    title: "This invoice has expired",
                    detail: "It ran out at \(invoice.expires.map(Formatting.expiry) ?? "") unpaid."
                ) {
                    PaneLink(title: "Make a new one", action: renew)
                }
            } else {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 8) {
                        Circle().fill(Theme.accent).frame(width: 8, height: 8)
                            .overlay(Circle().stroke(Theme.accent.opacity(0.25), lineWidth: 4))
                        Text("Waiting for payment").font(Theme.font(13.5))
                        Spacer()
                        if let expires = invoice.expires {
                            Text(left < 3600
                                ? "Expires in \(Duration.seconds(left).formatted(.time(pattern: .minuteSecond)))"
                                : "Expires \(Formatting.expiry(expires))")
                                .font(Theme.font(12.5))
                                .monospacedDigit()
                                .foregroundStyle(Theme.secondaryText)
                        }
                    }
                    if let expires = invoice.expires {
                        let total = max(expires.timeIntervalSince(invoice.created), 1)
                        Capsule().fill(Theme.divider)
                            .frame(height: 3)
                            .overlay(alignment: .leading) {
                                GeometryReader { box in
                                    Capsule().fill(Theme.accent)
                                        .frame(width: box.size.width * max(0, min(1, left / total)))
                                }
                            }
                    }
                    Text("You can close this, and Peel too: the server takes the payment, and it shows in your history.")
                        .font(Theme.font(12))
                        .foregroundStyle(Theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.divider))
            }
        }
    }
}

extension QRCode {
    /// Puts the code on the clipboard as an image, large enough to scan.
    /// Returns whether it is there.
    static func copyImage(_ text: String) -> Bool {
        #if os(macOS)
        guard let code = image(text) else { return false }
        let scale = 8
        let size = NSSize(width: code.width * scale, height: code.height * scale)
        let image = NSImage(size: size)
        image.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .none
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        NSImage(cgImage: code, size: NSSize(width: code.width, height: code.height))
            .draw(in: NSRect(origin: .zero, size: size))
        image.unlockFocus()
        return Clipboard.copy(image)
        #else
        return false
        #endif
    }
}

// MARK: - Pay an invoice

/// Its content, told whether the invoice has expired, and drawn again the
/// moment it does, so Pay goes then rather than at the next redraw.
private struct UntilExpiry<Content: View>: View {
    let invoice: Invoice
    @ViewBuilder let content: (_ expired: Bool) -> Content

    var body: some View {
        TimelineView(.explicit(invoice.expiresAt.map { [$0] } ?? [])) { context in
            content(invoice.isExpired(now: context.date))
        }
    }
}

/// Pay an invoice: paste (or drop on the window) a BOLT11, see what it asks
/// and who it pays, and pay with the shared confirmation; what stops it
/// (expired, already paid, this account's own, too little balance) shows as
/// an amber note with the button off. After paying, the status, then the fee.
private struct PayInvoicePane: View {
    @Environment(AppModel.self) private var model
    @Binding var text: String
    let history: [PaymentItem]
    let show: (String) -> Void
    let receive: () -> Void
    let close: () -> Void

    @State private var attempt = PaymentAttempt()
    /// Our payment of the invoice shown, once there is one.
    @State private var payment: InvoiceRecord?
    /// What stops paying an invoice, worked out in `details`' task.
    @State private var verdict: Verdict?

    private struct Verdict {
        let check: Check
        let problem: Engine.Failure?
        let paidAt: Date?
    }

    /// What `invoiceProblem` depends on: a change asks it again.
    private struct Check: Equatable {
        let invoice: Invoice
        let expired: Bool
        let balanceMsat: UInt64?
        let paymentStatus: InvoiceRecord.Status?
        let inHistory: Bool
    }

    private var invoice: Invoice? {
        text.trimmed.isEmpty ? nil : try? Invoice(text)
    }

    var body: some View {
        PaneFrame(title: "Pay an invoice", close: close) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Invoice").font(Theme.font(12.5)).foregroundStyle(Theme.secondaryText)
                TextEditor(text: $text)
                    .font(.system(size: 12, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .frame(height: 58)
                    .padding(4)
                    .background(Theme.input, in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.divider))
                Text(!text.trimmed.isEmpty && invoice == nil
                     ? "That is not an invoice Peel can read." : "Paste one, or drop it anywhere on the window.")
                    .font(Theme.font(12))
                    .foregroundStyle(Theme.secondaryText)
            }
            if let invoice {
                UntilExpiry(invoice: invoice) { expired in details(invoice, expired: expired) }
            }
        }
        .task(id: invoice?.paymentHash) {
            payment = nil
            attempt.armed = nil
            attempt.problem = nil
            guard let hash = invoice?.paymentHash, let updates = model.invoiceUpdates(hash, incoming: false) else { return }
            do {
                for try await record in updates { payment = record }
            } catch {
                attempt.problem = PeelError.readable(error)
            }
        }
    }

    /// The invoice's facts, then the outcome, what stops paying it, or Pay.
    /// Pay is off until the engine's rules are checked for what is shown
    /// now; while a recheck runs, the last note for this invoice stays.
    private func details(_ invoice: Invoice, expired: Bool) -> some View {
        // Our payment of it in the history, from here or another device.
        let sent = history.first { $0.paymentHash == invoice.paymentHash && !$0.incoming }
        let check = Check(invoice: invoice, expired: expired, balanceMsat: model.balanceMsat, paymentStatus: payment?.status,
                          inHistory: sent != nil)
        let checked = verdict?.check.invoice == invoice ? verdict : nil
        return VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(Sats.number(msat: invoice.amountMsat))
                        .font(Theme.font(30, .bold))
                    Text("sats").font(Theme.font(15)).foregroundStyle(Theme.secondaryText)
                }
                .monospacedDigit()
                KeyValues(rows: facts(invoice, expired: expired))
            }
            .padding(.top, 16)
            .overlay(alignment: .top) { Theme.divider.frame(height: 1) }
            if let payment, payment.status != .failed {
                outcome(payment, sent: sent)
            } else if let checked, checked.check == check, checked.problem == nil {
                payForm(invoice)
            } else {
                if let checked, let problem = checked.problem {
                    blocker(problem, invoice: invoice, paidAt: checked.paidAt, sent: sent)
                }
                HStack(spacing: 8) {
                    Button("Cancel", action: close).buttonStyle(GhostButtonStyle())
                    Spacer()
                    Button("Pay") {}
                        .buttonStyle(GhostButtonStyle(prominent: true))
                        .disabled(true)
                }
            }
        }
        .task(id: check) {
            let (problem, paidAt) = await model.invoiceProblem(invoice)
            guard !Task.isCancelled else { return }
            verdict = Verdict(check: check, problem: problem, paidAt: paidAt)
        }
    }

    private func payForm(_ invoice: Invoice) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let failed = payment?.error {
                Text("The last try failed (\(failed)); nothing was sent, so paying again pays once.")
                    .font(Theme.font(12))
                    .foregroundStyle(Theme.secondaryText)
            }
            FormFooter(problem: attempt.problem) {
                Button("Cancel", action: close).buttonStyle(GhostButtonStyle())
                PayButton(verb: "Pay", totalMsat: invoice.amountMsat, attempt: attempt, send: { confirmed in
                    await model.payInvoice(invoice, confirmedMsat: confirmed)
                }, sent: {}, namesAmount: false)
            }
            Text(model.paymentConfirmationMsat == 0 ? "Every payment takes a second click."
                 : "Payments over \(Sats.format(msat: model.paymentConfirmationMsat)) take a second click.")
                .font(Theme.font(12))
                .monospacedDigit()
                .foregroundStyle(Theme.secondaryText)
        }
    }

    private func facts(_ invoice: Invoice, expired: Bool) -> [KeyValues.Row] {
        var rows: [KeyValues.Row] = []
        let key = Formatting.shortKey(invoice.payee)
        rows.append(.init(key: "To", value: model.contactName(invoice.payee).map { "\($0) · \(key)" } ?? "\(key), not a contact"))
        if !invoice.memo.isEmpty { rows.append(.init(key: "Memo", value: invoice.memo)) }
        if let expires = invoice.expiresAt {
            let at = Formatting.expiry(expires)
            rows.append(expired
                ? .init(key: "Expires", value: "Expired at \(at)", tint: Theme.attention)
                : .init(key: "Expires", value: "\(expires.formatted(.relative(presentation: .named))), at \(at)"))
        }
        if payment == nil || payment?.status == .failed {
            rows.append(.init(key: "Fee", value: "Any routing fee is added on top and shown once paid."))
        }
        return rows
    }

    /// Why this invoice cannot be paid from here: the engine's own rules,
    /// in words. One amber note, and a link when there is somewhere to go.
    private func blocker(_ problem: Engine.Failure, invoice: Invoice, paidAt: Date?, sent: PaymentItem?) -> some View {
        let reserve = Engine.feeReserveMsat(for: invoice.amountMsat)
        let (title, detail): (String, String)
        var link: (String, () -> Void)?
        switch problem {
        case .invoiceWithoutAmount:
            (title, detail) = ("This invoice names no amount", "Peel pays invoices that say how much. Ask for one with an amount.")
        case .invoiceExpired:
            (title, detail) = ("This invoice has expired",
                               "It ran out \(invoice.expiresAt?.formatted(date: .abbreviated, time: .shortened) ?? ""). Ask for a new one.")
        case .ownInvoice:
            (title, detail) = ("This is your own invoice", "Send it to whoever is paying you.")
        case .invoiceAlreadyPaid:
            (title, detail) = ("You already paid this invoice",
                               paidAt.map { "On \($0.formatted(.dateTime.weekday(.wide).day().month(.wide).hour().minute()))." } ?? "")
            if let sent {
                link = ("Show that payment", { show(sent.id) })
            }
        case .invoicePending:
            (title, detail) = ("A payment of this invoice is on its way",
                               "It may already have paid, so it cannot be paid again until the server says.")
        case .insufficientBalance:
            (title, detail) = ("Not enough sats",
                               "This needs \(Sats.format(msat: invoice.amountMsat)) plus up to \(Sats.format(msat: reserve)) "
                                   + "for routing. You have \(Sats.format(msat: model.balanceMsat ?? 0)).")
            link = ("Receive sats", receive)
        default:
            (title, detail) = ("This invoice cannot be paid now", problem.description)
        }
        return AttentionNote(title: title, detail: detail) {
            if let link { PaneLink(title: link.0, action: link.1) }
        }
    }

    @ViewBuilder private func outcome(_ payment: InvoiceRecord, sent item: PaymentItem?) -> some View {
        switch payment.status {
        case .paid:
            VStack(alignment: .leading, spacing: 8) {
                Label("Paid \(Sats.format(msat: payment.amountMsat))", systemImage: "checkmark")
                    .font(Theme.font(14, .semibold))
                    .foregroundStyle(Theme.text)
                    .monospacedDigit()
                Text(item?.feeMsat.map { $0 == 0 ? "No routing fee." : "Routing fee \(Sats.format(msat: $0))." }
                     ?? "The fee shows once the server's history has this payment.")
                    .font(Theme.font(12))
                    .monospacedDigit()
                    .foregroundStyle(Theme.secondaryText)
                HStack {
                    if let item { PaneLink(title: "Show the payment") { show(item.id) } }
                    Spacer()
                    Button("Done", action: close).buttonStyle(GhostButtonStyle())
                }
            }
        case .unsettled:
            Text("Not settled yet: the server holds this payment of \(Sats.format(msat: payment.amountMsat)) and may "
                 + "never settle it. It is not paid again from here.")
                .font(Theme.font(13))
                .monospacedDigit()
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        default:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Paying \(Sats.format(msat: payment.amountMsat)). It stays pending until the server confirms.")
                    .font(Theme.font(13))
                    .monospacedDigit()
                    .foregroundStyle(Theme.secondaryText)
            }
        }
    }
}

// MARK: - Requests in a chat

/// A payment request in a direct message: who asked, how much, what for,
/// and for someone else's a Pay button; then Paid. The amount, memo and
/// payee are the invoice's, never the message's own words.
struct PaymentRequestRow: View {
    @Environment(AppModel.self) private var model
    let row: ChatRow

    @State private var attempt = PaymentAttempt()
    @State private var hovering = false

    private var message: Message { row.message }

    var body: some View {
        HStack(alignment: .top, spacing: MessageRow.gutterSpacing) {
            Avatar(name: row.alias ?? "?", url: row.photoURL, size: MessageRow.avatarSize, hue: row.hue)
            VStack(alignment: .leading, spacing: 4) {
                RunHeader(row: row)
                card
                if message.fromMe, message.delivery == .failed {
                    UndeliveredActions(message: message)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 6)
        .background {
            if hovering { Theme.hover.opacity(0.55) } else if message.fromMe { Theme.accent.opacity(0.06) }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    private var request: PaymentRequest? { row.paymentRequest }

    @ViewBuilder private var card: some View {
        let invoice = request?.invoice
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "bolt")
                    .font(.system(size: 11))
                Text(message.fromMe ? "You requested" : "\(row.alias ?? "Someone") requested")
                Spacer(minLength: 8)
                if case .paid = request?.state {
                    Label("Paid", systemImage: "checkmark")
                        .font(Theme.font(12, .semibold))
                        .foregroundStyle(Theme.text)
                }
            }
            .font(Theme.font(12))
            .foregroundStyle(Theme.secondaryText)
            if let invoice {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(Sats.number(msat: invoice.amountMsat))
                        .font(Theme.font(22, .bold))
                    Text("sats").font(Theme.font(14)).foregroundStyle(Theme.secondaryText)
                }
                .monospacedDigit()
                if !invoice.memo.isEmpty {
                    Text(invoice.memo).font(Theme.font(13.5)).fixedSize(horizontal: false, vertical: true)
                }
                if !message.fromMe, request?.paysRequester == false {
                    Text("This invoice pays \(Formatting.shortKey(invoice.payee)), not \(row.alias ?? "them").")
                        .font(Theme.font(12))
                        .foregroundStyle(Theme.attention)
                        .fixedSize(horizontal: false, vertical: true)
                }
                footer(invoice)
            } else {
                Text("This request's invoice cannot be read, so it cannot be paid.")
                    .font(Theme.font(13))
                    .foregroundStyle(Theme.secondaryText)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: 320, alignment: .leading)
        .background(Theme.quote, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.divider))
        .padding(.top, 2)
    }

    @ViewBuilder private func footer(_ invoice: Invoice) -> some View {
        switch request?.state ?? .open {
        case .underpaid(let msat):
            Text("Partly paid: \(msat.map { Sats.format(msat: $0, of: invoice.amountMsat) } ?? "an unknown amount") came; this invoice cannot take the rest.")
                .font(Theme.font(12))
                .monospacedDigit()
                .foregroundStyle(Theme.attention)
                .fixedSize(horizontal: false, vertical: true)
        case .paid(let at):
            Text(message.fromMe ? "Paid\(at.map { " · \(Formatting.when($0))" } ?? "")"
                 : "You paid\(at.map { " · \(Formatting.when($0))" } ?? "")")
                .font(Theme.font(12))
                .monospacedDigit()
                .foregroundStyle(Theme.secondaryText)
        case .paying:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Paying; it stays pending until the server confirms.")
            }
            .font(Theme.font(12))
            .foregroundStyle(Theme.secondaryText)
        case .open, .failed:
            UntilExpiry(invoice: invoice) { expired in
                if expired {
                    Text("Expired at \(invoice.expiresAt.map(Formatting.expiry) ?? "")")
                        .font(Theme.font(12))
                        .monospacedDigit()
                        .foregroundStyle(Theme.secondaryText)
                } else if message.fromMe {
                    Text("Waiting to be paid · expires \(invoice.expiresAt.map(Formatting.expiry) ?? "never")")
                        .font(Theme.font(12))
                        .monospacedDigit()
                        .foregroundStyle(Theme.secondaryText)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        if case .failed(let reason) = request?.state {
                            Text("Not paid\(reason.map { ": \($0)" } ?? ""). Nothing was sent.")
                                .font(Theme.font(12))
                                .foregroundStyle(Theme.secondaryText)
                        }
                        PayButton(verb: "Pay", totalMsat: invoice.amountMsat, attempt: attempt, send: { confirmed in
                            await model.payRequest(message, invoice: invoice, confirmedMsat: confirmed)
                        }, sent: {}, isDefault: false, namesAmount: false)
                        if let problem = attempt.problem { ProblemText(problem) }
                    }
                    .padding(.top, 4)
                }
            }
        }
    }
}
