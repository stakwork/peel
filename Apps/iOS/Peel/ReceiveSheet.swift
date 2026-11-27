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
    /// Paid has come in: its check, then two beats (`arrival`).
    @State private var paidShown = false
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
                problem = PeelError.problem(error, couldNot: String(localized: "check the invoice"))
            }
        }
    }

    private var form: some View {
        let amountMsat = Sats.msat(amount)
        return SheetPage(title: String(localized: "Receive")) {
            FieldLabel(String(localized: "Amount")) { SatsInput(label: String(localized: "Amount"), text: $amount, focused: $amountFocused) }
            FieldLabel(String(localized: "Note")) { NoteInput(label: String(localized: "Note"), prompt: String(localized: "What it's for (optional)"), text: $memo) }
            if let problem { ProblemText(problem) }
        } actions: {
            Button {
                guard let amountMsat else { return }
                Task { await create(amountMsat) }
            } label: {
                Text(amountMsat.map { String(localized: "Create invoice for \(Sats.format(msat: $0))") } ?? String(localized: "Create invoice"))
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
        SheetPage(title: String(localized: "Receive")) {
            VStack(spacing: Theme.Space.md) {
                QRCodeTile(text: invoice.bolt11.uppercased(), label: String(localized: "QR code of the invoice for \(Sats.format(msat: invoice.amountMsat))"),
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
                CopyButton(String(localized: "Copy"), text: invoice.bolt11)
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
        return SheetPage(title: String(localized: "Receive")) {
            VStack(spacing: Theme.Space.md) {
                Image(systemName: full ? "checkmark" : "exclamationmark")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(full ? Theme.confirmed : Theme.attention)
                    .frame(width: 64, height: 64)
                    .background((full ? Theme.confirmed : Theme.attention).opacity(0.14), in: Circle())
                    .arrival(paidShown, delay: 0.08, mark: true)
                    .accessibilityHidden(true)
                VStack(spacing: Theme.Space.md) {
                    Text(full ? String(localized: "Paid") : String(localized: "Partly paid"))
                        .phoneFont(PhoneFont(size: 22, weight: .bold, style: .title2))
                        .accessibilityAddTraits(.isHeader)
                    BigAmount(amount: invoice.paidMsat.map { Sats.signed(msat: $0, incoming: true) } ?? String(localized: "Amount not known"),
                              color: full ? Theme.confirmed : Theme.text)
                    if !invoice.memo.isEmpty { Text(invoice.memo).phoneFont(.row) }
                }
                .arrival(paidShown, delay: 0.18)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, Theme.Space.xl)
            .onAppear { paidShown = true }
            .onDisappear { paidShown = false }
            PhoneCard {
                VStack(alignment: .leading, spacing: Theme.Space.md) {
                    if let paid = invoice.paid {
                        FactRow(String(localized: "Received"), Formatting.time(paid, seconds: true))
                    }
                    FactRow(String(localized: "Invoice for"), Sats.format(msat: invoice.amountMsat))
                }
                .padding(Theme.Space.md)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .arrival(paidShown, delay: 0.28)
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
                Callout(.attention, String(localized: "This invoice has expired"), detail: String(localized: "Nothing was paid.")) {
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
                             ? String(localized: "Expires in \(Duration.seconds(left).formatted(.time(pattern: .minuteSecond)))")
                             : String(localized: "Expires \(Formatting.expiry(expires))"))
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
