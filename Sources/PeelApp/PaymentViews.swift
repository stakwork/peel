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
    /// The one-tap Boost, as in the official apps (Tom, 2026-10-07): the
    /// boost amount, plus a tribe's price, at once, with no panel and no
    /// confirmation. The row shows it pending, then the bolt or Retry,
    /// through storage; the engine ignores a second tap within a second. A
    /// refusal (the balance) shows in the chat, as the official apps' alert.
    func quickBoost(_ message: Message) async {
        guard let id = message.id else { return }
        switch await pay("boost \(id)", { try await $0.quickBoost(messageID: id) }) {
        case .refused(let reason): conversationNotices[message.chat] = "Could not boost: \(reason)"
        case .sent:
            sent(in: message.chat)
            if conversationNotices[message.chat]?.hasPrefix("Could not boost") == true {
                conversationNotices[message.chat] = nil
            }
        case .needsConfirmation, .busy: break
        }
    }

    /// "Boost 100 sats": the boost amount only, as the hover bar and menu
    /// name it. Neither official app shows a tribe's price on a boost (the
    /// chip's total then includes it, as theirs does).
    var quickBoostLabel: String { "Boost \(Sats.format(msat: boostAmountMsat))" }

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
        let outcome = await pay("pay \(chat)") {
            try await $0.sendPayment(to: chat, amountMsat: amountMsat, text: note.trimmed, confirmedMsat: confirmedMsat)
        }
        if case .sent = outcome { sent(in: chat) }
        return outcome
    }

    /// Sends a failed payment or boost again, for the amount it was for.
    func retryPayment(_ message: Message, confirmedMsat: UInt64?) async -> PaymentOutcome {
        guard let id = message.id else { return .refused("This payment cannot be sent again.") }
        return await pay("retry \(id)") { try await $0.resend(messageID: id, confirmedMsat: confirmedMsat) }
    }

    /// One payment at a time per key, through the engine; its refusals in
    /// words, and the threshold's question as an outcome.
    func pay(_ key: String, _ action: (Engine) async throws -> Void) async -> PaymentOutcome {
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
/// says the verb ("Boost", "Send", "Pay", "Unlock"); once the engine asks,
/// it turns orange, naming the amount ("Send 2,000 sats") unless it already
/// stands beside the button, with "Click again to confirm" under it, and the next click sends
/// exactly that. Any change to the amount puts it back. `send` is called
/// with nil, then with the amount.
struct PayButton: View {
    /// "Boost", "Send", "Save", "Pay", "Unlock".
    let verb: String
    /// The total as it stands; nil while the amount is not valid.
    let totalMsat: UInt64?
    let attempt: PaymentAttempt
    let send: (_ confirmedMsat: UInt64?) async -> PaymentOutcome
    var sent: () -> Void = {}
    /// Return presses it: in a panel of its own, not in a list of many.
    var isDefault = true
    /// Armed, the button names the amount ("Boost 150 sats"); false where the
    /// amount already stands beside it (a request, a paid attachment, an
    /// invoice), so it says only the verb, in orange.
    var namesAmount = true

    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            Button {
                Task { if await attempt.run(send) { sent() } }
            } label: {
                Text(attempt.armed.flatMap { namesAmount ? "\(verb) \(Sats.format(msat: $0))" : nil } ?? verb)
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
                    .buttonProgress(attempt.working)
            }
            .buttonStyle(FormButtonStyle(kind: .primary, fill: attempt.armed == nil ? nil : Theme.attention))
            .keyboardShortcut(isDefault ? .defaultAction : nil)
            // Not off while it sends, so it keeps its fill under the spinner;
            // `PaymentAttempt.run` ignores a second click.
            .disabled(totalMsat == nil)
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
            .fixedSize()
    }
}

/// "Balance 12,345 sats", quiet, under a payment form.
struct BalanceLine: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Text(model.balanceMsat.map { "Balance \(Sats.format(msat: $0))" } ?? "Balance known once connected")
            .font(Theme.font(12))
            .monospacedDigit()
            .foregroundStyle(Theme.secondaryText)
    }
}

/// A field for a whole number of sats: the form's number field, digits only.
struct SatsField: View {
    let label: String
    @Binding var text: String

    var body: some View {
        FormNumberField(label: label, text: $text, unit: "sats")
            .onChange(of: text) { _, value in
                let digits = String(value.filter { $0.isASCII && $0.isNumber }.prefix(12))
                if digits != value { text = digits }
            }
    }
}

/// Sending or requesting sats in a direct message: amount, an optional
/// note (a request's memo), and Send with your balance, or Request. A
/// request moves no money, so it takes one click.
struct SendSatsPanel: View {
    @Environment(AppModel.self) private var model
    let chat: String
    let name: String
    let done: () -> Void

    enum Mode: Hashable { case send, request }

    @State private var mode = Mode.send
    @State private var amount = ""
    @State private var note = ""
    @State private var attempt = PaymentAttempt()
    @State private var requesting = false
    @State private var requestProblem: String?

    var body: some View {
        let amountMsat = Sats.msat(amount)
        FormPopover(title: mode == .send ? "Send sats to \(name)" : "Request sats from \(name)", close: done) {
            SegmentedChoice(selection: $mode, options: [(.send, "Send"), (.request, "Request")])
                .padding(.top, 8)
            FormSection {
                FormRow(label: "Amount") { SatsField(label: "Amount", text: $amount) }
                FormRow(label: mode == .send ? "Note" : "What it's for") {
                    FormTextField(label: mode == .send ? "Note" : "What it's for", prompt: "Optional", text: $note)
                }
            }
            Group {
                if mode == .send {
                    BalanceLine()
                } else {
                    Text("\(name) gets an invoice in this chat, payable for an hour.")
                        .font(Theme.font(12))
                        .foregroundStyle(Theme.secondaryText)
                }
            }
            .padding(.horizontal, 4)
            .padding(.top, 8)
        } footer: {
            switch mode {
            case .send:
                FormFooter(problem: attempt.problem) {
                    Button("Cancel", action: done)
                        .buttonStyle(FormButtonStyle())
                        .disabled(attempt.working)
                    PayButton(verb: "Send", totalMsat: amountMsat, attempt: attempt, send: { confirmed in
                        guard let amountMsat else { return .refused("Enter an amount.") }
                        return await model.sendPayment(to: chat, amountMsat: amountMsat, note: note, confirmedMsat: confirmed)
                    }, sent: done)
                }
            case .request:
                FormFooter(problem: requestProblem) {
                    Button("Cancel", action: done)
                        .buttonStyle(FormButtonStyle())
                        .disabled(requesting)
                    Button {
                        // Not twice: the button stays on, keeping its fill under the spinner.
                        guard let amountMsat, !requesting else { return }
                        requesting = true
                        Task {
                            defer { requesting = false }
                            do {
                                try await model.requestPayment(from: chat, amountMsat: amountMsat, memo: note)
                                done()
                            } catch {
                                requestProblem = PeelError.readable(error)
                            }
                        }
                    } label: { Text("Request").buttonProgress(requesting) }
                    .buttonStyle(FormButtonStyle(kind: .primary))
                    .keyboardShortcut(.defaultAction)
                    .disabled(amountMsat == nil)
                }
            }
        }
        // A new note is a new payment: ask again over the threshold.
        .onChange(of: note) {
            attempt.armed = nil
            attempt.problem = nil
        }
        .onChange(of: mode) { requestProblem = nil }
    }
}

/// Two or three choices side by side, the chosen one filled, as on the
/// boards; on the form's soft fill, as a boxed field is.
struct SegmentedChoice<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(Value, String)]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { value, label in
                Button {
                    selection = value
                } label: {
                    Text(label)
                        .font(Theme.font(12, selection == value ? .medium : .regular))
                        .foregroundStyle(selection == value ? Theme.selectionText : Theme.secondaryText)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3)
                        .background(selection == value ? Theme.selection : .clear, in: RoundedRectangle(cornerRadius: 5))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Theme.fieldFill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.formEdge))
    }
}

// MARK: - Account

/// A setting's presets, with its current value among them if it is not one.
func presets<Value: Comparable>(_ choices: [Value], including current: Value) -> [Value] {
    choices.contains(current) ? choices : (choices + [current]).sorted()
}

/// What the one-tap Boost tips (the official apps' "Default tip amount",
/// 100 sats): presets, or another amount typed in. Over the confirmation
/// threshold a typed amount takes a second click, as a payment would.
struct BoostAmountRow: View {
    @Environment(AppModel.self) private var model
    @State private var custom: String?
    @State private var attempt = PaymentAttempt()

    private static let choices: [UInt64] = [10, 50, 100, 500, 1_000].map { $0 * Sats.msatPerSat }
    /// "Custom…" in the dropdown; never an amount (zero is refused).
    private static let other: UInt64 = 0

    var body: some View {
        let current = model.boostAmountMsat
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                PeelDropdown(
                    selection: custom == nil ? current : Self.other,
                    options: presets(Self.choices, including: current).map { ($0, Sats.format(msat: $0)) }
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
                    SatsField(label: "Boost amount", text: Binding(get: { custom }, set: { self.custom = $0 }))
                    PayButton(verb: "Save", totalMsat: typed, attempt: attempt, send: { confirmed in
                        guard let typed else { return .refused("Enter an amount.") }
                        return await model.setBoostAmount(msat: typed, confirmedMsat: confirmed)
                    }, sent: { self.custom = nil })
                }
            }
            Text(attempt.problem ?? "Boost sends this at once, plus a tribe's price.")
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
    private static let choices: [UInt64] = [0, 100, 1_000, 10_000].map { $0 * Sats.msatPerSat }

    var body: some View {
        let current = model.paymentConfirmationMsat
        VStack(alignment: .leading, spacing: 2) {
            PeelDropdown(
                selection: current,
                options: presets(Self.choices, including: current)
                    .map { ($0, $0 == 0 ? "Always confirm" : "Over \(Sats.format(msat: $0))") }
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
