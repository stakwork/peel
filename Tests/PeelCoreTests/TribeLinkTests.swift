import Foundation
import Testing
@testable import PeelCore
@testable import PeelTestSupport

/// Tribe links in both forms (`sphinx.chat://?action=tribeV2…`, `peel://tribe?…`, the one Peel writes): reading,
/// building, finding them in message text and cards, and where one goes in Peel (`TribeRoute`).
struct TribeLinkTests {
    static let host = "tribes.v2.sphinx.chat"
    static let official = "sphinx.chat://?action=tribeV2&pubkey=\(keyG)&host=\(host)"
    static let peel = "peel://tribe?pubkey=\(keyG)&host=\(host)"

    @Test func bothFormsAreRead() throws {
        for text in [Self.official, Self.peel, "  \(Self.peel)\n"] {
            let link = try #require(TribeLink(text))
            #expect(link.pubkey == keyG)
            #expect(link.host == Self.host)
        }
    }

    @Test func caseInTheSchemeAndKeyIsForgiven() throws {
        let upper = "PEEL://TRIBE?pubkey=\(keyG.uppercased())&host=\(Self.host)"
        #expect(try #require(TribeLink(upper)).pubkey == keyG)
        let official = "SPHINX.CHAT://?action=tribeV2&pubkey=\(keyG.uppercased())&host=\(Self.host)"
        #expect(try #require(TribeLink(official)).pubkey == keyG)
    }

    /// The official form ignores what else it carries; Peel's own is read strictly (`PeelLink.values`).
    @Test func extraParametersAreIgnoredOnlyInTheOfficialForm() {
        #expect(TribeLink(Self.official + "&utm=x") == TribeLink(Self.official))
        #expect(TribeLink(Self.peel + "&x=1") == nil)
    }

    @Test func otherLinksAreNotTribes() {
        #expect(TribeLink("sphinx.chat://?action=i&pubkey=\(keyG)&host=\(Self.host)") == nil)
        #expect(TribeLink("sphinx.chat://?action=tribe&pubkey=\(keyG)&host=\(Self.host)") == nil)
        #expect(TribeLink("peel://open?pubkey=\(keyG)&host=\(Self.host)") == nil)
        #expect(TribeLink("peel://tribes?pubkey=\(keyG)&host=\(Self.host)") == nil)
        #expect(TribeLink("https://tribe?pubkey=\(keyG)&host=\(Self.host)") == nil)
    }

    @Test func aBadKeyOrHostIsRefused() {
        #expect(TribeLink("peel://tribe?pubkey=\(keyG.dropLast(2))&host=\(Self.host)") == nil)
        #expect(TribeLink("peel://tribe?pubkey=zz\(keyG.dropFirst(2))&host=\(Self.host)") == nil)
        #expect(TribeLink("peel://tribe?host=\(Self.host)") == nil)
        #expect(TribeLink("peel://tribe?pubkey=\(keyG)") == nil)
        #expect(TribeLink("peel://tribe?pubkey=\(keyG)&host=") == nil)
        #expect(TribeLink("peel://tribe?pubkey=\(keyG)&host=evil.com/x") == nil)
        #expect(TribeLink("sphinx.chat://?action=tribeV2&pubkey=\(keyG)&host=a%20b") == nil)
    }

    @Test func thePeelLinkInitTakesOnlyThePeelForm() throws {
        #expect(TribeLink(peelLink: try #require(URL(string: Self.peel))) == TribeLink(Self.official))
        #expect(TribeLink(peelLink: try #require(URL(string: Self.official))) == nil)
        #expect(TribeLink(peelLink: try #require(URL(string: "peel://tribe?pubkey=short&host=h.io"))) == nil)
    }

    @Test func theBuilderWritesThePeelFormAndRoundTrips() throws {
        #expect(TribeLink.text(pubkey: keyG, host: Self.host) == Self.peel)
        #expect(Tribe(pubkey: keyG, host: Self.host).link == Self.peel)
        let link = try #require(TribeLink(Self.official))
        #expect(link.text == Self.peel)
        #expect(TribeLink(link.text) == link)
    }

    @Test func messageTextLinksBothForms() throws {
        let text = "join: \(Self.official), or \(Self.peel)."
        let spans = MessageMarkup.spans(in: text)
        #expect(spans.map(\.text) == [Self.official, Self.peel])
        for span in spans {
            guard case .link(let url) = span.kind else { Issue.record("not a link"); continue }
            #expect(TribeLink(url.absoluteString) != nil)
        }
        #expect(MessageMarkup.spans(in: "(\(Self.peel))").map(\.text) == [Self.peel])
    }

    @Test func otherTextStaysText() {
        #expect(MessageMarkup.spans(in: "sphinx.chat://?action=i&d=abc").isEmpty)
        #expect(MessageMarkup.spans(in: "peel://tribe?pubkey=short&host=h.io").isEmpty)
        #expect(MessageMarkup.spans(in: "xpeel://tribe?pubkey=\(keyG)&host=\(Self.host)").isEmpty)
        #expect(MessageMarkup.spans(in: "`\(Self.peel)`").count == 1)
    }

    @Test func tribeLinksSitWithHttpsLinks() {
        let spans = MessageMarkup.spans(in: "https://a.co/x then \(Self.peel)")
        #expect(spans.count == 2)
    }

    @Test func theCardFindsBothForms() {
        let expected = MessageLink.tribe(TribeLink(Self.official)!)
        #expect(MessageLink.card(in: "Join us: \(Self.peel).")?.link == expected)
        #expect(MessageLink.card(in: Self.official)?.link == expected)
        #expect(MessageLink.card(in: "peel://tribe?pubkey=short&host=h.io") == nil)
    }

    @Test func aMemberOpensTheChatAndAnyoneElseJoins() throws {
        let link = try #require(TribeLink(Self.peel))
        let tribes = [keyG: Tribe(pubkey: keyG, host: Self.host)]
        #expect(TribeRoute.decide(link, tribes: tribes) == .open(keyG))
        // Asking to join counts: there is a chat to open.
        #expect(TribeRoute.decide(link, tribes: [keyG: Tribe(pubkey: keyG, status: .pending)]) == .open(keyG))
        // Left, removed, declined or unknown: the Join form, with the link in the form Peel shares.
        #expect(TribeRoute.decide(link, tribes: [keyG: Tribe(pubkey: keyG, left: true)]) == .join(Self.peel))
        #expect(TribeRoute.decide(link, tribes: [keyG: Tribe(pubkey: keyG, status: .removed)]) == .join(Self.peel))
        #expect(TribeRoute.decide(link, tribes: [key2G: Tribe(pubkey: key2G)]) == .join(Self.peel))
        #expect(TribeRoute.decide(link, tribes: [:]) == .join(Self.peel))
    }

    @Test func aRouteIsDecidedFromText() {
        #expect(TribeRoute.decide(Self.official, tribes: [:]) == .join(Self.peel))
        #expect(TribeRoute.decide(Self.peel, tribes: [keyG: Tribe(pubkey: keyG)]) == .open(keyG))
        #expect(TribeRoute.decide("https://a.co", tribes: [:]) == nil)
    }

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
