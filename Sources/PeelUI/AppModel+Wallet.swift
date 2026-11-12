import Foundation
import PeelCore

/// The app wallet in the model (docs/app-wallet.md): the host apps' pages
/// pay through, opened with the account over its engine, its notifications
/// handed to the pages that listen, and Connected apps (what the person
/// granted, which they can lower, raise or revoke at any time). The
/// bridges are the apps' own: the Mac's `StrutWalletBridge` on strut's UI
/// from Peel's strut, the iPhone's on an org's.
extension AppModel {
    /// Opens the wallet over `engine`; the tasks that follow it, for the
    /// account's.
    func openWallet(_ engine: Engine) async -> [Task<Void, Never>] {
        let host = WalletHost(storage: engine.storage, wallet: EngineWallet(engine: engine))
        wallet = host
        await host.start()
        let storage = engine.storage
        return [
            Task { [weak self] in
                for await push in host.notifications {
                    guard let self, self.wallet === host else { return }
                    for listener in self.walletListeners.values { listener(push) }
                }
            },
            Task { [weak self] in
                do {
                    for try await connections in storage.walletConnectionUpdates() {
                        guard let self, self.wallet === host else { return }
                        self.walletConnections = connections
                    }
                } catch {}
            },
        ]
    }

    func closeWallet() {
        let host = wallet
        wallet = nil
        walletConnections = []
        walletListeners = [:]
        if let host { Task { await host.stop() } }
    }

    /// One message from strut's UI in a page Peel opened. Refused while
    /// Peel is locked or signed out.
    public func walletReply(to message: JSONValue, from caller: WalletCaller) async -> JSONValue {
        guard phase == .ready, let wallet else {
            return .object(["error": WalletError(.restricted, "Peel is locked.").body])
        }
        return await wallet.handle(message, from: caller)
    }

    /// Hears each notification for a page; `stopListening` with what this returns.
    public func listenToWallet(_ listener: @escaping @MainActor (WalletPush) -> Void) -> UUID {
        let id = UUID()
        walletListeners[id] = listener
        return id
    }

    public func stopListening(_ id: UUID) {
        walletListeners[id] = nil
    }

    /// Revoked: the app must ask again. Its payments stay in Payments.
    public func revokeWalletConnection(_ key: String) {
        do {
            try engine?.storage.deleteWalletConnection(key: key)
        } catch {
            notice = PeelError.noted(error, couldNot: "disconnect the app")
        }
    }

    /// The spending limit per period, lowered or raised; nil asks for every payment.
    public func setSpendingLimit(_ key: String, msat: Int64?) {
        update(key) { $0.maxAmountMsat = msat.flatMap { $0 > 0 ? $0 : nil } }
    }

    /// What happens over the limit: a sheet for each payment, or a refusal.
    public func setOverLimit(_ key: String, _ choice: WalletConnection.OverBudget) {
        update(key) { $0.overBudget = choice }
    }

    private func update(_ key: String, _ change: (inout WalletConnection) -> Void) {
        guard let storage = engine?.storage else { return }
        do {
            guard var connection = try storage.walletConnection(key: key) else { return }
            change(&connection)
            try storage.saveWalletConnection(connection)
        } catch {
            notice = PeelError.noted(error, couldNot: "change the app's spending limit")
        }
    }

    /// What a connection has spent this period, and when it renews.
    public func walletUsage(_ key: String) async -> (usedMsat: UInt64, renewsAt: Int64?)? {
        await wallet?.usage(of: key)
    }
}

/// The app wallet's words for the person (docs/VISION.md, "How we talk
/// about it": a spending limit, never a budget), for the Mac's and the
/// iPhone's sheets and Connected apps alike.
public enum WalletWords {
    /// What a method lets the app do.
    public static func method(_ method: WalletMethod) -> String {
        switch method {
        case .payInvoice: "Pay invoices"
        case .payKeysend: "Send sats straight to people and nodes"
        case .makeInvoice: "Make invoices for you to be paid"
        case .lookupPayment, .lookupInvoice: "Look up its own payments"
        case .listTransactions: "List its own payments"
        case .getBudget: "See what is left of its spending limit"
        case .getBalance: "See your balance"
        case .payLightningAddress: "Pay Lightning addresses"
        case .connect, .getInfo: "Ask to connect"
        }
    }

    /// The methods, each once, in words.
    public static func methods(_ methods: [WalletMethod]) -> [String] {
        var out: [String] = []
        for words in methods.map(method) where !out.contains(words) { out.append(words) }
        return out
    }

    /// "Up to 5,000 sats a week", or how every payment is asked.
    public static func limit(_ msat: Int64?, renewal: WalletRenewal) -> String {
        guard let msat else { return "No spending limit: it asks you before every payment" }
        let amount = Sats.format(msat: UInt64(max(msat, 0)))
        switch renewal {
        case .never: return "Up to \(amount) in all"
        case .daily: return "Up to \(amount) a day"
        case .weekly: return "Up to \(amount) a week"
        case .monthly: return "Up to \(amount) a month"
        case .yearly: return "Up to \(amount) a year"
        }
    }

    public static func overLimit(_ choice: WalletConnection.OverBudget) -> String {
        switch choice {
        case .ask: "Over the limit, ask me"
        case .refuse: "Over the limit, refuse"
        }
    }

    /// Who the person signs in as (strut's plans/app-payments.md §4.4).
    public static func signIn(_ key: SignInKey) -> String {
        switch key {
        case .root: "As you"
        case .domain: "As a new identity for this app"
        }
    }

    /// What each choice means, under it.
    public static func signInNote(_ key: SignInKey) -> String {
        switch key {
        case .root: "Your Sphinx account: every app you sign in to this way sees the same you."
        case .domain: "A key for this app alone: no other app can tell it is you. Payments still come from your account."
        }
    }

    /// The connection sheet's title: connecting a wallet, signing in, or both.
    public static func connectTitle(_ sheet: WalletConnectSheet) -> String {
        switch (sheet.asksWallet, sheet.signIn) {
        case (false, let offer?): "Sign in to \(offer.host)?"
        case (true, let offer?): "Sign in to \(offer.host) and connect your wallet?"
        case (_, nil): "Connect \(sheet.title) to your wallet?"
        }
    }

    /// Its yes and its no.
    public static func connectAnswers(_ sheet: WalletConnectSheet) -> (yes: String, no: String) {
        switch (sheet.asksWallet, sheet.signIn != nil) {
        case (false, true): ("Sign in", "Don't sign in")
        case (true, true): ("Sign in and connect", "Not now")
        default: ("Connect", "Don't connect")
        }
    }

    /// The toast for a sign-in within a connection, with no sheet.
    public static func signedIn(to host: String, as key: SignInKey) -> String {
        key == .root ? "Signed in to \(host) as you" : "Signed in to \(host) as its own identity"
    }

    /// A connection's sign-in in Connected apps.
    public static func signsIn(_ key: SignInKey, to place: String) -> String {
        key == .root ? "Signs you in to \(place) as you" : "Signs you in to \(place) as a new identity"
    }

    /// The credit sheet's title (specs/WALLET.md §1.2).
    public static func creditTitle(_ sheet: WalletCreditSheet) -> String { "Buy credit on \(sheet.host)?" }

    /// The app the launch is in, as the server names it.
    public static func creditApp(_ sheet: WalletCreditSheet) -> String {
        "\(sheet.title) · \(sheet.app)@\(sheet.version), as \(sheet.host) names it"
    }

    /// What the server says the payment buys: its own figure, never the price.
    public static func creditBuys(_ sheet: WalletCreditSheet) -> String {
        "\(sheet.usd.formatted(.currency(code: "USD"))) of credit, by the server's own figure"
    }

    /// What credit is, under the sheet.
    public static func creditNote(_ sheet: WalletCreditSheet) -> String {
        "This buys credit on \(sheet.host). Runs in this app spend it, and what a run does not use stays there."
    }

    /// Who is asking, from Peel's own record: the app on the Mac, the org
    /// on the iPhone (whose page names the app).
    public static func who(title: String, app: String, version: String, place: String, byOrg: Bool) -> String {
        byOrg ? "An app on \(place), which calls itself \(title)" : "\(title) · \(app)@\(version) · \(place)"
    }
}
