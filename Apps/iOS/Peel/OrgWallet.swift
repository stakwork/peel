import PeelCore
import PeelUI
import SwiftUI
import WebKit

/// The app wallet's handler on the iPhone's page sheet (`StrutWallet`,
/// docs/app-wallet.md). On an org's page the main frame is the org's own
/// strut UI, which can name any of the org's apps, so the org is what Peel
/// trusts (`WalletScope.org`); on a stranger's public app Peel loaded
/// itself, the box's own code, so only the origin Peel loaded
/// (`WalletScope.origin`), which a sign-in's challenge must name. The
/// sheets name either from Peel's own record of the page it opened, never
/// from the page, and only the main frame at that origin is answered. A
/// sheet opens only right after the person's own tap.
@MainActor
final class OrgWalletBridge: NSObject, WKScriptMessageHandlerWithReply {
    private let scope: WalletScope
    private let place: String
    /// The address Peel loaded: only its origin is answered.
    private let origin: URL
    private let serves: (URL) -> Bool
    private weak var model: AppModel?
    private weak var webView: WKWebView?
    private var acted: () -> Bool = { false }
    private var listening: UUID?
    private let sheets: PhoneWalletSheets

    init(
        scope: WalletScope, place: String, origin: URL, serves: @escaping (URL) -> Bool, model: AppModel,
        sheets: PhoneWalletSheets
    ) {
        self.scope = scope
        self.place = place
        self.origin = origin
        self.serves = serves
        self.model = model
        self.sheets = sheets
    }

    func install(in configuration: WKWebViewConfiguration) {
        configuration.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: StrutWallet.handlerName)
    }

    func attach(_ view: WKWebView, acted: @escaping () -> Bool) {
        webView = view
        self.acted = acted
        sheets.stillOpen = { [weak model] in model?.phase == .ready }
        listening = model?.listenToWallet { [weak self] push in self?.push(push) }
    }

    /// The sheet is going: the handler, its listener and any sheet with it.
    func detach() {
        if let listening { model?.stopListening(listening) }
        listening = nil
        sheets.dismiss()
        webView?.configuration.userContentController.removeScriptMessageHandler(
            forName: StrutWallet.handlerName, contentWorld: .page
        )
        webView = nil
    }

    func userContentController(
        _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
    ) async -> (Any?, String?) {
        guard StrutWallet.mayAnswer(message.frameInfo, origin: origin), let webView, message.webView === webView,
              let url = webView.url, serves(url), let model, let body = StrutWallet.json(message.body) else {
            return (nil, StrutWallet.notAnswered)
        }
        let caller = WalletCaller(scope: scope, place: place, personActed: acted(), person: PhoneWalletPerson(sheets: sheets))
        let reply = await model.walletReply(to: body, from: caller)
        return (StrutWallet.foundation(reply), nil)
    }

    private func push(_ push: WalletPush) {
        guard let webView, push.connection == scope.key else { return }
        StrutWallet.push(push.envelope, into: webView, origin: origin)
    }
}

/// The person, on the iPhone: the org page's sheets.
struct PhoneWalletPerson: WalletPerson {
    let sheets: PhoneWalletSheets

    func connect(_ sheet: WalletConnectSheet) async -> WalletConnectAnswer? {
        await sheets.ask(.connect(sheet)).connect
    }

    func pay(_ sheet: WalletPaymentSheet) async -> Bool {
        await sheets.ask(.payment(sheet)).paid
    }

    func signedIn(to host: String, as key: SignInKey) async {
        await sheets.show(WalletWords.signedIn(to: host, as: key))
    }
}

/// The sheet the org page shows over itself, one at a time, answered once:
/// by the person, or as a no when Peel stops waiting.
@MainActor @Observable
final class PhoneWalletSheets {
    enum Sheet: Identifiable {
        case connect(WalletConnectSheet)
        case payment(WalletPaymentSheet)

        var id: String {
            switch self {
            case .connect(let sheet): "connect \(sheet.app) \(sheet.signIn?.host ?? "")"
            case .payment(let sheet): "pay \(sheet.payee) \(sheet.amountMsat)"
            }
        }
    }

    struct Answer: Sendable {
        var connect: WalletConnectAnswer?
        var paid = false
    }

    var shown: Sheet?
    /// What a connection did with no sheet, for a moment over the page.
    var toast: String?
    /// Whether an answer still counts when it is given (Peel unlocked).
    @ObservationIgnored var stillOpen: () -> Bool = { true }
    @ObservationIgnored private var waiting: CheckedContinuation<Answer, Never>?
    @ObservationIgnored private var toastShown: Task<Void, Never>?

    /// Shows `words` for a moment over the page, and says them to VoiceOver.
    func show(_ words: String) {
        toast = words
        CopyFeedback.announce(words)
        toastShown?.cancel()
        toastShown = Task { [weak self] in
            guard (try? await Task.sleep(for: .seconds(2.5))) != nil else { return }
            self?.toast = nil
        }
    }

    func ask(_ sheet: Sheet) async -> Answer {
        guard waiting == nil, !Task.isCancelled else { return Answer() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiting = continuation
                shown = sheet
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.dismiss() }
        }
    }

    func answer(_ answer: Answer) {
        shown = nil
        // A yes given once Peel locked is a no.
        waiting?.resume(returning: stillOpen() ? answer : Answer())
        waiting = nil
    }

    /// Taken down unanswered: a no.
    func dismiss() { answer(Answer()) }
}

/// The CONNECT sheet on the iPhone: the org from Peel's own record, the app
/// as the org's page names it, what for, the spending limit (lowered here
/// if wanted, never above what was asked), what to do over it.
struct WalletConnectPhoneSheet: View {
    let sheet: WalletConnectSheet
    let done: (WalletConnectAnswer?) -> Void
    @State private var limit: String
    @State private var overLimit: WalletConnection.OverBudget
    @State private var optional: Set<WalletMethod>
    /// Who the person signs in as, when the sheet asks.
    @State private var identity: SignInKey?

    init(sheet: WalletConnectSheet, done: @escaping (WalletConnectAnswer?) -> Void) {
        self.sheet = sheet
        self.done = done
        _limit = State(initialValue: sheet.maxAmountMsat.map { String($0 / 1000) } ?? "")
        _optional = State(initialValue: Set(sheet.optional))
        _overLimit = State(initialValue: sheet.held?.overBudget ?? .ask)
        _identity = State(initialValue: sheet.signIn?.keys.first)
    }

    private var limitMsat: Int64? {
        guard let typed = Sats.msat(limit).map(Int64.init(clamping:)) else { return nil }
        return sheet.maxAmountMsat.map { min(typed, $0) } ?? typed
    }

    var body: some View {
        let answers = WalletWords.connectAnswers(sheet)
        NavigationStack {
            Form {
                Section {
                    Text(WalletWords.who(title: sheet.title, app: sheet.app, version: sheet.version, place: sheet.place,
                                         byOrg: sheet.byOrg))
                    Text("Every app on \(sheet.place) shares this connection\(sheet.asksWallet ? " and its spending limit" : "").")
                        .foregroundStyle(Theme.secondaryText)
                }
                if let offer = sheet.signIn {
                    Section {
                        Picker("Sign in", selection: $identity) {
                            ForEach(offer.keys, id: \.self) { key in
                                Text(WalletWords.signIn(key)).tag(Optional(key))
                            }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    } header: {
                        Text("Sign in")
                    } footer: {
                        if let identity { Text(WalletWords.signInNote(identity)) }
                    }
                }
                if sheet.asksWallet { walletSections }
            }
            .navigationTitle(WalletWords.connectTitle(sheet))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(answers.no) { done(nil) } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(answers.yes) {
                        done(WalletConnectAnswer(optional: Array(optional), maxAmountMsat: limitMsat, overBudget: overLimit,
                                                 signIn: identity))
                    }
                    // Not as the sheet rises: a tap meant for the page is never the yes.
                    .disabled(!settled || (sheet.signIn != nil && identity == nil))
                }
            }
        }
        .interactiveDismissDisabled()
        .task { settled = (try? await Task.sleep(for: TouchPayButton.settle)) != nil }
    }

    /// What the app may spend: its methods, the limit, over it.
    @ViewBuilder private var walletSections: some View {
        Section("It may") {
            ForEach(WalletWords.methods(sheet.required), id: \.self) { Text($0) }
            ForEach(sheet.optional, id: \.self) { method in
                Toggle(WalletWords.method(method), isOn: Binding(
                    get: { optional.contains(method) },
                    set: { if $0 { optional.insert(method) } else { optional.remove(method) } }
                ))
            }
            if !sheet.notifications.isEmpty { Text("Hear when its own payments land") }
        }
        Section {
            HStack {
                TextField("None", text: $limit)
                    .keyboardType(.numberPad)
                    .monospacedDigit()
                Text("sats").foregroundStyle(Theme.secondaryText)
            }
            Text(WalletWords.limit(limitMsat, renewal: sheet.renewal)).foregroundStyle(Theme.secondaryText)
            Picker("Over the limit", selection: $overLimit) {
                Text("Ask me each time").tag(WalletConnection.OverBudget.ask)
                Text("Refuse").tag(WalletConnection.OverBudget.refuse)
            }
        } header: {
            Text("Spending limit")
        } footer: {
            Text("Inside it, apps pay without asking you. Change it or take it back in You › Connected apps.")
        }
    }

    @State private var settled = false
}

/// The PAYMENT sheet on the iPhone, for one payment over the limit: the
/// amount Peel decoded, the payee, the memo or message, the fee, the app's
/// own words marked as its, and the touch-safe two-step (`TouchPayButton`).
struct WalletPaymentPhoneSheet: View {
    let sheet: WalletPaymentSheet
    let done: (Bool) -> Void
    @State private var attempt = PaymentAttempt()

    var body: some View {
        let amount = UInt64(max(sheet.amountMsat, 0))
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.lg) {
                    Text(WalletWords.who(title: sheet.title, app: sheet.app, version: sheet.version, place: sheet.place,
                                         byOrg: sheet.byOrg))
                        .foregroundStyle(Theme.secondaryText)
                    BigAmount(amount: Sats.number(msat: sheet.amountMsat), size: 34)
                    VStack(alignment: .leading, spacing: Theme.Space.sm) {
                        let key = Formatting.shortKey(sheet.payee)
                        Text("To " + (sheet.payeeName.map { "\($0) · \(key)" } ?? "\(key), not a contact"))
                        if let memo = sheet.memo { Text((sheet.keysend ? "Message: " : "Memo: ") + memo) }
                        Text(sheet.async ? "Fee added on top, with 1 sat to reach them" : "Fee added on top")
                            .foregroundStyle(Theme.secondaryText)
                        if let max = sheet.maxAmountMsat {
                            Text("\(Sats.format(msat: sheet.usedMsat)) of its \(Sats.format(msat: max)) limit spent")
                                .foregroundStyle(Theme.secondaryText)
                        }
                        if let comment = sheet.comment {
                            Text("The app says: “\(comment)”").foregroundStyle(Theme.secondaryText)
                        }
                    }
                    TouchPayButton(verb: "Pay", totalMsat: amount, attempt: attempt, send: { confirmed in
                        confirmed == amount ? .sent : .needsConfirmation(msat: amount)
                    }, sent: { done(true) }, armedNote: "That's over this app's spending limit. Check it, then confirm.")
                }
                .padding(Theme.Space.lg)
            }
            .navigationTitle("\(sheet.title) asks to pay")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Decline") { done(false) } }
            }
        }
        .interactiveDismissDisabled()
    }
}

/// You › Connected apps: each org or app the person connected, its
/// spending limit and what it spent, what happens over it, Disconnect.
struct ConnectedAppsScreen: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            if model.walletConnections.isEmpty {
                Text("An app that asks to use your wallet appears here once you connect it.")
                    .foregroundStyle(Theme.secondaryText)
            }
            ForEach(model.walletConnections) { connection in
                Section(connection.title) {
                    Text(connection.place).foregroundStyle(Theme.secondaryText)
                    if let signIn = connection.signIn { Text(WalletWords.signsIn(signIn, to: connection.place)) }
                    if !connection.methods.isEmpty {
                        Text(WalletWords.limit(connection.maxAmountMsat, renewal: connection.renewal))
                        Picker("Over the limit", selection: Binding(
                            get: { connection.overBudget }, set: { model.setOverLimit(connection.key, $0) }
                        )) {
                            Text("Ask me").tag(WalletConnection.OverBudget.ask)
                            Text("Refuse").tag(WalletConnection.OverBudget.refuse)
                        }
                        ConnectedLimitRow(connection: connection)
                    }
                    Button("Disconnect", role: .destructive) { model.revokeWalletConnection(connection.key) }
                }
            }
        }
        .navigationTitle("Connected apps")
    }
}

private struct ConnectedLimitRow: View {
    @Environment(AppModel.self) private var model
    let connection: WalletConnection
    @State private var limit = ""
    @State private var spent: UInt64?

    var body: some View {
        HStack {
            TextField("No limit", text: $limit)
                .keyboardType(.numberPad)
                .monospacedDigit()
            Text("sats").foregroundStyle(Theme.secondaryText)
            Button("Save") { model.setSpendingLimit(connection.key, msat: Sats.msat(limit).map(Int64.init(clamping:))) }
                .disabled(Sats.msat(limit).map(Int64.init(clamping:)) == connection.maxAmountMsat)
        }
        .task(id: connection) {
            limit = connection.maxAmountMsat.map { String($0 / 1000) } ?? ""
            spent = await model.walletUsage(connection.key)?.usedMsat
        }
        if let spent, connection.maxAmountMsat != nil {
            Text("\(Sats.format(msat: spent)) spent this period").monospacedDigit().foregroundStyle(Theme.secondaryText)
        }
    }
}
