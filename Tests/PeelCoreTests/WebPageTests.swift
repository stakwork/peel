import Foundation
import Testing
@testable import PeelCore

/// What the web pane opens (`WebPage`), the tribe records that give it a
/// tribe's app and second brain, and each profile's own store.
struct WebPageTests {
    @Test(arguments: [
        "https://example.com", "https://www.youtube.com/watch?v=abc", "HTTPS://Example.COM/a",
        "http://example.com/page", "http://localhost:3000", "https://graph.sphinx.chat/?tribe=02ab",
    ])
    func webPagesOpenInThePane(string: String) throws {
        let url = try #require(URL(string: string))
        #expect(WebPage.address(url) == url)
    }

    @Test(arguments: [
        // other schemes keep their own handling
        "mailto:a@example.com", "sphinx.chat://?action=tribeV2&pubkey=02ab&host=x", "file:///etc/hosts",
        "ftp://example.com/a", "javascript:alert(1)", "data:text/html,hi", "about:blank",
        // no host, or a user name that would read as the host
        "https://", "https:///path", "https://google.com@evil.example/", "https://user:pw@example.com/",
    ])
    func everythingElseDoesNot(string: String) throws {
        let url = try #require(URL(string: string))
        #expect(WebPage.address(url) == nil)
    }

    @Test func aTypedAddressIsTrimmedAndCheckedTheSameWay() {
        #expect(WebPage.address("  https://app.example.com/x \n")?.absoluteString == "https://app.example.com/x")
        #expect(WebPage.address("") == nil)
        #expect(WebPage.address(nil as String?) == nil)
        #expect(WebPage.address("not a url") == nil)
        #expect(WebPage.address("sphinx.chat://?action=tribeV2") == nil)
    }

    @Test(arguments: [
        ("example.com", "https://example.com"),
        ("  https://example.com/a?b=c \n", "https://example.com/a?b=c"),
        ("HTTP://Example.com", "HTTP://Example.com"),
        ("https://example.com/a b", "https://example.com/a%20b"),
        ("example.com:8080/x", "https://example.com:8080/x"),
        ("www.youtube.com/watch?v=abc", "https://www.youtube.com/watch?v=abc"),
        ("localhost:3000", "http://localhost:3000"),
        ("127.0.0.1:8642/a", "http://127.0.0.1:8642/a"),
        ("192.168.1.1", "https://192.168.1.1"),
        // an international name in its xn-- form, as the field shows it
        ("bücher.de", "https://xn--bcher-kva.de"),
    ])
    func aTypedAddressOpens(typed: String, expected: String) {
        #expect(WebPage.typed(typed)?.absoluteString == expected)
    }

    @Test(arguments: [
        ("swift tabs", "swift%20tabs"), ("hello", "hello"), ("3.14", "3.14"), ("c++ & a=b #1", "c%2B%2B%20%26%20a%3Db%20%231"),
        // no scheme: a name with credentials is not opened, only searched for
        ("google.com@evil.example", "google.com@evil.example"),
        // spaces make it words, whatever the first one looks like
        ("javascript:alert(1) x", "javascript:alert(1)%20x"),
        ("javascript:1", "javascript:1"),
    ])
    func wordsAreASearch(typed: String, query: String) {
        #expect(WebPage.typed(typed)?.absoluteString == "https://duckduckgo.com/?q=" + query)
    }

    @Test(arguments: [
        "", "   ", "javascript:alert(1)", "JavaScript:alert(document.cookie)", "file:///etc/hosts", "data:text/html,hi",
        "about:blank", "blob:https://example.com/1", "mailto:a@example.com", "sphinx.chat://?action=tribeV2",
        "vbscript:x", "http:example.com", "https://", "https://exa mple.com", "https://google.com@evil.example/", "ftp://example.com",
    ])
    func otherSchemesAreRefused(typed: String) {
        #expect(WebPage.typed(typed) == nil)
    }

    @Test func eachProfileKeepsOneStoreIdentifier() throws {
        let one = TempProfile(), two = TempProfile()
        #expect(try WebPage.storeIdentifier(in: one.url, create: false) == nil)
        let first = try #require(try WebPage.storeIdentifier(in: one.url))
        #expect(try WebPage.storeIdentifier(in: one.url) == first)
        #expect(try WebPage.storeIdentifier(in: one.url, create: false) == first)
        #expect(try WebPage.storeIdentifier(in: two.url) != first)
    }

    @Test func theRegistryGivesATribesAppAndSecondBrain() throws {
        let json = #"""
            {"pubkey":"02ab","name":"Club","app_url":" https://app.example.com ",
             "second_brain_url":"https://brain.example.com/graph","feed_url":"https://x/feed"}
            """#
        let info = try JSONDecoder().decode(TribeInfo.self, from: Data(json.utf8))
        #expect(info.appURL == " https://app.example.com ")
        #expect(info.secondBrainURL == "https://brain.example.com/graph")
        var tribe = Tribe(pubkey: "02ab")
        tribe.update(from: info, trustingPrivacy: true)
        #expect(tribe.appURL == "https://app.example.com")
        #expect(tribe.secondBrainURL == "https://brain.example.com/graph")

        // Gone from the record, or not a web page: none.
        let other = #"{"pubkey":"02ab","name":"Club","app_url":"javascript:alert(1)","second_brain_url":""}"#
        tribe.update(from: try JSONDecoder().decode(TribeInfo.self, from: Data(other.utf8)), trustingPrivacy: true)
        #expect(tribe.appURL == nil)
        #expect(tribe.secondBrainURL == nil)
    }

    @Test func aTribesPagesComeInOneOrder() {
        var tribe = Tribe(pubkey: "02ab")
        #expect(tribe.pages.isEmpty)
        tribe.secondBrainURL = "https://brain.example.com/graph"
        #expect(tribe.pages.map(\.kind) == [.secondBrain])
        tribe.appURL = "https://app.example.com"
        #expect(tribe.pages == [
            TribePage(kind: .app, url: URL(string: "https://app.example.com")!),
            TribePage(kind: .secondBrain, url: URL(string: "https://brain.example.com/graph")!),
        ])
    }

    @Test func anEditSendsTheAddressesBackAsTheServerHadThem() throws {
        let record: [String: Any] = [
            "pubkey": "02ab", "name": "Old", "app_url": "https://app.example.com",
            "second_brain_url": "https://brain.example.com",
        ]
        let fields = try TribeSettings(name: "New").fields(over: record)
        #expect(fields["app_url"] as? String == "https://app.example.com")
        #expect(fields["second_brain_url"] as? String == "https://brain.example.com")
    }

    @Test func aTribesAddressesAreStored() throws {
        let profile = TempProfile()
        let storage = try profile.storage()
        var tribe = Tribe(pubkey: "02ab", name: "Club")
        tribe.appURL = "https://app.example.com"
        tribe.secondBrainURL = "https://brain.example.com"
        try storage.save([tribe])
        #expect(try storage.tribes() == [tribe])
    }

    @Test func htmlAttachmentsAreShownAsPages() {
        #expect(WebPage.isHTML(fileName: "Report.HTML", mediaType: "application/octet-stream"))
        #expect(WebPage.isHTML(fileName: "notes.htm", mediaType: nil))
        // Before a download names it, by what it says it is.
        #expect(WebPage.isHTML(fileName: nil, mediaType: "text/html; charset=utf-8"))
        #expect(!WebPage.isHTML(fileName: "page.html.zip", mediaType: "application/zip"))
        #expect(!WebPage.isHTML(fileName: "notes.txt", mediaType: "text/plain"))
        #expect(!WebPage.isHTML(fileName: nil, mediaType: nil))
    }
}
