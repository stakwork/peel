import SwiftUI
import PeelCore

/// Sats that reached this account: a payment or boost to it
/// (`Engine.Event.moneyReceived`), or an invoice made here, paid
/// (`.invoicePaid`). The engine tells each payment once.
struct Receipt: Sendable {
    enum Kind: Sendable { case payment, boost, invoice }

    let kind: Kind
    let msat: Int64
    let chat: String?
    let messageID: Int64?
    let paymentHash: String?
    /// Who sent it, as the message names them (`Sender(member:)`; only its
    /// name is read, the member's in a tribe); nil for an invoice.
    let member: Sender?
    /// A payment's note or an invoice's memo.
    let note: String?

    init(_ message: Message) {
        kind = message.type == MessageType.boost ? .boost : .payment
        msat = message.msat ?? 0
        chat = message.chat
        messageID = message.id
        paymentHash = message.paymentHash
        member = Sender(member: message)
        note = message.preview.nilIfEmpty
    }

    init(_ invoice: InvoiceRecord) {
        kind = .invoice
        // Underpaid by an amount not known: nothing to count.
        msat = invoice.paidMsat ?? (invoice.status == .paid ? invoice.amountMsat : 0)
        // A request made in a chat names who paid it.
        chat = invoice.chat
        messageID = nil
        paymentHash = invoice.paymentHash
        member = nil
        note = invoice.memo.nilIfEmpty
    }

    /// Whether a row of the payment history is this payment.
    func matches(_ item: PaymentItem) -> Bool {
        (paymentHash != nil && item.paymentHash == paymentHash) || (messageID != nil && item.message?.id == messageID)
    }

    static func totalMsat(_ receipts: [Receipt]) -> Int64 {
        receipts.reduce(0) { $0 + $1.msat }
    }

    /// "+350 sats", with "· 3 payments" for more than one.
    static func label(_ receipts: [Receipt]) -> String {
        let total = "+\(Sats.format(msat: totalMsat(receipts)))"
        return receipts.count > 1 ? "\(total) · \(Formatting.count(receipts.count, "payment"))" : total
    }
}

/// Turns money events into what the sidebar shows: the balance, which rolls
/// up when a payment explains its rise; the latest arrival, for the bolt's
/// glow; and what Payments has not shown yet, summed on its row. A rise
/// nothing explains (the first balance, a restore, sats with no message)
/// just appears; a fall is never animated.
@MainActor @Observable
final class MoneyArrivals {
    /// What the sidebar header shows. A rise is held back for a moment (it
    /// is then below `balanceMsat`), so that it and the payment behind it,
    /// whichever comes first, roll as one.
    private(set) var shownMsat: UInt64?
    /// The balance as the server last gave it.
    private(set) var balanceMsat: UInt64?
    /// Arrivals so far: payments close together (a catch-up on connect
    /// brings several at once) are one, with one count-up, one glow and one
    /// notification. The bolt glows when it changes.
    private(set) var arrivals = 0
    /// Received since Payments was last on screen.
    private(set) var unseen: [Receipt] = []
    var unseenMsat: Int64 { Receipt.totalMsat(unseen) }

    /// Called once per arrival, with every payment in it.
    @ObservationIgnored var arrived: (([Receipt]) -> Void)?

    @ObservationIgnored private var burst: [Receipt] = []
    @ObservationIgnored private var burstStarted: ContinuousClock.Instant?
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    @ObservationIgnored private var settleTask: Task<Void, Never>?
    /// A payment came before its balance: the next rise rolls at once.
    @ObservationIgnored private var expectRiseUntil: ContinuousClock.Instant?

    /// Payments this close together are one arrival...
    private static let gathering: Duration = .milliseconds(700)
    /// ...up to this long from the first.
    private static let longestBurst: Duration = .seconds(3)
    /// How long a rise waits for the payment behind it before it just
    /// appears. A paid invoice is told after its balance, once the history
    /// is in; later than this it glows and notifies without a roll.
    private static let hold: Duration = .milliseconds(1500)
    /// How long after an arrival its balance may still come and roll.
    private static let expectRise: Duration = .seconds(5)
    private static let roll: Animation = .smooth(duration: 0.7)

    func balance(_ msat: UInt64) {
        let previous = balanceMsat
        balanceMsat = msat
        guard shownMsat != nil, let previous, msat > previous else {
            // The first balance or a fall shows at once; the same again changes nothing.
            if msat != previous {
                settleTask?.cancel()
                shownMsat = msat
            }
            return
        }
        if let until = expectRiseUntil, ContinuousClock.now < until {
            expectRiseUntil = nil
            settleTask?.cancel()
            withAnimation(Self.roll) { shownMsat = msat }
            return
        }
        // A burst gathering rolls it when it ends.
        guard burst.isEmpty else { return }
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            try? await Task.sleep(for: Self.hold)
            guard !Task.isCancelled, let self else { return }
            shownMsat = balanceMsat
        }
    }

    func received(_ receipt: Receipt) {
        guard receipt.msat > 0 else { return }
        burst.append(receipt)
        let now = ContinuousClock.now
        let started = burstStarted ?? now
        burstStarted = started
        settleTask?.cancel()
        flushTask?.cancel()
        let wait = max(.zero, min(Self.gathering, started + Self.longestBurst - now))
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    /// What Payments should light, and no longer counts as unseen.
    func takeUnseen() -> [Receipt] {
        defer { unseen = [] }
        return unseen
    }

    func reset() {
        flushTask?.cancel()
        settleTask?.cancel()
        shownMsat = nil
        balanceMsat = nil
        unseen = []
        burst = []
        burstStarted = nil
        expectRiseUntil = nil
    }

    private func flush() {
        let receipts = burst
        burst = []
        burstStarted = nil
        flushTask = nil
        guard !receipts.isEmpty else { return }
        arrivals += 1
        unseen += receipts
        arrived?(receipts)
        if let balance = balanceMsat, let shown = shownMsat, balance > shown {
            withAnimation(Self.roll) { shownMsat = balance }
        } else {
            expectRiseUntil = .now + Self.expectRise
        }
    }
}

/// The balance under your name in the sidebar header: it rolls up, digit by
/// digit, when a payment arrives. Nothing moves: the line keeps the width of
/// the larger of the two numbers from the start, in tabular digits. Under
/// Reduce Motion the number just changes. Sats promised to people still
/// offline follow it as the pending clock and the amount, or the clock alone
/// where the header has no room (the tooltip, VoiceOver and Payments say it
/// in words).
struct BalanceLabel: View {
    let money: MoneyArrivals
    var waitingMsat: UInt64 = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let shown = money.shownMsat {
            Group {
                if waitingMsat > 0 {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 0) { balance(shown); Text(" · ") + clock + Text(" \(Sats.number(msat: waitingMsat))") }
                        HStack(spacing: 0) { balance(shown); Text(" · ") + clock }
                    }
                    .help("\(Sats.format(msat: waitingMsat)) waiting for people to come online: their server takes it then, so it is not yours to spend.")
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(Sats.format(msat: shown)), \(Sats.format(msat: waitingMsat)) waiting")
                } else {
                    balance(shown)
                }
            }
            .font(Theme.font(12))
            .monospacedDigit()
            .lineLimit(1)
            .foregroundStyle(Theme.secondaryText)
        }
    }

    private var clock: Text { Text(Image(systemName: "clock")) }

    private func balance(_ shown: UInt64) -> some View {
        ZStack(alignment: .leading) {
            Text(Sats.format(msat: max(shown, money.balanceMsat ?? 0))).hidden()
            Text(Sats.format(msat: shown))
                .contentTransition(reduceMotion ? .identity : .numericText(value: Double(shown)))
        }
    }
}

/// The Payments row in the sidebar, its own view so an arrival redraws only
/// it. Its badge while something received is unseen: "+350",
/// the sum, in the green of received amounts. It pops in with a short scale
/// and fade, rolls to "+420" as more comes, and leaves when Payments opens.
/// Under Reduce Motion it is a plain badge with the final number.
struct PaymentsLink: View {
    let money: MoneyArrivals

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let msat = money.unseenMsat
        SidebarLink("Payments", to: .payments, unread: msat > 0) {
            Image(systemName: "bolt").font(.system(size: 13))
        } accessory: {
            if msat > 0 {
                Badge(Sats.signed(msat: msat, incoming: true), .success)
                    .contentTransition(reduceMotion ? .identity : .numericText(value: Double(msat)))
                    .transition(reduceMotion ? .identity : .scale(scale: 0.6).combined(with: .opacity))
                    .accessibilityLabel("Received \(Sats.format(msat: msat)), not seen yet")
            }
        }
        .animation(reduceMotion ? nil : .spring(duration: 0.3, bounce: 0), value: msat)
    }
}

extension View {
    /// A glow behind the connection bolt for a moment when sats arrive.
    func receivedGlow(_ money: MoneyArrivals) -> some View {
        modifier(ReceivedGlow(arrivals: money.arrivals))
    }
}

private struct ReceivedGlow: ViewModifier {
    let arrivals: Int

    @State private var glowing = false

    func body(content: Content) -> some View {
        content
            .shadow(color: Theme.confirmed.opacity(glowing ? 0.9 : 0), radius: glowing ? 5 : 0)
            .onChange(of: arrivals) {
                withAnimation(.easeOut(duration: 0.2)) { glowing = true }
                Task {
                    try? await Task.sleep(for: .milliseconds(400))
                    withAnimation(.easeOut(duration: 0.8)) { glowing = false }
                }
            }
    }
}
