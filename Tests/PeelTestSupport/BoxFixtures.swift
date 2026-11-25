import Foundation
@testable import PeelCore

/// A strut box as Peel's tests stand one in (strut's specs/API.md §13.6):
/// its link challenges and its answers, for the PeelCore and PeelUI tests.
enum BoxFixture {
    /// 2026-11-18, before every challenge here ends.
    static let now = Date(timeIntervalSince1970: 1_795_000_000)
    static let nowMs: Int64 = 1_795_000_000_000
    /// An end long after any test runs (2096), for tests on the real clock.
    static let later: Int64 = 4_000_000_000_000

    /// A challenge as strut's `linkChallenge` writes one: base64url JSON
    /// claims, then its HMAC (a stand-in: Peel never checks it).
    static func challenge(host: String, actor: String? = "ada-3f9a", name: String? = "Ada Lovelace",
                          exp: Int64 = nowMs + 600_000) -> String {
        var claims: [String: JSONValue] = ["host": .string(host), "nonce": .string("00112233445566778899aabbccddeeff"),
                                           "exp": .int(exp)]
        if let actor { claims["actor"] = .string(actor) }
        if let name { claims["name"] = .string(name) }
        // Keys in order: the same text every run, so a signature over it is a vector.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = try! encoder.encode(JSONValue.object(claims))
        let claimsPart = json.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return BoxChallenge.prefix + claimsPart + ".Xk2bYWJjZGVmZ2hpamtsbW5vcHFyc3R1dnd4eXo"
    }

    /// What strut answers a link or a renewal with. Its token ends a week from the real
    /// clock, which the tests that use it run on: a fixed date went stale.
    static func answer(actor: String = "ada-3f9a", name: String? = "Ada Lovelace", token: String = "strut-person.eyJ.abc",
                       exp: Int64 = Int64(Date().timeIntervalSince1970 * 1000) + 7 * 86_400_000) -> String {
        #"{"actor":"\#(actor)",\#(name.map { #""name":"\#($0)","# } ?? "")"token":"\#(token)","exp":\#(exp)}"#
    }

    /// A box kept as linked, its token named by its address.
    static func box(_ url: String, renewedAt: Date = now, exp: Date = now.addingTimeInterval(7 * 86_400)) -> BoxLink {
        BoxLink(url: URL(string: url)!, actor: "ada-3f9a", name: "Ada", token: "strut-person.secret-\(url.count)",
                exp: exp, linkedAt: renewedAt, renewedAt: renewedAt)
    }
}
