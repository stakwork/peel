import Foundation

/// An invoice as the wallet decodes it: what the host shows and counts,
/// never what the app said about it.
public struct WalletInvoice: Sendable, Equatable {
    public var bolt11: String
    public var paymentHash: String
    /// msat; 0 when it names no amount.
    public var amountMsat: Int64
    public var payee: String
    public var memo: String
    /// Unix seconds.
    public var expiresAt: Int64?

    public init(bolt11: String, paymentHash: String, amountMsat: Int64, payee: String, memo: String, expiresAt: Int64?) {
        self.bolt11 = bolt11
        self.paymentHash = paymentHash
        self.amountMsat = amountMsat
        self.payee = payee
        self.memo = memo
        self.expiresAt = expiresAt
    }
}

/// A payment an app asked for, as the host decoded it.
public enum WalletPayment: Sendable, Equatable {
    case invoice(WalletInvoice)
    /// `routeHint` is the core's `<lsp_pubkey>_<scid>`; `data` rides in record 13377331.
    case keysend(pubkey: String, amountMsat: Int64, routeHint: String?, data: Data?)

    public var amountMsat: Int64 {
        switch self {
        case .invoice(let invoice): invoice.amountMsat
        case .keysend(_, let amount, _, _): amount
        }
    }
}

/// The wallet behind the host: Peel's Sphinx account (`EngineWallet`), or a
/// scripted one in the tests. Every refusal is a `WalletError`.
public protocol AppWallet: Sendable {
    /// For `get_info`: bitcoin, testnet, signet or regtest.
    func network() async -> String
    /// Reads an invoice; a `BAD_REQUEST` when it cannot.
    func decode(invoice: String) async throws -> WalletInvoice
    /// What stops this payment before anyone is asked (an expired invoice,
    /// the balance); nil when nothing does.
    func problem(paying payment: WalletPayment) async -> WalletError?
    /// Pays through `tag`'s connection, within `tag.budget` checked with the
    /// payment's own write (a `QUOTA_EXCEEDED` when it does not fit, and
    /// nothing sent). Answers once the wallet accepted it.
    func pay(_ payment: WalletPayment, for tag: Engine.WalletTag) async throws -> WalletRecord
    func makeInvoice(amountMsat: Int64, description: String, for tag: Engine.WalletTag) async throws -> WalletRecord
    /// A connection's transactions, newest first.
    func records(connection: String) async throws -> [WalletRecord]
    /// What can be spent now, in msat.
    func balance() async throws -> Int64
    /// The name Peel knows a payee by, when it is a contact.
    func payeeName(_ pubkey: String) async -> String?
    /// Each app transaction that settled or failed (an invoice made: settled
    /// or expired), as it happens.
    func updates() -> AsyncStream<WalletRecord>
}

/// Who a message is from, as Peel itself knows it, never as the page says.
public enum WalletScope: Sendable, Hashable {
    /// The Mac: an app on Peel's own strut, whose UI Peel ships; `peer` is
    /// the org it lives on, nil for the person's own.
    case app(peer: String?, name: String)
    /// The iPhone: an org, whose own strut's UI is the main frame and can
    /// name any of its apps, so the org is what is trusted.
    case org(peer: String)

    /// The connection's key (`WalletConnection.key`).
    public var key: String {
        switch self {
        case .app(let peer, let name): "app:\(peer ?? "")/\(name)"
        case .org(let peer): "org:\(peer)"
        }
    }
}

/// The app a message names (strut's `NativeWalletApp`): the version
/// hosted, its title and its `app.yaml` `wallet:` request.
public struct WalletApp: Sendable, Equatable {
    public var name: String
    public var version: String
    public var peer: String?
    public var title: String
    /// The request, checked (`WalletProtocol.connectionRequestProblems`);
    /// nil when it asks for none, or for one that is not a request.
    public var request: WalletRequest?

    /// strut's `nativeAppKey`: `<peer>/<name>`.
    public var key: String { "\(peer ?? "")/\(name)" }

    public init(name: String, version: String, peer: String?, title: String, request: WalletRequest?) {
        self.name = name
        self.version = version
        self.peer = peer
        self.title = title
        self.request = request
    }

    /// Read from a message's `app`; nil when it is not one.
    public init?(_ json: JSONValue?) {
        guard case .object(let o)? = json, let name = o["name"]?.string, !name.isEmpty,
              let version = o["version"]?.string else { return nil }
        let peer = o["peer"]?.string
        if o["peer"] != nil, o["peer"] != .null, peer == nil || peer!.isEmpty || peer!.contains("/") { return nil }
        self.init(
            name: name, version: version, peer: peer, title: o["title"]?.string ?? name,
            request: WalletRequest(o["request"])
        )
    }
}

/// An `app.yaml` `wallet:` block (NWC-08's request fields).
public struct WalletRequest: Sendable, Equatable {
    public var required: [WalletMethod]
    public var optional: [WalletMethod]
    public var notifications: [WalletNotificationType]
    public var maxAmountMsat: Int64?
    public var renewal: WalletRenewal?
    public var expiresAt: Int64?

    public init(
        required: [WalletMethod], optional: [WalletMethod] = [], notifications: [WalletNotificationType] = [],
        maxAmountMsat: Int64? = nil, renewal: WalletRenewal? = nil, expiresAt: Int64? = nil
    ) {
        self.required = required
        self.optional = optional
        self.notifications = notifications
        self.maxAmountMsat = maxAmountMsat
        self.renewal = renewal
        self.expiresAt = expiresAt
    }

    /// Nil for none (null, absent) and for anything the contract refuses.
    public init?(_ json: JSONValue?) {
        guard let json, json != .null, WalletProtocol.connectionRequestProblems(json).isEmpty,
              case .object(let r) = json else { return nil }
        func methods(_ key: String) -> [WalletMethod] {
            guard case .array(let list)? = r[key] else { return [] }
            var out: [WalletMethod] = []
            for m in list.compactMap({ $0.string.flatMap(WalletMethod.init) }) where !out.contains(m) { out.append(m) }
            return out
        }
        var notifications: [WalletNotificationType] = []
        if case .array(let list)? = r["notification_types"] {
            for n in list.compactMap({ $0.string.flatMap(WalletNotificationType.init) }) where !notifications.contains(n) {
                notifications.append(n)
            }
        }
        self.init(
            required: methods("request_methods"), optional: methods("optional_request_methods"),
            notifications: notifications, maxAmountMsat: WalletProtocol.integer(r["max_amount"]),
            renewal: r["renewal_period"]?.string.flatMap(WalletRenewal.init),
            expiresAt: WalletProtocol.integer(r["expires_at"])
        )
    }
}

/// What the CONNECT sheet shows: who asks, from Peel's own record of the
/// page, and what for.
public struct WalletConnectSheet: Sendable, Equatable {
    public var title: String
    public var app: String
    public var version: String
    /// Where it lives as the person reads it: "Yours", "@acme", an org's name.
    public var place: String
    /// On the iPhone: the org is who Peel knows; the app is named by the org's page.
    public var byOrg: Bool
    public var required: [WalletMethod]
    public var optional: [WalletMethod]
    public var notifications: [WalletNotificationType]
    public var maxAmountMsat: Int64?
    public var renewal: WalletRenewal
    public var expiresAt: Int64?
    /// What is already granted, when the version asks for more.
    public var held: WalletConnection?
}

/// The person's yes on a connect sheet.
public struct WalletConnectAnswer: Sendable, Equatable {
    /// The optional methods granted.
    public var optional: [WalletMethod]
    /// The budget: at most what was asked; nil for none (every payment asks).
    public var maxAmountMsat: Int64?
    public var overBudget: WalletConnection.OverBudget

    public init(optional: [WalletMethod], maxAmountMsat: Int64?, overBudget: WalletConnection.OverBudget = .ask) {
        self.optional = optional
        self.maxAmountMsat = maxAmountMsat
        self.overBudget = overBudget
    }

    /// Everything as asked, over budget asking.
    public static func asAsked(_ sheet: WalletConnectSheet) -> WalletConnectAnswer {
        WalletConnectAnswer(optional: sheet.optional, maxAmountMsat: sheet.maxAmountMsat, overBudget: .ask)
    }
}

/// What the PAYMENT sheet shows for one payment over budget: every amount
/// decoded by Peel, the app's own words marked as its.
public struct WalletPaymentSheet: Sendable, Equatable {
    public var title: String
    public var app: String
    public var version: String
    public var place: String
    public var byOrg: Bool
    public var amountMsat: Int64
    public var payee: String
    /// The contact's name, when Peel knows the payee.
    public var payeeName: String?
    /// The invoice's memo, or a keysend's message when it is text.
    public var memo: String?
    /// Unix seconds.
    public var expiresAt: Int64?
    /// The app's `metadata.comment`: its words, never Peel's.
    public var comment: String?
    public var keysend: Bool
    /// Sent the asynchronous way: a 1-sat ping goes with it.
    public var async: Bool
    public var usedMsat: Int64
    public var maxAmountMsat: Int64?
}

/// The person, for the sheets. An implementation draws a sheet and answers
/// once the person does; when its task is cancelled (Peel stopped waiting)
/// it takes the sheet down and returns at once.
public protocol WalletPerson: Sendable {
    /// The person's yes, or nil for no.
    func connect(_ sheet: WalletConnectSheet) async -> WalletConnectAnswer?
    func pay(_ sheet: WalletPaymentSheet) async -> Bool
}

/// One message's sender, as the bridge knows it.
public struct WalletCaller: Sendable {
    public var scope: WalletScope
    /// Where it lives as the person reads it, from Peel's own record.
    public var place: String
    /// The person clicked or tapped in the page in the last few seconds:
    /// native events, which no script makes. No sheet opens without it.
    public var personActed: Bool
    public var person: any WalletPerson

    public init(scope: WalletScope, place: String, personActed: Bool, person: any WalletPerson) {
        self.scope = scope
        self.place = place
        self.personActed = personActed
        self.person = person
    }
}

/// A notification for the pages hosting an app: the whole
/// `window.strutWallet.notify` message (`envelope`).
public struct WalletPush: Sendable, Equatable {
    /// The connection it is for: a bridge sends it only to pages of that scope.
    public var connection: String
    /// `<peer>/<name>`, as strut names the app.
    public var app: String
    public var envelope: JSONValue
}

/// The native wallet host (strut's specs/WALLET.md, Peel's side;
/// docs/app-wallet.md): answers strut's UI relaying an app's
/// `strut/wallet/*` calls, and pushes its notifications. Everything is
/// decided here, never in the page: the params checked again, the
/// connection (`UNAUTHORIZED` with none, `RESTRICTED` for a method it does
/// not grant), the budget (pending counts, settled adds fees, failed
/// refunds, renewal, counted in the payment's own write), the sheets (only
/// after the person acted, one at a time, given up after `sheetTimeout`),
/// and notifications only of a connection's own transactions and types.
public actor WalletHost {
    /// What Peel's wallet offers: no Lightning Address yet.
    public static let offered: [WalletMethod] = [
        .connect, .getInfo, .payInvoice, .payKeysend, .makeInvoice, .lookupPayment, .lookupInvoice, .getBudget,
        .getBalance, .listTransactions,
    ]

    let storage: Storage
    let wallet: any AppWallet
    let now: @Sendable () -> Int64
    let sheetTimeout: Duration
    private var sheetOpen = false
    /// What a page was last told of each transaction, by connection and id.
    private var told: [String: String] = [:]
    /// Pay calls in flight, by connection: their notifications wait for the answer.
    private var paying: [String: Int] = [:]
    private var held: [WalletRecord] = []
    private var watching: Task<Void, Never>?
    private let pushes: AsyncStream<WalletPush>.Continuation
    /// Every notification for a page, as it happens.
    public nonisolated let notifications: AsyncStream<WalletPush>

    /// `now` is unix seconds. A sheet nobody answers is given up after
    /// `sheetTimeout`, before the page's own ten minutes, so a late yes
    /// never pays for a page that has stopped waiting.
    public init(
        storage: Storage, wallet: any AppWallet, now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970) },
        sheetTimeout: Duration = .seconds(9 * 60)
    ) {
        self.storage = storage
        self.wallet = wallet
        self.now = now
        self.sheetTimeout = sheetTimeout
        (notifications, pushes) = AsyncStream.makeStream(of: WalletPush.self)
    }

    deinit {
        watching?.cancel()
        pushes.finish()
    }

    /// Starts following the wallet's transactions for notifications.
    public func start() {
        guard watching == nil else { return }
        let updates = wallet.updates()
        watching = Task { [weak self] in
            for await record in updates { await self?.updated(record) }
        }
    }

    public func stop() {
        watching?.cancel()
        watching = nil
    }

    /// What a connection has spent in its current period and when that
    /// renews: Connected apps.
    public func usage(of key: String) async -> (usedMsat: UInt64, renewsAt: Int64?)? {
        guard let connection = try? storage.walletConnection(key: key), let records = try? await wallet.records(connection: key)
        else { return nil }
        let period = WalletBudget.period(created: connection.createdAt, renewal: connection.renewal, now: now())
        return (WalletBudget.used(records.compactMap(\.entry), since: period.start), period.renewsAt)
    }

    // MARK: Messages

    /// One message from strut's UI (`NativeWalletMessage`), answered as a
    /// `NativeWalletReply`: always `{ result }` or `{ error }`.
    public func handle(_ message: JSONValue, from caller: WalletCaller) async -> JSONValue {
        guard case .object(let m) = message, WalletProtocol.integer(m["v"]) == 1, let op = m["op"]?.string,
              let app = WalletApp(m["app"]) else {
            return Self.reply(WalletError(.badRequest, "That is not a wallet message Peel reads."))
        }
        // On the Mac, strut's UI names the app Peel itself opened.
        if case .app(let peer, let name) = caller.scope, peer != app.peer || name != app.name {
            return Self.reply(WalletError(.restricted, "That is not the app this page shows."))
        }
        switch op {
        case "capability":
            return capability(app, caller)
        case "call":
            guard let name = m["method"]?.string else {
                return Self.reply(WalletError(.badRequest, "The call names no method."))
            }
            guard let method = WalletMethod(rawValue: name) else {
                return Self.reply(WalletError(.notImplemented, "Peel's wallet has no method \(TextLine.clean(name, max: 40))."))
            }
            do {
                return .object(["result": try await call(method, m["params"], app: app, caller: caller)])
            } catch let error as WalletError {
                return Self.reply(error)
            } catch {
                return Self.reply(WalletError(.internal, PeelError.readable(error)))
            }
        default:
            return Self.reply(WalletError(.badRequest, "That is not a wallet message Peel reads."))
        }
    }

    static func reply(_ error: WalletError) -> JSONValue { .object(["error": error.body]) }

    private func capability(_ app: WalletApp, _ caller: WalletCaller) -> JSONValue {
        guard app.request != nil else { return Self.reply(WalletError(.restricted, "This app asks for no wallet.")) }
        let connected = (try? validConnection(caller.scope.key)) != nil
        return .object(["result": .object([
            "version": .int(Int64(WalletProtocol.version)),
            "methods": .array(Self.offered.map { .string($0.rawValue) }),
            "notifications": .array(WalletNotificationType.allCases.map { .string($0.rawValue) }),
            "wallet": .string("sphinx"),
            "connected": .bool(connected),
        ])])
    }

    /// One method: the params checked first, then what Peel offers, then
    /// the connection and what it grants.
    func call(_ method: WalletMethod, _ raw: JSONValue?, app: WalletApp, caller: WalletCaller) async throws -> JSONValue {
        let params = try WalletProtocol.checkParams(method, raw).get()
        guard Self.offered.contains(method) else {
            throw WalletError(.notImplemented, "Peel's wallet cannot do \(method.rawValue) yet.")
        }
        switch method {
        case .connect: return try await connect(app, caller)
        case .getInfo: return await info(try? validConnection(caller.scope.key))
        default: break
        }
        guard let connection = try validConnection(caller.scope.key) else {
            throw WalletError(.unauthorized, "This app is not connected to your wallet.")
        }
        guard connection.methods.contains(method) else {
            throw WalletError(.restricted, "You did not let this app use \(method.rawValue).")
        }
        let p = params.objectValue
        switch method {
        case .payInvoice, .payKeysend:
            return try await pay(method, p, app: app, caller: caller, connection: connection)
        case .makeInvoice:
            if p["description_hash"] != nil {
                throw WalletError(.notImplemented, "Peel's invoices carry a description, not its hash.")
            }
            let amount = WalletProtocol.integer(p["amount"]) ?? 0
            let record = try await wallet.makeInvoice(
                amountMsat: amount, description: p["description"]?.string ?? "",
                for: Engine.WalletTag(connection: connection.key, app: app.key)
            )
            return record.transaction
        case .lookupInvoice:
            let records = try await wallet.records(connection: connection.key)
            let hash = try await paymentHash(p)
            guard let record = records.first(where: { $0.paymentType == .bolt11 && $0.paymentHash == hash }) else {
                throw WalletError(.notFound, "No invoice of this app's is that one.")
            }
            return record.transaction
        case .lookupPayment:
            let records = try await wallet.records(connection: connection.key)
            let record: WalletRecord?
            if let id = p["transaction_id"]?.string {
                record = records.first { $0.transactionID == id }
            } else {
                let hash = try await paymentHash(p)
                record = records.first { $0.paymentHash == hash }
            }
            guard let record else { throw WalletError(.notFound, "No payment of this app's is that one.") }
            return record.lookup
        case .listTransactions:
            return try await list(p, connection: connection)
        case .getBudget:
            guard let max = connection.maxAmountMsat else { return .object([:]) }
            let period = WalletBudget.period(created: connection.createdAt, renewal: connection.renewal, now: now())
            let used = WalletBudget.used(try await entries(connection), since: period.start)
            var out: [String: JSONValue] = [
                "used_budget": .int(Int64(clamping: used)), "total_budget": .int(max),
                "renewal_period": .string(connection.renewal.rawValue),
            ]
            if let renews = period.renewsAt { out["renews_at"] = .int(renews) }
            return .object(out)
        case .getBalance:
            return .object(["balance": .int(try await wallet.balance())])
        case .connect, .getInfo, .payLightningAddress:
            throw WalletError(.notImplemented, "Peel's wallet cannot do \(method.rawValue) yet.")
        }
    }

    /// A connection that holds: kept, and not past its expiry.
    private func validConnection(_ key: String) throws -> WalletConnection? {
        guard let connection = try storage.walletConnection(key: key), !connection.isExpired(now: now()) else { return nil }
        return connection
    }

    private func info(_ connection: WalletConnection?) async -> JSONValue {
        let granted = connection?.methods.filter(Self.offered.contains) ?? []
        return .object([
            "network": .string(await wallet.network()),
            "methods": .array(([.connect, .getInfo] + granted).map { .string($0.rawValue) }),
            "notifications": .array((connection?.notificationTypes ?? []).map { .string($0.rawValue) }),
        ])
    }

    private func entries(_ connection: WalletConnection) async throws -> [WalletBudget.Entry] {
        try await wallet.records(connection: connection.key).compactMap(\.entry)
    }

    private func paymentHash(_ p: [String: JSONValue]) async throws -> String {
        if let hash = p["payment_hash"]?.string { return hash }
        guard let invoice = p["invoice"]?.string else { throw WalletError(.badRequest, "Give a payment hash or an invoice.") }
        return try await wallet.decode(invoice: invoice).paymentHash
    }

    private func list(_ p: [String: JSONValue], connection: WalletConnection) async throws -> JSONValue {
        let from = WalletProtocol.integer(p["from"]), until = WalletProtocol.integer(p["until"])
        let type = p["type"]?.string
        let unpaid = p["unpaid"] == .bool(true)
        let matching = try await wallet.records(connection: connection.key).filter { record in
            if let from, record.createdAt < from { return false }
            if let until, record.createdAt > until { return false }
            if let type, record.direction.rawValue != type { return false }
            // NWC-05: an invoice not paid only when asked for.
            if record.direction == .incoming, record.state != .settled, !unpaid { return false }
            return true
        }
        let offset = Int(WalletProtocol.integer(p["offset"]) ?? 0)
        let limit = Int(WalletProtocol.integer(p["limit"]) ?? WalletProtocol.listLimitMax)
        let page = matching.dropFirst(offset).prefix(limit)
        return .object([
            "transactions": .array(page.map(\.transaction)),
            "total_count": .int(Int64(matching.count)),
        ])
    }

    // MARK: Connect

    private func connect(_ app: WalletApp, _ caller: WalletCaller) async throws -> JSONValue {
        guard let request = app.request else { throw WalletError(.restricted, "This app asks for no wallet.") }
        let unoffered = request.required.filter { !Self.offered.contains($0) }
        guard unoffered.isEmpty else {
            throw WalletError(
                .notImplemented, "Peel's wallet cannot do \(unoffered.map(\.rawValue).joined(separator: ", ")), which this app needs."
            )
        }
        let held = try validConnection(caller.scope.key)
        if let held, request.required.allSatisfy(held.methods.contains),
           request.notifications.allSatisfy(held.notificationTypes.contains) {
            return .object(["connection": held.granted])
        }
        guard caller.personActed else {
            throw WalletError(.restricted, "Peel asks you about a wallet only right after you click or tap in the app.")
        }
        let optional = request.optional.filter { Self.offered.contains($0) && !request.required.contains($0) }
        let sheet = WalletConnectSheet(
            title: TextLine.clean(app.title, max: 80), app: TextLine.clean(app.name, max: 80),
            version: TextLine.clean(app.version, max: 20), place: caller.place, byOrg: Self.byOrg(caller.scope),
            required: request.required, optional: optional, notifications: request.notifications,
            // A version asking for more keeps the budget held when it names none.
            maxAmountMsat: request.maxAmountMsat ?? held?.maxAmountMsat,
            renewal: request.maxAmountMsat != nil ? request.renewal ?? .never : held?.renewal ?? .never,
            expiresAt: request.expiresAt ?? held?.expiresAt, held: held
        )
        let person = caller.person
        guard let answer = try await askPerson({ await person.connect(sheet) }) else {
            throw WalletError(.userRejected, "You declined to connect this app.")
        }
        // Lower only, never more than asked.
        var max = answer.maxAmountMsat.map { Swift.max($0, 0) }
        if let asked = sheet.maxAmountMsat { max = max.map { min($0, asked) } }
        var methods = request.required
        for m in optional where answer.optional.contains(m) && !methods.contains(m) { methods.append(m) }
        for m in held?.methods ?? [] where !methods.contains(m) { methods.append(m) }
        var types = request.notifications
        for t in held?.notificationTypes ?? [] where !types.contains(t) { types.append(t) }
        let connection = WalletConnection(
            key: caller.scope.key, app: app.key, title: sheet.title, place: caller.place, methods: methods,
            notificationTypes: types, maxAmountMsat: max == 0 ? nil : max, renewal: sheet.renewal,
            expiresAt: sheet.expiresAt, overBudget: answer.overBudget, createdAt: held?.createdAt ?? now()
        )
        try storage.saveWalletConnection(connection)
        return .object(["connection": connection.granted])
    }

    private static func byOrg(_ scope: WalletScope) -> Bool {
        if case .org = scope { return true }
        return false
    }

    // MARK: Pay

    private func pay(
        _ method: WalletMethod, _ p: [String: JSONValue], app: WalletApp, caller: WalletCaller, connection: WalletConnection
    ) async throws -> JSONValue {
        let payment = try await decodedPayment(method, p)
        if let problem = await wallet.problem(paying: payment) { throw problem }
        let amount = UInt64(max(payment.amountMsat, 0))
        let period = WalletBudget.period(created: connection.createdAt, renewal: connection.renewal, now: now())
        if let max = connection.maxAmountMsat {
            let within = WalletBudget.Guard(limitMsat: UInt64(max), since: period.start)
            if within.admits(amount, beside: try await entries(connection)) {
                do {
                    return try await paid(payment, connection: connection, app: app, budget: within)
                } catch let error as WalletError where error.code == .quotaExceeded {
                    // Another payment took the room meanwhile: over budget after all.
                }
            }
        }
        switch connection.overBudget {
        case .refuse:
            throw WalletError(.quotaExceeded, "That is over what you let this app spend.")
        case .ask:
            guard caller.personActed else {
                throw WalletError(.restricted, "Peel asks you to pay only right after you click or tap in the app.")
            }
            let sheet = await paymentSheet(payment, p, app: app, caller: caller, connection: connection, since: period.start)
            let person = caller.person
            guard try await askPerson({ await person.pay(sheet) }) else {
                throw WalletError(.userRejected, "You declined the payment.")
            }
            // Approved on its own sheet: counted, not limited.
            return try await paid(payment, connection: connection, app: app,
                                  budget: WalletBudget.Guard(limitMsat: nil, since: period.start))
        }
    }

    /// Pays, and answers with the payment as the page is told it; the
    /// notifications for this connection wait for the answer.
    private func paid(
        _ payment: WalletPayment, connection: WalletConnection, app: WalletApp, budget: WalletBudget.Guard
    ) async throws -> JSONValue {
        paying[connection.key, default: 0] += 1
        defer {
            paying[connection.key, default: 1] -= 1
            if paying[connection.key] == 0 {
                paying[connection.key] = nil
                let waiting = held.filter { $0.connection == connection.key }
                held.removeAll { $0.connection == connection.key }
                for record in waiting { notify(record) }
            }
        }
        let record = try await wallet.pay(payment, for: Engine.WalletTag(connection: connection.key, app: app.key, budget: budget))
        let answer = record.payment
        told[Self.toldKey(record)] = answer.objectValue["state"]?.string
        return answer
    }

    /// The payment as Peel reads it: the amount from the invoice, never
    /// from the app; what the Sphinx core cannot send refused as
    /// `NOT_IMPLEMENTED`.
    private func decodedPayment(_ method: WalletMethod, _ p: [String: JSONValue]) async throws -> WalletPayment {
        if method == .payInvoice {
            let invoice = try await wallet.decode(invoice: p["invoice"]?.string ?? "")
            if invoice.amountMsat <= 0 {
                throw p["amount"] != nil
                    ? WalletError(.notImplemented, "Peel pays only invoices that say how much.")
                    : WalletError(.badRequest, "The invoice names no amount.")
            }
            if p["amount"] != nil { throw WalletError(.badRequest, "The invoice names its own amount.") }
            return .invoice(invoice)
        }
        if p["preimage"] != nil { throw WalletError(.notImplemented, "Peel's wallet makes a keysend's preimage itself.") }
        var hint: String?
        if case .array(let routes)? = p["route_hints"] {
            guard routes.count == 1, case .array(let hops) = routes[0], hops.count == 1, case .object(let hop) = hops[0],
                  let pubkey = hop["pubkey"]?.string, let scid = hop["short_channel_id"]?.string,
                  let sphinx = SphinxAddress.routeHint(pubkey: pubkey, shortChannelID: scid) else {
                throw WalletError(.notImplemented, "Peel's wallet takes one route hint of one hop, with a decimal channel id.")
            }
            hint = sphinx
        }
        var data: Data?
        if case .array(let records)? = p["tlv_records"] {
            for case .object(let record) in records {
                guard WalletProtocol.integer(record["type"]) == WalletProtocol.sphinxTLVType,
                      let value = record["value"]?.string, let bytes = Data(hexString: value) else {
                    throw WalletError(.notImplemented, "Peel's wallet sends only Sphinx's record, \(WalletProtocol.sphinxTLVType).")
                }
                data = try Self.sphinxData(bytes)
            }
        }
        return .keysend(
            pubkey: p["pubkey"]?.string ?? "", amountMsat: WalletProtocol.integer(p["amount"]) ?? 0, routeHint: hint, data: data
        )
    }

    /// The core sends record 13377331 as base64 of its `data`, so a record
    /// whose value is base64 text is sent as the data it decodes to; any
    /// other value the core cannot send as it is.
    static func sphinxData(_ value: Data) throws -> Data {
        guard let text = String(data: value, encoding: .utf8), let data = Data(base64Encoded: text),
              data.base64EncodedString() == text else {
            throw WalletError(.notImplemented, "Sphinx's record carries base64 text; Peel cannot send this value as it is.")
        }
        return data
    }

    private func paymentSheet(
        _ payment: WalletPayment, _ p: [String: JSONValue], app: WalletApp, caller: WalletCaller,
        connection: WalletConnection, since: Int64
    ) async -> WalletPaymentSheet {
        let payee: String, memo: String?, expires: Int64?, keysend: Bool, async: Bool
        switch payment {
        case .invoice(let invoice):
            (payee, memo, expires, keysend, async) = (invoice.payee, invoice.memo.nilIfEmpty, invoice.expiresAt, false, false)
        case .keysend(let pubkey, _, let hint, let data):
            let words = data.flatMap { String(data: $0, encoding: .utf8) }
            (payee, memo, expires, keysend, async) = (pubkey, words, nil, true, hint != nil)
        }
        let comment = p["metadata"]?.objectValue["comment"]?.string
        let used = (try? await entries(connection)).map { WalletBudget.used($0, since: since) } ?? 0
        return WalletPaymentSheet(
            title: TextLine.clean(app.title, max: 80), app: TextLine.clean(app.name, max: 80),
            version: TextLine.clean(app.version, max: 20), place: caller.place, byOrg: Self.byOrg(caller.scope),
            amountMsat: payment.amountMsat, payee: payee, payeeName: await wallet.payeeName(payee),
            memo: memo.map { TextLine.block($0, max: 500) }.flatMap(\.nilIfEmpty), expiresAt: expires,
            comment: comment.map { TextLine.block($0, max: 500) }.flatMap(\.nilIfEmpty), keysend: keysend, async: async,
            usedMsat: Int64(clamping: used), maxAmountMsat: connection.maxAmountMsat
        )
    }

    // MARK: Sheets

    private enum Asked<T: Sendable>: Sendable {
        case answered(T)
        case timedOut
    }

    /// One sheet at a time (`RATE_LIMITED` beside one open), given up after
    /// `sheetTimeout` (`RESTRICTED`, the sheet taken down).
    private func askPerson<T: Sendable>(_ present: @escaping @Sendable () async -> T) async throws -> T {
        guard !sheetOpen else {
            throw WalletError(.rateLimited, "Peel is already asking you something; answer that first.")
        }
        sheetOpen = true
        defer { sheetOpen = false }
        let timeout = sheetTimeout
        let outcome = await withTaskGroup(of: Asked<T>.self) { group in
            group.addTask { .answered(await present()) }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return .timedOut
            }
            let first = await group.next() ?? .timedOut
            group.cancelAll()
            return first
        }
        guard case .answered(let value) = outcome else {
            throw WalletError(.restricted, "You did not answer in time.")
        }
        return value
    }

    // MARK: Notifications

    private static func toldKey(_ record: WalletRecord) -> String {
        "\(record.connection)|\(record.direction.rawValue)|\(record.transactionID)"
    }

    /// A transaction moved: told to the pages of its connection, as the
    /// type it now is, when that connection holds the type, and once.
    func updated(_ record: WalletRecord) {
        if paying[record.connection] != nil {
            held.append(record)
        } else {
            notify(record)
        }
    }

    private func notify(_ record: WalletRecord) {
        let type: WalletNotificationType
        switch (record.direction, record.state) {
        case (.outgoing, .settled): type = .paymentSent
        case (.outgoing, .failed): type = .paymentFailed
        case (.incoming, .settled): type = .paymentReceived
        default: return
        }
        let key = Self.toldKey(record)
        guard told[key] != record.state.rawValue else { return }
        told[key] = record.state.rawValue
        guard let connection = try? validConnection(record.connection), connection.notificationTypes.contains(type) else {
            return
        }
        let notification: JSONValue = .object([
            "notification_type": .string(type.rawValue), "notification": record.transaction,
        ])
        let (peer, name) = Self.appParts(record.app)
        var app: [String: JSONValue] = ["name": .string(name)]
        if let peer { app["peer"] = .string(peer) }
        pushes.yield(WalletPush(
            connection: connection.key, app: record.app,
            envelope: .object(["v": .int(1), "app": .object(app), "notification": notification])
        ))
    }

    /// `<peer>/<name>` split at its first `/` (a peer id has none).
    static func appParts(_ key: String) -> (peer: String?, name: String) {
        guard let slash = key.firstIndex(of: "/") else { return (nil, key) }
        let peer = String(key[..<slash])
        return (peer.isEmpty ? nil : peer, String(key[key.index(after: slash)...]))
    }
}

extension JSONValue {
    /// The members of an object; empty for anything else.
    var objectValue: [String: JSONValue] {
        if case .object(let o) = self { return o }
        return [:]
    }
}
