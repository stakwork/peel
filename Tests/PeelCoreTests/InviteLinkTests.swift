import Foundation
import Testing
@testable import PeelCore

/// A worker's invite as a link (docs/phases/13-worker-invite-iphone.md):
/// `peel://join?…` as strut's join page opens Peel, the clipboard's whole
/// `sphinx.chat://?action=i&…` link or strut's join link, and the `a=` that
/// names the app to open. The cases are Android's `InviteLinkTest`.
struct InviteLinkTests {
    let link = "sphinx.chat://?action=i&d=abc"
    /// A worker's Tasks address, percent-encoded as it rides in `a=`.
    let worker = "https%3A%2F%2Facme.example.com%2Fpublic%2F%3Fapp%3Dworker"
    let tasks = "https%3A%2F%2Fs.example%2F%3Fapp%3Dstrut%252Fworker%26solo%3D1%26public%3D1%26input%3Dinvite%253Dstrut-invite.eyJ9.sig%2526type%253Dbook-scan-page"
    let tasksURL = "https://s.example/?app=strut%2Fworker&solo=1&public=1&input=invite%3Dstrut-invite.eyJ9.sig%26type%3Dbook-scan-page"

    func peel(_ text: String) throws -> String? { InviteLink.fromPeelLink(try #require(URL(string: text))) }

    // MARK: peel://join

    @Test func aPeelJoinLinkIsTheSphinxLinkWithTheSameQuery() throws {
        #expect(try peel("peel://join?action=i&d=abc&c=BBBB&a=\(worker)") == "sphinx.chat://?action=i&d=abc&c=BBBB&a=\(worker)")
        #expect(try peel("PEEL://JOIN?action=i&d=abc") == link)
        #expect(try peel("peel://join/?action=i&d=abc") == link)
        // The a= rides through whole, so the app is read from the converted link.
        let converted = try #require(try peel("peel://join?action=i&d=abc&a=\(tasks)"))
        #expect(InviteLink.appOf(converted)?.url.absoluteString == tasksURL)
    }

    /// Any page can open a `peel:` link, so only a well-formed invite does.
    @Test(arguments: [
        "peel://join", "peel://join?", "peel://join?action=i", "peel://join?action=i&d=", "peel://join?d=abc",
        "peel://join?action=i&action=i&d=abc", "peel://join?action=tribeV2&d=abc",
        "peel://join/x?action=i&d=abc", "peel://join?action=i&d=abc#x", "peel://u@join?action=i&d=abc",
        "peel://open?action=i&d=abc", "peel://home-setup?action=i&d=abc", "https://join?action=i&d=abc",
        "sphinx.chat://?action=i&d=abc",
    ])
    func whatIsNoJoinLink(text: String) throws {
        #expect(try peel(text) == nil)
    }

    // MARK: The clipboard

    @Test func anInviteLinkOnTheClipboardIsTakenWholeWithItsApp() {
        let app = "https%3A%2F%2Fs.example%2F%3Fapp%3Dstrut%252Fworker%26solo%3D1%26public%3D1"
        let copied = "sphinx.chat://?action=i&d=abc&c=BBBB&a=\(app)"
        #expect(InviteLink.fromClipboard(copied) == copied)
        #expect(InviteLink.fromClipboard("  \(copied)\n") == copied)
        #expect(InviteLink.appOf(InviteLink.fromClipboard(copied)!)?.url.absoluteString == "https://s.example/?app=strut%2Fworker&solo=1&public=1")
        #expect(InviteLink.fromClipboard("SPHINX.CHAT://?action=i&d=abc") == "SPHINX.CHAT://?action=i&d=abc")
    }

    @Test(arguments: [
        "", "   ", "hello", "d=abc", "action=i&d=abc",
        "sphinx.chat://?action=tribeV2&pubkey=x",
        "sphinx.chat://?action=i", "sphinx.chat://?action=i&d=", "sphinx.chat://?d=abc",
        "sphinx.chat://?action=i&action=i&d=abc",
        "sphinx.chat://?action=i&d=abc and more words",
    ])
    func nothingElseSomeoneCopiedIsTaken(text: String) {
        #expect(InviteLink.fromClipboard(text) == nil)
    }

    @Test func noTextAndTooMuchTextAreNotAnInvite() {
        #expect(InviteLink.fromClipboard(nil) == nil)
        #expect(InviteLink.fromClipboard("sphinx.chat://?action=i&d=" + String(repeating: "a", count: InviteLink.maxLength)) == nil)
    }

    /// The link a worker is sent is strut's join page, the invite after its `#`.
    @Test func strutsJoinLinkIsTakenAsTheLinkThePageOpensPeelWith() {
        let asTapped = "sphinx.chat://?action=i&d=abc&c=BBBB&a=\(tasks)"
        let join = "https://s.example/public/join#action=i&d=abc&c=BBBB&a=\(tasks)"
        #expect(InviteLink.fromClipboard(join) == asTapped)
        #expect(InviteLink.fromClipboard("\n\(join) ") == asTapped)
        // The page's own ?lang=, an upper-case scheme, and a sphinx.chat://? after the # (the page drops it too).
        #expect(InviteLink.fromClipboard("https://s.example/public/join?lang=es#action=i&d=abc&c=BBBB&a=\(tasks)") == asTapped)
        #expect(InviteLink.fromClipboard("HTTPS://s.example/public/join#action=i&d=abc&c=BBBB&a=\(tasks)") == asTapped)
        #expect(InviteLink.fromClipboard("https://s.example/public/join#sphinx.chat://?action=i&d=abc&c=BBBB&a=\(tasks)") == asTapped)
        #expect(InviteLink.appOf(InviteLink.fromClipboard(join)!)?.url.absoluteString == tasksURL)
    }

    @Test(arguments: [
        "http://s.example/public/join#action=i&d=abc",
        "https://s.example/public/joinx#action=i&d=abc",
        "https://s.example/join#action=i&d=abc",
        "https://s.example/public/join/#action=i&d=abc",
        "https://u:p@s.example/public/join#action=i&d=abc",
        "https://s.example/public/join",
        "https://s.example/public/join#",
        "https://s.example/public/join#action=tribeV2&pubkey=x",
        "https://s.example/public/join#action=i&d=",
        "https://s.example/public/join#action=i&d=abc and more",
        "peel://open?url=https%3A%2F%2Fs.example%2Fpublic%2Fjoin#action=i&d=abc",
    ])
    func whatIsNoJoinLinkOnTheClipboard(text: String) {
        #expect(InviteLink.fromClipboard(text) == nil)
    }

    // MARK: a=

    @Test func aWorkersLinkNamesTheAppToOpenByAPeelOpenLinksRules() throws {
        let app = try #require(InviteLink.appOf("sphinx.chat://?action=i&d=abc&c=def&a=\(worker)"))
        #expect(app.url.absoluteString == "https://acme.example.com/public/?app=worker")
        #expect(app.app == "worker")
        #expect(app.origin == "https://acme.example.com")
        #expect(app.seller.absoluteString == "https://acme.example.com")
        #expect(app == PublicAppLink(try #require(URL(string: "https://acme.example.com/public/?app=worker"))))
        // Anywhere in the link, and a plus stays a plus.
        let plus = InviteLink.appOf("sphinx.chat://?a=https%3A%2F%2Facme.example.com%2Fa+b&action=i&d=abc")
        #expect(plus?.url.absoluteString == "https://acme.example.com/a+b")
    }

    @Test(arguments: [
        "",                                                   // no a=
        "&a=",
        "&a=http%3A%2F%2Facme.example.com",                   // not https, off this machine
        "&a=javascript%3Aalert(1)",
        "&a=https%3A%2F%2Facme.example.com%2F%23x",           // a fragment
        "&a=https%3A%2F%2Fu%3Ap%40acme.example.com",          // credentials
        "&a=https%3A%2F%2Facme.example.com%2F%3Fapp%3Da%26app%3Db",
        "&a=https%3A%2F%2Facme.example.com%2",                // a broken escape
        "&aa=https%3A%2F%2Facme.example.com%2Fpublic%2F%3Fapp%3Dworker",
        "&app=https%3A%2F%2Facme.example.com%2Fpublic%2F%3Fapp%3Dworker",
    ])
    func noAppOrOneThatFailsTheRulesOpensNothing(tail: String) {
        #expect(InviteLink.appOf(link + tail) == nil)
    }

    @Test func twoAppsOpenNeither() {
        #expect(InviteLink.appOf("\(link)&a=\(worker)&a=\(worker)") == nil)
    }

    /// Wherever its sections start: the join link's `#`, the sphinx link's `?`, or none (a bare `d=…&a=…`).
    @Test func anInvitePastedOrScannedNamesItsAppWhereverItsSectionsStart() {
        let join = "https://s.example/public/join#action=i&d=abc&c=BBBB&a=\(tasks)"
        #expect(InviteLink.appOf(join)?.url.absoluteString == tasksURL)
        #expect(InviteLink.appOf("https://s.example/public/join?lang=es#action=i&d=abc&a=\(tasks)")?.url.absoluteString == tasksURL)
        #expect(InviteLink.appOf("sphinx.chat://?action=i&d=abc&a=\(tasks)")?.url.absoluteString == tasksURL)
        #expect(InviteLink.appOf("d=abc&c=BBBB&a=\(tasks)")?.url.absoluteString == tasksURL)
        // A join link with no a= opens nothing; the invite is read as before.
        #expect(InviteLink.appOf("https://s.example/public/join#action=i&d=abc") == nil)
    }
}
