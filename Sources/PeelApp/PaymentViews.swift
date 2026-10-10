import SwiftUI
import PeelCore

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
            .buttonStyle(.peel(.primary, fill: attempt.armed == nil ? nil : Theme.attention))
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
        Text(model.balanceText.map { "Balance \($0)" } ?? "Balance known once connected")
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
    /// The payment template's muid, nil for none.
    @State private var template: String?
    @State private var attempt = PaymentAttempt()
    @State private var requesting = false
    @State private var requestProblem: String?

    var body: some View {
        let amountMsat = Sats.msat(amount)
        FormPopover(title: mode == .send ? "Send sats to \(name)" : "Request sats from \(name)", close: done) {
            SegmentedChoice(selection: $mode, options: [(.send, "Send"), (.request, "Request")])
                .padding(.top, 8)
            FormSection {
                FormItem(label: "Amount") { SatsField(label: "Amount", text: $amount) }
                FormItem(label: mode == .send ? "Note" : "What it's for") {
                    FormTextField(label: mode == .send ? "Note" : "What it's for", prompt: "Optional", text: $note)
                }
                if mode == .send {
                    TemplatePicker(selection: $template)
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
            .padding(.top, 10)
        } footer: {
            switch mode {
            case .send:
                FormFooter(problem: attempt.problem) {
                    Button("Cancel", action: done)
                        .buttonStyle(.peel(.outline))
                        .disabled(attempt.working)
                    PayButton(verb: "Send", totalMsat: amountMsat, attempt: attempt, send: { confirmed in
                        guard let amountMsat else { return .refused("Enter an amount.") }
                        return await model.sendPayment(
                            to: chat, amountMsat: amountMsat, note: note, template: template, confirmedMsat: confirmed
                        )
                    }, sent: done)
                }
            case .request:
                FormFooter(problem: requestProblem) {
                    Button("Cancel", action: done)
                        .buttonStyle(.peel(.outline))
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
                    .buttonStyle(.peel(.primary))
                    .keyboardShortcut(.defaultAction)
                    .disabled(amountMsat == nil)
                }
            }
        }
        // A new note or picture is a new payment: ask again over the threshold.
        .onChange(of: note) {
            attempt.armed = nil
            attempt.problem = nil
        }
        .onChange(of: template) {
            attempt.armed = nil
            attempt.problem = nil
        }
        .onChange(of: mode) { requestProblem = nil }
    }
}

/// The picture a payment carries, as the official apps' templates: None
/// first and chosen at the start, then the memes server's pictures in a
/// row that scrolls. A click picks one; with the row focused (Tab), the
/// left and right arrows step through them.
struct TemplatePicker: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: String?

    private enum Loading { case loading, loaded([PaymentTemplate]), failed(String) }
    @State private var loading = Loading.loading
    @FocusState private var focused: Bool

    static let tile: CGFloat = 48

    var body: some View {
        FormItem(label: "Picture", helper: helper) {
            switch loading {
            case .loaded(let templates) where !templates.isEmpty:
                row([nil] + templates.map(\.muid))
            case .loading:
                ProgressView().controlSize(.small).frame(height: Self.tile)
            case .loaded, .failed:
                EmptyView()
            }
        }
        .task {
            do {
                loading = .loaded(try await model.paymentTemplates())
            } catch {
                loading = .failed(PeelError.readable(error))
            }
        }
    }

    private var helper: String? {
        switch loading {
        case .loading: nil
        case .loaded(let templates): templates.isEmpty ? "This account's memes server offers no pictures." : nil
        case .failed(let reason): "Pictures could not be loaded: \(reason)"
        }
    }

    private func row(_ choices: [String?]) -> some View {
        ScrollViewReader { scroller in
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(choices, id: \.self) { muid in
                        Button { selection = muid } label: { tile(muid) }
                            .buttonStyle(.plain)
                            .id(muid)
                            .accessibilityLabel(muid == nil ? "No picture" : "Picture")
                            .accessibilityAddTraits(selection == muid ? .isSelected : [])
                    }
                }
                .padding(5)
                .padding(.bottom, 6)
            }
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.control + 5, style: .continuous)
                    .strokeBorder(Theme.accent.opacity(focused ? 0.5 : 0), lineWidth: 2)
                    .allowsHitTesting(false)
            }
            .onKeyPress(.leftArrow) { step(-1, in: choices) }
            .onKeyPress(.rightArrow) { step(1, in: choices) }
            .onChange(of: selection) { scroller.scrollTo(selection, anchor: .center) }
        }
    }

    private func step(_ by: Int, in choices: [String?]) -> KeyPress.Result {
        let index = choices.firstIndex(of: selection) ?? 0
        selection = choices[min(max(index + by, 0), choices.count - 1)]
        return .handled
    }

    private func tile(_ muid: String?) -> some View {
        let chosen = selection == muid
        return Group {
            if let muid {
                TemplateImage(muid: muid, side: Self.tile)
            } else {
                Text("None")
                    .font(Theme.font(11, .medium))
                    .foregroundStyle(Theme.secondaryText)
            }
        }
        .frame(width: Self.tile, height: Self.tile)
        .background(Theme.fieldFill, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .strokeBorder(chosen ? Theme.accent : Theme.formEdge, lineWidth: chosen ? 2 : 1)
        }
        .contentShape(Rectangle())
    }
}

/// A payment template's picture, aspect fit in a square of `side`: by its
/// muid (the picker), or the one a payment in the chat carries.
struct TemplateImage: View {
    @Environment(AppModel.self) private var model
    var muid: String?
    var message: Message?
    let side: CGFloat

    @State private var loaded: CGImage?
    @State private var failed = false

    /// The muid, and for a payment's picture the host its token names.
    private var named: (host: String?, muid: String)? {
        if let muid { return (nil, muid) }
        return message?.paymentTemplate.map { ($0.host, $0.muid) }
    }
    private var key: String? { named.map { "\($0.host ?? "")|\($0.muid)" } }
    private var pixels: Int { Int(side * 2) }

    var body: some View {
        Group {
            if let image = loaded ?? named.flatMap({ ImageCache.shared.cached(template: $0.muid, host: $0.host, maxPixels: pixels) }) {
                Image(decorative: image, scale: 1).resizable().scaledToFit()
            } else if failed {
                Image(systemName: "photo")
                    .font(.system(size: side > 60 ? 18 : 13))
                    .foregroundStyle(Theme.secondaryText)
                    .help("Picture not available")
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(width: side, height: side)
        .task(id: key) {
            guard let named else { return }
            if loaded != nil || failed { (loaded, failed) = (nil, false) }
            let image = if let message {
                await model.templateImage(of: message, maxPixels: pixels)
            } else {
                await model.templateImage(muid: named.muid, maxPixels: pixels)
            }
            loaded = image
            failed = image == nil
        }
        .accessibilityLabel("Payment picture")
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
                        .frame(width: 120)
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
