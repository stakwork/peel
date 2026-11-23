import Foundation
import Testing
@testable import PeelCore
@testable import PeelTestSupport

/// Tribe links in both forms (`sphinx.chat://?action=tribeV2…`, `peel://tribe?…`): reading, building, finding
/// them in message text and cards, and where one goes in Peel (`TribeRoute`).
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

    @Test func extraParametersAreIgnored() {
        #expect(TribeLink(Self.official + "&utm=x") == TribeLink(Self.official))
        #expect(TribeLink(Self.peel + "&x=1") == TribeLink(Self.peel))
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

    @Test func theBuilderIsUnchangedAndRoundTrips() throws {
        #expect(TribeLink.text(pubkey: keyG, host: Self.host) == Self.official)
        #expect(Tribe(pubkey: keyG, host: Self.host).link == Self.official)
        let link = try #require(TribeLink(Self.official))
        #expect(link.text == Self.official)
        #expect(link.peelText == Self.peel)
        #expect(TribeLink(link.peelText) == link)
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
        #expect(TribeRoute.decide(link, tribes: [keyG: Tribe(pubkey: keyG, left: true)]) == .join(Self.official))
        #expect(TribeRoute.decide(link, tribes: [keyG: Tribe(pubkey: keyG, status: .removed)]) == .join(Self.official))
        #expect(TribeRoute.decide(link, tribes: [key2G: Tribe(pubkey: key2G)]) == .join(Self.official))
        #expect(TribeRoute.decide(link, tribes: [:]) == .join(Self.official))
    }

    @Test func aRouteIsDecidedFromText() {
        #expect(TribeRoute.decide(Self.official, tribes: [:]) == .join(Self.official))
        #expect(TribeRoute.decide(Self.peel, tribes: [keyG: Tribe(pubkey: keyG)]) == .open(keyG))
        #expect(TribeRoute.decide("https://a.co", tribes: [:]) == nil)
    }
}
