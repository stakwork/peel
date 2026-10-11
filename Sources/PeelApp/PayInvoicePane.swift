import SwiftUI
import PeelCore

/// Pay an invoice: paste (or drop on the window) a BOLT11, see what it asks
/// and who it pays, and pay with the shared confirmation; what stops it
/// (expired, already paid, this account's own, too little balance) shows as
/// an amber note with the button off. After paying, the status, then the fee.
struct PayInvoicePane: View {
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
            let unreadable = !text.trimmed.isEmpty && invoice == nil
            FormItem(
                label: "Invoice", helper: "Paste one, or drop it anywhere on the window.",
                problem: unreadable ? "That is not an invoice Peel can read." : nil
            ) {
                FormTextField(label: "Invoice", prompt: "lnbc…", text: $text, axis: .vertical, problem: unreadable, monospaced: true)
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
                attempt.problem = PeelError.problem(error, couldNot: "check the payment")
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
                BigAmount(amount: Sats.number(msat: invoice.amountMsat), size: 30)
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
                    Button("Cancel", action: close).buttonStyle(.peel(.outline))
                    Spacer()
                    Button("Pay") {}
                        .buttonStyle(.peel(.primary))
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
                Button("Cancel", action: close).buttonStyle(.peel(.outline))
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
            if let link { Button(link.0, action: link.1).buttonStyle(.peel(.link)) }
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
                    if let item { Button("Show the payment") { show(item.id) }.buttonStyle(.peel(.link)) }
                    Spacer()
                    Button("Done", action: close).buttonStyle(.peel(.outline))
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
