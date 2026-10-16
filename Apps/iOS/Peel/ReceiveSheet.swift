import PeelCore
import PeelUI
import SwiftUI

/// Receive (the Mac's `ReceivePane`): an amount and a note make an invoice,
/// which the server's node writes; shown as a QR code with Copy and Share
/// and the time until it expires. It turns to Paid, with a success haptic,
/// once the server's history shows the payment.
struct ReceiveSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var amount = ""
    @State private var memo = ""
    @State private var invoice: InvoiceRecord?
    @State private var working = false
    @State private var problem: String?
    @FocusState private var amountFocused: Bool

    var body: some View {
        NavigationStack {
            Group {
                if let invoice, invoice.status == .paid || invoice.status == .underpaid {
                    paid(invoice)
                } else if let invoice {
                    waiting(invoice)
                } else {
                    form
                }
            }
        }
        .environment(\.dismissSheet, { dismiss() })
        .sensoryFeedback(.success, trigger: invoice?.status == .paid)
        .task(id: invoice?.paymentHash) {
            guard let hash = invoice?.paymentHash, let updates = model.invoiceUpdates(hash, incoming: true) else { return }
            do {
                for try await record in updates {
                    if let record { invoice = record }
                }
            } catch {
                problem = PeelError.problem(error, couldNot: "check the invoice")
            }
        }
    }

    private var form: some View {
        let amountMsat = Sats.msat(amount)
        return SheetPage(title: "Receive") {
            FieldLabel("Amount") { SatsInput(label: "Amount", text: $amount, focused: $amountFocused) }
            FieldLabel("Note") { NoteInput(label: "Note", prompt: "What it's for (optional)", text: $memo) }
            if let problem { ProblemText(problem) }
        } actions: {
            Button {
                guard let amountMsat else { return }
                Task { await create(amountMsat) }
            } label: {
                Text(amountMsat.map { "Create invoice for \(Sats.format(msat: $0))" } ?? "Create invoice")
                    .monospacedDigit()
                    .frame(maxWidth: .infinity)
                    .buttonProgress(working)
            }
            .buttonStyle(.peel(.primary, size: .touch))
            // Not off while it runs, so it keeps its fill under the spinner;
            // `create` ignores a second tap.
            .disabled(amountMsat == nil)
        }
        .onAppear { amountFocused = true }
    }

    private func create(_ msat: UInt64) async {
        guard !working else { return }
        working = true
        defer { working = false }
        do {
            invoice = try await model.createInvoice(amountMsat: msat, memo: memo)
            problem = nil
        } catch {
            problem = PeelError.problem(error)
        }
    }

    private func waiting(_ invoice: InvoiceRecord) -> some View {
        SheetPage(title: "Receive") {
            VStack(spacing: Theme.Space.md) {
                QRCodeTile(text: invoice.bolt11.uppercased(), label: "QR code of the invoice for \(Sats.format(msat: invoice.amountMsat))",
                           size: 260, inset: 14)
                BigAmount(amount: Sats.number(msat: invoice.amountMsat), size: 28)
                if !invoice.memo.isEmpty {
                    Text(invoice.memo)
                        .phoneFont(.row)
                        .foregroundStyle(Theme.secondaryText)
                        .multilineTextAlignment(.center)
                }
                Text("\(invoice.bolt11.prefix(16))…\(invoice.bolt11.suffix(12))")
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(Theme.tertiaryText)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity)
            InvoiceCountdown(invoice: invoice) { self.invoice = nil }
            if let problem { ProblemText(problem) }
        } actions: {
            HStack(spacing: Theme.Space.md) {
                CopyButton("Copy", text: invoice.bolt11)
                    .buttonStyle(.peel(.primary, size: .touch))
                ShareLink(item: invoice.bolt11) {
                    Label("Share", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                }
                .buttonStyle(.peel(.outline, size: .touch))
            }
        }
    }

    private func paid(_ invoice: InvoiceRecord) -> some View {
        let full = invoice.status == .paid
        return SheetPage(title: "Receive") {
            VStack(spacing: Theme.Space.md) {
                Image(systemName: full ? "checkmark" : "exclamationmark")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(full ? Theme.confirmed : Theme.attention)
                    .frame(width: 64, height: 64)
                    .background((full ? Theme.confirmed : Theme.attention).opacity(0.14), in: Circle())
                    .accessibilityHidden(true)
                Text(full ? "Paid" : "Partly paid")
                    .phoneFont(PhoneFont(size: 22, weight: .bold, style: .title2))
                    .accessibilityAddTraits(.isHeader)
                BigAmount(amount: invoice.paidMsat.map { Sats.signed(msat: $0, incoming: true) } ?? "Amount not known",
                          color: full ? Theme.confirmed : Theme.text)
                if !invoice.memo.isEmpty { Text(invoice.memo).phoneFont(.row) }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, Theme.Space.xl)
            PhoneCard {
                VStack(alignment: .leading, spacing: Theme.Space.md) {
                    if let paid = invoice.paid {
                        FactRow("Received", Formatting.time(paid, seconds: true))
                    }
                    FactRow("Invoice for", Sats.format(msat: invoice.amountMsat))
                }
                .padding(Theme.Space.md)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } actions: {
            HStack(spacing: Theme.Space.md) {
                Button { dismiss() } label: { Text("Done").frame(maxWidth: .infinity) }
                    .buttonStyle(.peel(.outline, size: .touch))
                Button {
                    self.invoice = nil
                    amount = ""
                    memo = ""
                } label: { Text("New invoice").frame(maxWidth: .infinity) }
                    .buttonStyle(.peel(.primary, size: .touch))
            }
        }
    }
}

/// "Waiting for payment · Expires in 59:41"; once it runs out, an amber
/// note and a new invoice.
private struct InvoiceCountdown: View {
    let invoice: InvoiceRecord
    let renew: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let left = invoice.expires.map { $0.timeIntervalSince(context.date) } ?? .infinity
            if left <= 0 {
                Callout(.attention, "This invoice has expired", detail: "Nothing was paid.") {
                    Button("Make a new one", action: renew).buttonStyle(.peel(.link))
                }
            } else {
                HStack(spacing: Theme.Space.sm) {
                    Circle().fill(Theme.accent).frame(width: 8, height: 8).accessibilityHidden(true)
                    Text("Waiting for payment")
                        .phoneFont(.row)
                    Spacer(minLength: Theme.Space.sm)
                    if let expires = invoice.expires {
                        Text(left < 3600
                             ? "Expires in \(Duration.seconds(left).formatted(.time(pattern: .minuteSecond)))"
                             : "Expires \(Formatting.expiry(expires))")
                            .phoneFont(.secondary)
                            .monospacedDigit()
                            .foregroundStyle(Theme.tertiaryText)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}
