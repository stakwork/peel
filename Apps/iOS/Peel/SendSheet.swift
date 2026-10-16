import PeelCore
import PeelUI
import SwiftUI

/// Send (docs/design/iphone.md, "To design: Send flows"): pay an invoice,
/// pasted or scanned, or send sats to a contact. Every rule is the engine's,
/// through the model, as on the Mac's Pay an invoice and Send sats panels.
struct SendSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// The payment history, to find our payment of an invoice already paid.
    let history: [PaymentItem]
    let receive: () -> Void

    @State private var text = ""
    @State private var scanning = false

    private var invoice: Invoice? {
        text.trimmed.isEmpty ? nil : try? Invoice(text)
    }

    var body: some View {
        NavigationStack {
            Group {
                if let invoice {
                    PayInvoiceForm(invoice: invoice, history: history, clear: { text = "" }, receive: receive)
                        // Another invoice is another payment: nothing armed carries over.
                        .id(invoice.paymentHash)
                } else {
                    start
                }
            }
            .navigationDestination(for: Contact.self) { contact in
                SendToContactForm(chat: contact.chat, name: contact.name)
            }
        }
        .environment(\.dismissSheet, { dismiss() })
        .fullScreenCover(isPresented: $scanning) {
            InvoiceScanner { code in
                text = code
                scanning = false
            } cancel: {
                scanning = false
            }
        }
    }

    private struct Contact: Hashable {
        let chat: String
        let name: String
    }

    private var start: some View {
        let unreadable = !text.trimmed.isEmpty
        let contacts = model.conversations.filter { !$0.isTribe }
        return SheetPage(title: "Send") {
            FieldLabel("Pay an invoice") {
                TextField("Invoice", text: $text, prompt: Text("lnbc…"), axis: .vertical)
                    .font(.system(.body, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .lineLimit(1...4)
                    .padding(Theme.Space.md)
                    .frame(minHeight: 48)
                    .fieldBox(focused: false)
                if unreadable {
                    ProblemText("That isn't an invoice.")
                }
                HStack(spacing: Theme.Space.md) {
                    PasteButton(payloadType: String.self) { texts in
                        if let first = texts.first { text = first.trimmed }
                    }
                    .buttonBorderShape(.capsule)
                    .labelStyle(.titleAndIcon)
                    Button { scanning = true } label: {
                        Label("Scan", systemImage: "qrcode.viewfinder")
                    }
                    .buttonStyle(.peel(.outline, size: .touch))
                }
            }
            if !contacts.isEmpty {
                LazyVStack(alignment: .leading, spacing: 0) {
                    PhoneSectionHeader("Or send to a contact")
                    ForEach(contacts, id: \.chat) { conversation in
                        NavigationLink(value: Contact(chat: conversation.chat, name: conversation.name)) {
                            HStack(spacing: Theme.Space.md) {
                                ConversationIcon(conversation: conversation, size: 30)
                                Text(conversation.name)
                                    .phoneFont(.row)
                                    .foregroundStyle(Theme.text)
                                    .lineLimit(1)
                                Spacer(minLength: Theme.Space.sm)
                                Image(systemName: "chevron.right")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(Theme.tertiaryText)
                            }
                            .frame(minHeight: Theme.touchTarget)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Theme.divider.frame(height: 1).padding(.leading, 42)
                    }
                }
            }
        } actions: {
            EmptyView()
        }
    }
}

/// An invoice read: its amount, who it pays, its memo and expiry, then the
/// outcome of our payment of it, what stops paying it (the engine's rules,
/// as an amber note), or Pay with the touch-safe confirm.
private struct PayInvoiceForm: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(PhoneRouter.self) private var router
    @Environment(\.dismissSheet) private var dismissSheet
    let invoice: Invoice
    let history: [PaymentItem]
    let clear: () -> Void
    let receive: () -> Void

    @State private var attempt = PaymentAttempt()
    /// Our payment of this invoice, once there is one.
    @State private var payment: InvoiceRecord?
    /// What stops paying it, by the engine's rules, for what was shown when asked.
    @State private var verdict: InvoiceVerdict?
    @ScaledMetric(relativeTo: .largeTitle) private var amountSize: CGFloat = 34

    var body: some View {
        UntilExpiry(invoice: invoice) { expired in
            content(expired: expired)
        }
        .task(id: invoice.paymentHash) {
            guard let updates = model.invoiceUpdates(invoice.paymentHash, incoming: false) else { return }
            do {
                for try await record in updates { payment = record }
            } catch {
                attempt.problem = PeelError.problem(error, couldNot: "check the payment")
            }
        }
    }

    private func content(expired: Bool) -> some View {
        let sent = history.first { $0.paymentHash == invoice.paymentHash && !$0.incoming }
        let check = InvoiceCheck(invoice: invoice, expired: expired, balanceMsat: model.balanceMsat,
                                 paymentStatus: payment?.status, inHistory: sent != nil)
        // While a recheck runs, the last note for this invoice stays.
        let checked = verdict?.about(invoice)
        return SheetPage(title: "Pay an invoice") {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text("Invoice for")
                    .phoneFont(.secondary)
                    .foregroundStyle(Theme.tertiaryText)
                BigAmount(amount: Sats.number(msat: invoice.amountMsat), size: amountSize, unitSize: amountSize * 15 / 32)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Invoice for \(Sats.format(msat: invoice.amountMsat))")
            }
            PhoneCard { facts(expired: expired) }
            if let payment, payment.status != .failed {
                outcome(payment, sent: sent)
            } else if let checked, let problem = checked.problem {
                blocker(problem, paidAt: checked.paidAt, sent: sent)
            } else {
                BalanceLine()
                if let failed = payment?.error {
                    ProblemText("Last try failed (\(failed)). Nothing was sent.")
                }
            }
        } actions: {
            if let payment, payment.status == .paid {
                Button { dismiss() } label: { Text("Done").frame(maxWidth: .infinity) }
                    .buttonStyle(.peel(.outline, size: .touch))
            } else if payment == nil || payment?.status == .failed {
                if checked?.problem == nil {
                    // Pay waits until the engine's rules are checked for what is shown now.
                    TouchPayButton(verb: "Pay", totalMsat: invoice.amountMsat, attempt: attempt, send: { confirmed in
                        await model.payInvoice(invoice, confirmedMsat: confirmed)
                    }, canPay: checked?.allowsPaying(check) == true)
                }
                Button { clear() } label: { Text("Another invoice").frame(maxWidth: .infinity) }
                    .buttonStyle(.peel(.ghost, size: .touch))
                    .disabled(attempt.working)
            }
        }
        // Pay waits until the engine's rules are checked for what is shown now.
        .task(id: check) {
            let answer = await model.verdict(on: check)
            guard !Task.isCancelled else { return }
            verdict = answer
        }
    }

    @ViewBuilder private func facts(expired: Bool) -> some View {
        let key = Formatting.shortKey(invoice.payee)
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            FactRow("To", model.contactName(invoice.payee).map { "\($0) · \(key)" } ?? "\(key), not a contact")
            if !invoice.memo.isEmpty { FactRow("Memo", invoice.memo) }
            if let expires = invoice.expiresAt {
                FactRow("Expires") {
                    Text(expired ? "Expired at \(Formatting.expiry(expires))"
                         : "\(expires.formatted(.relative(presentation: .named))), at \(Formatting.expiry(expires))")
                        .foregroundStyle(expired ? Theme.attention : Theme.text)
                }
            }
            if payment == nil || payment?.status == .failed {
                FactRow("Fee", "Added on top")
            }
        }
        .padding(Theme.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func blocker(_ problem: Engine.Failure, paidAt: Date?, sent: PaymentItem?) -> some View {
        let words = model.invoiceBlocker(problem, invoice: invoice, paidAt: paidAt)
        return Callout(.attention, words.title, detail: words.detail) {
            if problem == .insufficientBalance {
                Button("Receive sats", action: receive).buttonStyle(.peel(.link))
            } else if problem == .invoiceAlreadyPaid, let sent {
                Button("Show that payment") {
                    dismissSheet()
                    router.openPayment(sent.id)
                }
                .buttonStyle(.peel(.link))
            }
        }
    }

    @ViewBuilder private func outcome(_ payment: InvoiceRecord, sent item: PaymentItem?) -> some View {
        switch payment.status {
        case .paid:
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                Label("Paid \(Sats.format(msat: payment.amountMsat))", systemImage: "checkmark.circle.fill")
                    .phoneFont(PhoneFont.row.weight(.semibold))
                    .foregroundStyle(Theme.confirmed)
                    .monospacedDigit()
                Text(item?.feeMsat.map { $0 == 0 ? "No routing fee." : "Routing fee \(Sats.format(msat: $0))." }
                     ?? "Fee not known yet.")
                    .phoneFont(.secondary)
                    .monospacedDigit()
                    .foregroundStyle(Theme.secondaryText)
            }
        case .unsettled:
            ProblemText(PaymentItem.notSettled + ".")
        default:
            HStack(spacing: Theme.Space.sm) {
                ProgressView()
                Text("Paying \(Sats.format(msat: payment.amountMsat))…")
                    .phoneFont(.row)
                    .monospacedDigit()
                    .foregroundStyle(Theme.secondaryText)
            }
        }
    }
}

/// Sats to a contact (the Mac's Send sats panel, without the picture): an
/// amount, an optional note, and Send with the touch-safe confirm.
private struct SendToContactForm: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let chat: String
    let name: String

    @State private var amount = ""
    @State private var note = ""
    @State private var attempt = PaymentAttempt()
    @FocusState private var amountFocused: Bool

    var body: some View {
        let amountMsat = Sats.msat(amount)
        SheetPage(title: "Send to \(name)") {
            FieldLabel("Amount") { SatsInput(label: "Amount", text: $amount, focused: $amountFocused) }
            FieldLabel("Note") { NoteInput(label: "Note", prompt: "Optional", text: $note) }
            BalanceLine()
        } actions: {
            TouchPayButton(verb: "Send", totalMsat: amountMsat, attempt: attempt, send: { confirmed in
                guard let amountMsat else { return .refused("Enter an amount.") }
                return await model.sendPayment(to: chat, amountMsat: amountMsat, note: note, template: nil, confirmedMsat: confirmed)
            }, sent: {
                // The sheet closes; the payment shows in Payments and the chat.
                Task {
                    try? await Task.sleep(for: .milliseconds(400))
                    dismissSheet()
                }
            })
        }
        // A new note is a new payment: ask again over the threshold.
        .onChange(of: note) {
            attempt.armed = nil
            attempt.problem = nil
        }
        .onAppear { amountFocused = true }
    }

    @Environment(\.dismissSheet) private var dismissSheet
}

extension EnvironmentValues {
    /// Closes the sheet a pushed screen sits in (the Send sheet's).
    @Entry var dismissSheet: () -> Void = {}
}
