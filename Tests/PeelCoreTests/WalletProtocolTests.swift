import Foundation
import Testing
@testable import PeelCore

/// strut's wallet conformance vectors (`kit/src/wallet/vectors.json`, its
/// specs/WALLET.md §7), copied into `WalletVectors/` from the strut commit
/// docs/app-wallet.md names. Every list must pass whole.
enum WalletVectors {
    static let all: [String: JSONValue] = {
        guard let url = Bundle.module.url(forResource: "vectors", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              case .object(let object)? = try? JSONDecoder().decode(JSONValue.self, from: data) else { return [:] }
        return object
    }()

    static func list(_ name: String) -> [[String: JSONValue]] {
        guard case .array(let items)? = all[name] else { return [] }
        return items.compactMap { $0.objectValue.isEmpty ? nil : $0.objectValue }
    }

    static func name(_ entry: [String: JSONValue]) -> String { entry["name"]?.string ?? "?" }
}

/// Two JSON values alike, numbers by value (`5` and `5.0` the same).
func sameJSON(_ a: JSONValue?, _ b: JSONValue?) -> Bool {
    switch (a, b) {
    case (nil, nil): return true
    case (.object(let x)?, .object(let y)?):
        return x.keys.sorted() == y.keys.sorted() && x.allSatisfy { sameJSON($0.value, y[$0.key]) }
    case (.array(let x)?, .array(let y)?):
        return x.count == y.count && zip(x, y).allSatisfy { sameJSON($0, $1) }
    case (.int, _), (.double, _):
        guard let b, let x = WalletProtocol.integer(a), let y = WalletProtocol.integer(b) else { return a == b }
        return x == y
    default:
        return a == b
    }
}

func list(_ value: JSONValue?) -> [JSONValue] {
    if case .array(let items)? = value { return items }
    return []
}

func jsonText(_ value: JSONValue?) -> String {
    guard let value else { return "nil" }
    return (try? value.text) ?? "\(value)"
}

struct WalletProtocolTests {
    @Test func theVectorsAreThere() {
        #expect(WalletVectors.all["version"] == .int(1))
        #expect(WalletVectors.list("params").count == 31)
        #expect(WalletVectors.list("results").count == 14)
        #expect(WalletVectors.list("notifications").count == 5)
        #expect(WalletVectors.list("connection_requests").count == 6)
        #expect(WalletVectors.list("preimages").count == 4)
        #expect(WalletVectors.list("scenarios").count == 10)
    }

    @Test(arguments: WalletVectors.list("params").indices)
    func paramsAreCheckedAsStrutChecksThem(_ index: Int) throws {
        let entry = WalletVectors.list("params")[index]
        let method = try #require(entry["method"]?.string.flatMap(WalletMethod.init), "\(WalletVectors.name(entry))")
        let expect = entry["expect"]?.objectValue ?? [:]
        switch WalletProtocol.checkParams(method, entry["params"]) {
        case .success(let params):
            #expect(expect["error"] == nil, "\(WalletVectors.name(entry)): accepted \(jsonText(params))")
            #expect(sameJSON(params, expect["params"]),
                    "\(WalletVectors.name(entry)): \(jsonText(params)) is not \(jsonText(expect["params"]))")
        case .failure(let error):
            #expect(expect["error"] == .string("BAD_REQUEST"), "\(WalletVectors.name(entry)): refused, \(error.message)")
            #expect(error.code == .badRequest)
        }
    }

    @Test(arguments: WalletVectors.list("results").indices)
    func resultShapesAreJudgedAsStrutJudgesThem(_ index: Int) throws {
        let entry = WalletVectors.list("results")[index]
        let method = try #require(entry["method"]?.string.flatMap(WalletMethod.init))
        let problems = WalletProtocol.resultProblems(method, entry["result"] ?? .null)
        #expect(problems.isEmpty == (entry["valid"] == .bool(true)), "\(WalletVectors.name(entry)): \(problems)")
    }

    @Test(arguments: WalletVectors.list("notifications").indices)
    func notificationShapesAreJudgedAsStrutJudgesThem(_ index: Int) {
        let entry = WalletVectors.list("notifications")[index]
        let problems = WalletProtocol.notificationProblems(entry["notification"] ?? .null)
        #expect(problems.isEmpty == (entry["valid"] == .bool(true)), "\(WalletVectors.name(entry)): \(problems)")
    }

    @Test(arguments: WalletVectors.list("connection_requests").indices)
    func connectionRequestsAreJudgedAsStrutJudgesThem(_ index: Int) {
        let entry = WalletVectors.list("connection_requests")[index]
        let problems = WalletProtocol.connectionRequestProblems(entry["request"])
        #expect(problems.isEmpty == (entry["valid"] == .bool(true)), "\(WalletVectors.name(entry)): \(problems)")
        // A request the contract takes reads as one; one it refuses as none.
        #expect((WalletRequest(entry["request"]) != nil) == problems.isEmpty)
    }

    @Test(arguments: WalletVectors.list("preimages").indices)
    func preimagesProveTheirHash(_ index: Int) {
        let entry = WalletVectors.list("preimages")[index]
        let valid = WalletProtocol.verifyPreimage(entry["preimage"]?.string ?? "", paymentHash: entry["payment_hash"]?.string ?? "")
        #expect(valid == (entry["valid"] == .bool(true)))
    }

    @Test func aSphinxAddressSplitsIntoItsKeyAndHint() {
        let address = SphinxAddress(
            " 02AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA_03bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb_1099511627776 "
        )
        #expect(address?.pubkey == "02" + String(repeating: "a", count: 64))
        #expect(address?.lsp == "03" + String(repeating: "b", count: 64))
        #expect(address?.scid == "1099511627776")
        #expect(SphinxAddress("02aa_03bb_1") == nil)
        #expect(SphinxAddress.routeHint(pubkey: "03bb", shortChannelID: "12") == "03bb_12")
        #expect(SphinxAddress.routeHint(pubkey: "03bb", shortChannelID: "1x2x3") == nil)
    }

    /// Every error is a JSON-RPC error with the wallet code in `data.code`;
    /// `BAD_REQUEST` is Invalid params.
    @Test func errorsAreJSONRPCErrors() {
        #expect(WalletError(.badRequest, "no").body.objectValue["code"] == .int(-32602))
        let quota = WalletError(.quotaExceeded, "over").body.objectValue
        #expect(quota["code"] == .int(-32000))
        #expect(quota["data"]?.objectValue["code"] == .string("QUOTA_EXCEEDED"))
        #expect(quota["message"] == .string("over"))
    }
}
