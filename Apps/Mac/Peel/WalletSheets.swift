import PeelCore
import PeelUI
import SwiftUI

/// The app wallet's CONNECT sheet (strut's specs/WALLET.md §5.2): who asks,
/// from Peel's own record of the page (the app, its version and where it
/// lives), what for, the spending limit (lowered here if the person wants,
/// never raised past what was asked), what to do over it, and when it ends.
struct WalletConnectSheetView: View {
    let sheet: WalletConnectSheet
    let done: @MainActor (WalletConnectAnswer?) -> Void

    @State private var limit: String
    @State private var overLimit: WalletConnection.OverBudget = .ask
    @State private var optional: Set<WalletMethod>
    /// Who the person signs in as, when the sheet asks.
    @State private var identity: SignInKey?

    init(sheet: WalletConnectSheet, done: @escaping @MainActor (WalletConnectAnswer?) -> Void) {
        self.sheet = sheet
        self.done = done
        _limit = State(initialValue: sheet.maxAmountMsat.map { Sats.number(msat: $0).replacingOccurrences(of: ",", with: "") } ?? "")
        _optional = State(initialValue: Set(sheet.optional))
        _overLimit = State(initialValue: sheet.held?.overBudget ?? .ask)
        _identity = State(initialValue: sheet.signIn?.keys.first)
    }

    /// The limit typed, in msat, never above what was asked; nil for none.
    private var limitMsat: Int64? {
        guard let typed = Sats.msat(limit).map(Int64.init(clamping:)) else { return nil }
        return sheet.maxAmountMsat.map { min(typed, $0) } ?? typed
    }

    private var raised: Bool {
        guard let asked = sheet.maxAmountMsat, let typed = Sats.msat(limit) else { return false }
        return typed > UInt64(asked)
    }

    var body: some View {
        let answers = WalletWords.connectAnswers(sheet)
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(WalletWords.connectTitle(sheet))
                    .font(Theme.font(16, .semibold))
                Text(WalletWords.who(title: sheet.title, app: sheet.app, version: sheet.version, place: sheet.place,
                                     byOrg: sheet.byOrg))
                    .muted()
            }
            FactList(labelWidth: 120) {
                if let offer = sheet.signIn {
                    Fact("Sign in") {
                        VStack(alignment: .leading, spacing: 6) {
                            Picker("Sign in", selection: $identity) {
                                ForEach(offer.keys, id: \.self) { key in
                                    Text(WalletWords.signIn(key)).tag(Optional(key))
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.radioGroup)
                            if let identity { Text(WalletWords.signInNote(identity)).muted().fixedSize(horizontal: false, vertical: true) }
                        }
                    }
                }
                if sheet.asksWallet { walletFacts }
            }
            Text(sheet.asksWallet ? "You can lower, raise or take this back in Account › Payments."
                                  : "You can take this back in Account › Payments › Connected apps.")
                .muted()
            HStack {
                Spacer()
                Button(answers.no) { done(nil) }
                    .buttonStyle(.peel(.outline))
                    .keyboardShortcut(.cancelAction)
                Button(answers.yes) {
                    done(WalletConnectAnswer(optional: Array(optional), maxAmountMsat: limitMsat, overBudget: overLimit,
                                             signIn: identity))
                }
                .buttonStyle(.peel(.primary))
                // No Return: a key meant for the page must never say yes.
                .disabled(!settled || (sheet.signIn != nil && identity == nil))
            }
        }
        .font(Theme.font(13))
        .padding(24)
        .frame(width: 460)
        .task { settled = await WalletSheetSettle.wait() }
    }

    /// What the app may spend: its methods, the limit, over it, the end.
    @ViewBuilder private var walletFacts: some View {
        Fact("It may") {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(WalletWords.methods(sheet.required), id: \.self) { Text($0) }
                ForEach(sheet.optional, id: \.self) { method in
                    Toggle(WalletWords.method(method), isOn: Binding(
                        get: { optional.contains(method) },
                        set: { if $0 { optional.insert(method) } else { optional.remove(method) } }
                    ))
                    .toggleStyle(.checkbox)
                }
                if !sheet.notifications.isEmpty { Text("Hear when its own payments land").muted() }
            }
        }
        Fact("Spending limit") {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    TextField("None", text: $limit)
                        .textFieldStyle(.roundedBorder)
                        .monospacedDigit()
                        .frame(width: 110)
                    Text("sats").muted()
                }
                Text(raised ? "Up to what the app asked for, \(Sats.format(msat: sheet.maxAmountMsat ?? 0))."
                            : WalletWords.limit(limitMsat, renewal: sheet.renewal))
                    .muted()
                Text("Inside it, the app pays without asking you.").muted()
            }
        }
        Fact("Over the limit") {
            Picker("Over the limit", selection: $overLimit) {
                Text("Ask me each time").tag(WalletConnection.OverBudget.ask)
                Text("Refuse").tag(WalletConnection.OverBudget.refuse)
            }
            .labelsHidden()
            .pickerStyle(.radioGroup)
        }
        if let expires = sheet.expiresAt {
            Fact("Ends", text: Date(timeIntervalSince1970: TimeInterval(expires)).formatted(date: .abbreviated, time: .shortened))
        }
    }

    /// The sheet has been up long enough that a click meant for the page
    /// cannot land on Connect.
    @State private var settled = false
}

/// How long a wallet sheet's yes waits after the sheet opens, and after
/// Pay arms, so a click or key meant for the page, or a double click, is
/// never the yes (the iPhone's `TouchPayButton.settle`).
enum WalletSheetSettle {
    static let delay: Duration = .milliseconds(700)

    static func wait() async -> Bool {
        (try? await Task.sleep(for: delay)) != nil
    }
}

/// The PAYMENT sheet for one payment over an app's limit (WALLET.md §5.3):
/// the amount Peel decoded, who it pays (their name when a contact), the
/// memo or keysend's message, when it expires, the fee, and the app's own
/// words marked as its. Paid on a second click, as every payment here
/// (`PayButton`); the person's "confirm over" amount is not asked: over
/// the limit, an app's payment is always asked.
struct WalletPaymentSheetView: View {
    let sheet: WalletPaymentSheet
    let done: @MainActor (Bool) -> Void
    @State private var attempt = PaymentAttempt()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(sheet.title) asks to pay")
                    .font(Theme.font(16, .semibold))
                Text(WalletWords.who(title: sheet.title, app: sheet.app, version: sheet.version, place: sheet.place,
                                     byOrg: sheet.byOrg))
                    .muted()
            }
            BigAmount(amount: Sats.number(msat: sheet.amountMsat), size: 30)
            FactList(labelWidth: 100) {
                let key = Formatting.shortKey(sheet.payee)
                Fact("To", text: sheet.payeeName.map { "\($0) · \(key)" } ?? "\(key), not a contact")
                if let memo = sheet.memo { Fact(sheet.keysend ? "Message" : "Memo", text: memo) }
                if let expires = sheet.expiresAt {
                    Fact("Expires", text: Date(timeIntervalSince1970: TimeInterval(expires)).formatted(.relative(presentation: .named)))
                }
                Fact("Fee", text: sheet.async ? "Added on top, with 1 sat to reach them" : "Added on top")
                if let max = sheet.maxAmountMsat {
                    Fact("Limit", text: "\(Sats.format(msat: sheet.usedMsat)) of \(Sats.format(msat: max)) spent")
                } else {
                    Fact("Limit", text: "None: it asks you each time")
                }
            }
            if let comment = sheet.comment {
                Callout(.neutral, "The app says", detail: "“\(comment)”")
            }
            HStack {
                Spacer()
                Button("Decline") { done(false) }
                    .buttonStyle(.peel(.outline))
                    .keyboardShortcut(.cancelAction)
                // Pay arms, the second click pays, each only once the sheet
                // (then the armed button) has settled; never on Return.
                PayButton(verb: "Pay", totalMsat: settled ? UInt64(max(sheet.amountMsat, 0)) : nil, attempt: attempt,
                          send: { confirmed in
                              let amount = UInt64(max(sheet.amountMsat, 0))
                              return confirmed == amount && armedSettled ? .sent : .needsConfirmation(msat: amount)
                          }, sent: { done(true) }, isDefault: false, namesAmount: true)
            }
        }
        .font(Theme.font(13))
        .padding(24)
        .frame(width: 440)
        .task { settled = await WalletSheetSettle.wait() }
        .task(id: attempt.armed) {
            armedSettled = false
            guard attempt.armed != nil else { return }
            armedSettled = await WalletSheetSettle.wait()
        }
    }

    @State private var settled = false
    /// Pay has been armed long enough that the click that armed it, doubled, cannot pay.
    @State private var armedSettled = false
}

/// Account › Payments › Connected apps: each app (or org) the person
/// connected, what it may do, its spending limit and what it spent this
/// period, what happens over it, and Disconnect. The limit can be lowered
/// or raised here at any time.
struct ConnectedAppsSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        SettingsSection("Connected apps") {
            if model.walletConnections.isEmpty {
                Fact("None yet") {
                    Text("An app that asks to use your wallet appears here once you connect it. Inside its spending limit it pays without asking you.")
                        .muted()
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                ForEach(model.walletConnections) { connection in
                    ConnectedAppRow(connection: connection)
                }
            }
        }
    }
}

private struct ConnectedAppRow: View {
    @Environment(AppModel.self) private var model
    let connection: WalletConnection
    @State private var spent: (usedMsat: UInt64, renewsAt: Int64?)?
    @State private var editing = false
    @State private var limit = ""
    @State private var disconnecting = false

    var body: some View {
        Fact(connection.title) {
            VStack(alignment: .leading, spacing: 6) {
                Text(connection.place).muted()
                if let signIn = connection.signIn { Text(WalletWords.signsIn(signIn, to: connection.place)) }
                if !connection.methods.isEmpty { walletRows }
                HStack(spacing: 8) {
                    if !editing, !connection.methods.isEmpty {
                        Button("Change limit") {
                            limit = connection.maxAmountMsat.map { String($0 / 1000) } ?? ""
                            editing = true
                        }
                        .buttonStyle(.peel(.outline))
                    }
                    if disconnecting {
                        Button("Disconnect \(connection.title)") { model.revokeWalletConnection(connection.key) }
                            .buttonStyle(.peel(.destructive))
                        Button("Keep") { disconnecting = false }.buttonStyle(.peel(.outline))
                    } else {
                        Button("Disconnect") { disconnecting = true }.buttonStyle(.peel(.outline))
                    }
                }
            }
        }
        .task(id: connection) { spent = await model.walletUsage(connection.key) }
    }

    /// What it may spend: its methods, the limit and what it spent, over it.
    @ViewBuilder private var walletRows: some View {
        ForEach(WalletWords.methods(connection.methods), id: \.self) { Text($0).muted() }
        Text(WalletWords.limit(connection.maxAmountMsat, renewal: connection.renewal))
        if let spent, connection.maxAmountMsat != nil {
            Text("\(Sats.format(msat: spent.usedMsat)) spent"
                 + (spent.renewsAt.map { ", renews \(Date(timeIntervalSince1970: TimeInterval($0)).formatted(.relative(presentation: .named)))" } ?? ""))
                .monospacedDigit()
                .muted()
        }
        Picker("Over the limit", selection: Binding(
            get: { connection.overBudget }, set: { model.setOverLimit(connection.key, $0) }
        )) {
            Text("Over the limit, ask me").tag(WalletConnection.OverBudget.ask)
            Text("Over the limit, refuse").tag(WalletConnection.OverBudget.refuse)
        }
        .labelsHidden()
        .fixedSize()
        if editing {
            HStack(spacing: 6) {
                TextField("None", text: $limit)
                    .textFieldStyle(.roundedBorder)
                    .monospacedDigit()
                    .frame(width: 110)
                Text("sats").muted()
                Button("Save") {
                    model.setSpendingLimit(connection.key, msat: Sats.msat(limit).map(Int64.init(clamping:)))
                    editing = false
                }
                .buttonStyle(.peel(.primary))
                Button("Cancel") { editing = false }.buttonStyle(.peel(.outline))
            }
        }
    }
}
