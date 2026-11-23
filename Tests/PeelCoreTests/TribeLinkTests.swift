import Foundation
import Testing
@testable import PeelCore

@Suite struct TribeLinkTests {
    let key = "02" + String(repeating: "ab", count: 32)

    @Test func writesAPeelLinkAndReadsItBack() throws {
        let text = TribeLink.text(pubkey: key, host: "tribes.example.com")
        #expect(text == "peel://tribe?pubkey=\(key)&host=tribes.example.com")
        let link = try #require(TribeLink(text))
        #expect(link.pubkey == key && link.host == "tribes.example.com")
        #expect(link.text == text)
        guard case .tribe(let read) = try ContactCode.read(text) else { Issue.record("not a tribe"); return }
        #expect(read == link)
        #expect(ScanLabel(text) == ScanLabel(kind: .tribe, text: "Tribe"))
        #expect(MessageLink.card(in: "Join us: \(text).")?.link == .tribe(link))
    }

    @Test func stillReadsTheOldSphinxLink() throws {
        let old = try #require(TribeLink("sphinx.chat://?action=tribeV2&pubkey=\(key)&host=tribes.example.com"))
        #expect(old == TribeLink("peel://tribe?pubkey=\(key)&host=tribes.example.com"))
    }

    @Test(arguments: [
        "peel://tribe?pubkey=KEY&host=tribes.example.com&extra=1",
        "peel://tribe/x?pubkey=KEY&host=tribes.example.com",
        "peel://tribe?pubkey=KEY&host=tribes.example.com#frag",
        "peel://tribe?pubkey=nothex&host=tribes.example.com",
        "peel://tribe?pubkey=KEY&host=evil.com/path",
        "peel://tribe?pubkey=KEY",
        "peel://other?pubkey=KEY&host=tribes.example.com",
    ])
    func refusesMalformedPeelLinks(_ text: String) {
        let text = text.replacingOccurrences(of: "KEY", with: key)
        #expect(TribeLink(text) == nil)
        #expect(throws: Engine.Failure.notAContactCode) { try ContactCode.read(text) }
    }
}
