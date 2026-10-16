import PeelCore
import PeelUI
import SwiftUI

/// One payment (the Mac's `PaymentDetailPane`): what it was and the amount,
/// who it was with, the message it was for or its note, a way to its chat,
/// then its facts in a group.
struct PaymentDetailScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(PhoneRouter.self) private var router
    let item: PaymentItem?
    @ScaledMetric(relativeTo: .largeTitle) private var amountSize: CGFloat = 34

    var body: some View {
        Group {
            if let item {
                List {
                    Section { top(item) }
                        .listRowSeparator(.hidden)
                        .phoneRows()
                    if let quoted = item.quoted {
                        Section {
                            QuotedMessage(message: quoted.message)
                        } header: {
                            PhoneSectionHeader(quoted.label)
                        }
                        .phoneRows(.grouped)
                    } else if let note = item.note {
                        Section {
                            Text(note)
                                .phoneFont(.row)
                                .textSelection(.enabled)
                        } header: {
                            PhoneSectionHeader(item.kind == .invoice ? "Memo" : "Note")
                        }
                        .phoneRows(.grouped)
                    }
                    Section { facts(item) }
                        .phoneRows(.grouped)
                }
                .phoneList(.grouped)
            } else {
                Text("This payment is gone.")
                    .phoneFont(.row)
                    .foregroundStyle(Theme.tertiaryText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.background)
            }
        }
        .navigationTitle("Payment")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func top(_ item: PaymentItem) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.lg) {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text(item.headline)
                    .phoneFont(.secondary)
                    .foregroundStyle(Theme.tertiaryText)
                BigAmount(
                    amount: Sats.signed(msat: item.amountMsat, incoming: item.incoming),
                    size: amountSize,
                    color: item.status != .complete ? Theme.secondaryText : item.incoming ? Theme.confirmed : Theme.text,
                    struck: item.status == .failed,
                    unitSize: amountSize * 15 / 32
                )
            }
            .accessibilityElement(children: .combine)
            HStack(spacing: Theme.Space.md) {
                if let name = item.counterpart {
                    Avatar(name: name, url: item.counterpartPhotoURL, size: 40, hue: model.hue(of: item))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .phoneFont(PhoneFont.row.weight(.semibold))
                        .foregroundStyle(item.counterpart == nil ? Theme.text : model.hue(of: item).name)
                    Text(item.context)
                        .phoneFont(.secondary)
                        .foregroundStyle(Theme.tertiaryText)
                }
            }
            .accessibilityElement(children: .combine)
            if let chat = item.chat {
                Button(item.isTribe ? "Open #\(item.chatName ?? "")" : "Open chat with \(item.chatName ?? "them")") {
                    router.openChat(chat)
                }
                .buttonStyle(.peel(.outline, size: .touch))
            }
        }
        .padding(.vertical, Theme.Space.sm)
    }

    @ViewBuilder private func facts(_ item: PaymentItem) -> some View {
        let status = item.statusFact
        FactRow("Status") {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: status.symbol).accessibilityHidden(true)
                Text(status.text)
            }
            .foregroundStyle(status.settled ? Theme.confirmed : Theme.text)
        }
        FactRow("When", Formatting.moment(item.date, seconds: true))
        FactRow("Amount", "\(Sats.format(msat: item.amountMsat)) · \(item.amountMsat.formatted()) msat")
        if let fee = item.feeMsat {
            FactRow("Routing fee", fee == 0 ? "None" : Sats.format(msat: fee))
        }
        if let why = item.keyExchangeNote {
            FactRow("Why", why)
        }
        if let ping = item.pingMsat {
            FactRow("Ping", Sats.format(msat: ping))
        }
        if let hash = item.paymentHash {
            FactRow("Payment hash") {
                HStack {
                    Text(Formatting.shortKey(hash)).font(.system(.body, design: .monospaced))
                    Spacer(minLength: Theme.Space.sm)
                    CopyButton("Copy", text: hash)
                        .buttonStyle(.peel(.outline, size: .touch))
                        .accessibilityLabel("Copy payment hash")
                }
            }
        }
    }
}

/// A fact on a grouped cell: its label in the quiet grey over the value, so
/// long values wrap at any text size.
struct FactRow<Value: View>: View {
    let label: String
    @ViewBuilder let value: Value

    init(_ label: String, @ViewBuilder value: () -> Value) {
        self.label = label
        self.value = value()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .phoneFont(.secondary)
                .foregroundStyle(Theme.quietText(on: .raised))
            value
                .phoneFont(.row)
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

extension FactRow where Value == Text {
    init(_ label: String, _ text: String) {
        self.init(label) { Text(text) }
    }
}

/// A message a payment was for: who and when, then its text.
private struct QuotedMessage: View {
    @Environment(AppModel.self) private var model
    let message: Message

    var body: some View {
        let sender = model.sender(of: message)
        VStack(alignment: .leading, spacing: 3) {
            (Text(sender.label).fontWeight(.semibold).foregroundColor(sender.hue.name)
                + Text(" · \(Formatting.when(message.date))").foregroundColor(Theme.quietText(on: .raised)))
                .phoneFont(.secondary)
                .monospacedDigit()
            Text(message.preview)
                .phoneFont(.row)
                .lineLimit(8)
        }
        .accessibilityElement(children: .combine)
    }
}
