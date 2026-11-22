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
            openedAppsTask(storage),
        ]
    }

    func closeWallet() {
        let host = wallet
        wallet = nil
        walletConnections = []
        openedApps = []
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
            notice = PeelError.noted(error, couldNot: String(localized: "disconnect the app", table: "Shared"))
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
            notice = PeelError.noted(error, couldNot: String(localized: "change the app's spending limit", table: "Shared"))
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
        case .payInvoice: String(localized: "Pay invoices", table: "Shared")
        case .payKeysend: String(localized: "Send sats straight to people and nodes", table: "Shared")
        case .makeInvoice: String(localized: "Make invoices for you to be paid", table: "Shared")
        case .lookupPayment, .lookupInvoice: String(localized: "Look up its own payments", table: "Shared")
        case .listTransactions: String(localized: "List its own payments", table: "Shared")
        case .getBudget: String(localized: "See what is left of its spending limit", table: "Shared")
        case .getBalance: String(localized: "See your balance", table: "Shared")
        case .payLightningAddress: String(localized: "Pay Lightning addresses", table: "Shared")
        case .connect, .getInfo: String(localized: "Ask to connect", table: "Shared")
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
        guard let msat else { return String(localized: "No spending limit: it asks you before every payment", table: "Shared") }
        let amount = Sats.format(msat: UInt64(max(msat, 0)))
        switch renewal {
        case .never: return String(localized: "Up to \(amount) in all", table: "Shared")
        case .daily: return String(localized: "Up to \(amount) a day", table: "Shared")
        case .weekly: return String(localized: "Up to \(amount) a week", table: "Shared")
        case .monthly: return String(localized: "Up to \(amount) a month", table: "Shared")
        case .yearly: return String(localized: "Up to \(amount) a year", table: "Shared")
        }
    }

    public static func overLimit(_ choice: WalletConnection.OverBudget) -> String {
        switch choice {
        case .ask: String(localized: "Over the limit, ask me", table: "Shared")
        case .refuse: String(localized: "Over the limit, refuse", table: "Shared")
        }
    }

    /// Who the person signs in as (strut's plans/app-payments.md §4.4).
    public static func signIn(_ key: SignInKey) -> String {
        switch key {
        case .root: String(localized: "As you", table: "Shared")
        case .domain: String(localized: "As a new identity for this app", table: "Shared")
        }
    }

    /// What each choice means, under it.
    public static func signInNote(_ key: SignInKey) -> String {
        switch key {
        case .root: String(localized: "Your Sphinx account: every app you sign in to this way sees the same you.", table: "Shared")
        case .domain: String(localized: "A key for this app alone: no other app can tell it is you. Payments still come from your account.", table: "Shared")
        }
    }

    /// The connection sheet's title: connecting a wallet, signing in, or both.
    public static func connectTitle(_ sheet: WalletConnectSheet) -> String {
        switch (sheet.asksWallet, sheet.signIn) {
        case (false, let offer?): String(localized: "Sign in to \(offer.host)?", table: "Shared")
        case (true, let offer?): String(localized: "Sign in to \(offer.host) and connect your wallet?", table: "Shared")
        case (_, nil): String(localized: "Connect \(sheet.title) to your wallet?", table: "Shared")
        }
    }

    /// Its yes and its no.
    public static func connectAnswers(_ sheet: WalletConnectSheet) -> (yes: String, no: String) {
        switch (sheet.asksWallet, sheet.signIn != nil) {
        case (false, true): (String(localized: "Sign in", table: "Shared"), String(localized: "Don't sign in", table: "Shared"))
        case (true, true): (String(localized: "Sign in and connect", table: "Shared"), String(localized: "Not now", table: "Shared"))
        default: (String(localized: "Connect", table: "Shared"), String(localized: "Don't connect", table: "Shared"))
        }
    }

    /// The toast for a sign-in within a connection, with no sheet.
    public static func signedIn(to host: String, as key: SignInKey) -> String {
        key == .root ? String(localized: "Signed in to \(host) as you", table: "Shared") : String(localized: "Signed in to \(host) as its own identity", table: "Shared")
    }

    /// A connection's sign-in in Connected apps.
    public static func signsIn(_ key: SignInKey, to place: String) -> String {
        key == .root ? String(localized: "Signs you in to \(place) as you", table: "Shared") : String(localized: "Signs you in to \(place) as a new identity", table: "Shared")
    }

    /// The credit sheet's title (specs/WALLET.md §1.2).
    public static func creditTitle(_ sheet: WalletCreditSheet) -> String { String(localized: "Buy credit on \(sheet.host)?", table: "Shared") }

    /// The app the launch is in, as the server names it.
    public static func creditApp(_ sheet: WalletCreditSheet) -> String {
        String(localized: "\(sheet.title) · \(sheet.app)@\(sheet.version), as \(sheet.host) names it", table: "Shared")
    }

    /// What the server says the payment buys: its own figure, never the price.
    public static func creditBuys(_ sheet: WalletCreditSheet) -> String {
        String(localized: "\(sheet.usd.formatted(.currency(code: "USD"))) of credit, by the server's own figure", table: "Shared")
    }

    /// What credit is, under the sheet.
    public static func creditNote(_ sheet: WalletCreditSheet) -> String {
        String(localized: "This buys credit on \(sheet.host). Runs in this app spend it, and what a run does not use stays there.", table: "Shared")
    }

    /// Who is asking, from Peel's own record: the app on the Mac, the org
    /// on the iPhone (whose page names the app).
    public static func who(title: String, app: String, version: String, place: String, byOrg: Bool) -> String {
        byOrg ? String(localized: "An app on \(place), which calls itself \(title)", table: "Shared") : "\(title) · \(app)@\(version) · \(place)"
    }
}
