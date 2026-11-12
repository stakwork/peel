import CryptoKit
import Foundation

/// The wallet contract an app's page and its host speak (strut's
/// specs/WALLET.md, its types and checks in `kit/src/wallet/protocol.ts`):
/// NWC's methods, params, results and errors, with strut's additions (route
/// hints on keysend, a `state` on every payment, `payment_failed`,
/// `USER_REJECTED`, `connect`). This is a port of the checks, run on what
/// strut's UI relays from the page, and tested against strut's
/// `vectors.json` (docs/app-wallet.md). Where it and strut's module
/// disagree, strut's wins and this is a bug.
///
/// Params, results and notifications stay `JSONValue`: what crosses the
/// web view is JSON, and the checks answer the params normalized as strut's
/// do, so the vectors compare whole.
public enum WalletMethod: String, Sendable, CaseIterable, Codable {
    case connect, getInfo = "get_info", payInvoice = "pay_invoice", payKeysend = "pay_keysend",
         makeInvoice = "make_invoice", lookupPayment = "lookup_payment", lookupInvoice = "lookup_invoice",
         getBudget = "get_budget", getBalance = "get_balance", listTransactions = "list_transactions",
         payLightningAddress = "pay_lightning_address"

    /// What a connection request may name: everything but `connect` and `get_info`.
    public var isRequestable: Bool { self != .connect && self != .getInfo }
    /// The methods that move money out, which a budget counts.
    public var pays: Bool { [.payInvoice, .payKeysend, .payLightningAddress].contains(self) }
}

public enum WalletNotificationType: String, Sendable, CaseIterable, Codable {
    case paymentReceived = "payment_received", paymentSent = "payment_sent", paymentFailed = "payment_failed"
}

public enum WalletRenewal: String, Sendable, CaseIterable, Codable {
    case never, daily, weekly, monthly, yearly
}

/// NWC's codes and strut's `USER_REJECTED`.
public enum WalletErrorCode: String, Sendable, CaseIterable, Codable {
    case userRejected = "USER_REJECTED", badRequest = "BAD_REQUEST", paymentFailed = "PAYMENT_FAILED",
         insufficientBalance = "INSUFFICIENT_BALANCE", quotaExceeded = "QUOTA_EXCEEDED", restricted = "RESTRICTED",
         unauthorized = "UNAUTHORIZED", notImplemented = "NOT_IMPLEMENTED", rateLimited = "RATE_LIMITED",
         notFound = "NOT_FOUND", `internal` = "INTERNAL", other = "OTHER"
}

/// A refusal: the wallet's code and the person's words. As a JSON-RPC error
/// (`body`): `BAD_REQUEST` is Invalid params (-32602), every other code the
/// server-error code (-32000), the code in `data.code`.
public struct WalletError: Error, Sendable, Equatable {
    public let code: WalletErrorCode
    public let message: String

    public init(_ code: WalletErrorCode, _ message: String) {
        self.code = code
        self.message = message
    }

    public var body: JSONValue {
        .object([
            "code": .int(code == .badRequest ? -32602 : -32000),
            "message": .string(message),
            "data": .object(["code": .string(code.rawValue)]),
        ])
    }
}

public enum WalletProtocol {
    public static let version = 1
    /// BOLT 1: custom records are 2^16 and up; 5482373484 is keysend's preimage.
    public static let minCustomTLVType: Int64 = 65536
    public static let keysendPreimageTLVType: Int64 = 5_482_373_484
    /// Sphinx's own record (the core's `SPHINX_TLV_KEY`): its `data`, as base64 text.
    public static let sphinxTLVType: Int64 = 13_377_331
    public static let metadataMaxChars = 4096
    public static let listLimitMax: Int64 = 100
    /// JavaScript's `Number.MAX_SAFE_INTEGER`: what a page's number holds exactly.
    static let maxSafeInteger: Int64 = 9_007_199_254_740_991

    // MARK: Checking params

    /// Checks a request's params as every side must: the params as the
    /// method takes them, normalized (hex and invoices lower case, a
    /// `lightning:` prefix dropped, a Sphinx address split, unknown keys
    /// dropped), or a `BAD_REQUEST`. A port of strut's `checkParams`.
    public static func checkParams(_ method: WalletMethod, _ params: JSONValue?) -> Result<JSONValue, WalletError> {
        do {
            return .success(try check(method, params))
        } catch let bad as Bad {
            return .failure(WalletError(.badRequest, bad.message))
        } catch {
            return .failure(WalletError(.badRequest, "\(error)"))
        }
    }

    struct Bad: Error {
        let message: String
    }

    private static func fail(_ message: String) -> Bad { Bad(message: message) }

    private static func obj(_ value: JSONValue?, _ what: String) throws -> [String: JSONValue] {
        switch value {
        case nil, .null?: return [:]
        case .object(let object)?: return object
        default: throw fail("\(what) must be an object")
        }
    }

    /// A whole number in JavaScript's safe range, from either JSON shape.
    static func integer(_ value: JSONValue?) -> Int64? {
        switch value {
        case .int(let n)?: return abs(n) <= maxSafeInteger ? n : nil
        case .double(let d)?:
            guard d.rounded() == d, abs(d) <= Double(maxSafeInteger) else { return nil }
            return Int64(d)
        default: return nil
        }
    }

    private static func amount(_ value: JSONValue?, _ what: String = "amount") throws -> Int64 {
        guard let n = integer(value), n > 0 else { throw fail("\(what) must be a whole number of msat above 0") }
        return n
    }

    private static func count(_ value: JSONValue?, _ what: String) throws -> Int64 {
        guard let n = integer(value), n >= 0 else { throw fail("\(what) must be a whole number, 0 or more") }
        return n
    }

    static func isHex(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }

    static func isPubkey(_ text: String) -> Bool {
        text.count == 66 && (text.hasPrefix("02") || text.hasPrefix("03")) && isHex(text)
    }

    static func isHash(_ text: String) -> Bool { text.count == 64 && isHex(text) }

    private static func isDigits(_ text: Substring) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy { ("0"..."9").contains($0) }
    }

    /// A decimal u64, or `<block>x<tx>x<output>`.
    static func isSCID(_ text: String) -> Bool {
        if isDigits(text[...]) { return true }
        let parts = text.split(separator: "x", omittingEmptySubsequences: false)
        return parts.count == 3 && parts.allSatisfy(isDigits)
    }

    private enum HexShape { case any, pubkey, hash }

    private static func hex(_ value: JSONValue?, _ what: String, _ shape: HexShape = .any) throws -> String {
        guard case .string(let raw)? = value else { throw fail("\(what) must be a hex string") }
        let h = raw.lowercased()
        let ok: Bool
        switch shape {
        case .any: ok = isHex(h)
        case .pubkey: ok = isPubkey(h)
        case .hash: ok = isHash(h)
        }
        guard ok, h.count % 2 == 0 else { throw fail("\(what) is not valid hex of the right length") }
        return h
    }

    /// A string at most `max` long, counted as JavaScript counts (UTF-16).
    private static func text(_ value: JSONValue?, _ what: String, _ max: Int) throws -> String {
        guard case .string(let s)? = value else { throw fail("\(what) must be a string") }
        guard s.utf16.count <= max else { throw fail("\(what) is longer than \(max) characters") }
        return s
    }

    /// JavaScript's `trim()`.
    static func trim(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// BOLT 11 as bech32: `ln`, a network, an optional amount, `1`, the data.
    /// Shape only; a host decodes it. Answers the invoice normalized and
    /// whether its prefix names an amount.
    static func parsedInvoice(_ value: JSONValue?) throws -> (invoice: String, namesAmount: Bool) {
        guard case .string(let raw)? = value else { throw fail("invoice must be a BOLT11 string") }
        var s = trim(raw).lowercased()
        if s.hasPrefix("lightning:") { s.removeFirst("lightning:".count) }
        guard let match = s.wholeMatch(of: invoicePattern) else { throw fail("invoice is not a BOLT11 invoice") }
        return (s, match.output.2 != nil)
    }

    /// Whether `text` is BOLT 11's shape exactly as it stands (not trimmed
    /// or lowered), and if so whether its prefix names an amount; nil when
    /// it is not.
    static func invoiceNamesAmount(_ text: String) -> Bool? {
        text.wholeMatch(of: invoicePattern).map { $0.output.2 != nil }
    }

    // `[0-9]` rather than `\d`: JavaScript's `\d` is ASCII only.
    nonisolated(unsafe) private static let invoicePattern =
        #/ln(bcrt|bc|tbs|tb|sb)([0-9]+[munp]?)?1[qpzry9x8gf2tvdw0s3jn54khce6mua7l]{20,}/#
    nonisolated(unsafe) private static let lightningAddressPattern =
        #/[a-z0-9._+-]+@[a-z0-9-]+(\.[a-z0-9-]+)*\.[a-z]{2,}/#
    nonisolated(unsafe) private static let lnurlPattern =
        #/(lnurl1[qpzry9x8gf2tvdw0s3jn54khce6mua7l]{10,}|lnurlp:\/\/\S+)/#

    /// The JSON text's length as JavaScript's `JSON.stringify(m).length` counts it.
    private static func jsonLength(_ value: JSONValue) -> Int {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return .max }
        return String(decoding: data, as: UTF8.self).utf16.count
    }

    private static func metadata(_ value: JSONValue?) throws -> JSONValue? {
        guard let value else { return nil }
        let m = try obj(value, "metadata")
        guard jsonLength(.object(m)) <= metadataMaxChars else {
            throw fail("metadata is longer than \(metadataMaxChars) characters as JSON")
        }
        return .object(m)
    }

    /// Exactly one of `keys` is present (a JSON null counts as present, as
    /// `!== undefined` does).
    private static func exactlyOne(_ p: [String: JSONValue], _ keys: [String]) throws -> String {
        let present = keys.filter { p[$0] != nil }
        guard present.count == 1 else { throw fail("give exactly one of \(keys.joined(separator: ", "))") }
        return present[0]
    }

    private static func routeHints(_ value: JSONValue?) throws -> JSONValue {
        guard case .array(let routes)? = value, !routes.isEmpty else {
            throw fail("route_hints must be a non-empty list of routes")
        }
        return .array(try routes.enumerated().map { i, route in
            guard case .array(let hops) = route, !hops.isEmpty else {
                throw fail("route_hints[\(i)] must be a non-empty list of hops")
            }
            return .array(try hops.enumerated().map { j, h in
                let hop = try obj(h, "route_hints[\(i)][\(j)]")
                var out: [String: JSONValue] = [
                    "pubkey": .string(try hex(hop["pubkey"], "route_hints[\(i)][\(j)].pubkey", .pubkey)),
                ]
                guard case .string(let scid)? = hop["short_channel_id"], isSCID(scid) else {
                    throw fail("route_hints[\(i)][\(j)].short_channel_id must be a decimal u64 or <block>x<tx>x<output>")
                }
                out["short_channel_id"] = .string(scid)
                for key in ["fee_base_msat", "fee_proportional_millionths", "cltv_expiry_delta"] where hop[key] != nil {
                    out[key] = .int(try count(hop[key], "route_hints[\(i)][\(j)].\(key)"))
                }
                return .object(out)
            })
        })
    }

    private static func tlvRecords(_ value: JSONValue?) throws -> JSONValue {
        guard case .array(let records)? = value else { throw fail("tlv_records must be a list") }
        var seen: Set<Int64> = []
        return .array(try records.enumerated().map { i, r in
            let record = try obj(r, "tlv_records[\(i)]")
            guard let type = integer(record["type"]), type >= minCustomTLVType else {
                throw fail("tlv_records[\(i)].type must be a whole number of \(minCustomTLVType) or more")
            }
            guard type != keysendPreimageTLVType else {
                throw fail("tlv_records[\(i)]: \(keysendPreimageTLVType) is keysend's preimage, which the wallet sets")
            }
            guard seen.insert(type).inserted else { throw fail("tlv_records[\(i)]: type \(type) is given twice") }
            return .object(["type": .int(type), "value": .string(try hex(record["value"], "tlv_records[\(i)].value"))])
        })
    }

    private static func check(_ method: WalletMethod, _ raw: JSONValue?) throws -> JSONValue {
        let p = try obj(raw, "params")
        switch method {
        case .connect, .getInfo, .getBudget, .getBalance:
            return .object([:])
        case .payInvoice:
            let invoice = try parsedInvoice(p["invoice"])
            var out: [String: JSONValue] = ["invoice": .string(invoice.invoice)]
            if p["amount"] != nil {
                out["amount"] = .int(try amount(p["amount"]))
                if invoice.namesAmount {
                    throw fail("the invoice names its own amount: amount is only for an invoice that names none")
                }
            } else if !invoice.namesAmount {
                throw fail("the invoice names no amount: give amount")
            }
            if let m = try metadata(p["metadata"]) { out["metadata"] = m }
            return .object(out)
        case .payKeysend:
            guard case .string(let target)? = p["pubkey"] else {
                throw fail("pubkey must be a node pubkey or a Sphinx address")
            }
            var out: [String: JSONValue]
            if let address = SphinxAddress(target) {
                guard p["route_hints"] == nil else {
                    throw fail("a Sphinx address carries its route hint: give route_hints or the address, not both")
                }
                out = ["pubkey": .string(address.pubkey), "amount": .int(try amount(p["amount"])), "route_hints": address.routeHints]
            } else {
                out = ["pubkey": .string(try hex(p["pubkey"], "pubkey", .pubkey)), "amount": .int(try amount(p["amount"]))]
                if p["route_hints"] != nil { out["route_hints"] = try routeHints(p["route_hints"]) }
            }
            if p["tlv_records"] != nil { out["tlv_records"] = try tlvRecords(p["tlv_records"]) }
            if p["preimage"] != nil { out["preimage"] = .string(try hex(p["preimage"], "preimage", .hash)) }
            if let m = try metadata(p["metadata"]) { out["metadata"] = m }
            return .object(out)
        case .makeInvoice:
            var out: [String: JSONValue] = ["amount": .int(try amount(p["amount"]))]
            if p["description"] != nil { out["description"] = .string(try text(p["description"], "description", 639)) }
            if p["description_hash"] != nil {
                out["description_hash"] = .string(try hex(p["description_hash"], "description_hash", .hash))
            }
            if p["expiry"] != nil {
                let expiry = try count(p["expiry"], "expiry")
                guard expiry != 0 else { throw fail("expiry must be above 0 seconds") }
                out["expiry"] = .int(expiry)
            }
            if let m = try metadata(p["metadata"]) { out["metadata"] = m }
            return .object(out)
        case .lookupPayment:
            switch try exactlyOne(p, ["transaction_id", "payment_hash", "invoice"]) {
            case "transaction_id":
                let id = try text(p["transaction_id"], "transaction_id", 256)
                guard !id.isEmpty else { throw fail("transaction_id is empty") }
                return .object(["transaction_id": .string(id)])
            case "payment_hash":
                return .object(["payment_hash": .string(try hex(p["payment_hash"], "payment_hash", .hash))])
            default:
                return .object(["invoice": .string(try parsedInvoice(p["invoice"]).invoice)])
            }
        case .lookupInvoice:
            if try exactlyOne(p, ["payment_hash", "invoice"]) == "payment_hash" {
                return .object(["payment_hash": .string(try hex(p["payment_hash"], "payment_hash", .hash))])
            }
            return .object(["invoice": .string(try parsedInvoice(p["invoice"]).invoice)])
        case .listTransactions:
            var out: [String: JSONValue] = [:]
            var from: Int64?, until: Int64?
            if p["from"] != nil { from = try count(p["from"], "from"); out["from"] = .int(from!) }
            if p["until"] != nil { until = try count(p["until"], "until"); out["until"] = .int(until!) }
            if let from, let until, from > until { throw fail("from is after until") }
            if p["limit"] != nil {
                let limit = try count(p["limit"], "limit")
                guard limit >= 1, limit <= listLimitMax else { throw fail("limit must be 1 to \(listLimitMax)") }
                out["limit"] = .int(limit)
            }
            if p["offset"] != nil { out["offset"] = .int(try count(p["offset"], "offset")) }
            if let unpaid = p["unpaid"] {
                guard case .bool(let flag) = unpaid else { throw fail("unpaid must be true or false") }
                out["unpaid"] = .bool(flag)
            }
            if let type = p["type"] {
                guard type == .string("incoming") || type == .string("outgoing") else {
                    throw fail("type must be incoming or outgoing")
                }
                out["type"] = type
            }
            return .object(out)
        case .payLightningAddress:
            var out: [String: JSONValue]
            if try exactlyOne(p, ["address", "lnurl"]) == "address" {
                let address = trim(try text(p["address"], "address", 320)).lowercased()
                guard address.wholeMatch(of: lightningAddressPattern) != nil else {
                    throw fail("address is not a Lightning Address (name@domain)")
                }
                out = ["address": .string(address)]
            } else {
                let lnurl = trim(try text(p["lnurl"], "lnurl", 2048))
                let norm = lnurl.lowercased().hasPrefix("lnurl1") ? lnurl.lowercased() : lnurl
                guard norm.wholeMatch(of: lnurlPattern) != nil else {
                    throw fail("lnurl is not an LNURL (lnurl1… or lnurlp://…)")
                }
                out = ["lnurl": .string(norm)]
            }
            out["amount"] = .int(try amount(p["amount"]))
            if p["comment"] != nil { out["comment"] = .string(try text(p["comment"], "comment", 2000)) }
            if p["payer_data"] != nil { out["payer_data"] = .object(try obj(p["payer_data"], "payer_data")) }
            if let m = try metadata(p["metadata"]) { out["metadata"] = m }
            return .object(out)
        }
    }

    // MARK: Connection requests

    /// What is wrong with an `app.yaml` `wallet:` block, one line each;
    /// none when it is good. A port of strut's `connectionRequestProblems`.
    public static func connectionRequestProblems(_ raw: JSONValue?) -> [String] {
        guard case .object(let r)? = raw else { return ["wallet must be a mapping"] }
        var problems: [String] = []
        let requestable = WalletMethod.allCases.filter(\.isRequestable).map(\.rawValue)
        func methods(_ key: String, required: Bool) {
            guard let value = r[key] else {
                if required { problems.append("\(key) is required: the methods the app cannot work without") }
                return
            }
            guard case .array(let list) = value else {
                problems.append("\(key) must be a list of methods")
                return
            }
            for m in list where !(m.string.map(requestable.contains) ?? false) {
                problems.append("\(key): \"\(m.string ?? "\(m)")\" is not a method an app may request")
            }
        }
        methods("request_methods", required: true)
        methods("optional_request_methods", required: false)
        if let nt = r["notification_types"] {
            if case .array(let list) = nt {
                for n in list where WalletNotificationType(rawValue: n.string ?? "") == nil {
                    problems.append("notification_types: \"\(n.string ?? "\(n)")\" is not a notification type")
                }
            } else {
                problems.append("notification_types must be a list")
            }
        }
        if let max = r["max_amount"], !(integer(max).map { $0 > 0 } ?? false) {
            problems.append("max_amount must be a whole number of msat above 0")
        }
        if let period = r["renewal_period"] {
            if WalletRenewal(rawValue: period.string ?? "") == nil {
                problems.append("renewal_period must be one of \(WalletRenewal.allCases.map(\.rawValue).joined(separator: ", "))")
            } else if r["max_amount"] == nil {
                problems.append("renewal_period needs max_amount")
            }
        }
        if let expires = r["expires_at"], expires != .null, !(integer(expires).map { $0 > 0 } ?? false) {
            problems.append("expires_at must be unix seconds, or null")
        }
        let known: Set = [
            "request_methods", "optional_request_methods", "notification_types", "max_amount", "renewal_period", "expires_at",
        ]
        for key in r.keys.sorted() where !known.contains(key) { problems.append("\(key) is not a connection request field") }
        return problems
    }

    // MARK: Checking results and notifications

    private static func isInt(_ v: JSONValue?, min: Int64 = 0) -> Bool { integer(v).map { $0 >= min } ?? false }
    private static func isHashValue(_ v: JSONValue?) -> Bool { v?.string.map(isHash) ?? false }
    private static func oneOf(_ v: JSONValue?, _ list: [String]) -> Bool { v?.string.map(list.contains) ?? false }

    private static func paymentProblems(_ p: [String: JSONValue]) -> [String] {
        var out: [String] = []
        if (p["transaction_id"]?.string ?? "").isEmpty { out.append("transaction_id is missing") }
        if !oneOf(p["state"], ["pending", "settled", "failed"]) { out.append("state must be pending, settled or failed") }
        if !isHashValue(p["payment_hash"]) { out.append("payment_hash must be 64 hex") }
        if !isInt(p["amount"]) { out.append("amount must be msat") }
        if p["fees_paid"] != nil, !isInt(p["fees_paid"]) { out.append("fees_paid must be msat") }
        if !isInt(p["created_at"]) { out.append("created_at must be unix seconds") }
        if p["state"] == .string("settled") {
            if !isHashValue(p["preimage"]) { out.append("a settled payment carries its preimage") }
            if !isInt(p["settled_at"]) { out.append("a settled payment carries settled_at") }
        } else if p["preimage"] != nil {
            out.append("preimage only once settled")
        }
        if p["state"] != .string("failed"), p["failure_reason"] != nil { out.append("failure_reason only on a failed payment") }
        return out
    }

    private static func transactionProblems(_ t: [String: JSONValue], _ at: String = "") -> [String] {
        var out: [String] = []
        if !oneOf(t["type"], ["incoming", "outgoing"]) { out.append(at + "type must be incoming or outgoing") }
        if let state = t["state"], !oneOf(state, ["pending", "settled", "accepted", "expired", "failed"]) {
            out.append(at + "state is not a transaction state")
        }
        if !isHashValue(t["payment_hash"]) { out.append(at + "payment_hash must be 64 hex") }
        if !isInt(t["amount"]) { out.append(at + "amount must be msat") }
        if !isInt(t["created_at"]) { out.append(at + "created_at must be unix seconds") }
        if t["preimage"] != nil, let state = t["state"], state != .string("settled") { out.append(at + "preimage only once settled") }
        return out
    }

    /// What is wrong with a host's answer to `method`; none when it is the
    /// shape the contract promises. A port of strut's `resultProblems`.
    public static func resultProblems(_ method: WalletMethod, _ raw: JSONValue) -> [String] {
        guard case .object(let r) = raw else { return ["the result must be an object"] }
        switch method {
        case .payInvoice, .payKeysend, .payLightningAddress:
            return paymentProblems(r)
        case .makeInvoice:
            var out = transactionProblems(r)
            if r["type"] != .string("incoming") { out.append("an invoice made is incoming") }
            if r["invoice"]?.string == nil { out.append("invoice is missing") }
            return out
        case .lookupInvoice:
            return transactionProblems(r)
        case .listTransactions:
            guard case .array(let list)? = r["transactions"] else { return ["transactions must be a list"] }
            return list.enumerated().flatMap { i, t in
                guard case .object(let o) = t else { return ["transactions[\(i)]: must be an object"] }
                return transactionProblems(o, "transactions[\(i)]: ")
            }
        case .lookupPayment:
            var out: [String] = []
            if (r["transaction_id"]?.string ?? "").isEmpty { out.append("transaction_id is missing") }
            if !oneOf(r["type"], ["incoming", "outgoing"]) { out.append("type must be incoming or outgoing") }
            if !oneOf(r["state"], ["pending", "accepted", "settled", "failed", "expired", "canceled"]) {
                out.append("state is not a lookup state")
            }
            if !oneOf(r["payment_type"], ["bolt11", "keysend"]) { out.append("payment_type must be bolt11 or keysend") }
            if !isInt(r["amount"]) { out.append("amount must be msat") }
            if !isInt(r["created_at"]) { out.append("created_at must be unix seconds") }
            if case .object(let d)? = r["details"] {
                if !isHashValue(d["payment_hash"]) { out.append("details.payment_hash must be 64 hex") }
                if r["payment_type"] == .string("keysend"), !(d["pubkey"]?.string.map(isPubkey) ?? false) {
                    out.append("a keysend's details carry its pubkey")
                }
                if d["preimage"] != nil, r["state"] != .string("settled") { out.append("preimage only once settled") }
            } else {
                out.append("details is missing")
            }
            return out
        case .getInfo:
            var out: [String] = []
            if !oneOf(r["network"], ["bitcoin", "testnet", "signet", "regtest"]) { out.append("network is not a network") }
            if !isList(r["methods"], of: WalletMethod.allCases.map(\.rawValue)) { out.append("methods must be wallet methods") }
            if !isList(r["notifications"], of: WalletNotificationType.allCases.map(\.rawValue)) {
                out.append("notifications must be notification types")
            }
            return out
        case .getBudget:
            if r.isEmpty { return [] }
            var out: [String] = []
            if !isInt(r["used_budget"]) { out.append("used_budget must be msat") }
            if !isInt(r["total_budget"]) { out.append("total_budget must be msat") }
            if !oneOf(r["renewal_period"], WalletRenewal.allCases.map(\.rawValue)) {
                out.append("renewal_period is not a renewal period")
            }
            return out
        case .getBalance:
            return isInt(r["balance"]) ? [] : ["balance must be msat"]
        case .connect:
            guard case .object(let c)? = r["connection"] else { return ["connection is missing"] }
            var out: [String] = []
            if !isList(c["methods"], of: WalletMethod.allCases.filter(\.isRequestable).map(\.rawValue)) {
                out.append("connection.methods must be requestable methods")
            }
            if !isList(c["notification_types"], of: WalletNotificationType.allCases.map(\.rawValue)) {
                out.append("connection.notification_types must be notification types")
            }
            return out
        }
    }

    private static func isList(_ v: JSONValue?, of names: [String]) -> Bool {
        guard case .array(let list)? = v else { return false }
        return list.allSatisfy { oneOf($0, names) }
    }

    /// What is wrong with a notification; none when it is good. A port of
    /// strut's `notificationProblems`.
    public static func notificationProblems(_ raw: JSONValue) -> [String] {
        guard case .object(let n) = raw else { return ["a notification must be an object"] }
        guard let type = WalletNotificationType(rawValue: n["notification_type"]?.string ?? "") else {
            return ["notification_type is not a notification type"]
        }
        guard case .object(let t)? = n["notification"] else { return ["notification is missing"] }
        var out = transactionProblems(t)
        if (t["transaction_id"]?.string ?? "").isEmpty { out.append("transaction_id is missing") }
        let expected = type == .paymentReceived ? "incoming" : "outgoing"
        if t["type"] != .string(expected) { out.append("\(type.rawValue) carries an \(expected) transaction") }
        if type == .paymentFailed, t["state"] != .string("failed") { out.append("payment_failed carries state failed") }
        if type != .paymentFailed, let state = t["state"], state != .string("settled") {
            out.append("\(type.rawValue) carries a settled transaction")
        }
        return out
    }

    // MARK: Preimages

    /// Whether `sha256(preimage) == paymentHash`, both 64 hex: proof a
    /// payment went. Peel keeps and hands on only a preimage that passes.
    public static func verifyPreimage(_ preimage: String, paymentHash: String) -> Bool {
        let p = preimage.lowercased(), h = paymentHash.lowercased()
        guard isHash(p), isHash(h), let bytes = Data(hexString: p) else { return false }
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() == h
    }
}

/// A Sphinx address, `<pubkey>_<lsp_pubkey>_<scid>`, as a pubkey and its
/// one-hop route hint (the core's `parse_route_hint`: the hint is what
/// follows the first `_`). A port of strut's `parseSphinxAddress`.
public struct SphinxAddress: Sendable, Equatable {
    public let pubkey: String
    public let lsp: String
    public let scid: String

    public init?(_ text: String) {
        let parts = WalletProtocol.trim(text).lowercased().split(separator: "_", omittingEmptySubsequences: false)
        guard parts.count == 3, WalletProtocol.isPubkey(String(parts[0])), WalletProtocol.isPubkey(String(parts[1])),
              !parts[2].isEmpty, parts[2].unicodeScalars.allSatisfy({ ("0"..."9").contains($0) }) else { return nil }
        pubkey = String(parts[0])
        lsp = String(parts[1])
        scid = String(parts[2])
    }

    /// `[[{ pubkey, short_channel_id }]]`, BOLT 11's `r` with one hop.
    public var routeHints: JSONValue {
        .array([.array([.object(["pubkey": .string(lsp), "short_channel_id": .string(scid)])])])
    }

    /// One hop back to the core's route hint, `<lsp_pubkey>_<scid>`, the form
    /// it pays the asynchronous way; nil when the scid is not a decimal u64
    /// (strut's `sphinxRouteHint`).
    public static func routeHint(pubkey: String, shortChannelID: String) -> String? {
        guard !shortChannelID.isEmpty, shortChannelID.unicodeScalars.allSatisfy({ ("0"..."9").contains($0) }),
              UInt64(shortChannelID) != nil else { return nil }
        return "\(pubkey)_\(shortChannelID)"
    }
}

extension Data {
    /// Lower- or upper-case hex, an even number of digits; nil otherwise.
    init?(hexString: String) {
        guard hexString.count % 2 == 0 else { return nil }
        var data = Data(capacity: hexString.count / 2)
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let next = hexString.index(index, offsetBy: 2)
            guard let byte = UInt8(hexString[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        self = data
    }
}
