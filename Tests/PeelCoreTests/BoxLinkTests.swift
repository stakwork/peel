import Foundation
import Sphinxrs
import os
import Testing
@testable import PeelCore
@testable import PeelTestSupport

/// Peel linked to a strut box (strut's plans/people-and-hosts.md §2.1,
/// specs/API.md §13.6): the `peel://strut/link` a box's Connect shows,
/// what Peel will and will not sign, the signature strut checks, the box
/// list kept beside Hive's pairing, and strut's three routes on a stand-in.
struct BoxLinkTests {
    static let now = BoxFixture.now
    static let nowMs = BoxFixture.nowMs

    static func challenge(host: String, actor: String? = "ada-3f9a", name: String? = "Ada Lovelace",
                          exp: Int64 = nowMs + 600_000) -> String {
        BoxFixture.challenge(host: host, actor: actor, name: name, exp: exp)
    }

    /// The link strut's `accountsCapability` makes: both values with
    /// `encodeURIComponent`, which leaves `-_.!~*'()` as they are.
    static func link(_ base: String, _ challenge: String) -> URL {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")
        func encoded(_ text: String) -> String { text.addingPercentEncoding(withAllowedCharacters: allowed)! }
        return URL(string: "peel://strut/link?url=\(encoded(base))&challenge=\(encoded(challenge))")!
    }

    // MARK: The link

    /// A box's link reads back as its box, with a mount path or a port, and
    /// the challenge's claims; the question names the box and the person.
    @Test(arguments: [
        ("https://box.example.com", "https://box.example.com", "box.example.com"),
        ("https://box.example.com/lab", "https://box.example.com/lab", "box.example.com"),
        ("https://Box.Example.com:8443/", "https://box.example.com:8443", "box.example.com"),
    ])
    func aBoxsLinkReadsAsStrutWritesIt(base: String, box: String, host: String) throws {
        let offer = try #require(BoxLinkOffer(peelLink: Self.link(base, Self.challenge(host: host))))
        #expect(offer.box.absoluteString == box)
        #expect(offer.host == host)
        #expect(offer.challenge.actor == "ada-3f9a" && offer.challenge.name == "Ada Lovelace")
        #expect(offer.challenge.expiresAtMs == Self.nowMs + 600_000)
        #expect(offer.challenge.person == "Ada Lovelace")
        #expect(offer.problem(at: Self.now, allowsLoopback: false) == nil)
    }

    /// Only `peel://strut/link?url=…&challenge=…` is a box's link, and only
    /// with a box Peel would post to and a link challenge to sign.
    @Test(arguments: [
        "peel://open?url=https%3A%2F%2Fbox.example.com&challenge=C",
        "peel://strut/other?url=https%3A%2F%2Fbox.example.com&challenge=C",
        "https://strut/link?url=https%3A%2F%2Fbox.example.com&challenge=C",
        "peel://strut/link?url=https%3A%2F%2Fbox.example.com",
        "peel://strut/link?url=https%3A%2F%2Fbox.example.com&challenge=C&extra=1",
        "peel://strut/link?url=https%3A%2F%2Fbox.example.com&challenge=C#frag",
        "peel://strut/link?url=http%3A%2F%2Fbox.example.com&challenge=C",
        "peel://strut/link?url=https%3A%2F%2Fu%3Ap%40box.example.com&challenge=C",
        "peel://strut/link?url=ftp%3A%2F%2Fbox.example.com&challenge=C",
        "peel://strut/link?url=https%3A%2F%2Fbox.example.com&challenge=strut-visitor.eyJ9.abc",
        "peel://strut/link?url=https%3A%2F%2Fbox.example.com&challenge=strut-link.notbase64!.abc",
    ])
    func whatIsNotABoxsLink(_ text: String) throws {
        let challenge = Self.challenge(host: "box.example.com")
        let encoded = challenge.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_.")))!
        let url = try #require(URL(string: text.replacingOccurrences(of: "challenge=C", with: "challenge=\(encoded)")))
        #expect(BoxLinkOffer(peelLink: url) == nil)
    }

    /// What Peel will not sign, though it reads: another host's challenge, one
    /// run out, a renewal's (naming nobody), and this machine's address
    /// outside a development profile.
    @Test func whatPeelWillNotSign() throws {
        func offer(_ base: String, _ challenge: String) throws -> BoxLinkOffer {
            try #require(BoxLinkOffer(box: base, challenge: challenge))
        }
        let other = try offer("https://box.example.com", Self.challenge(host: "evil.example.com"))
        #expect(other.problem(at: Self.now, allowsLoopback: true)?.contains("not box.example.com") == true)
        let ended = try offer("https://box.example.com", Self.challenge(host: "box.example.com", exp: Self.nowMs - 1))
        #expect(ended.problem(at: Self.now, allowsLoopback: true)?.contains("ran out") == true)
        let nobody = try offer("https://box.example.com", Self.challenge(host: "box.example.com", actor: nil, name: nil))
        #expect(nobody.problem(at: Self.now, allowsLoopback: true)?.contains("doesn't name anyone") == true)
        for local in ["http://127.0.0.1:3400", "https://localhost:3400", "http://[::1]:3400"] {
            let host = try #require(Seller.host(of: URL(string: local)!))
            let offer = try offer(local, Self.challenge(host: host))
            #expect(offer.problem(at: Self.now, allowsLoopback: false)?.contains("https") == true, "\(local)")
            #expect(offer.problem(at: Self.now, allowsLoopback: true) == nil, "\(local)")
        }
    }

    // MARK: The signature

    /// The engine signs a box's challenge with the account's own key (child
    /// 0), over the challenge's UTF-8 bytes, exactly as a visitor's sign-in
    /// with it is signed: the key and signature strut's `ln-message` check
    /// takes. The vector's signature was made by this core for these words
    /// and checked with strut's own check (`VERIFIERS["ln-message"]`,
    /// src/visitors.ts at strut 35fbefc0, the one `POST /people/link` runs):
    /// it recovers the vector's key, and refuses the text with a byte added.
    @Test func theEngineSignsABoxsChallengeAsStrutChecksIt() async throws {
        let account = TempProfile()
        defer { withExtendedLifetime(account) {} }
        let engine = try testEngine(try account.storage())
        let text = Self.challenge(host: "box.example.com")
        let signed = try await engine.signBoxLink(#require(BoxChallenge(text)))
        let accountKey = await engine.accountKey
        #expect(signed.key == accountKey)
        let seed = try Engine.seed(of: abandon.joined(separator: " "))
        #expect(signed.sig == (try Sphinxrs.signBytes(seed: seed, idx: 0, time: "1", network: "bitcoin", msg: Data(text.utf8))))
        #expect(text == Self.vector.text)
        #expect(signed.key == Self.vector.key)
        #expect(signed.sig == Self.vector.sig)
    }

    /// See `theEngineSignsABoxsChallengeAsStrutChecksIt`.
    static let vector = (
        text: "strut-link.eyJhY3RvciI6ImFkYS0zZjlhIiwiZXhwIjoxNzk1MDAwNjAwMDAwLCJob3N0IjoiYm94LmV4YW1wbGUuY29tIiwibmFtZSI6IkFkYSBMb3ZlbGFjZSIsIm5vbmNlIjoiMDAxMTIyMzM0NDU1NjY3Nzg4OTlhYWJiY2NkZGVlZmYifQ.Xk2bYWJjZGVmZ2hpamtsbW5vcHFyc3R1dnd4eXo",
        key: "03216967587493cc956be284fb14c9a5f102d1030b61694d622f368a554828e766",
        sig: "20e791ec9f2ec2be6dd6ee0d46564ef8ffc522f3917ff9a77633d63172013bde175b254bf01ef70ea4eea4ef84277d8c66434ed6b8cbb7a386c6ffaac9cfaf1f6d"
    )

    // MARK: The box list

    /// The boxes are kept in their own item beside Hive's pairing, which
    /// they never touch, several at once; none kept reads as none, the last
    /// one forgotten removes the item, and removing the account removes them.
    @Test func theBoxesAreKeptBesideHivesPairing() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "boxes-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let hive = MemoryItem(Data("hive pairing".utf8))
        let profile = Profile(developmentAt: folder, hive: hive, keepsHive: true)
        #expect(try BoxLink.read(from: profile.boxes).isEmpty)
        let boxes = [BoxFixture.box("https://one.example.com"), BoxFixture.box("https://two.example.com/lab")]
        try BoxLink.write(boxes, to: profile.boxes)
        #expect(try BoxLink.read(from: profile.boxes) == boxes)
        #expect(hive.value == Data("hive pairing".utf8))
        try BoxLink.write([], to: profile.boxes)
        #expect(try profile.boxes.read() == nil)
        try BoxLink.write(boxes, to: profile.boxes)
        try profile.delete()
        #expect(try profile.boxes.read() == nil)
        #expect(hive.value == Data("hive pairing".utf8))
    }

    /// A box link is never described with its token.
    @Test func aBoxLinkIsNeverDescribedWithItsToken() {
        let box = BoxFixture.box("https://one.example.com")
        for text in ["\(box)", String(reflecting: box), String(describing: Mirror(reflecting: box).children.map(\.value))] {
            #expect(!text.contains(box.token), "\(text)")
        }
    }

    /// A server reads by its short name: its address's first label, past
    /// strut's own `strut.`, whatever its case, port or mount path; an IP
    /// address or a one-label host whole. Its whole address stays `host`.
    @Test(arguments: [
        ("https://strut.stadeum.stakwork.ai", "stadeum"),
        ("https://strut.stadeum1.sphinx.chat/", "stadeum1"),
        ("https://STRUT.Stadeum2.sphinx.chat:8443/lab", "stadeum2"),
        ("https://lab.example.com/jamie", "lab"),
        ("https://strut", "strut"),
        ("http://localhost:3000", "localhost"),
        ("http://127.0.0.1:3000", "127.0.0.1"),
        ("http://[::1]:3000", "::1"),
    ])
    func aServerReadsByItsShortName(address: String, title: String) throws {
        let box = BoxFixture.box(address)
        #expect(box.title == title)
        #expect(BoxClient(box: box.url).title == title)
        #expect(box.host == Seller.host(of: box.url))
    }

    /// Due a day after the last renewal, or within a day of the token's end.
    @Test func aBoxIsDueDailyAndBeforeItsTokenEnds() {
        #expect(!BoxFixture.box("https://a.example.com").due(at: Self.now.addingTimeInterval(3600)))
        #expect(BoxFixture.box("https://a.example.com").due(at: Self.now.addingTimeInterval(86_400)))
        #expect(BoxFixture.box("https://a.example.com", exp: Self.now.addingTimeInterval(80_000)).due(at: Self.now.addingTimeInterval(60)))
    }

    // MARK: strut's routes, on a stand-in

    /// Linking posts the challenge, the account's key and signature, its
    /// name and address, with no other credential, under the box's mount
    /// path; the answer is the link kept.
    @Test func linkingPostsTheSignedChallengeAndKeepsTheAnswer() async throws {
        let stub = try await HTTPStub(reply: { _, _ in BoxFixture.answer() })
        defer { stub.stop() }
        let base = try #require(Seller.base("http://127.0.0.1:\(stub.port)/lab"))
        let challenge = try #require(BoxChallenge(Self.challenge(host: "127.0.0.1")))
        let signed = VisitorSignature(key: "02" + String(repeating: "ab", count: 32), sig: String(repeating: "1f", count: 65),
                                      address: "02" + String(repeating: "ab", count: 32) + "_03" + String(repeating: "cd", count: 32) + "_7")
        let link = try await BoxClient(box: base).link(challenge, signed: signed, name: "Ada\non Sphinx", now: Self.now)
        #expect(link.url == base && link.actor == "ada-3f9a" && link.name == "Ada Lovelace")
        #expect(link.token == "strut-person.eyJ.abc" && link.exp == Self.now.addingTimeInterval(7 * 86_400))
        #expect(link.linkedAt == Self.now && link.renewedAt == Self.now)
        let request = try #require(stub.requests.first)
        #expect(request.hasPrefix("POST /lab/people/link "))
        #expect(!request.lowercased().contains("authorization:"))
        #expect(HTTPStub.jsonBody(of: request) == ["challenge": challenge.text, "key": signed.key, "sig": signed.sig,
                                                   "name": "Ada on Sphinx", "address": signed.address!])
    }

    @Test func aRepo2graphBoxIsAddressedUnderLab() throws {
        let bare = try #require(Seller.base("https://swarm38.sphinx.chat:3355"))
        #expect(Seller.mounted(bare).absoluteString == "https://swarm38.sphinx.chat:3355/lab")
        #expect(BoxClient(box: bare).box.absoluteString == "https://swarm38.sphinx.chat:3355/lab")
        for kept in ["https://swarm38.sphinx.chat:3355/lab", "https://acme.example", "https://acme.example:8443"] {
            let url = try #require(Seller.base(kept))
            #expect(Seller.mounted(url) == url)
        }
    }

    /// strut's refusals of a link, in words the person can act on; an
    /// answer that is not a person token is not kept.
    @Test(arguments: [
        (401, #"{"error":"unauthorized: the challenge was already used"}"#, "ran out or was already used"),
        (409, #"{"error":"linked_elsewhere: sphinx:02ab is linked to another person here"}"#, "linked to someone else"),
        (413, #"{"error":"too large"}"#, "too large"),
        (429, #"{"error":"slow down"}"#, "busy"),
        (400, #"{"error":"name is one line of at most 80 characters"}"#, "name is one line"),
        (200, #"{"actor":"ada","token":"strut-visitor.x.y","exp":1795600000000}"#, "could not be read"),
        (200, #"{"actor":"ada","token":"strut-person.x.y","exp":1}"#, "already run out"),
    ])
    func aRefusedLinkIsSaidPlainly(status: Int, body: String, words: String) async throws {
        let stub = try await HTTPStub(respond: { _, _ in (status, body) })
        defer { stub.stop() }
        let challenge = try #require(BoxChallenge(Self.challenge(host: "127.0.0.1")))
        let signed = VisitorSignature(key: "02ab", sig: "1f")
        let error = await #expect(throws: PeelError.self) {
            _ = try await BoxClient(box: URL(string: "http://127.0.0.1:\(stub.port)")!).link(challenge, signed: signed, name: nil, now: Self.now)
        }
        #expect(error?.description.contains(words) == true, "\(error?.description ?? "")")
    }

    /// Renewing asks the box for a fresh challenge, signs it only when it is
    /// for the box's own host, and keeps the new token; a key the member
    /// unlinked is `.unlinked`.
    @Test func renewingSignsAFreshChallengeForTheBoxAlone() async throws {
        let fresh = Self.challenge(host: "127.0.0.1", actor: nil, name: nil)
        let unlinked = OSAllocatedUnfairLock(initialState: false)
        let stub = try await HTTPStub(respond: { _, request in
            if request.hasPrefix("GET /people/challenge ") { return (200, #"{"challenge":"\#(fresh)","exp":\#(Self.nowMs + 60_000)}"#) }
            if unlinked.withLock({ $0 }) { return (403, #"{"error":"not_linked: sphinx:02ab is not linked to a person here"}"#) }
            return (200, BoxFixture.answer(token: "strut-person.renewed"))
        })
        defer { stub.stop() }
        let box = BoxFixture.box("http://127.0.0.1:\(stub.port)", renewedAt: Self.now.addingTimeInterval(-90_000))
        let signedFor = OSAllocatedUnfairLock<[String]>(initialState: [])
        let sign: @Sendable (BoxChallenge) async throws -> VisitorSignature = { challenge in
            signedFor.withLock { $0.append(challenge.text) }
            return VisitorSignature(key: "02ab", sig: "1f")
        }
        let later = Self.now.addingTimeInterval(10)
        guard case .renewed(let renewed) = try await BoxClient(box: box.url).renew(box, now: later, sign: sign) else {
            Issue.record("not renewed")
            return
        }
        #expect(renewed.token == "strut-person.renewed" && renewed.renewedAt == later && renewed.linkedAt == box.linkedAt)
        #expect(signedFor.withLock { $0 } == [fresh])
        let posted = try #require(stub.requests.last)
        #expect(posted.hasPrefix("POST /people/token "))
        #expect(HTTPStub.jsonBody(of: posted) == ["challenge": fresh, "key": "02ab", "sig": "1f"])
        unlinked.withLock { $0 = true }
        #expect(try await BoxClient(box: box.url).renew(box, now: later, sign: sign) == .unlinked)
    }

    /// A renewal challenge for another host is never signed.
    @Test func aRenewalChallengeForAnotherHostIsNeverSigned() async throws {
        let challenge = Self.challenge(host: "evil.example.com", actor: nil, name: nil)
        let stub = try await HTTPStub(reply: { _, _ in #"{"challenge":"\#(challenge)","exp":1}"# })
        defer { stub.stop() }
        let signed = OSAllocatedUnfairLock(initialState: 0)
        await #expect(throws: PeelError.self) {
            _ = try await BoxClient(box: URL(string: "http://127.0.0.1:\(stub.port)")!)
                .renew(BoxFixture.box("http://127.0.0.1:\(stub.port)"), now: Self.now) { _ in
                    signed.withLock { $0 += 1 }
                    return VisitorSignature(key: "02ab", sig: "1f")
                }
        }
        #expect(signed.withLock { $0 } == 0)
        #expect(stub.requests.count == 1)
    }
}
