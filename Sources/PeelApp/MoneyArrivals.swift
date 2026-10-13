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
