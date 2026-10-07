import SwiftUI
import PeelCore

// MARK: - Model

/// How a boost or payment went from here.
enum PaymentOutcome: Equatable {
    case sent
    /// Over the confirmation threshold: show this amount and ask once more.
    case needsConfirmation(msat: UInt64)
    case refused(String)
    /// The same payment is already on its way (a double click).
    case busy
}

extension AppModel {
    /// What a boost with this tip costs here, as the engine will count it:
    /// the tribe's price and escrow (0 in a direct message) and the total.
    func boostCost(tipMsat: UInt64, in chat: String) -> (priceMsat: UInt64, totalMsat: UInt64)? {
        let tribe = isTribe(chat) ? tribe(chat) : nil
        return Engine.boostTotalMsat(tipMsat: tipMsat, in: tribe).map { (tribe?.paymentPriceMsat ?? 0, $0) }
    }

    /// Boosts someone else's message by `tipMsat` (the engine adds a tribe's
    /// price). `confirmedMsat`: the total the person confirmed, if asked.
    func boost(_ message: Message, tipMsat: UInt64, confirmedMsat: UInt64?) async -> PaymentOutcome {
        guard let id = message.id else { return .refused("This message cannot be boosted.") }
        return await pay("boost \(id)") {
            try await $0.boost(messageID: id, amountMsat: tipMsat, confirmedMsat: confirmedMsat)
        }
    }

    /// The one-tap Boost, as in the official apps (Tom, 2026-10-07): the
    /// boost amount, plus a tribe's price, at once, with no panel and no
    /// confirmation. The row shows it pending, then the bolt or Retry,
    /// through storage; the engine ignores a second tap within a second. A
    /// refusal (the balance) shows in the chat, as the official apps' alert.
    func quickBoost(_ message: Message) async {
        guard let id = message.id else { return }
        switch await pay("boost \(id)", { try await $0.quickBoost(messageID: id) }) {
        case .refused(let reason): conversationNotices[message.chat] = "Could not boost: \(reason)"
        case .sent: if conversationNotices[message.chat]?.hasPrefix("Could not boost") == true {
            conversationNotices[message.chat] = nil
        }
        case .needsConfirmation, .busy: break
        }
    }

    /// "Boost 100 sats": the boost amount only, as the hover bar and menu
    /// name it. Neither official app shows a tribe's price on a boost (the
    /// chip's total then includes it, as theirs does).
    var quickBoostLabel: String { "Boost \(Formatting.sats(msat: boostAmountMsat))" }

    /// Over the confirmation threshold the engine asks first, as for a payment.
    func setBoostAmount(msat: UInt64, confirmedMsat: UInt64?) async -> PaymentOutcome {
        guard let engine else { return .refused("Not signed in.") }
        do {
            try await engine.setBoostAmount(msat: msat, confirmedMsat: confirmedMsat)
            boostAmountMsat = msat
            return .sent
        } catch Engine.Failure.needsConfirmation(let msat) {
            return .needsConfirmation(msat: msat)
        } catch {
            return .refused(PeelError.readable(error))
        }
    }

    /// Sends sats to a contact in their chat, with an optional note.
    func sendPayment(to chat: String, amountMsat: UInt64, note: String, confirmedMsat: UInt64?) async -> PaymentOutcome {
        await pay("pay \(chat)") {
            try await $0.sendPayment(to: chat, amountMsat: amountMsat, text: note.trimmed, confirmedMsat: confirmedMsat)
        }
    }

    /// Sends a failed payment or boost again, for the amount it was for.
    func retryPayment(_ message: Message, confirmedMsat: UInt64?) async -> PaymentOutcome {
        guard let id = message.id else { return .refused("This payment cannot be sent again.") }
        return await pay("retry \(id)") { try await $0.resend(messageID: id, confirmedMsat: confirmedMsat) }
    }

    /// One payment at a time per key, through the engine; its refusals in
    /// words, and the threshold's question as an outcome.
    private func pay(_ key: String, _ action: (Engine) async throws -> Void) async -> PaymentOutcome {
        guard let engine else { return .refused("Not signed in.") }
        guard moneyInFlight.insert(key).inserted else { return .busy }
        defer { moneyInFlight.remove(key) }
        do {
            try await action(engine)
            return .sent
        } catch Engine.Failure.needsConfirmation(let msat) {
            return .needsConfirmation(msat: msat)
        } catch {
            return .refused(PeelError.readable(error))
        }
    }

    func setPaymentConfirmation(msat: UInt64) async throws {
        try await signedIn().setPaymentConfirmation(msat: msat)
        paymentConfirmationMsat = msat
    }
}

extension Formatting {
    /// "1,210": whole sats, for chips and lists.
    static func satsNumber(msat: Int64) -> String {
        (max(msat, 0) / 1000).formatted()
    }

    /// As `sats(msat:)` for a stored amount, never below nothing.
    static func sats(msat: Int64) -> String {
        sats(msat: UInt64(max(msat, 0)))
    }
}

// MARK: - Paying

/// One payment from a button: the engine is asked first; over the threshold
/// it answers with the amount, which arms the button (orange, "Boost 150 sats"),
/// and the second click sends exactly that amount (the engine refuses any
/// other). Not twice while one is on its way.
@MainActor @Observable
final class PaymentAttempt {
    /// The amount the engine asked to confirm, once asked.
    var armed: UInt64?
    var working = false
    var problem: String?

    /// Returns whether it was sent.
    func run(_ send: (_ confirmedMsat: UInt64?) async -> PaymentOutcome) async -> Bool {
        guard !working else { return false }
        working = true
        problem = nil
        let outcome = await send(armed)
        working = false
        switch outcome {
        case .sent:
            armed = nil
            return true
        case .needsConfirmation(let msat):
            armed = msat
        case .refused(let reason):
            armed = nil
            problem = reason
        case .busy:
            break
        }
        return false
    }
}

/// The button that sends money (Tom, 2026-10-07: plain verbs). Idle it
/// says the verb ("Boost", "Send"); once the engine asks, it turns orange
/// and names the amount ("Boost 150 sats"), with "Click again to confirm"
/// under it, and the next click sends exactly that. Any change to the
/// amount puts it back. `send` is called with nil, then with the amount.
struct PayButton: View {
    /// "Boost", "Send", "Save".
    let verb: String
    /// The total as it stands; nil while the amount is not valid.
    let totalMsat: UInt64?
    let attempt: PaymentAttempt
    let send: (_ confirmedMsat: UInt64?) async -> PaymentOutcome
    var sent: () -> Void = {}

    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            Button {
                Task { if await attempt.run(send) { sent() } }
            } label: {
                Text(attempt.armed.map { "\(verb) \(Formatting.sats(msat: $0))" } ?? verb).monospacedDigit()
            }
            .buttonStyle(GhostButtonStyle(prominent: true, fill: attempt.armed == nil ? nil : Theme.attention))
            .keyboardShortcut(.defaultAction)
            .disabled(totalMsat == nil || attempt.working)
            if attempt.armed != nil {
                ConfirmHint()
            }
        }
        .onChange(of: totalMsat) { attempt.armed = nil }
    }
}

/// "Click again to confirm", quiet, beside or under an armed money button.
struct ConfirmHint: View {
    var body: some View {
        Text("Click again to confirm")
            .font(Theme.font(11))
            .foregroundStyle(Theme.secondaryText)
    }
}

/// "Balance 12,345 sats", quiet, under a payment form.
private struct BalanceLine: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Text(model.balanceMsat.map { "Balance \(Formatting.sats(msat: $0))" } ?? "Balance known once connected")
            .font(Theme.font(12))
            .monospacedDigit()
            .foregroundStyle(Theme.secondaryText)
    }
}

/// A label and an amount on one line, the amount right-aligned.
private struct AmountLine: View {
    let label: String
    let msat: UInt64?
    var bold = false

    var body: some View {
        HStack {
            Text(label)
                .foregroundStyle(bold ? Theme.text : Theme.secondaryText)
            Spacer()
            Text(msat.map { Formatting.sats(msat: $0) } ?? "–")
                .monospacedDigit()
                .foregroundStyle(Theme.text)
        }
        .font(Theme.font(13, bold ? .semibold : .regular))
    }
}

/// A field for a whole number of sats.
struct SatsField: View {
    let placeholder: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 6) {
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .monospacedDigit()
                .onChange(of: text) { _, value in
                    let digits = String(value.filter { $0.isASCII && $0.isNumber }.prefix(12))
                    if digits != value { text = digits }
                }
            Text("sats")
                .foregroundStyle(Theme.secondaryText)
        }
        .font(Theme.font(13))
        .fieldBoxed()
    }
}

/// Boosting a message: a tip (presets or your own), the tribe's price on
/// top when in a tribe, the total, your balance, and Boost.
struct BoostPanel: View {
    @Environment(AppModel.self) private var model
    let message: Message
    let done: () -> Void

    static let presets: [UInt64] = [10, 50, 100, 500]

    @State private var tip: UInt64 = 100
    @State private var custom = ""
    @State private var attempt = PaymentAttempt()

    private var tipMsat: UInt64? {
        custom.isEmpty ? tip * 1000 : Sats.msat(custom)
    }

    var body: some View {
        let cost = tipMsat.flatMap { model.boostCost(tipMsat: $0, in: message.chat) }
        VStack(alignment: .leading, spacing: 12) {
            Text("Boost \(model.sender(of: message).name)")
                .font(Theme.font(15, .bold))
                .lineLimit(1)
            HStack(spacing: 6) {
                ForEach(Self.presets, id: \.self) { sats in
                    let chosen = custom.isEmpty && tip == sats
                    Button {
                        tip = sats
                        custom = ""
                    } label: {
                        Text(sats.formatted())
                            .font(Theme.font(13, chosen ? .semibold : .regular))
                            .monospacedDigit()
                            .foregroundStyle(chosen ? Theme.selectionText : Theme.text)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 5)
                            .background(chosen ? Theme.selection : Theme.input, in: RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(chosen ? .clear : Theme.divider))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            SatsField(placeholder: "Other amount", text: $custom)
            VStack(spacing: 4) {
                if let price = cost?.priceMsat, price > 0 {
                    AmountLine(label: "Tip", msat: tipMsat)
                    AmountLine(label: "Tribe price and escrow", msat: price)
                }
                AmountLine(label: "Total", msat: cost?.totalMsat, bold: true)
            }
            BalanceLine()
            FormFooter(problem: attempt.problem, working: attempt.working) {
                PayButton(verb: "Boost", totalMsat: cost?.totalMsat, attempt: attempt, send: { confirmed in
                    guard let tipMsat else { return .refused("Enter an amount.") }
                    return await model.boost(message, tipMsat: tipMsat, confirmedMsat: confirmed)
                }, sent: done)
            }
        }
        .padding(16)
        .frame(width: 300)
    }
}

/// Sending sats in a direct message: amount, an optional note, your
/// balance, and Send.
struct SendSatsPanel: View {
    @Environment(AppModel.self) private var model
    let chat: String
    let name: String
    let done: () -> Void

    @State private var amount = ""
    @State private var note = ""
    @State private var attempt = PaymentAttempt()

    var body: some View {
        let amountMsat = Sats.msat(amount)
        VStack(alignment: .leading, spacing: 12) {
            Text("Send sats to \(name)")
                .font(Theme.font(15, .bold))
                .lineLimit(1)
            SatsField(placeholder: "Amount", text: $amount)
            TextField("Note (optional)", text: $note)
                .textFieldStyle(.plain)
                .font(Theme.font(13))
                .fieldBoxed()
            BalanceLine()
            FormFooter(problem: attempt.problem, working: attempt.working) {
                PayButton(verb: "Send", totalMsat: amountMsat, attempt: attempt, send: { confirmed in
                    guard let amountMsat else { return .refused("Enter an amount.") }
                    return await model.sendPayment(to: chat, amountMsat: amountMsat, note: note, confirmedMsat: confirmed)
                }, sent: done)
            }
        }
        .padding(16)
        .frame(width: 300)
        // A new note is a new payment: ask again over the threshold.
        .onChange(of: note) {
            attempt.armed = nil
            attempt.problem = nil
        }
    }
}

// MARK: - In the conversation

/// Under a message: its boosts as a chip ("⚡ 1,210 sats" and the boosters'
/// photos; tinted when you boosted it), who boosted on a click, and your boosts that are still on
/// their way or failed.
struct BoostLine: View {
    let boosts: BoostSummary
    /// False under a deleted message: only our failed boosts stay, to clear.
    var showsChip = true

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if showsChip, boosts.count > 0 {
                BoostChip(boosts: boosts)
            }
            if let since = boosts.pendingSince {
                WaitingForServer(since: since, what: "Boost")
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
private struct BoostChip: View {
    @Environment(AppModel.self) private var model
    let boosts: BoostSummary

    @State private var showing = false
    @State private var hovering = false

    static let shownBoosters = 3
    /// 24 or more, so a booster without a photo shows their initial.
    private static let avatarSize: CGFloat = 24
    private static let overlap: CGFloat = 8

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
        let pending = boosts.pendingSince != nil
        let people = boosters
        let ring = boosts.boostedByMe ? Theme.selection : hovering ? Theme.hover : Theme.quote
        Button {
            showing = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(pending ? Theme.secondaryText : Theme.attention)
                (Text(Formatting.satsNumber(msat: boosts.totalMsat)).font(Theme.font(12, .semibold))
                    .foregroundColor(Theme.text)
                    + Text(" sats").font(Theme.font(12)).foregroundColor(Theme.secondaryText))
                HStack(spacing: -Self.overlap) {
                    ForEach(Array(people.prefix(Self.shownBoosters).enumerated()), id: \.offset) { index, boost in
                        Avatar(name: boost.fromMe ? model.myAlias ?? "?" : boost.alias ?? "?",
                               url: boost.fromMe ? model.myPhotoURL : boost.photoURL, size: Self.avatarSize)
                            .padding(1.5)
                            .background(ring, in: Circle())
                            .zIndex(Double(Self.shownBoosters - index))
                    }
                }
                if people.count > Self.shownBoosters {
                    Text("+\(people.count - Self.shownBoosters)")
                        .font(Theme.font(12, .medium))
                        .foregroundStyle(Theme.secondaryText)
                }
            }
            .monospacedDigit()
            .padding(.leading, 9)
            .padding(.trailing, people.count > Self.shownBoosters ? 9 : 3)
            .padding(.vertical, 2)
            .background(ring, in: Capsule())
            .overlay(Capsule().strokeBorder(boosts.boostedByMe ? Theme.accent.opacity(0.6) : Theme.divider))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .peelPopover(isPresented: $showing) {
            BoostersPanel(boosts: boosts)
        }
    }

    private var help: String {
        let count = boosts.count == 1 ? "1 boost" : "\(boosts.count) boosts"
        return "\(Formatting.sats(msat: boosts.totalMsat)) from \(count)"
            + (boosts.boostedByMe ? ", yours among them" : "") + ". Click for who."
    }
}

/// Who boosted a message and by how much, oldest first.
private struct BoostersPanel: View {
    @Environment(AppModel.self) private var model
    let boosts: BoostSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Boosts")
                    .font(Theme.font(14, .bold))
                Spacer()
                Text(Formatting.sats(msat: boosts.totalMsat))
                    .font(Theme.font(13, .semibold))
                    .monospacedDigit()
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(boosts.boosts.enumerated()), id: \.offset) { _, boost in
                        let name = boost.fromMe ? "You" : boost.alias ?? "Someone"
                        HStack(spacing: 8) {
                            Avatar(name: boost.fromMe ? model.myAlias ?? "?" : name,
                                   url: boost.fromMe ? model.myPhotoURL : boost.photoURL, size: 22)
                            Text(name)
                                .font(Theme.font(13))
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            if boost.pendingSince != nil {
                                Text("sending")
                                    .font(Theme.font(12))
                                    .foregroundStyle(Theme.secondaryText)
                            }
                            Text(Formatting.sats(msat: boost.amountMsat))
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
        .padding(14)
        .frame(width: 260)
    }
}

/// "Waiting for the server…" once our payment or boost has gone unconfirmed
/// past the usual wait. It may have paid, so there is no Discard or Retry
/// until the engine marks it failed.
struct WaitingForServer: View {
    let since: Date
    let what: String

    var body: some View {
        TimelineView(.explicit([since.addingTimeInterval(Message.confirmationTimeout)])) { context in
            if context.date.timeIntervalSince(since) >= Message.confirmationTimeout {
                Text("\(what) waiting for the server…")
                    .font(Theme.font(11, .medium))
                    .foregroundStyle(Theme.secondaryText)
                    .help("It may already have paid, so it cannot be sent again until the server says it failed.")
            }
        }
    }
}

/// A direct payment in the timeline: a bolt, who sent how much ("You sent
/// 1,000 sats", "Bob sent you 1,000 sats"), the note, the time, and for
/// ours the delivery bolt, the wait or Retry.
struct PaymentRow: View {
    let row: ChatRow

    @State private var hovering = false

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
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    headline
                    Text(message.date, format: .dateTime.hour().minute())
                        .font(Theme.font(12))
                        .monospacedDigit()
                        .foregroundStyle(Theme.secondaryText)
                        .help(message.date.formatted(date: .complete, time: .shortened))
                    if message.fromMe, message.delivery == .delivered {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(Theme.confirmed)
                            .help("Delivered")
                    }
                }
                if !message.deleted, let note = message.content?.trimmed.nilIfEmpty {
                    MessageText(text: note)
                }
                if message.fromMe, !message.deleted {
                    switch message.delivery {
                    case .pending: WaitingForServer(since: message.date, what: "Payment")
                    case .failed: UndeliveredActions(message: message)
                    case .delivered, nil: EmptyView()
                    }
                }
            }
            .frame(maxWidth: MessageRow.textWidth, alignment: .leading)
            .opacity(message.fromMe && message.delivery == .pending ? 0.6 : 1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 6)
        .background {
            if hovering {
                Theme.hover.opacity(0.55)
            } else if message.fromMe {
                Theme.accent.opacity(0.06)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .peelMenu(source: row.id) {
            message.content?.trimmed.nilIfEmpty.map { [.copyText($0)] } ?? []
        }
    }

    @ViewBuilder private var headline: some View {
        let who = row.alias ?? "Someone"
        if message.deleted {
            Text("This payment has been deleted")
                .font(Theme.font(13))
                .italic()
                .foregroundStyle(Theme.secondaryText)
        } else if let msat = message.amountMsat, msat > 0 {
            let amount = Text(Formatting.sats(msat: msat)).font(Theme.font(14, .semibold))
            (message.fromMe ? Text("You sent ") + amount : Text("\(who) sent you ") + amount)
                .font(Theme.font(14))
                .monospacedDigit()
                .foregroundStyle(Theme.text)
        } else {
            // A contact's type 5 that carried no sats: whatever it declared
            // is not money received.
            Text(message.fromMe ? "You sent a payment" : "\(who) sent a payment with no sats")
                .font(Theme.font(14))
                .foregroundStyle(Theme.secondaryText)
        }
    }
}

// MARK: - Account

/// A setting's presets, with its current value among them if it is not one.
private func presets(_ choices: [UInt64], including current: UInt64) -> [UInt64] {
    choices.contains(current) ? choices : (choices + [current]).sorted()
}

/// What the one-tap Boost tips (the official apps' "Default tip amount",
/// 100 sats): presets, or another amount typed in. Over the confirmation
/// threshold a typed amount takes a second click, as a payment would.
struct BoostAmountRow: View {
    @Environment(AppModel.self) private var model
    @State private var custom: String?
    @State private var attempt = PaymentAttempt()

    private static let choices: [UInt64] = [10, 50, 100, 500, 1_000].map { $0 * 1000 }
    /// "Custom…" in the dropdown; never an amount (zero is refused).
    private static let other: UInt64 = 0

    var body: some View {
        let current = model.boostAmountMsat
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                PeelDropdown(
                    selection: custom == nil ? current : Self.other,
                    options: presets(Self.choices, including: current).map { ($0, Formatting.sats(msat: $0)) }
                        + [(Self.other, "Custom…")]
                ) { msat in
                    attempt.armed = nil
                    if msat == Self.other {
                        custom = ""
                    } else {
                        custom = nil
                        // Picking a labelled preset is the confirmation.
                        Task { _ = await attempt.run { _ in await model.setBoostAmount(msat: msat, confirmedMsat: msat) } }
                    }
                }
                .fixedSize()
                if let custom {
                    let typed = Sats.msat(custom)
                    SatsField(placeholder: "Amount", text: Binding(get: { custom }, set: { self.custom = $0 }))
                        .frame(width: 120)
                    PayButton(verb: "Save", totalMsat: typed, attempt: attempt, send: { confirmed in
                        guard let typed else { return .refused("Enter an amount.") }
                        return await model.setBoostAmount(msat: typed, confirmedMsat: confirmed)
                    }, sent: { self.custom = nil })
                }
            }
            Text(attempt.problem ?? "Boost sends this at once, plus a tribe's price; Boost… in a message's menu picks another amount.")
                .font(Theme.font(12))
                .foregroundStyle(Theme.secondaryText)
        }
    }
}

/// The threshold over which a payment or boost takes a second click.
struct PaymentConfirmationRow: View {
    @Environment(AppModel.self) private var model
    @State private var problem: String?

    /// "Always confirm" (0), then over 100, 1,000 and 10,000 sats.
    private static let choices: [UInt64] = [0, 100, 1_000, 10_000].map { $0 * 1000 }

    var body: some View {
        let current = model.paymentConfirmationMsat
        VStack(alignment: .leading, spacing: 2) {
            PeelDropdown(
                selection: current,
                options: presets(Self.choices, including: current)
                    .map { ($0, $0 == 0 ? "Always confirm" : "Over \(Formatting.sats(msat: $0))") }
            ) { msat in
                Task {
                    do {
                        try await model.setPaymentConfirmation(msat: msat)
                        problem = nil
                    } catch {
                        problem = PeelError.readable(error)
                    }
                }
            }
            .fixedSize()
            Text(problem ?? "A boost or payment above this takes a second click that shows the amount.")
                .font(Theme.font(12))
                .foregroundStyle(Theme.secondaryText)
        }
    }
}
