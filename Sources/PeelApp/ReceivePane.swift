import SwiftUI
import PeelCore

// MARK: - Receive

/// Receive: an amount (required) and a memo make an invoice, which the
/// server's node writes; shown as a QR code with Copy and a countdown to its
/// expiry. It turns to Paid once the server's history shows the payment.
struct ReceivePane: View {
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
                problem = PeelError.problem(error, couldNot: "check the invoice")
            }
        }
    }

    @ViewBuilder private var form: some View {
        let amountMsat = Sats.msat(amount)
        FormItem(label: "Amount", helper: "Lightning invoices from Peel name an amount; the payer cannot choose one.") {
            SatsField(label: "Amount", text: $amount)
        }
        FormItem(label: "Memo") {
            FormTextField(label: "Memo", prompt: "What it's for (optional)", text: $memo)
        }
        FormFooter(problem: problem) {
            Button {
                guard let amountMsat else { return }
                Task { await create(amountMsat) }
            } label: {
                Text(amountMsat.map { "Create invoice for \(Sats.format(msat: $0))" } ?? "Create invoice")
                    .buttonProgress(working)
            }
            .buttonStyle(.peel(.primary))
            .keyboardShortcut(.defaultAction)
            // Not off while it runs, so it keeps its fill under the spinner;
            // `create` ignores a second click.
            .disabled(amountMsat == nil)
        }
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

    @ViewBuilder private func waiting(_ invoice: InvoiceRecord) -> some View {
        VStack(spacing: Theme.Space.md) {
            QRCodeTile(text: invoice.bolt11.uppercased(), label: "QR code of the invoice", size: 220, inset: 12)
            Text("\(invoice.bolt11.prefix(16))…\(invoice.bolt11.suffix(12))")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Theme.secondaryText)
                .textSelection(.enabled)
            HStack(spacing: Theme.Space.sm) {
                CopyButton("Copy invoice", text: invoice.bolt11)
                    .buttonStyle(.peel(.primary))
                CopyButton("Copy QR image", systemImage: "qrcode") { QRCode.copyImage(invoice.bolt11.uppercased()) }
                    .buttonStyle(.peel(.outline))
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
        VStack(spacing: Theme.Space.md) {
            Image(systemName: full ? "checkmark" : "exclamationmark")
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(full ? Theme.confirmed : Theme.attention)
                .frame(width: 64, height: 64)
                .background((full ? Theme.confirmed : Theme.attention).opacity(0.14), in: Circle())
            Text(full ? "Paid" : "Partly paid").font(Theme.font(20, .bold))
            BigAmount(amount: invoice.paidMsat.map { Sats.signed(msat: $0, incoming: true) } ?? "Amount not known",
                      color: full ? Theme.confirmed : Theme.text)
            if !invoice.memo.isEmpty { Text(invoice.memo).font(Theme.font(14)) }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 24)
        FactList {
            Fact("Received", text: Formatting.time(invoice.paid ?? .now, seconds: true))
            Fact("Invoice for", text: Sats.format(msat: invoice.amountMsat))
        }
        HStack(spacing: Theme.Space.sm) {
            Button { close() } label: { Text("Done").frame(maxWidth: .infinity) }
                .buttonStyle(.peel(.outline))
            Button {
                self.invoice = nil
                amount = ""
                memo = ""
            } label: { Text("New invoice").frame(maxWidth: .infinity) }
                .buttonStyle(.peel(.primary))
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
                Callout(
                    .attention, "This invoice has expired",
                    detail: "It ran out at \(invoice.expires.map(Formatting.expiry) ?? "") unpaid."
                ) {
                    Button("Make a new one", action: renew).buttonStyle(.peel(.link))
                }
            } else {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: Theme.Space.sm) {
                        Circle().fill(Theme.accent).frame(width: 8, height: 8)
                            .overlay(Circle().stroke(Theme.accent.opacity(0.25), lineWidth: 4))
                        Text("Waiting for payment").font(Theme.font(13))
                        Spacer()
                        if let expires = invoice.expires {
                            Text(left < 3600
                                ? "Expires in \(Duration.seconds(left).formatted(.time(pattern: .minuteSecond)))"
                                : "Expires \(Formatting.expiry(expires))")
                                .monospacedDigit()
                                .muted()
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
                        .muted()
                }
                .padding(Theme.Space.md)
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(Theme.divider))
            }
        }
    }
}
