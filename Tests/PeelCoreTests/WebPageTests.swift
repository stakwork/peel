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
}
