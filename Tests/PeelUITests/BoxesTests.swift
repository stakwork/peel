import Foundation
import os
import Testing
@testable import PeelCore
@testable import PeelTestSupport
@testable import PeelUI

/// The strut boxes the Mac and the iPhone share (`Boxes`): a link signed
/// only on the person's yes and kept, renewed when due, let go when its
/// member removed it, and a refused token renewed once before a box opens.
/// Each against a stand-in strut on this machine, from a development profile.
@MainActor @Suite(.timeLimit(.minutes(1)))
struct BoxesTests {
    /// A development profile in a folder of its own.
    private func profile() throws -> Profile {
        let folder = FileManager.default.temporaryDirectory.appending(path: "boxes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return Profile(developmentAt: folder)
    }

    /// Waits for `done`, a few seconds at most.
    private func until(_ done: () -> Bool) async {
        for _ in 0..<100 where !done() { try? await Task.sleep(for: .milliseconds(50)) }
    }

    /// A model on `profile` whose account signs as `02ab`, counting its signatures.
    private func boxes(on profile: Profile, signed: OSAllocatedUnfairLock<Int>) -> Boxes {
        let boxes = Boxes()
        boxes.sign = { _ in
            signed.withLock { $0 += 1 }
            return VisitorSignature(key: "02ab", sig: "1f")
        }
        boxes.accountName = { "Ada on Sphinx" }
        boxes.open(profile)
        return boxes
    }

    /// No signs nothing and asks nothing; yes signs once, posts the link
    /// with the account's name, and keeps the box the answer names.
    @Test func aBoxIsLinkedOnlyOnTheYes() async throws {
        let stub = try await HTTPStub(reply: { _, _ in BoxFixture.answer() })
        defer { stub.stop() }
        let profile = try profile()
        let signed = OSAllocatedUnfairLock(initialState: 0)
        let boxes = boxes(on: profile, signed: signed)
        defer { boxes.close() }
        let offer = try #require(BoxLinkOffer(box: "http://127.0.0.1:\(stub.port)",
                                              challenge: BoxFixture.challenge(host: "127.0.0.1", exp: BoxFixture.later)))
        boxes.take(offer)
        #expect(boxes.asking == offer)
        boxes.decline()
        #expect(boxes.asking == nil && boxes.accept() == nil)
        #expect(signed.withLock { $0 } == 0 && stub.requests.isEmpty)

        boxes.take(offer)
        await boxes.accept()?.value
        #expect(boxes.asking == nil && boxes.linking == nil && boxes.problem == nil)
        #expect(signed.withLock { $0 } == 1)
        #expect(HTTPStub.jsonBody(of: try #require(stub.requests.first))?["name"] == "Ada on Sphinx")
        #expect(boxes.links.map(\.actor) == ["ada-3f9a"] && boxes.links.first?.url == offer.box)
        #expect(try Self.kept(profile) == boxes.links.map(\.token))
    }

    /// The tokens of the boxes `profile` keeps.
    private static func kept(_ profile: Profile) throws -> [String] {
        try BoxLink.read(from: profile.boxes).map(\.token)
    }

    /// A link Peel will not sign is said, and never asked.
    @Test func aLinkForAnotherHostIsNeverAsked() throws {
        let boxes = boxes(on: try profile(), signed: OSAllocatedUnfairLock(initialState: 0))
        defer { boxes.close() }
        boxes.take(try #require(BoxLinkOffer(box: "https://box.example.com",
                                             challenge: BoxFixture.challenge(host: "evil.example.com", exp: BoxFixture.later))))
        #expect(boxes.asking == nil && boxes.problem?.contains("evil.example.com") == true)
    }

    /// As the account opens, a box due is renewed and kept with its new
    /// token; one whose member removed the link there (`403 not_linked`) is
    /// let go and said, and gone from what is kept.
    @Test func aDueBoxIsRenewedAndAnUnlinkedOneLetGo() async throws {
        let renews = try await Self.strut(token: { _ in (200, BoxFixture.answer(token: "strut-person.renewed")) })
        let unlinked = try await Self.strut(token: { _ in (403, #"{"error":"not_linked: sphinx:02ab is not linked"}"#) })
        defer { renews.stop(); unlinked.stop() }
        let profile = try profile()
        let dayAgo = Date().addingTimeInterval(-90_000)
        try BoxLink.write([BoxFixture.box("http://127.0.0.1:\(renews.port)", renewedAt: dayAgo),
                           BoxFixture.box("http://127.0.0.1:\(unlinked.port)", renewedAt: dayAgo)], to: profile.boxes)
        let boxes = boxes(on: profile, signed: OSAllocatedUnfairLock(initialState: 0))
        defer { boxes.close() }
        await until { boxes.links.count == 1 && boxes.links.first?.token == "strut-person.renewed" }
        #expect(boxes.links.map(\.url.port) == [Int(renews.port)])
        #expect(boxes.notice?.contains("removed Peel's link") == true)
        #expect(try Self.kept(profile) == ["strut-person.renewed"])
    }

    /// A box that refuses the token kept (401) is renewed once and opens
    /// with the new one, as the first request's bearer; one whose renewal
    /// says the link is gone does not open and is let go.
    @Test func aRefusedTokenIsRenewedOnceBeforeTheBoxOpens() async throws {
        let linked = OSAllocatedUnfairLock(initialState: true)
        let stub = try await Self.strut(token: { _ in
            linked.withLock { $0 } ? (200, BoxFixture.answer(token: "strut-person.renewed")) : (403, #"{"error":"not_linked: gone"}"#)
        }, apps: { request in
            request.contains("Bearer strut-person.renewed") ? (200, #"{"apps":[]}"#) : (401, #"{"error":"no longer linked"}"#)
        })
        defer { stub.stop() }
        let profile = try profile()
        let base = "http://127.0.0.1:\(stub.port)/lab"
        try BoxLink.write([BoxFixture.box(base, renewedAt: Date())], to: profile.boxes)
        let boxes = boxes(on: profile, signed: OSAllocatedUnfairLock(initialState: 0))
        defer { boxes.close() }
        let page = try await boxes.home(of: try #require(boxes.links.first))
        #expect(page.token == "strut-person.renewed" && page.url.absoluteString == base + "/")
        #expect(page.request.value(forHTTPHeaderField: "Authorization") == "Bearer strut-person.renewed")
        #expect(boxes.shows(page) && boxes.links.first?.token == "strut-person.renewed")

        linked.withLock { $0 = false }
        try BoxLink.write([BoxFixture.box(base, renewedAt: Date())], to: profile.boxes)
        boxes.open(profile)
        #expect(await boxes.page(of: try #require(boxes.links.first)) == nil)
        #expect(boxes.links.isEmpty && boxes.notice?.contains("removed Peel's link") == true)
        #expect(!boxes.shows(page))
    }

    /// A stand-in strut: a renewal's challenge for 127.0.0.1, `token`'s
    /// answer to `POST /people/token`, and `apps`' to `GET /apps`.
    private static func strut(
        token: @escaping @Sendable (String) -> (Int, String),
        apps: @escaping @Sendable (String) -> (Int, String) = { _ in (200, #"{"apps":[]}"#) }
    ) async throws -> HTTPStub {
        try await HTTPStub(respond: { _, request in
            let line = request.prefix(while: { $0 != "\r" })
            if line.contains(" /people/challenge ") || line.contains("/people/challenge HTTP") {
                let challenge = BoxFixture.challenge(host: "127.0.0.1", actor: nil, name: nil, exp: BoxFixture.later)
                return (200, #"{"challenge":"\#(challenge)","exp":1}"#)
            }
            if line.contains("/people/token") { return token(request) }
            if line.contains("/apps") { return apps(request) }
            return (404, #"{"error":"not here"}"#)
        })
    }
}
