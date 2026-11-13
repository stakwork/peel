import Foundation
import Sphinxrs
import Testing
@testable import PeelCore
@testable import PeelTestSupport

/// Signing a visitor in to a public app through the wallet connection
/// (strut's plans/app-payments.md §4.4, specs/WALLET.md §1.2 "sign_in";
/// docs/app-wallet.md, "Signing in"): strut's vectors (what may be signed,
/// and signatures by Sphinx's own signer), and the host's guard, sheet and
/// grant beyond them.
struct VisitorSignInTests {
    let profile = TempProfile()
    /// The profile's storage, opened once (a profile takes one process's lock).
    let storage: Storage
    static let now: Int64 = 1_793_800_000
    static let origin = WalletScope.origin("https://shop.example.com")
    static let remote = WalletScope.remote(seller: URL(string: "https://shop.example.com")!, name: "moon-game")

    init() throws { storage = try profile.storage() }

    // MARK: strut's vectors

    @Test func theSignInVectorsAreThere() {
        #expect(WalletVectors.list("sign_in_requests").count == 17)
        #expect(WalletVectors.list("sign_in_signatures").count == 9)
        #expect(WalletVectors.list("host_capabilities").count == 9)
    }

    /// What may be signed at `now`, as strut's `signInRequestProblems`
    /// reads it: above all, a strut challenge for the seller's host alone.
    @Test(arguments: WalletVectors.list("sign_in_requests").indices)
    func aSignInRequestAsStrutReadsIt(_ index: Int) throws {
        let vector = WalletVectors.list("sign_in_requests")[index]
        let now = try #require(WalletProtocol.integer(vector["now"]))
        let problems = SignInRequest.problems(vector["request"] ?? .null, nowMs: now)
        #expect(problems.isEmpty == (vector["valid"] == .bool(true)), "\(WalletVectors.name(vector)): \(problems)")
    }

    /// Peel's linked core signs a challenge exactly as Sphinx's signer does
    /// for strut's vectors (sphinx-rs `sign_bytes`, the account's key at
    /// child index 0): the key and signature strut's `ln-message` checks.
    @Test(arguments: WalletVectors.list("sign_in_signatures").filter { $0["signer"] != nil }.indices)
    func peelsCoreSignsAsStrutsVectors(_ index: Int) throws {
        let vector = WalletVectors.list("sign_in_signatures").filter { $0["signer"] != nil }[index]
        let signer = try #require(vector["signer"]?.objectValue)
        let seed = try #require(signer["seed"]?.string), network = try #require(signer["network"]?.string)
        let idx = UInt64(try #require(WalletProtocol.integer(signer["idx"])))
        let message = try #require(vector["message"]?.string)
        #expect(try Sphinxrs.pubkeyFromSeed(seed: seed, idx: idx, time: "1", network: network) == vector["key"]?.string)
        #expect(try Sphinxrs.signBytes(seed: seed, idx: idx, time: "1", network: network, msg: Data(message.utf8))
            == vector["sig"]?.string, "\(WalletVectors.name(vector))")
    }

    /// What strut's UI reads a native host's capability as: on a
    /// stranger's page, Peel's answer names every op of the host's own
    /// (buying credit and signing in), and its own name.
    @Test func hostCapabilityNamesTheHostsOpsWherePeelIsAVisitors() async throws {
        let host = try host(ScriptedWallet())
        let open = await host.handle(.object(["v": .int(1), "op": .string("host_capability")]), from: caller(ScriptedPerson()))
        let ops = ["buy_credit", "buy_credit_status", "buy_credit_cancel", "sign_in"]
        #expect(open == .object(["result": .object([
            "version": .int(1), "ops": .array(ops.map(JSONValue.string)), "wallet": .string("Peel"),
        ])]))
        // A page of the person's own strut, or an org's, knows who is looking: no sign-in there.
        let own = await host.handle(
            .object(["v": .int(1), "op": .string("host_capability")]),
            from: caller(ScriptedPerson(), scope: .org(peer: "acme"))
        )
        #expect(own.objectValue["result"]?.objectValue["ops"] == .array([]))
    }

    // MARK: The guard

    /// The iPhone trusts only the origin it loaded: the page's `seller` is
    /// its own claim, and a challenge for any other host is never signed.
    @Test func theIPhoneSignsOnlyForTheOriginItLoaded() async throws {
        let wallet = ScriptedWallet(), person = ScriptedPerson()
        let host = try host(wallet)
        try keep(.root, scope: Self.origin)
        // The page names another seller; the challenge is for the origin: signed.
        let claimed = await host.handle(signIn(challenge("shop.example.com"), seller: "https://elsewhere.example"),
                                        from: caller(person))
        #expect(claimed.objectValue["result"] != nil)
        // The page names the challenge's host as the seller, but Peel loaded another: refused.
        let other = await host.handle(signIn(challenge("evil.example.net"), seller: "https://evil.example.net"),
                                      from: caller(person))
        #expect(code(other) == "BAD_REQUEST")
        #expect(wallet.calls == ["sign_in root"])
    }

    /// The Mac's page is Peel's own strut UI hosting a stranger's app: the
    /// seller it names must be the one Peel opened, and the challenge that
    /// seller's.
    @Test func theMacSignsOnlyForTheSellerItsPageShows() async throws {
        let wallet = ScriptedWallet(), person = ScriptedPerson()
        let host = try host(wallet)
        try keep(.root, scope: Self.remote)
        let shown = await host.handle(signIn(challenge("shop.example.com")), from: caller(person, scope: Self.remote))
        #expect(shown.objectValue["result"] != nil)
        let another = await host.handle(
            signIn(challenge("evil.example.net"), seller: "https://evil.example.net"), from: caller(person, scope: Self.remote)
        )
        #expect(code(another) == "BAD_REQUEST")
        // A path under the same host is another seller on the Mac.
        let underPath = await host.handle(
            signIn(challenge("shop.example.com"), seller: "https://shop.example.com/lab"), from: caller(person, scope: Self.remote)
        )
        #expect(code(underPath) == "BAD_REQUEST")
        #expect(wallet.calls == ["sign_in root"])
    }

    /// Nothing but a strut challenge, nothing that has ended, nothing where
    /// Peel did not open a stranger's page: refused before anyone is asked.
    @Test func whatIsNeverSigned() async throws {
        let wallet = ScriptedWallet(), person = ScriptedPerson()
        person.will("approve")
        let host = try host(wallet)
        let ended = await host.handle(signIn(challenge("shop.example.com", exp: Self.now * 1000)), from: caller(person))
        #expect(code(ended) == "BAD_REQUEST")
        let lnurl = await host.handle(signIn(.string(String(repeating: "ab", count: 32))), from: caller(person))
        #expect(code(lnurl) == "BAD_REQUEST")
        let own = await host.handle(signIn(challenge("shop.example.com")), from: caller(person, scope: .org(peer: "acme")))
        #expect(code(own) == "RESTRICTED")
        #expect(person.takeShown().isEmpty && wallet.calls.isEmpty)
    }

    // MARK: The sheet and the grant

    /// The first sign-in asks, only after the person's tap: who they sign
    /// in as, the account first. The yes is kept on the connection; the
    /// next sign-in signs with no sheet, with a toast. Revoking ends it.
    @Test func theFirstSignInAsksAndTheConnectionKeepsIt() async throws {
        let wallet = ScriptedWallet(), person = ScriptedPerson()
        let host = try host(wallet)
        let untapped = await host.handle(signIn(challenge("shop.example.com")), from: caller(person, acted: false))
        #expect(code(untapped) == "RESTRICTED")
        #expect(person.takeShown().isEmpty)

        person.will("approve")
        let first = await host.handle(signIn(challenge("shop.example.com")), from: caller(person))
        #expect(first.objectValue["result"]?.objectValue["key"] == .string(keyG))
        #expect(person.takeShown() == ["connect"])
        let sheet = try #require(person.lastConnect)
        #expect(sheet.signIn == SignInOffer(host: "shop.example.com", keys: [.root, .domain]))
        #expect(!sheet.asksWallet && sheet.required.isEmpty && sheet.byOrg)
        let kept = try #require(try storage.walletConnection(key: Self.origin.key))
        #expect(kept.signIn == .root && kept.methods.isEmpty)

        person.will(nil)
        let again = await host.handle(signIn(challenge("shop.example.com")), from: caller(person, acted: false))
        #expect(again.objectValue["result"] != nil)
        #expect(person.takeShown() == ["signed in to shop.example.com as root"])

        try storage.deleteWalletConnection(key: Self.origin.key)
        let revoked = await host.handle(signIn(challenge("shop.example.com")), from: caller(person, acted: false))
        #expect(code(revoked) == "RESTRICTED")
        #expect(wallet.calls == ["sign_in root", "sign_in root"])
    }

    /// "A new identity for this app": picked by the person and kept, or the
    /// only choice when the app takes a key of its domain alone.
    @Test func aNewIdentityIsThePersonsChoiceOrTheAppsRule() async throws {
        let wallet = ScriptedWallet(), person = ScriptedPerson()
        let host = try host(wallet)
        person.will("approve")
        person.pick(.domain)
        let picked = await host.handle(signIn(challenge("shop.example.com")), from: caller(person))
        #expect(picked.objectValue["result"]?.objectValue["key"] == .string(key2G))
        #expect(try storage.walletConnection(key: Self.origin.key)?.signIn == .domain)

        // A root grant does not answer an app that takes its domain's key alone: asked again, that key only.
        let mac = Self.remote
        try keep(.root, scope: mac)
        person.pick(nil)
        let domainOnly = await host.handle(signIn(challenge("shop.example.com", key: "domain")), from: caller(person, scope: mac))
        #expect(domainOnly.objectValue["result"]?.objectValue["key"] == .string(key2G))
        #expect(person.lastConnect?.signIn?.keys == [.domain])
        #expect(wallet.calls == ["sign_in domain", "sign_in domain"])
    }

    /// While the wallet cannot sign with a key of one domain, the sheet
    /// offers the account alone, and an app that takes only that key is
    /// told so before anyone is asked.
    @Test func withoutAKeyPerDomainOnlyTheAccountIsOffered() async throws {
        let wallet = ScriptedWallet(signsPerDomain: false), person = ScriptedPerson()
        let host = try host(wallet)
        person.will("approve")
        _ = await host.handle(signIn(challenge("shop.example.com")), from: caller(person))
        #expect(person.lastConnect?.signIn?.keys == [.root])
        let domainOnly = await host.handle(signIn(challenge("shop.example.com", key: "domain")), from: caller(person))
        #expect(code(domainOnly) == "NOT_IMPLEMENTED")
        #expect(person.takeShown() == ["connect"])
    }

    /// A no keeps nothing; a sheet still up when the challenge ends is
    /// taken down, since the page has stopped waiting.
    @Test func aDeclineKeepsNothingAndTheSheetEndsWithTheChallenge() async throws {
        let wallet = ScriptedWallet()
        let host = try host(wallet)
        let declining = ScriptedPerson()
        let declined = await host.handle(signIn(challenge("shop.example.com")), from: caller(declining))
        #expect(code(declined) == "USER_REJECTED")
        #expect(try storage.walletConnection(key: Self.origin.key) == nil)

        let away = ScriptedPerson(absent: true)
        let started = ContinuousClock.now
        let ended = await host.handle(signIn(challenge("shop.example.com", exp: Self.now * 1000 + 200)), from: caller(away))
        #expect(code(ended) == "RESTRICTED")
        #expect(ContinuousClock.now - started < .seconds(5))
        #expect(wallet.calls.isEmpty)
    }

    /// ONE sheet for an app that wants both: the wallet its page asked for,
    /// beside signing in. The yes grants both; `connect` then asks nothing,
    /// and keeps the sign-in.
    @Test func oneSheetForSigningInAndTheWallet() async throws {
        let wallet = ScriptedWallet(), person = ScriptedPerson()
        let host = try host(wallet)
        let request: JSONValue = .object([
            "request_methods": .array([.string("pay_keysend")]), "max_amount": .int(5_000_000),
            "renewal_period": .string("weekly"),
        ])
        let app: JSONValue = .object([
            "name": .string("moon-game"), "version": .string("v3"), "title": .string("Moon Game"), "request": request,
        ])
        _ = await host.handle(.object(["v": .int(1), "op": .string("capability"), "app": app]), from: caller(person))
        person.will("approve")
        _ = await host.handle(signIn(challenge("shop.example.com")), from: caller(person))
        #expect(person.takeShown() == ["connect"])
        let sheet = try #require(person.lastConnect)
        #expect(sheet.asksWallet && sheet.required == [.payKeysend] && sheet.maxAmountMsat == 5_000_000)
        #expect(sheet.signIn?.keys.first == .root)
        let kept = try #require(try storage.walletConnection(key: Self.origin.key))
        #expect(kept.signIn == .root && kept.methods == [.payKeysend] && kept.maxAmountMsat == 5_000_000)

        person.will(nil)
        let connect = await host.handle(
            .object(["v": .int(1), "op": .string("call"), "method": .string("connect"), "params": .object([:]), "app": app]),
            from: caller(person, acted: false)
        )
        #expect(connect.objectValue["result"] != nil)
        #expect(person.takeShown().isEmpty)
        #expect(try storage.walletConnection(key: Self.origin.key)?.signIn == .root)
    }

    /// A connection that only signs in holds no wallet: the page is told it
    /// is not connected, and every method is refused.
    @Test func aSignInAloneIsNoWallet() async throws {
        let wallet = ScriptedWallet(), person = ScriptedPerson()
        let host = try host(wallet)
        try keep(.root, scope: Self.origin)
        let app: JSONValue = .object([
            "name": .string("moon-game"), "version": .string("v3"), "title": .string("Moon Game"),
            "request": .object(["request_methods": .array([.string("get_balance")])]),
        ])
        let capability = await host.handle(.object(["v": .int(1), "op": .string("capability"), "app": app]), from: caller(person))
        #expect(capability.objectValue["result"]?.objectValue["connected"] == .bool(false))
        let balance = await host.handle(
            .object(["v": .int(1), "op": .string("call"), "method": .string("get_balance"), "params": .object([:]), "app": app]),
            from: caller(person)
        )
        #expect(code(balance) == "RESTRICTED")
    }

    // MARK: The engine

    /// The engine signs with the account's own key (child index 0, the key
    /// its payments come from), as strut's vectors' signer does; or, as a
    /// new identity, with LUD-05's linking key for the challenge's host: the
    /// keys an independent BIP39/BIP32 implementation derives for these
    /// words (sphinx-rs#106's vectors), another for each host, and none of
    /// them the account's.
    @Test func theEngineSignsWithTheAccountsKey() async throws {
        let account = TempProfile()
        defer { withExtendedLifetime(account) {} }
        let engine = try testEngine(try registeredStorage(account))
        let text = try #require(challengeText("shop.example.com"))
        let signed = try await engine.signVisitor(#require(VisitorChallenge(text)), as: .root)
        let accountKey = await engine.accountKey
        #expect(signed.key == accountKey)
        let seed = try Sphinxrs.mnemonicToSeed(mnemonic: abandon.joined(separator: " "))
        #expect(signed.sig == (try Sphinxrs.signBytes(seed: seed, idx: 0, time: "1", network: "bitcoin", msg: Data(text.utf8))))
        // What strut's `readSignInReply` takes: a compressed key and 65 bytes, hex.
        #expect(signed.key.count == 66 && ["02", "03"].contains(String(signed.key.prefix(2))))
        #expect(signed.sig.count == 130 && Data(hex: signed.sig) != nil)
        let site = try #require(challengeText("site.com")), app = try #require(challengeText("app.example.com"))
        let forSite = try await engine.signVisitor(#require(VisitorChallenge(site)), as: .domain)
        let forApp = try await engine.signVisitor(#require(VisitorChallenge(app)), as: .domain)
        #expect(forSite.key == "027da5d64331f61260eb8e2b356403446555f525bc7dc35b991ec1447e4f58991f")
        #expect(forApp.key == "0278e4feeddc78fae0a8d5d1b5d40c4d56ffa88ac42d13e8e3b2ac480e2b85b243")
        #expect(forSite.sig.count == 130 && forSite.key != accountKey)
        let bip39 = try Sphinxrs.mnemonicToBip39Seed(mnemonic: abandon.joined(separator: " "))
        // The Sphinx seed is its first half: the engine makes one from the other.
        let seedHeld = await engine.seed
        #expect(seedHeld == (try Engine.seed(of: abandon.joined(separator: " "))))
        #expect(forSite.sig == (try Sphinxrs.signBytesLud05(bip39Seed: bip39, domain: "site.com", msg: Data(site.utf8)).sig))
    }

    // MARK: Helpers

    func host(_ wallet: ScriptedWallet) throws -> WalletHost {
        WalletHost(storage: storage, wallet: wallet, now: { Self.now }, nowMs: { Self.now * 1000 }, sheetTimeout: .seconds(60))
    }

    func caller(_ person: ScriptedPerson, acted: Bool = true, scope: WalletScope = origin) -> WalletCaller {
        WalletCaller(scope: scope, place: "shop.example.com", personActed: acted, person: person)
    }

    /// A connection that already signs in with `key`.
    func keep(_ key: SignInKey, scope: WalletScope) throws {
        try storage.saveWalletConnection(WalletConnection(
            key: scope.key, app: "/moon-game", title: "Moon Game", place: "shop.example.com", methods: [],
            notificationTypes: [], maxAmountMsat: nil, renewal: .never, expiresAt: nil, overBudget: .ask,
            createdAt: Self.now - 10, signIn: key
        ))
    }

    /// A challenge as strut makes one (its HMAC is the seller's to check;
    /// Peel never reads it).
    func challengeText(_ host: String, key: String = "root", exp: Int64 = now * 1000 + 60_000) -> String? {
        let claims = #"{"host":"\#(host)","visitorKey":"\#(key)","nonce":"6f0c3a9d","exp":\#(exp)}"#
        return "strut-visitor.\(MediaToken.base64URLEncode(Data(claims.utf8)).replacingOccurrences(of: "=", with: "")).c2ln"
    }

    func challenge(_ host: String, key: String = "root", exp: Int64 = now * 1000 + 60_000) -> JSONValue {
        .string(challengeText(host, key: key, exp: exp) ?? "")
    }

    func signIn(_ challenge: JSONValue, seller: String = "https://shop.example.com") -> JSONValue {
        .object([
            "v": .int(1), "op": .string("sign_in"), "seller": .string(seller), "challenge": challenge,
            "app": .object(["name": .string("moon-game"), "version": .string("v3"), "title": .string("Moon Game")]),
        ])
    }

    func code(_ reply: JSONValue) -> String? {
        reply.objectValue["error"]?.objectValue["data"]?.objectValue["code"]?.string
    }
}
