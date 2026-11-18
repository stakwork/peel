import Foundation
import Testing
@testable import PeelCore
@testable import PeelUI

/// When a page may ask for the person's location, and what a kept decision does.
struct PageLocationTests {
    let page = URL(string: "https://trash.example.com/app")!

    func ask(
        main: Bool = true, frame: String? = "https://trash.example.com/other", opaque: Bool = false,
        page: URL? = nil, visible: Bool = true, active: Bool = true
    ) -> String? {
        PageLocation.mayAsk(
            frameIsMain: main, frameURL: frame.flatMap(URL.init(string:)), frameOriginIsOpaque: opaque,
            pageURL: page ?? self.page, pageVisible: visible, appActive: active)
    }

    @Test func mainFrameOnThePageOriginIsAskedAsThePage() {
        #expect(ask() == "https://trash.example.com")
        #expect(ask(frame: "https://TRASH.example.com:443/x") == "https://trash.example.com")
    }

    @Test func anotherOriginIsDenied() {
        #expect(ask(frame: "https://evil.example.net/") == nil)
        #expect(ask(frame: "https://trash.example.com:8443/") == nil)
        #expect(ask(frame: nil) == nil)
    }

    @Test func theSandboxedAppFrameIsAttributedToThePage() {
        #expect(ask(main: false, frame: "about:srcdoc", opaque: true) == "https://trash.example.com")
    }

    @Test func otherFramesAreDenied() {
        #expect(ask(main: false, frame: "https://trash.example.com/x", opaque: false) == nil)
        #expect(ask(main: false, frame: "https://evil.example.net/", opaque: true) == nil)
        #expect(ask(main: false, frame: "about:srcdoc", opaque: false) == nil)
    }

    @Test func plainHTTPOnlyOnThisMachine() throws {
        let remote = try #require(URL(string: "http://trash.example.com/"))
        #expect(ask(frame: remote.absoluteString, page: remote) == nil)
        let local = try #require(URL(string: "http://localhost:3000/"))
        #expect(ask(frame: "http://localhost:3000/a", page: local) == "http://localhost:3000")
        let ftp = try #require(URL(string: "ftp://trash.example.com/"))
        #expect(ask(frame: ftp.absoluteString, page: ftp) == nil)
    }

    @Test func aHiddenPageOrBackgroundAppIsDenied() {
        #expect(ask(visible: false) == nil)
        #expect(ask(active: false) == nil)
    }

    @Test func aKeptDecisionWinsAndOnceOnlyCountsWithNone() {
        let allowed = SiteLocationGrant(origin: "https://a", allowed: true, decidedAt: 1)
        let blocked = SiteLocationGrant(origin: "https://a", allowed: false, decidedAt: 1)
        #expect(PageLocation.decide(stored: allowed, allowOnce: false) == .allow)
        #expect(PageLocation.decide(stored: blocked, allowOnce: false) == .deny)
        #expect(PageLocation.decide(stored: blocked, allowOnce: true) == .deny)
        #expect(PageLocation.decide(stored: nil, allowOnce: true) == .allow)
        #expect(PageLocation.decide(stored: nil, allowOnce: false) == .ask)
    }

    @Test func summaryWords() {
        #expect(PageLocation.summary(.init(origin: "o", allowed: true, precise: true, decidedAt: 0)) == "Allowed · precise")
        #expect(PageLocation.summary(.init(origin: "o", allowed: true, decidedAt: 0)) == "Allowed · approximate")
        #expect(PageLocation.summary(.init(origin: "o", allowed: false, decidedAt: 0)) == "Blocked")
    }
}
