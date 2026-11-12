import Foundation

/// A purchase of CREDIT on a strut server for a visitor's page (strut's
/// specs/WALLET.md §1.2, `CreditPurchase`): what strut's UI asks the native
/// host to pay, one tap, so that a priced launch in a public app runs. The
/// host's own purchase, never an app's call: no connection carries it, no
/// budget counts it, and every purchase asks. Peel decodes the invoice
/// itself; everything else here is the seller's word.
public struct CreditPurchase: Sendable, Equatable {
    /// BOLT 11, lower case, naming its amount.
    public var invoice: String
    public var paymentHash: String
    /// msat: the price, `sats × 1000`.
    public var amountMsat: Int64
    /// The credit the seller says the payment buys, in dollars: its own
    /// figure, never the price.
    public var usd: Double
    /// The seller's words for what it sells.
    public var description: String
    /// Unix seconds, as the page says; the sheet holds the decoded end.
    public var expiresAt: Int64
    /// The strut server the credit is bought on, as the page names it.
    public var seller: String
    /// The public app whose page asked, as the seller serves it.
    public var app: SignInRequest.App
    /// The workflow the launch is for.
    public var workflow: String

    /// A purchase strut's checks pass; nil for anything else.
    public init?(_ raw: JSONValue?) {
        guard let raw, Self.problems(raw).isEmpty, case .object(let p) = raw, case .object(let app)? = p["app"],
              let invoice = p["invoice"]?.string, let hash = p["payment_hash"]?.string,
              let amount = WalletProtocol.integer(p["amount"]), let usd = Self.number(p["usd"]),
              let description = p["description"]?.string, let expires = WalletProtocol.integer(p["expires_at"]),
              let seller = p["seller"]?.string, let name = app["name"]?.string, let version = app["version"]?.string,
              let title = app["title"]?.string, let workflow = p["workflow"]?.string else { return nil }
        self.invoice = invoice
        paymentHash = hash
        amountMsat = amount
        self.usd = usd
        self.description = description
        expiresAt = expires
        self.seller = seller
        self.app = SignInRequest.App(name: name, version: version, title: title)
        self.workflow = workflow
    }

    /// The longest description, title or name a purchase carries (strut's
    /// `CREDIT_TEXT_MAX`).
    static let textMax = SignInRequest.textMax

    /// What is wrong with a purchase; none when it is good. Shapes and the
    /// arithmetic between them, a port of strut's `creditPurchaseProblems`
    /// (its vectors' `credit_purchases` hold it); the host still decodes the
    /// invoice and holds it to `amount`, `payment_hash` and its end.
    public static func problems(_ raw: JSONValue) -> [String] {
        guard case .object(let p) = raw else { return ["a purchase must be an object"] }
        var out: [String] = []
        func text(_ value: JSONValue?, _ what: String) {
            guard let text = value?.string, !text.isEmpty else { return out.append("\(what) must be a string") }
            if text.utf16.count > textMax { out.append("\(what) is longer than \(textMax) characters") }
        }
        func whole(_ value: JSONValue?, from min: Int64) -> Int64? { WalletProtocol.integer(value).flatMap { $0 >= min ? $0 : nil } }
        func dollars(_ value: JSONValue?) -> Bool { number(value).map { $0 >= 0 } ?? false }

        if let invoice = p["invoice"]?.string, invoice == invoice.lowercased(),
           let namesAmount = WalletProtocol.invoiceNamesAmount(invoice) {
            if !namesAmount { out.append("invoice must name its amount") }
        } else {
            out.append("invoice must be a BOLT11 invoice, lower case")
        }
        if !(p["payment_hash"]?.string.map(WalletProtocol.isHash) ?? false) { out.append("payment_hash must be 64 hex") }
        let sats = whole(p["sats"], from: 1)
        if sats == nil { out.append("sats must be a whole number above 0") }
        if let amount = whole(p["amount"], from: 1) {
            if let sats, sats.multipliedReportingOverflow(by: 1000) != (amount, false) { out.append("amount must be sats × 1000") }
        } else {
            out.append("amount must be msat above 0")
        }
        if !dollars(p["usd"]) { out.append("usd must be a number of dollars, 0 or more") }
        if let rate = p["rate"] {
            let r = rate.objectValue
            if !(number(r["usd_per_btc"]).map { $0 > 0 } ?? false) || r["at"]?.string == nil || r["source"]?.string == nil {
                out.append("rate must be { usd_per_btc, at, source }")
            }
        }
        text(p["description"], "description")
        if whole(p["expires_at"], from: 1) == nil { out.append("expires_at must be unix seconds") }
        if !(p["seller"]?.string.map(Seller.isSellerURL) ?? false) {
            out.append("seller must be a strut server's base URL: https, or http on loopback, with no credentials, query or fragment")
        }
        if case .object(let app)? = p["app"] {
            text(app["name"], "app.name")
            text(app["version"], "app.version")
            text(app["title"], "app.title")
        } else {
            out.append("app is missing")
        }
        text(p["workflow"], "workflow")
        if case .object(let credit)? = p["credit"] {
            if case .bool = credit["carries"] {} else { out.append("credit.carries must be true or false") }
            if let reason = credit["reason"], !["short", "expired", "replaced"].contains(reason.string ?? "") {
                out.append("credit.reason must be short, expired or replaced")
            }
            if let left = credit["remaining_usd"], !dollars(left) {
                out.append("credit.remaining_usd must be a number of dollars, 0 or more")
            }
        } else {
            out.append("credit is missing")
        }
        return out
    }

    /// A finite JSON number, either shape.
    static func number(_ value: JSONValue?) -> Double? {
        switch value {
        case .int(let n)?: Double(n)
        case .double(let d)? where d.isFinite: d
        default: nil
        }
    }
}
