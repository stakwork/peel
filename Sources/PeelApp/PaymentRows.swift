import SwiftUI
import PeelCore
import PeelUI

// MARK: - Rows

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
        item.timeWithStatus(Formatting.paymentTime(item.date, in: section))
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
            if let quoted = item.quoted {
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
                Text(item.context)
                    .muted()
            }
            .lineLimit(1)
        }
    }

    private var facts: some View {
        FactList {
            let status = item.statusFact
            Fact("Status", text: status.text, symbol: status.symbol, tint: status.settled ? Theme.confirmed : nil)
            Fact("When", text: Formatting.moment(item.date, seconds: true))
            Fact("Amount", text: "\(Sats.format(msat: item.amountMsat)) · \(item.amountMsat.formatted()) msat")
            if let fee = item.feeMsat {
                Fact("Routing fee", text: fee == 0 ? "None" : Sats.format(msat: fee))
            }
            if let why = item.keyExchangeNote {
                Fact("Why", text: why)
            }
            if let ping = item.pingMsat {
                Fact("Ping", text: Sats.format(msat: ping))
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
