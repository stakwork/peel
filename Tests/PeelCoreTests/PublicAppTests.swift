import Foundation
import Testing
@testable import PeelCore
@testable import PeelTestSupport

/// A stranger's public app as Peel opens it (strut's plans/app-payments.md
/// §5.3, R7): the `peel://open?url=` link any page can make, held to an
/// https address or one on this machine; the Mac's remote-mode address
/// into its own strut UI, read back as the seller and app it names and
/// never as one of the person's own apps; and which app a served box serves.
struct PublicAppTests {
    func link(_ address: String) throws -> PublicAppLink {
        let url = try #require(URL(string: address))
        return try #require(PublicAppLink(url))
    }

    @Test(arguments: [
        ("peel://open?url=https%3A%2F%2Fmoon.game%2F", "https://moon.game", nil, "https://moon.game"),
        ("peel://open?url=https://shop.example.com/lab/?app=moon-game%26public=1", "https://shop.example.com/lab", "moon-game",
         "https://shop.example.com"),
        ("peel://open?url=http://localhost:3000/", "http://localhost:3000", nil, "http://localhost:3000"),
        ("peel://open?url=https://Moon.Game:443/public", "https://moon.game", nil, "https://moon.game"),
    ] as [(String, String, String?, String)])
    func aLinkNamesTheServerAndItsApp(link: String, seller: String, app: String?, origin: String) throws {
        let url = try #require(URL(string: link))
        let opened = try #require(PublicAppLink(peelLink: url))
        #expect(opened.seller.absoluteString == seller)
        #expect(opened.app == app)
        #expect(opened.origin == origin)
    }

    /// Any page can open a `peel:` link, so only this one form opens.
    @Test(arguments: [
        "peel://open?url=http://moon.game/",                     // plain http off this machine
        "peel://open?url=https://user:pw@moon.game/",            // credentials
        "peel://open?url=https://moon.game/#x",                  // a fragment
        "peel://open?url=javascript:alert(1)",
        "peel://open?url=https://moon.game/?app=a%26app=b",      // an app named twice
        "peel://open?url=https://moon.game/?app=..%2Fetc",       // a name strut refuses
        "peel://open?url=https://a.example&url=https://b.example",
        "peel://open?url=https://moon.game&x=1",
        "peel://open/path?url=https://moon.game",
        "peel://home-setup?url=https://moon.game",
        "https://open?url=https://moon.game",
    ])
    func whatNeverOpens(link: String) throws {
        let url = try #require(URL(string: link))
        #expect(PublicAppLink(peelLink: url) == nil)
    }

    /// The Mac's own strut UI hosting another server's app: the address it
    /// opens, read back as that seller and app, and never as an app of the
    /// person's own strut, whose wallet connection is another.
    @Test func theMacsRemoteAddressNamesTheSellerAndNeverAnAppOfItsOwn() throws {
        let strut = try #require(URL(string: "http://127.0.0.1:4100"))
        let seller = try #require(URL(string: "https://shop.example.com/lab"))
        let page = try #require(StrutUI.page(on: strut, key: "k", "app", "moon-game", from: seller))
        #expect(page.absoluteString
            == "http://127.0.0.1:4100/?key=k&app=moon-game&public=1&from=https%3A%2F%2Fshop.example.com%2Flab&solo=1")
        let remote = try #require(StrutUI.remote(page, in: "/"))
        #expect(remote.seller == seller && remote.name == "moon-game")
        #expect(StrutAppLink(page, folder: "/", from: .own) == nil)
        // Read as strut's UI reads it: a value given twice, or a seller it would not open, is no page.
        for query in ["app=a&app=b&public=1&from=https://x.example", "app=a&public=1&from=http://x.example",
                      "app=a&public=1&public=1&from=https://x.example", "app=a&from=https://x.example"] {
            let url = try #require(URL(string: "http://127.0.0.1:4100/?\(query)"))
            #expect(StrutUI.remote(url, in: "/") == nil, "\(query)")
        }
        // The person's own app is still theirs.
        let own = try #require(URL(string: "http://127.0.0.1:4100/?app=moon-game&solo=1"))
        #expect(StrutAppLink(own, folder: "/", from: .own) != nil)
    }

    /// A served box names its app in its page (`strut-serve`); a public view
    /// with one app has that one; anything else is said, never guessed.
    @Test func theAppAServedBoxServes() async throws {
        let served = try await HTTPStub(contentType: "text/html") { _, request in
            request.hasPrefix("GET / ") ? #"<html><head><meta name="strut-serve" content="moon-game" /></head></html>"# : "[]"
        }
        defer { served.stop() }
        let servedLink = try link("http://127.0.0.1:\(served.port)/")
        #expect(try await servedLink.appName() == "moon-game")

        let listing = try await HTTPStub { _, request in
            request.hasPrefix("GET /public/apps ") ? #"[{"name":"tips","version":"v2","title":"Tips"}]"# : "<html></html>"
        }
        defer { listing.stop() }
        let listed = try link("http://127.0.0.1:\(listing.port)/")
        #expect(try await listed.appName() == "tips")

        let many = try await HTTPStub { _, _ in #"[{"name":"a"},{"name":"b"}]"# }
        defer { many.stop() }
        let unclear = try link("http://127.0.0.1:\(many.port)/")
        await #expect(throws: PeelError.self) { try await unclear.appName() }
        // A meta that names something strut would not take is no name.
        #expect(PublicAppLink.served(in: #"<meta name="strut-serve" content="../x" />"#) == nil)
        #expect(PublicAppLink.served(in: #"<meta name="strut-serve" content="" />"#) == nil)
    }
}
