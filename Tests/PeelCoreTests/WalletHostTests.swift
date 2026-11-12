import Foundation
import Synchronization
import Testing
@testable import PeelCore
@testable import PeelTestSupport

/// A wallet that answers as a scenario scripts it (strut's specs/WALLET.md
/// §7): each pay or invoice call takes the step's answer, and a call when
/// the step says the wallet must not be asked is recorded. What it accepted
/// it keeps, tagged as the host tagged it, so lookups and budgets read it,
/// and a wallet event moves it.
final class ScriptedWallet: AppWallet, Sendable {
    private struct State {
        var answer: JSONValue? = nil
        var decodedMsat: Int64 = 0
        /// What the decoder reads besides the amount: the hash and the end.
        var decodedHash = String(repeating: "f", count: 64)
        var decodedEnd: Int64?
        var records: [WalletRecord] = []
        var calls: [String] = []
        var problem: WalletError?
    }

    private let state = Mutex(State())
    private let stream = AsyncStream.makeStream(of: WalletRecord.self)

    /// What the next money call answers (`{ result }` or `{ error }`); nil:
    /// it must not be called.
    func script(_ answer: JSONValue?, decoded: Int64? = nil) {
        state.withLock {
            $0.answer = answer
            if let decoded { $0.decodedMsat = decoded }
        }
    }

    var calls: [String] { state.withLock(\.calls) }
    /// The invoice the decoder reads next: its hash and when it ends.
    func decodes(hash: String, ends: Int64?) { state.withLock { ($0.decodedHash, $0.decodedEnd) = (hash, ends) } }
    func failNextProblem(_ error: WalletError?) { state.withLock { $0.problem = error } }

    /// `msat` already spent through `connection`, settled.
    func seed(spent msat: Int64, connection: String, app: String, at time: Int64) {
        guard msat > 0 else { return }
        state.withLock {
            $0.records.append(WalletRecord(
                transactionID: "seed", direction: .outgoing, paymentType: .keysend, state: .settled,
                paymentHash: String(repeating: "e", count: 64), amountMsat: msat, preimage: String(repeating: "0", count: 64),
                createdAt: time, settledAt: time, connection: connection, app: app
            ))
        }
    }

    /// A wallet event: the transaction it names moved (one this wallet
    /// never made belongs to no connection). Returns the record told.
    @discardableResult
    func event(_ notification: JSONValue) -> WalletRecord? {
        let n = notification.objectValue
        let direction: WalletRecord.Direction = n["notification_type"] == .string("payment_received") ? .incoming : .outgoing
        let payload = n["notification"] ?? .null
        let id = payload.objectValue["transaction_id"]?.string
        let record: WalletRecord? = state.withLock { s in
            let known = s.records.firstIndex { $0.transactionID == id }
            let owner = known.map { s.records[$0] }
            guard var moved = WalletRecord(
                payment: payload, direction: direction, paymentType: owner?.paymentType ?? .keysend,
                connection: owner?.connection ?? "", app: owner?.app ?? ""
            ) else { return nil }
            moved.pubkey = owner?.pubkey
            if let known { s.records[known] = moved } else { s.records.append(moved) }
            return moved
        }
        if let record { stream.continuation.yield(record) }
        return record
    }

    private func take(_ call: String) throws -> JSONValue {
        let answer: JSONValue? = state.withLock {
            $0.calls.append(call)
            defer { $0.answer = nil }
            return $0.answer
        }
        guard let answer, answer != .null else {
            throw WalletError(.internal, "the scripted wallet was asked when it must not be")
        }
        if let code = answer.objectValue["error"]?.string.flatMap(WalletErrorCode.init) {
            throw WalletError(code, "scripted \(code.rawValue)")
        }
        return answer.objectValue["result"] ?? .null
    }

    func network() async -> String { "bitcoin" }

    func decode(invoice: String) async throws -> WalletInvoice {
        state.withLock {
            WalletInvoice(
                bolt11: invoice, paymentHash: $0.decodedHash, amountMsat: $0.decodedMsat, payee: keyG, memo: "",
                expiresAt: $0.decodedEnd
            )
        }
    }

    func problem(paying payment: WalletPayment) async -> WalletError? { state.withLock(\.problem) }

    func pay(_ payment: WalletPayment, for tag: Engine.WalletTag) async throws -> WalletRecord {
        if let budget = tag.budget,
           !budget.admits(UInt64(payment.amountMsat), beside: try await records(connection: tag.connection).compactMap(\.entry)) {
            throw WalletError(.quotaExceeded, "over budget")
        }
        let result = try take("pay")
        let type: WalletRecord.PaymentType = if case .invoice = payment { .bolt11 } else { .keysend }
        guard var record = WalletRecord(payment: result, paymentType: type, connection: tag.connection, app: tag.app) else {
            throw WalletError(.internal, "the script's result is not a payment")
        }
        if case .keysend(let pubkey, _, _, _) = payment { record.pubkey = pubkey }
        state.withLock { $0.records.append(record) }
        return record
    }

    func makeInvoice(amountMsat: Int64, description: String, for tag: Engine.WalletTag) async throws -> WalletRecord {
        let result = try take("make_invoice")
        guard let record = WalletRecord(payment: result, direction: .incoming, paymentType: .bolt11,
                                        connection: tag.connection, app: tag.app) else {
            throw WalletError(.internal, "the script's result is not a transaction")
        }
        state.withLock { $0.records.append(record) }
        return record
    }

    func records(connection: String) async throws -> [WalletRecord] {
        state.withLock { $0.records.filter { $0.connection == connection }.reversed() }
    }

    func balance() async throws -> Int64 {
        _ = try take("get_balance")
        return 1_000_000
    }

    func payeeName(_ pubkey: String) async -> String? { pubkey == keyG ? "Ada" : nil }

    func updates() -> AsyncStream<WalletRecord> { stream.stream }

    /// Signs as `key`: "<key>:<challenge>", so a test sees which key signed what.
    func signVisitor(_ challenge: VisitorChallenge, as key: SignInKey) async throws -> VisitorSignature {
        state.withLock { $0.calls.append("sign_in \(key.rawValue)") }
        return VisitorSignature(key: key == .root ? keyG : key2G, sig: "\(key.rawValue):\(challenge.text)")
    }

    let signsPerDomain: Bool

    init(signsPerDomain: Bool = true) { self.signsPerDomain = signsPerDomain }
}

/// The person, as a scenario scripts them: which sheets they were shown,
/// and what they did on each.
final class ScriptedPerson: WalletPerson, Sendable {
    private let state = Mutex<(answer: String?, shown: [String], connect: WalletConnectSheet?, payment: WalletPaymentSheet?,
                               signIn: SignInKey?, credit: WalletCreditSheet?)>(
        (nil, [], nil, nil, nil, nil)
    )
    /// Never answers until cancelled, as a person who walked away.
    let absent: Bool

    init(absent: Bool = false) { self.absent = absent }

    func will(_ answer: String?) { state.withLock { $0.answer = answer } }
    /// On a sheet that asks to sign in, the key picked; nil: the first offered.
    func pick(_ key: SignInKey?) { state.withLock { $0.signIn = key } }
    func takeShown() -> [String] { state.withLock { s in defer { s.shown = [] }; return s.shown } }
    var lastConnect: WalletConnectSheet? { state.withLock(\.connect) }
    var lastPayment: WalletPaymentSheet? { state.withLock(\.payment) }
    var lastCredit: WalletCreditSheet? { state.withLock(\.credit) }

    private func waitIfAbsent() async {
        guard absent else { return }
        while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
    }

    func connect(_ sheet: WalletConnectSheet) async -> WalletConnectAnswer? {
        let answer = state.withLock { s in
            s.shown.append("connect")
            s.connect = sheet
            return s.answer
        }
        await waitIfAbsent()
        guard answer == "approve", !absent else { return nil }
        var yes = WalletConnectAnswer.asAsked(sheet)
        if sheet.signIn != nil, let key = state.withLock(\.signIn) { yes.signIn = key }
        return yes
    }

    func pay(_ sheet: WalletPaymentSheet) async -> Bool {
        let answer = state.withLock { s in
            s.shown.append("payment")
            s.payment = sheet
            return s.answer
        }
        await waitIfAbsent()
        return answer == "approve" && !absent
    }

    func buyCredit(_ sheet: WalletCreditSheet) async -> Bool {
        let answer = state.withLock { s in
            s.shown.append("credit")
            s.credit = sheet
            return s.answer
        }
        await waitIfAbsent()
        return answer == "approve" && !absent
    }

    func signedIn(to host: String, as key: SignInKey) async {
        state.withLock { $0.shown.append("signed in to \(host) as \(key.rawValue)") }
    }
}

/// The pushes a host made, gathered as they come.
final class PushLog: Sendable {
    private final class Box: Sendable {
        let pushes = Mutex<[WalletPush]>([])
    }

    private let box = Box()
    private let task: Task<Void, Never>

    init(_ host: WalletHost) {
        let box = box
        task = Task { for await push in host.notifications { box.pushes.withLock { $0.append(push) } } }
    }

    deinit { task.cancel() }

    /// What came: once `count` pushes are in (waiting up to `timeout`, since
    /// a loaded CI runner can take longer than any fixed wait), then
    /// `settle` more for any that should not come. With no `count`, only the
    /// short wait, for a step that expects none.
    func take(
        expecting count: Int = 0, timeout: Duration = .seconds(5), settle: Duration = .milliseconds(150)
    ) async -> [WalletPush] {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while count > 0, box.pushes.withLock({ $0.count }) < count, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        try? await Task.sleep(for: settle)
        return box.pushes.withLock { p in defer { p = [] }; return p }
    }
}

/// The wallet host against strut's scenarios (vectors.json `scenarios`,
/// each replayed with real storage, a scripted wallet and a scripted
/// person), and what the contract asks beyond them: the person's gesture
/// before a sheet, one sheet at a time, a sheet given up, an org on the
/// iPhone, a connection that expired, isolation, renewal.
struct WalletHostTests {
    let profile = TempProfile()
    static let now: Int64 = 1_793_800_000
    let scope = WalletScope.app(peer: nil, name: "bench")

    func app(_ request: JSONValue?) -> JSONValue {
        .object(["name": .string("bench"), "version": .string("v3"), "title": .string("Bench"), "request": request ?? .null])
    }

    func message(_ method: String, _ params: JSONValue? = nil, request: JSONValue?, app named: JSONValue? = nil) -> JSONValue {
        var m: [String: JSONValue] = [
            "v": .int(1), "op": .string("call"), "method": .string(method), "app": named ?? app(request),
        ]
        if let params { m["params"] = params }
        return .object(m)
    }

    func host(_ wallet: ScriptedWallet, timeout: Duration = .seconds(60)) throws -> WalletHost {
        WalletHost(storage: try profile.storage(), wallet: wallet, now: { Self.now }, sheetTimeout: timeout)
    }

    func caller(_ person: ScriptedPerson, acted: Bool = true, scope: WalletScope? = nil) -> WalletCaller {
        WalletCaller(scope: scope ?? self.scope, place: "Yours", personActed: acted, person: person)
    }

    /// A scenario's connection as kept, and the request its app sends.
    func setUp(_ scenario: [String: JSONValue], storage: Storage, wallet: ScriptedWallet) throws -> JSONValue? {
        if let request = scenario["request"], request != .null { return request }
        let c = scenario["connection"]?.objectValue ?? [:]
        let methods = list(c["methods"]).compactMap { $0.string.flatMap(WalletMethod.init) }
        let types = list(c["notification_types"]).compactMap { $0.string.flatMap(WalletNotificationType.init) }
        try storage.saveWalletConnection(WalletConnection(
            key: scope.key, app: "/bench", title: "Bench", place: "Yours", methods: methods, notificationTypes: types,
            maxAmountMsat: WalletProtocol.integer(c["max_amount"]),
            renewal: c["renewal_period"]?.string.flatMap(WalletRenewal.init) ?? .never, expiresAt: nil,
            overBudget: c["over_budget"]?.string.flatMap(WalletConnection.OverBudget.init) ?? .ask,
            createdAt: Self.now - 100
        ))
        wallet.seed(spent: WalletProtocol.integer(c["used_budget"]) ?? 0, connection: scope.key, app: "/bench", at: Self.now - 50)
        var request: [String: JSONValue] = [
            "request_methods": .array(methods.map { .string($0.rawValue) }),
            "notification_types": .array(types.map { .string($0.rawValue) }),
        ]
        if let max = c["max_amount"] { request["max_amount"] = max }
        if let period = c["renewal_period"] { request["renewal_period"] = period }
        return .object(request)
    }

    @Test(arguments: WalletVectors.list("scenarios").indices)
    func strutsScenario(_ index: Int) async throws {
        let scenario = WalletVectors.list("scenarios")[index]
        let name = WalletVectors.name(scenario)
        let wallet = ScriptedWallet(), person = ScriptedPerson()
        let storage = try profile.storage()
        let host = WalletHost(storage: storage, wallet: wallet, now: { Self.now })
        let pushes = PushLog(host)
        await host.start()
        let request = try setUp(scenario, storage: storage, wallet: wallet)
        guard case .array(let steps)? = scenario["steps"] else { Issue.record("\(name): no steps"); return }
        for (n, stepValue) in steps.enumerated() {
            let step = stepValue.objectValue
            let at = "\(name), step \(n + 1)"
            if let event = step["wallet_event"] {
                wallet.event(event)
                let expected = step["expect"]?.objectValue["notification"]
                let told = await pushes.take(expecting: expected == nil || expected == .null ? 0 : 1)
                if let expected, expected != .null {
                    #expect(told.count == 1, "\(at): \(told.count) notifications")
                    let pushed = told.first?.envelope.objectValue
                    #expect(sameJSON(pushed?["notification"], expected), "\(at): \(jsonText(pushed?["notification"]))")
                    #expect(pushed?["app"] == .object(["name": .string("bench")]))
                    let problems = WalletProtocol.notificationProblems(pushed?["notification"] ?? .null)
                    #expect(problems.isEmpty, "\(at): \(problems)")
                } else {
                    #expect(told.isEmpty, "\(at): told \(told.map { jsonText($0.envelope) })")
                }
                continue
            }
            let call = step["call"]?.objectValue ?? [:]
            let method = call["method"]?.string ?? ""
            wallet.script(step["wallet"], decoded: WalletProtocol.integer(step["decoded"]?.objectValue["amount"]))
            person.will(step["person"]?.string)
            let callsBefore = wallet.calls.count
            let reply = await host.handle(message(method, call["params"], request: request), from: caller(person))
            let sheet = step["sheet"]?.string
            #expect(person.takeShown() == (sheet.map { [$0] } ?? []), "\(at): sheets")
            if step["wallet"] == nil || step["wallet"] == .null {
                #expect(wallet.calls.count == callsBefore, "\(at): the wallet was asked")
            }
            let expect = step["expect"]?.objectValue ?? [:]
            if let code = expect["error"]?.string {
                let got = reply.objectValue["error"]?.objectValue["data"]?.objectValue["code"]
                #expect(got == .string(code), "\(at): \(jsonText(reply))")
            } else {
                let result = reply.objectValue["result"]
                #expect(sameJSON(result, expect["result"]), "\(at): \(jsonText(reply)) is not \(jsonText(expect["result"]))")
                if let wm = WalletMethod(rawValue: method), let result {
                    #expect(WalletProtocol.resultProblems(wm, result).isEmpty, "\(at): \(WalletProtocol.resultProblems(wm, result))")
                }
            }
        }
        await host.stop()
    }

    // MARK: Beyond the scenarios

    static let keysendTo: JSONValue = .object([
        "pubkey": .string("02" + String(repeating: "a", count: 64)), "amount": .int(2_000),
    ])

    func pending(_ id: String, amount: Int64 = 2_000) -> JSONValue {
        .object(["result": .object([
            "transaction_id": .string(id), "state": .string("pending"), "payment_hash": .string(String(repeating: "7", count: 64)),
            "amount": .int(amount), "created_at": .int(Self.now),
        ])])
    }

    func connect(
        _ host: WalletHost, _ person: ScriptedPerson, request: JSONValue, scope: WalletScope? = nil, app named: JSONValue? = nil
    ) async -> JSONValue {
        person.will("approve")
        let reply = await host.handle(message("connect", request: request, app: named), from: caller(person, scope: scope))
        _ = person.takeShown()
        return reply
    }

    static let keysendRequest: JSONValue = .object([
        "request_methods": .array([.string("pay_keysend"), .string("get_budget"), .string("lookup_payment")]),
        "notification_types": .array([.string("payment_sent")]),
        "max_amount": .int(10_000), "renewal_period": .string("daily"),
    ])

    /// No sheet without the person: a call that needs one, made when they
    /// have not just clicked or tapped, is refused, and nothing is asked.
    @Test func noSheetOpensWithoutThePerson() async throws {
        let wallet = ScriptedWallet(), person = ScriptedPerson()
        let host = try host(wallet)
        let reply = await host.handle(message("connect", request: Self.keysendRequest), from: caller(person, acted: false))
        #expect(reply.objectValue["error"]?.objectValue["data"]?.objectValue["code"] == .string("RESTRICTED"))
        #expect(person.takeShown().isEmpty)
        // Connected, a payment inside the budget needs no gesture; one over it does.
        _ = await connect(host, person, request: Self.keysendRequest)
        wallet.script(pending("tx-1"))
        let inside = await host.handle(message("pay_keysend", Self.keysendTo, request: Self.keysendRequest),
                                       from: caller(person, acted: false))
        #expect(inside.objectValue["result"]?.objectValue["state"] == .string("pending"))
        let over: JSONValue = .object(["pubkey": .string("02" + String(repeating: "a", count: 64)), "amount": .int(9_000)])
        let refused = await host.handle(message("pay_keysend", over, request: Self.keysendRequest), from: caller(person, acted: false))
        #expect(refused.objectValue["error"]?.objectValue["data"]?.objectValue["code"] == .string("RESTRICTED"))
        #expect(person.takeShown().isEmpty)
        #expect(wallet.calls == ["pay"])
    }

    /// One sheet at a time: another call that needs one meanwhile is
    /// `RATE_LIMITED`; and a sheet nobody answers is taken down and refused.
    @Test func oneSheetAtATimeAndNoneForEver() async throws {
        let wallet = ScriptedWallet(), absent = ScriptedPerson(absent: true), other = ScriptedPerson()
        let storage = try profile.storage()
        let host = WalletHost(storage: storage, wallet: wallet, now: { Self.now }, sheetTimeout: .seconds(1))
        let asking = message("connect", request: Self.keysendRequest), walkedAway = caller(absent)
        let first = Task { await host.handle(asking, from: walkedAway) }
        // The first sheet is up before the second call (a fixed wait raced on a loaded CI runner).
        let clock = ContinuousClock(), deadline = clock.now.advanced(by: .seconds(5))
        while absent.lastConnect == nil, clock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        let second = await host.handle(message("connect", request: Self.keysendRequest), from: caller(other))
        #expect(second.objectValue["error"]?.objectValue["data"]?.objectValue["code"] == .string("RATE_LIMITED"))
        #expect(other.takeShown().isEmpty)
        let timedOut = await first.value
        #expect(timedOut.objectValue["error"]?.objectValue["data"]?.objectValue["code"] == .string("RESTRICTED"))
        #expect(try storage.walletConnection(key: scope.key) == nil)
    }

    /// Over budget and approved, the payment is counted beyond the limit;
    /// the sheet shows the decoded amount, the payee's name and the app's
    /// words as its own.
    @Test func anApprovedPaymentOverBudgetIsCountedAndTheSheetSaysWhat() async throws {
        let wallet = ScriptedWallet(), person = ScriptedPerson()
        let host = try host(wallet)
        _ = await connect(host, person, request: Self.keysendRequest)
        let params: JSONValue = .object([
            "pubkey": .string(keyG), "amount": .int(12_000), "metadata": .object(["comment": .string("tip\u{202E}!")]),
        ])
        wallet.script(pending("tx-big", amount: 12_000))
        person.will("approve")
        let reply = await host.handle(message("pay_keysend", params, request: Self.keysendRequest), from: caller(person))
        #expect(reply.objectValue["result"]?.objectValue["transaction_id"] == .string("tx-big"))
        let sheet = try #require(person.lastPayment)
        #expect(sheet.amountMsat == 12_000 && sheet.payeeName == "Ada" && sheet.keysend && !sheet.async)
        #expect(sheet.comment == "tip!")
        #expect(sheet.title == "Bench" && sheet.version == "v3" && sheet.place == "Yours")
        let budget = await host.handle(message("get_budget", request: Self.keysendRequest), from: caller(person))
        #expect(budget.objectValue["result"]?.objectValue["used_budget"] == .int(12_000))
        #expect(budget.objectValue["result"]?.objectValue["renews_at"] == .int(Self.now + 86_400))
    }

    /// The amount of an invoice is the one decoded, never the app's: an
    /// invoice that names none is not paid, and the over-budget sheet shows
    /// what the invoice says.
    @Test func anInvoicesAmountIsTheDecodedOne() async throws {
        let wallet = ScriptedWallet(), person = ScriptedPerson()
        let host = try host(wallet)
        let request: JSONValue = .object(["request_methods": .array([.string("pay_invoice")]), "max_amount": .int(1_000)])
        _ = await connect(host, person, request: request)
        let invoice = "lnbc1pvjluezsp5zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zygspp5qqqs"
        wallet.script(nil, decoded: 0)
        let named = await host.handle(message("pay_invoice", .object(["invoice": .string(invoice), "amount": .int(10)]),
                                              request: request), from: caller(person))
        #expect(named.objectValue["error"]?.objectValue["data"]?.objectValue["code"] == .string("NOT_IMPLEMENTED"))
        // The page's shape names an amount the decoder does not see: refused, not paid.
        let pricey = "lnbc210n1pqpzry9x8gf2tvdw0s3jn54khce6mua7lqpzry9x8gf2tvdw0s3jn54khce6mua7l"
        wallet.script(nil, decoded: 50_000)
        person.will("decline")
        let declined = await host.handle(message("pay_invoice", .object(["invoice": .string(pricey)]), request: request),
                                         from: caller(person))
        #expect(declined.objectValue["error"]?.objectValue["data"]?.objectValue["code"] == .string("USER_REJECTED"))
        #expect(person.lastPayment?.amountMsat == 50_000)
        #expect(wallet.calls.isEmpty)
    }

    /// What the wallet refuses before anyone is asked comes back as it is,
    /// with no sheet and no payment.
    @Test func aPaymentTheWalletCannotMakeAsksNobody() async throws {
        let wallet = ScriptedWallet(), person = ScriptedPerson()
        let host = try host(wallet)
        _ = await connect(host, person, request: Self.keysendRequest)
        wallet.failNextProblem(WalletError(.insufficientBalance, "not enough"))
        let reply = await host.handle(message("pay_keysend", Self.keysendTo, request: Self.keysendRequest), from: caller(person))
        #expect(reply.objectValue["error"]?.objectValue["data"]?.objectValue["code"] == .string("INSUFFICIENT_BALANCE"))
        #expect(wallet.calls.isEmpty && person.takeShown().isEmpty)
    }

    /// What the Sphinx core cannot send is `NOT_IMPLEMENTED`, never sent
    /// otherwise: a preimage, a record other than 13377331, a route of more
    /// than one hop. 13377331's value is the base64 text the core sends.
    @Test func whatTheCoreCannotSendIsNotImplemented() async throws {
        let wallet = ScriptedWallet(), person = ScriptedPerson()
        let host = try host(wallet)
        _ = await connect(host, person, request: Self.keysendRequest)
        let target = "02" + String(repeating: "a", count: 64), lsp = "03" + String(repeating: "b", count: 64)
        let refused: [JSONValue] = [
            .object(["pubkey": .string(target), "amount": .int(10), "preimage": .string(String(repeating: "1", count: 64))]),
            .object(["pubkey": .string(target), "amount": .int(10),
                     "tlv_records": .array([.object(["type": .int(7_629_169), "value": .string("00")])])]),
            .object(["pubkey": .string(target), "amount": .int(10), "route_hints": .array([.array([
                .object(["pubkey": .string(lsp), "short_channel_id": .string("1")]),
                .object(["pubkey": .string(lsp), "short_channel_id": .string("2")]),
            ])])]),
            .object(["pubkey": .string(target), "amount": .int(10), "route_hints": .array([.array([
                .object(["pubkey": .string(lsp), "short_channel_id": .string("1x2x3")]),
            ])])]),
        ]
        for params in refused {
            let reply = await host.handle(message("pay_keysend", params, request: Self.keysendRequest), from: caller(person))
            #expect(reply.objectValue["error"]?.objectValue["data"]?.objectValue["code"] == .string("NOT_IMPLEMENTED"))
        }
        #expect(wallet.calls.isEmpty)
        // "hi" as base64 text, hex: what the core sends for the data "hi".
        #expect(try WalletHost.sphinxData(Data("aGk=".utf8)) == Data("hi".utf8))
        #expect(throws: WalletError.self) { try WalletHost.sphinxData(Data([0xff, 0x00])) }
    }

    /// Isolation: a connection reads only its own transactions; another
    /// app's are `NOT_FOUND`, and their notifications never reach it.
    @Test func aConnectionSeesOnlyItsOwn() async throws {
        let wallet = ScriptedWallet(), person = ScriptedPerson()
        let storage = try profile.storage()
        let host = WalletHost(storage: storage, wallet: wallet, now: { Self.now })
        let pushes = PushLog(host)
        await host.start()
        let other = WalletScope.app(peer: "acme", name: "shop")
        let otherApp: JSONValue = .object([
            "name": .string("shop"), "peer": .string("acme"), "version": .string("v1"), "title": .string("Shop"),
            "request": Self.keysendRequest,
        ])
        _ = await connect(host, person, request: Self.keysendRequest)
        _ = await connect(host, person, request: Self.keysendRequest, scope: other, app: otherApp)
        wallet.script(pending("tx-shop"))
        let otherCaller = caller(person, scope: other)
        let paid = await host.handle(message("pay_keysend", Self.keysendTo, request: nil, app: otherApp), from: otherCaller)
        #expect(paid.objectValue["result"]?.objectValue["transaction_id"] == .string("tx-shop"))
        let looked = await host.handle(message("lookup_payment", .object(["transaction_id": .string("tx-shop")]),
                                               request: Self.keysendRequest), from: caller(person))
        #expect(looked.objectValue["error"]?.objectValue["data"]?.objectValue["code"] == .string("NOT_FOUND"))
        wallet.event(.object(["notification_type": .string("payment_sent"), "notification": .object([
            "type": .string("outgoing"), "state": .string("settled"), "transaction_id": .string("tx-shop"),
            "payment_hash": .string(String(repeating: "7", count: 64)), "preimage": .string(String(repeating: "1", count: 64)),
            "amount": .int(2_000), "created_at": .int(Self.now), "settled_at": .int(Self.now + 1),
        ])]))
        let told = await pushes.take(expecting: 1)
        #expect(told.map(\.connection) == [other.key])
        #expect(told.first?.envelope.objectValue["app"] == .object(["name": .string("shop"), "peer": .string("acme")]))
        await host.stop()
    }

    /// A message for an app the page does not show (Mac), or not one at
    /// all, is refused; an app that asks for no wallet has none.
    @Test func whatTheHostRefusesOutright() async throws {
        let wallet = ScriptedWallet(), person = ScriptedPerson()
        let host = try host(wallet)
        let elsewhere = caller(person, scope: .app(peer: nil, name: "other"))
        let reply = await host.handle(message("get_info", request: Self.keysendRequest), from: elsewhere)
        #expect(reply.objectValue["error"]?.objectValue["data"]?.objectValue["code"] == .string("RESTRICTED"))
        let garbage = await host.handle(.string("pay"), from: caller(person))
        #expect(garbage.objectValue["error"]?.objectValue["data"]?.objectValue["code"] == .string("BAD_REQUEST"))
        let none = await host.handle(.object(["v": .int(1), "op": .string("capability"), "app": app(nil)]), from: caller(person))
        #expect(none.objectValue["error"]?.objectValue["data"]?.objectValue["code"] == .string("RESTRICTED"))
        let noWallet = await host.handle(message("connect", request: nil), from: caller(person))
        #expect(noWallet.objectValue["error"]?.objectValue["data"]?.objectValue["code"] == .string("RESTRICTED"))
        let capability = await host.handle(
            .object(["v": .int(1), "op": .string("capability"), "app": app(Self.keysendRequest)]), from: caller(person)
        )
        let offered = capability.objectValue["result"]?.objectValue
        #expect(offered?["wallet"] == .string("sphinx") && offered?["connected"] == .bool(false))
        let methods = list(offered?["methods"])
        #expect(!methods.isEmpty && !methods.contains(.string("pay_lightning_address")))
    }

    /// Connecting again: nothing asked while the grant covers the version;
    /// a version that asks for more is asked again and keeps what was held.
    @Test func connectAgainAsksOnlyForMore() async throws {
        let wallet = ScriptedWallet(), person = ScriptedPerson()
        let host = try host(wallet)
        _ = await connect(host, person, request: Self.keysendRequest)
        person.will("decline")
        let again = await host.handle(message("connect", request: Self.keysendRequest), from: caller(person))
        #expect(person.takeShown().isEmpty)
        #expect(again.objectValue["result"]?.objectValue["connection"] != nil)
        let more: JSONValue = .object([
            "request_methods": .array([.string("make_invoice")]), "notification_types": .array([.string("payment_received")]),
        ])
        let grown = await connect(host, person, request: more)
        let methods = grown.objectValue["result"]?.objectValue["connection"]?.objectValue["methods"]
        #expect(methods == .array([.string("make_invoice"), .string("pay_keysend"), .string("get_budget"), .string("lookup_payment")]))
        #expect(person.lastConnect?.held != nil)
    }

    /// A connection past its expiry is none: `UNAUTHORIZED`.
    @Test func anExpiredConnectionIsNone() async throws {
        let wallet = ScriptedWallet(), person = ScriptedPerson()
        let storage = try profile.storage()
        let host = WalletHost(storage: storage, wallet: wallet, now: { Self.now })
        try storage.saveWalletConnection(WalletConnection(
            key: scope.key, app: "/bench", title: "Bench", place: "Yours", methods: [.getBudget], notificationTypes: [],
            maxAmountMsat: 1_000, renewal: .never, expiresAt: Self.now - 1, overBudget: .ask, createdAt: Self.now - 100
        ))
        let reply = await host.handle(message("get_budget", request: Self.keysendRequest), from: caller(person))
        #expect(reply.objectValue["error"]?.objectValue["data"]?.objectValue["code"] == .string("UNAUTHORIZED"))
    }

    /// On the iPhone the org is who is trusted: one connection for its apps,
    /// the sheet naming the org from Peel's own record.
    @Test func anOrgIsOneConnection() async throws {
        let wallet = ScriptedWallet(), person = ScriptedPerson()
        let storage = try profile.storage()
        let host = WalletHost(storage: storage, wallet: wallet, now: { Self.now })
        let org = WalletScope.org(peer: "acme")
        let orgCaller = WalletCaller(scope: org, place: "Acme Inc", personActed: true, person: person)
        person.will("approve")
        _ = await host.handle(message("connect", request: Self.keysendRequest), from: orgCaller)
        #expect(person.lastConnect?.byOrg == true && person.lastConnect?.place == "Acme Inc")
        #expect(try storage.walletConnection(key: "org:acme")?.app == "/bench")
        // Another app of the same org holds the same connection.
        let shop: JSONValue = .object([
            "v": .int(1), "op": .string("call"), "method": .string("get_budget"),
            "app": .object(["name": .string("shop"), "version": .string("v1"), "title": .string("Shop"), "request": Self.keysendRequest]),
        ])
        let budget = await host.handle(shop, from: orgCaller)
        #expect(budget.objectValue["result"]?.objectValue["total_budget"] == .int(10_000))
    }

    /// A pay call's answer comes before its notification: a payment that
    /// settles while the call is in flight is told in the answer, and not
    /// again.
    @Test func theAnswerComesBeforeTheNotification() async throws {
        let wallet = SettlingWallet()
        let person = ScriptedPerson()
        let storage = try profile.storage()
        let host = WalletHost(storage: storage, wallet: wallet, now: { Self.now })
        let pushes = PushLog(host)
        await host.start()
        _ = await connect(host, person, request: Self.keysendRequest)
        let reply = await host.handle(message("pay_keysend", Self.keysendTo, request: Self.keysendRequest), from: caller(person))
        #expect(reply.objectValue["result"]?.objectValue["state"] == .string("settled"))
        #expect(await pushes.take().isEmpty)
        await host.stop()
    }

    // MARK: Budgets

    @Test func periodsRenewFromCreation() {
        let day: Int64 = 86_400
        #expect(WalletBudget.period(created: 1_000, renewal: .never, now: 99_999_999) == (1_000, nil))
        #expect(WalletBudget.period(created: 1_000, renewal: .daily, now: 1_000 + day * 3 + 5) == (1_000 + day * 3, 1_000 + day * 4))
        #expect(WalletBudget.period(created: 1_000, renewal: .weekly, now: 1_000 + 6 * day) == (1_000, 1_000 + 7 * day))
        // 2026-01-31: February is short, so it renews on its last day.
        let jan31: Int64 = 1_769_817_600
        let (start, renews) = WalletBudget.period(created: jan31, renewal: .monthly, now: jan31 + 40 * day)
        #expect(start == 1_772_236_800)  // 2026-02-28
        #expect(renews == 1_774_915_200)  // 2026-03-31
        #expect(WalletBudget.period(created: jan31, renewal: .yearly, now: jan31 + 400 * day).start == 1_801_353_600)  // 2027-01-31
    }

    @Test func aBudgetCountsPendingSettledWithFeesAndNotFailed() {
        let entries = [
            WalletRecord(transactionID: "a", direction: .outgoing, paymentType: .keysend, state: .pending, paymentHash: "",
                         amountMsat: 100, createdAt: 10, connection: "c", app: "a"),
            WalletRecord(transactionID: "b", direction: .outgoing, paymentType: .keysend, state: .settled, paymentHash: "",
                         amountMsat: 200, feesMsat: 5, createdAt: 10, connection: "c", app: "a"),
            WalletRecord(transactionID: "c", direction: .outgoing, paymentType: .keysend, state: .failed, paymentHash: "",
                         amountMsat: 400, createdAt: 10, connection: "c", app: "a"),
            WalletRecord(transactionID: "d", direction: .incoming, paymentType: .bolt11, state: .settled, paymentHash: "",
                         amountMsat: 800, createdAt: 10, connection: "c", app: "a"),
            WalletRecord(transactionID: "e", direction: .outgoing, paymentType: .keysend, state: .pending, paymentHash: "",
                         amountMsat: 1_600, createdAt: 5, connection: "c", app: "a"),
        ].compactMap(\.entry)
        #expect(WalletBudget.used(entries, since: 10) == 305)
        #expect(WalletBudget.Guard(limitMsat: 400, since: 10).admits(95, beside: entries))
        #expect(!WalletBudget.Guard(limitMsat: 400, since: 10).admits(96, beside: entries))
        #expect(WalletBudget.Guard(limitMsat: nil, since: 10).admits(.max, beside: entries))
    }
}

/// A wallet whose payment settles while the call waits for it: the update
/// comes before the answer.
final class SettlingWallet: AppWallet, Sendable {
    private let stream = AsyncStream.makeStream(of: WalletRecord.self)
    private let made = Mutex<[WalletRecord]>([])

    func network() async -> String { "bitcoin" }
    func decode(invoice: String) async throws -> WalletInvoice { throw WalletError(.badRequest, "no") }
    func problem(paying payment: WalletPayment) async -> WalletError? { nil }

    func pay(_ payment: WalletPayment, for tag: Engine.WalletTag) async throws -> WalletRecord {
        let record = WalletRecord(
            transactionID: "tx-fast", direction: .outgoing, paymentType: .keysend, state: .settled,
            paymentHash: String(repeating: "7", count: 64), amountMsat: payment.amountMsat,
            preimage: String(repeating: "1", count: 64), createdAt: WalletHostTests.now, settledAt: WalletHostTests.now,
            connection: tag.connection, app: tag.app
        )
        made.withLock { $0.append(record) }
        stream.continuation.yield(record)
        try await Task.sleep(for: .milliseconds(100))
        return record
    }

    func makeInvoice(amountMsat: Int64, description: String, for tag: Engine.WalletTag) async throws -> WalletRecord {
        throw WalletError(.notImplemented, "no")
    }

    func records(connection: String) async throws -> [WalletRecord] { made.withLock { $0 } }
    func balance() async throws -> Int64 { 0 }
    func payeeName(_ pubkey: String) async -> String? { nil }
    func updates() -> AsyncStream<WalletRecord> { stream.stream }
    func signVisitor(_ challenge: VisitorChallenge, as key: SignInKey) async throws -> VisitorSignature {
        throw WalletError(.notImplemented, "no")
    }
    var signsPerDomain: Bool { false }
}
