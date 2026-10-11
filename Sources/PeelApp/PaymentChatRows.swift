import SwiftUI
import PeelCore

// MARK: - In the conversation

/// Under a message: its boosts as a quiet chip ("⚡ 1,210 sats" and the
/// boosters' photos; tinted when you boosted it), who boosted on a click, and your boosts that are still on
/// their way or failed.
struct BoostLine: View {
    let boosts: BoostSummary
    /// The boosted message's chat, which keys the boosters' colours.
    let chat: String
    let inTribe: Bool
    /// False under a deleted message: only our failed boosts stay, to clear.
    var showsChip = true

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if showsChip, boosts.count > 0 {
                BoostChip(boosts: boosts, chat: chat, inTribe: inTribe)
            }
            if let since = boosts.pendingSince {
                WaitingForServer(since: since, what: "Boost", person: inTribe ? nil : chat)
            }
            ForEach(Array(boosts.unsettled.enumerated()), id: \.offset) { _, boost in
                NotSettled(what: "Boost of \(Sats.format(msat: boost.amountMsat))")
            }
            ForEach(boosts.failed, id: \.id) { boost in
                UndeliveredActions(message: boost)
            }
        }
    }
}

/// As the Mac app draws it (`NewMessageBoostView`): a bolt, the total
/// ("1,210 sats"), then the first three boosters' photos overlapping, one
/// per person in the order they boosted, and "+N" for the other people.
/// Quiet, as Slack's reactions are (Tom, 2026-10-08: it shouted louder than
/// the message): small, on a soft fill inside a hairline, with Sphinx's
/// orange bolt (faded while your boost waits for the server). One of
/// yours, once the server has it, tints it faintly and puts its total in
/// `boostMineText`.
private struct BoostChip: View {
    @Environment(AppModel.self) private var model
    let boosts: BoostSummary
    let chat: String
    let inTribe: Bool

    @State private var showing = false

    static let shownBoosters = 3
    /// A booster without a photo shows their initial on their colour, as
    /// everywhere else.
    private static let avatarSize: CGFloat = 16
    private static let overlap: CGFloat = 5

    /// One per person, first boost first: by alias, as the Mac app keeps
    /// them (a boost is all a person is known by here); one without an
    /// alias counts on its own.
    private var boosters: [BoostSummary.Boost] {
        var seen = Set<String>()
        return boosts.boosts.enumerated().filter { index, boost in
            seen.insert(boost.fromMe ? "\u{0}me" : boost.alias.map { "a\($0)" } ?? "#\(index)").inserted
        }.map(\.element)
    }

    var body: some View {
        let people = boosters
        let pending = boosts.pendingSince != nil
        let mine = boosts.boostedByMe && !pending
        Chip(.inset, lit: mine, action: { showing = true }) {
            HStack(spacing: 4) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.attention.opacity(pending ? 0.5 : 1))
                (Text(Sats.number(msat: boosts.totalMsat)).font(Theme.font(11, .semibold))
                    .foregroundColor(mine ? Theme.boostMineText : Theme.text)
                    + Text(" sats").font(Theme.font(11)).foregroundColor(Theme.secondaryText))
                HStack(spacing: -Self.overlap) {
                    ForEach(Array(people.prefix(Self.shownBoosters).enumerated()), id: \.offset) { index, boost in
                        let avatar = model.avatar(fromMe: boost.fromMe, alias: boost.alias, photoURL: boost.photoURL,
                                                  chat: chat, inTribe: inTribe)
                        Avatar(name: avatar.avatarName, url: avatar.photoURL, size: Self.avatarSize, hue: avatar.hue)
                            .padding(1)
                            .background(ChipStyle.inset.fill(lit: mine), in: Circle())
                            .zIndex(Double(Self.shownBoosters - index))
                    }
                }
                // The letters name no one; the help and the panel do.
                .accessibilityHidden(true)
                if people.count > Self.shownBoosters {
                    Text("+\(people.count - Self.shownBoosters)")
                        .font(Theme.font(11, .medium))
                        .foregroundStyle(Theme.secondaryText)
                }
            }
            .monospacedDigit()
            .padding(.leading, 7)
            .padding(.trailing, people.count > Self.shownBoosters ? 7 : 2)
            .padding(.vertical, 1)
        }
        .help(help)
        .peelPopover(isPresented: $showing) {
            BoostersPanel(boosts: boosts, chat: chat, inTribe: inTribe) { showing = false }
        }
    }

    private var help: String {
        boosts.summaryLine + (boosts.boostedByMe ? ", yours among them" : "") + ". Click for who."
    }
}

private extension BoostSummary {
    /// "1,210 sats from 3 boosts".
    var summaryLine: String {
        "\(Sats.format(msat: totalMsat)) from \(count == 1 ? "1 boost" : "\(count) boosts")"
    }
}

/// Who boosted a message and by how much, oldest first.
private struct BoostersPanel: View {
    @Environment(AppModel.self) private var model
    let boosts: BoostSummary
    let chat: String
    let inTribe: Bool
    let done: () -> Void

    var body: some View {
        Panel("Boosts", compact: true, close: done) {
            Text(boosts.summaryLine)
                .font(Theme.font(12))
                .monospacedDigit()
                .foregroundStyle(Theme.secondaryText)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(boosts.boosts.enumerated()), id: \.offset) { _, boost in
                        let avatar = model.avatar(fromMe: boost.fromMe, alias: boost.alias, photoURL: boost.photoURL,
                                                  chat: chat, inTribe: inTribe)
                        HStack(spacing: 8) {
                            Avatar(name: avatar.avatarName, url: avatar.photoURL, size: 22, hue: avatar.hue)
                            Text(avatar.label)
                                .font(Theme.font(13))
                                .foregroundStyle(avatar.hue.name)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            if boost.pendingSince != nil || boost.unsettled {
                                Text(boost.unsettled ? "not settled" : "sending")
                                    .font(Theme.font(12))
                                    .foregroundStyle(Theme.secondaryText)
                            }
                            Text(Sats.format(msat: boost.amountMsat))
                                .font(Theme.font(13))
                                .monospacedDigit()
                                .foregroundStyle(Theme.secondaryText)
                        }
                    }
                }
            }
            .frame(maxHeight: 240)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// "Waiting for the server…" once our payment or boost has gone unconfirmed
/// past the usual wait; to a person (`person`, a direct message's chat)
/// "Waiting for Bob to come online", since their server holds the sats
/// until their app answers. It may have paid, so there is no Discard or
/// Retry until the engine marks it failed; Peel has no way to cancel it
/// and the server no expiry for it, so it says so (`waitsForPerson`,
/// payments review F5).
struct WaitingForServer: View {
    @Environment(AppModel.self) private var model
    let since: Date
    let what: String
    var person: String?

    /// What a payment of ours waiting for `name` (nil: unnamed) to come
    /// online will do, here and in Payments' detail.
    /// Hedged: a ping that never left (the connection went, or the app
    /// quit, during the wait for the server) means nothing wakes the
    /// payment, and one the server never recorded fails later.
    static func waitsForPerson(_ name: String?) -> String {
        let when = name.map { "\($0) next opens" } ?? "they next open"
        return "It should pay when \(when) Sphinx, however long that takes. It can't be cancelled from here"
    }

    var body: some View {
        TimelineView(.redrawing(at: since.addingTimeInterval(Message.confirmationTimeout))) { context in
            if context.date.timeIntervalSince(since) >= Message.confirmationTimeout {
                let words = person.map { person in
                    let name = model.contactName(person)
                    let days = Int(Message.waitingLimit / 86_400)
                    return (label: "\(what) waiting for \(name ?? "them") to come online · can't be cancelled from here",
                            help: "\(Self.waitsForPerson(name)). Their server holds it until then. For \(days) days it is kept out of what you can spend; after that the sats count as spendable again, but it may still go through if your balance covers it.")
                } ?? (label: "\(what) waiting for the server…",
                      help: "It may already have paid, so it cannot be sent again until the server says it failed.")
                Text(words.label)
                    .font(Theme.font(11, .medium))
                    .foregroundStyle(Theme.secondaryText)
                    .help(words.help)
            }
        }
    }
}

/// Our payment or boost the server passed on but never settled
/// (`Message.Delivery.unsettled`): they have the message, the sats may not
/// have moved. No Retry: it may still have paid.
struct NotSettled: View {
    let what: String

    /// The same words in Payments' detail.
    static let explanation = "Not settled: the server passed it on but never confirmed the sats moved; your balance shows whether they did"

    var body: some View {
        Text("\(what) not settled")
            .font(Theme.font(11, .medium))
            .foregroundStyle(Theme.secondaryText)
            .help(Self.explanation + ".")
    }
}

/// A direct payment in the timeline: a bolt, who sent how much ("You sent
/// 1,000 sats", "Bob sent you 1,000 sats"), the note, the time, and for
/// ours the delivery bolt, the wait or Retry.
struct PaymentRow: View {
    let row: ChatRow
    /// Lit for a moment, just jumped to.
    var flashed = false

    @State private var hovering = false

    /// The square a payment's picture is drawn in.
    static let templateSide: CGFloat = 140

    private var message: Message { row.message }

    var body: some View {
        HStack(alignment: .top, spacing: MessageRow.gutterSpacing) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 13))
                .foregroundStyle(message.deleted ? Theme.secondaryText : Theme.attention)
                .frame(width: 28, height: 28)
                .background(Theme.attention.opacity(message.deleted ? 0.06 : 0.14), in: Circle())
                .frame(width: MessageRow.avatarSize)
            VStack(alignment: .leading, spacing: 3) {
                RunHeader(row: row, headline: headline)
                if message.paymentTemplateMUID != nil {
                    // Its square is kept from the start, so the row never moves as it loads.
                    TemplateImage(message: message, side: Self.templateSide)
                        .background(Theme.quote, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                        .padding(.vertical, 2)
                }
                if !message.deleted, let note = message.content?.trimmed.nilIfEmpty {
                    MessageText(text: note, chat: message.chat)
                }
                if message.fromMe, !message.deleted {
                    switch message.delivery {
                    case .pending: WaitingForServer(since: message.date, what: "Payment", person: message.chat)
                    case .unsettled: NotSettled(what: "Payment")
                    case .failed: UndeliveredActions(message: message)
                    case .delivered, nil: EmptyView()
                    }
                } else if !message.deleted, message.arrived == false {
                    Text("Not received")
                        .font(Theme.font(11, .medium))
                        .foregroundStyle(Theme.secondaryText)
                        .help(PaymentItem.notArrived + ". The message came; the sats did not.")
                }
            }
            .frame(maxWidth: MessageRow.textWidth, alignment: .leading)
            .opacity(message.isSending() ? 0.6 : 1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 6)
        .rowChrome(row, lit: flashed, hovering: hovering)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .peelMenu(source: row.id) {
            message.content?.trimmed.nilIfEmpty.map { [.copyText($0)] } ?? []
        }
    }

    /// In the run header, in place of the sender's name.
    private var headline: Text {
        let who = row.sender.name
        if message.deleted {
            return Text("This payment has been deleted")
                .font(Theme.font(13))
                .italic()
                .foregroundStyle(Theme.secondaryText)
        } else if let msat = message.amountMsat, msat > 0 {
            let amount = Text(Sats.format(msat: msat)).font(Theme.font(14, .semibold))
            return (message.fromMe ? Text("You sent ") + amount : Text("\(who) sent you ") + amount)
                .font(Theme.font(14))
                .monospacedDigit()
                .foregroundStyle(Theme.text)
        } else {
            // A contact's type 5 that carried no sats: whatever it declared
            // is not money received.
            return Text(message.fromMe ? "You sent a payment" : "\(who) sent a payment with no sats")
                .font(Theme.font(14))
                .foregroundStyle(Theme.secondaryText)
        }
    }
}

// MARK: - Requests in a chat

/// A payment request in a direct message: who asked, how much, what for,
/// and for someone else's a Pay button; then Paid. The amount, memo and
/// payee are the invoice's, never the message's own words.
struct PaymentRequestRow: View {
    @Environment(AppModel.self) private var model
    let row: ChatRow
    /// Lit for a moment, just jumped to.
    var flashed = false

    @State private var attempt = PaymentAttempt()
    @State private var hovering = false

    private var message: Message { row.message }

    var body: some View {
        HStack(alignment: .top, spacing: MessageRow.gutterSpacing) {
            Avatar(name: row.sender.avatarName, url: row.sender.photoURL, size: MessageRow.avatarSize,
                   hue: row.sender.hue)
            VStack(alignment: .leading, spacing: 4) {
                RunHeader(row: row)
                card
                if message.fromMe, message.delivery == .failed {
                    UndeliveredActions(message: message)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 6)
        .rowChrome(row, lit: flashed, hovering: hovering)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    private var request: PaymentRequest? { row.paymentRequest }

    @ViewBuilder private var card: some View {
        let invoice = request?.invoice
        Card(.inset) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "bolt")
                        .font(.system(size: 11))
                    Text("\(row.sender.label) requested")
                    Spacer(minLength: 8)
                    if case .paid = request?.state {
                        Label("Paid", systemImage: "checkmark")
                            .font(Theme.font(12, .semibold))
                            .foregroundStyle(Theme.text)
                    }
                }
                .font(Theme.font(12))
                .foregroundStyle(Theme.secondaryText)
                if let invoice {
                    BigAmount(amount: Sats.number(msat: invoice.amountMsat), size: 22, unitSize: 14, spacing: 5)
                    if !invoice.memo.isEmpty {
                        Text(invoice.memo).font(Theme.font(13.5)).fixedSize(horizontal: false, vertical: true)
                    }
                    if !message.fromMe, request?.paysRequester == false {
                        Text("This invoice pays \(Formatting.shortKey(invoice.payee)), not \(row.sender.name).")
                            .font(Theme.font(12))
                            .foregroundStyle(Theme.attention)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    footer(invoice)
                } else {
                    Text("This request's invoice cannot be read, so it cannot be paid.")
                        .font(Theme.font(13))
                        .foregroundStyle(Theme.secondaryText)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(width: 320, alignment: .leading)
        }
        .padding(.top, 2)
    }

    @ViewBuilder private func footer(_ invoice: Invoice) -> some View {
        switch request?.state ?? .open {
        case .underpaid(let msat):
            Text("Partly paid: \(msat.map { Sats.format(msat: $0, of: invoice.amountMsat) } ?? "an unknown amount") came; this invoice cannot take the rest.")
                .font(Theme.font(12))
                .monospacedDigit()
                .foregroundStyle(Theme.attention)
                .fixedSize(horizontal: false, vertical: true)
        case .paid(let at):
            Text(message.fromMe ? "Paid\(at.map { " · \(Formatting.when($0))" } ?? "")"
                 : "You paid\(at.map { " · \(Formatting.when($0))" } ?? "")")
                .font(Theme.font(12))
                .monospacedDigit()
                .foregroundStyle(Theme.secondaryText)
        case .paying:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Paying; it stays pending until the server confirms.")
            }
            .font(Theme.font(12))
            .foregroundStyle(Theme.secondaryText)
        case .open, .failed:
            UntilExpiry(invoice: invoice) { expired in
                if expired {
                    Text("Expired at \(invoice.expiresAt.map(Formatting.expiry) ?? "")")
                        .font(Theme.font(12))
                        .monospacedDigit()
                        .foregroundStyle(Theme.secondaryText)
                } else if message.fromMe {
                    Text("Waiting to be paid · expires \(invoice.expiresAt.map(Formatting.expiry) ?? "never")")
                        .font(Theme.font(12))
                        .monospacedDigit()
                        .foregroundStyle(Theme.secondaryText)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        if case .failed(let reason) = request?.state {
                            Text("Not paid\(reason.map { ": \($0)" } ?? ""). Nothing was sent.")
                                .font(Theme.font(12))
                                .foregroundStyle(Theme.secondaryText)
                        }
                        PayButton(verb: "Pay", totalMsat: invoice.amountMsat, attempt: attempt, send: { confirmed in
                            await model.payRequest(message, invoice: invoice, confirmedMsat: confirmed)
                        }, sent: {}, isDefault: false, namesAmount: false)
                        if let problem = attempt.problem { ProblemText(problem) }
                    }
                    .padding(.top, 4)
                }
            }
        }
    }
}
