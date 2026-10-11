import SwiftUI
import PeelCore

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
        case .unsettled: return "\(incoming ? "Receiving" : "Sending") \(amount), not settled"
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

struct PaymentListRow: View {
    @Environment(AppModel.self) private var model
    let item: PaymentItem
    let section: PaymentSection
    let selected: Bool
    /// Just received, shown for the first time.
    var lit = false
    let action: () -> Void

    var body: some View {
        ListRow(size: .md, selected: selected, tint: lit ? Theme.confirmed.opacity(0.14) : nil, action: action) {
            PaymentAvatar(item: item, size: Theme.AvatarSize.lg)
        } title: {
            Text(item.title)
                .font(Theme.font(14, .semibold))
                .foregroundStyle(model.nameColour(of: item))
                .lineLimit(1)
        } detail: {
            Text(item.subtitle)
                .font(Theme.font(12))
                .lineLimit(1)
        } trailing: {
            VStack(alignment: .trailing, spacing: 2) {
                SignedAmount(msat: item.amountMsat, incoming: item.incoming, status: item.status)
                    .fixedSize()
                Text(time)
                    .font(Theme.font(12))
                    .monospacedDigit()
                    .fixedSize()
            }
        }
    }

    private var time: String {
        let time = Formatting.paymentTime(item.date, in: section)
        switch item.status {
        case .complete: return time
        case .pending: return "\(item.isToContact ? "Waiting" : "Pending") · \(time)"
        case .unsettled: return "Not settled · \(time)"
        case .failed: return "\(item.incoming ? "Not received" : "Failed") · \(time)"
        }
    }
}

// MARK: - A payment's detail

struct PaymentDetailPane: View {
    @Environment(AppModel.self) private var model
    let item: PaymentItem
    let close: () -> Void

    var body: some View {
        PaneFrame(title: "Payment", close: close) {
            VStack(alignment: .leading, spacing: 6) {
                Text(item.headline)
                    .muted()
                BigAmount(
                    amount: Sats.signed(msat: item.amountMsat, incoming: item.incoming),
                    color: item.status != .complete ? Theme.secondaryText : item.incoming ? Theme.confirmed : Theme.text,
                    struck: item.status == .failed
                )
            }
            who
            if let quoted {
                VStack(alignment: .leading, spacing: Theme.Space.sm) {
                    Text(quoted.label)
                        .muted()
                    QuotedMessage(message: quoted.message)
                }
            } else if let note = item.note {
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.kind == .invoice ? "Memo" : "Note")
                        .muted()
                    Text(note)
                        .font(Theme.font(13))
                        .textSelection(.enabled)
                }
            }
            if let chat = item.chat {
                Button {
                    model.destination = .chat(chat)
                } label: {
                    HStack(spacing: Theme.Space.xs) {
                        Text(item.isTribe ? "Open in #\(item.chatName ?? "")" : "Open chat with \(item.chatName ?? "them")")
                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                    }
                }
                .buttonStyle(.peel(.link))
            }
            facts
        }
    }

    @ViewBuilder private var who: some View {
        HStack(spacing: 10) {
            PaymentAvatar(item: item, size: Theme.AvatarSize.lg)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(Theme.font(14, .semibold))
                    .foregroundStyle(model.nameColour(of: item))
                Text(context)
                    .muted()
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
        guard item.isToContact else { return "Pending: not confirmed by the server yet" }
        return "Waiting for \(item.chatName ?? "them") to come online. \(WaitingForServer.waitsForPerson(item.chatName))"
    }

    private var facts: some View {
        FactList {
            switch item.status {
            case .complete:
                Fact("Status", text: item.incoming ? "Received" : "Settled", symbol: "checkmark", tint: Theme.confirmed)
            case .pending:
                Fact("Status", text: pendingStatus, symbol: "clock")
            case .unsettled:
                Fact("Status", text: NotSettled.explanation, symbol: "questionmark.circle")
            case .failed where item.incoming:
                Fact("Status", text: item.error ?? "Not received", symbol: "xmark")
            case .failed:
                Fact("Status", text: "Failed\(item.error.map { ": \($0)" } ?? ""), nothing was sent", symbol: "xmark")
            }
            Fact("When", text: Formatting.moment(item.date, seconds: true))
            Fact("Amount", text: "\(Sats.format(msat: item.amountMsat)) · \(item.amountMsat.formatted()) msat")
            if let fee = item.feeMsat {
                Fact("Routing fee", text: fee == 0 ? "None" : Sats.format(msat: fee))
            }
            if let why = item.keyExchangeNote {
                Fact("Why", text: why)
            }
            if let ping = item.pingMsat {
                Fact("Ping", text: "\(Sats.format(msat: ping)), sent with it to reach them")
            }
            if let hash = item.paymentHash {
                Fact("Payment hash", text: Formatting.shortKey(hash), monospaced: true) {
                    CopyButton("Copy", text: hash).buttonStyle(.peel(.outline, size: .sm))
                }
            }
        }
    }
}

/// A message quoted in a pane: who, when, and its text.
private struct QuotedMessage: View {
    @Environment(AppModel.self) private var model
    let message: Message

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            let sender = model.sender(of: message)
            (Text(sender.label).fontWeight(.semibold).foregroundColor(sender.hue.name)
                + Text(" · \(Formatting.when(message.date))"))
                .monospacedDigit()
                .muted()
            Text(message.preview)
                .font(Theme.font(13))
                .lineSpacing(3)
                .lineLimit(6)
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.quote, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
    }
}
