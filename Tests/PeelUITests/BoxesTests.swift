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
    /// The test's profile folder, removed with it.
    private let folder = TempProfile()

    /// A development profile in the test's own folder.
    private func profile() throws -> Profile {
        try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
        return Profile(developmentAt: folder.url)
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
        let stub = try await HTTPStub(reply: { _, _ in BoxFixture.answer(exp: BoxFixture.later) })
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

    /// What the account kept that cannot be read is never written over: a
    /// link is refused rather than kept in place of every box there.
    @Test func boxesThatCannotBeReadAreNeverWrittenOver() async throws {
        let stub = try await HTTPStub(reply: { _, _ in BoxFixture.answer(exp: BoxFixture.later) })
        defer { stub.stop() }
        let profile = try profile()
        try profile.boxes.write(Data("not what Peel keeps".utf8))
        let signed = OSAllocatedUnfairLock(initialState: 0)
        let boxes = boxes(on: profile, signed: signed)
        defer { boxes.close() }
        #expect(boxes.links.isEmpty && boxes.problem != nil)
        boxes.take(try #require(BoxLinkOffer(box: "http://127.0.0.1:\(stub.port)",
                                             challenge: BoxFixture.challenge(host: "127.0.0.1", exp: BoxFixture.later))))
        #expect(boxes.accept() == nil && boxes.problem?.contains("couldn't read") == true)
        #expect(signed.withLock { $0 } == 0 && stub.requests.isEmpty)
        #expect(try profile.boxes.read() == Data("not what Peel keeps".utf8))
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
        let renews = try await Self.strut(token: { _ in (200, BoxFixture.answer(token: "strut-person.renewed", exp: BoxFixture.later)) })
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
            linked.withLock { $0 } ? (200, BoxFixture.answer(token: "strut-person.renewed", exp: BoxFixture.later)) : (403, #"{"error":"not_linked: gone"}"#)
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

    /// A box's places (docs/hive-tribes.md, "From a box") are read, added
    /// to and removed from as its member, with the token kept; one the box
    /// no longer takes (401) is renewed once and the call made again with
    /// the new token. A read that fails says why and keeps what was read;
    /// a box forgotten takes its places with it. Only a tribe added here
    /// names its box's Jamie for approval, never one the box's list names.
    @Test func aBoxsPlacesAreReadAndChangedAsItsMember() async throws {
        let tribe = String(repeating: "ab", count: 33), jamie = String(repeating: "0c", count: 33)
        let theirs = String(repeating: "cd", count: 33)
        let held = OSAllocatedUnfairLock<Set<String>>(initialState: [theirs])
        let failing = OSAllocatedUnfairLock(initialState: false)
        let stub = try await Self.strut(token: { _ in (200, BoxFixture.answer(token: "strut-person.renewed", exp: BoxFixture.later)) }, places: { request in
            guard request.contains("Bearer strut-person.renewed") else { return (401, #"{"error":"unauthorized"}"#) }
            if failing.withLock({ $0 }) { return (500, #"{"error":"the box is restarting"}"#) }
            if request.hasPrefix("POST ") {
                held.withLock { _ = $0.insert(HTTPStub.jsonBody(of: request)?["key"] ?? "") }
                return (200, #"{"place":{"host":"sphinx","key":"\#(tribe)","link":"l","account":"sphinx:02ab","at":1},"account":"sphinx:\#(jamie)"}"#)
            }
            if request.hasPrefix("DELETE ") { return (200, #"{"removed":\#(held.withLock { $0.remove(tribe) != nil })}"#) }
            let places = held.withLock { $0 }.map { #"{"host":"sphinx","key":"\#($0)","link":"l","account":"sphinx:02ab","at":1}"# }
            return (200, #"{"hosts":[{"host":"sphinx","account":"sphinx:\#(jamie)"}],"places":[\#(places.joined(separator: ","))]}"#)
        })
        defer { stub.stop() }
        let profile = try profile()
        try BoxLink.write([BoxFixture.box("http://127.0.0.1:\(stub.port)", renewedAt: Date(), exp: Date().addingTimeInterval(7 * 86_400))],
                          to: profile.boxes)
        let signed = OSAllocatedUnfairLock(initialState: 0)
        let boxes = boxes(on: profile, signed: signed)
        defer { boxes.close() }
        let box = try #require(boxes.links.first)

        await boxes.readPlaces()
        #expect(boxes.places[box.url] == BoxPlaces(jamie: jamie, tribes: [theirs]))
        #expect(boxes.links.first?.token == "strut-person.renewed" && signed.withLock { $0 } == 1)
        // A tribe the box's own list names, but not added here: its Jamie is never approved unasked.
        #expect(boxes.jamiesAdded(in: theirs).isEmpty)

        let record = Tribe(pubkey: tribe, name: "Builders", host: "tribes.example.com", isOwner: true)
        #expect(try await boxes.addJamie(to: record, from: box) == jamie)
        #expect(boxes.places[box.url]?.tribes == [theirs, tribe] && boxes.jamiesAdded(in: tribe) == [jamie])
        let posted = try #require(stub.requests.last { $0.hasPrefix("POST /people/places ") })
        #expect(HTTPStub.jsonBody(of: posted) == ["host": "sphinx", "key": tribe, "link": try #require(record.link), "name": "Builders"])
        #expect(try await boxes.removeJamie(from: tribe, on: box) == jamie)
        #expect(boxes.places[box.url]?.tribes == [theirs] && held.withLock { $0 } == [theirs])
        #expect(boxes.jamiesAdded(in: tribe).isEmpty)
        #expect(try await boxes.removeJamie(from: tribe, on: box) == nil)
        #expect(signed.withLock { $0 } == 1)

        failing.withLock { $0 = true }
        await boxes.readPlaces()
        #expect(boxes.placesProblems[box.url]?.contains("restarting") == true)
        #expect(boxes.places[box.url] == BoxPlaces(jamie: jamie, tribes: [theirs]))
        boxes.forget(box)
        #expect(boxes.places.isEmpty && boxes.placesProblems.isEmpty)
    }

    /// A box's Jamie in a group call (docs/hive-calls.md, "From a box"):
    /// asked in as the member only once the box says it is ready on the
    /// call server's LiveKit, never while it loads; the person's own ticket
    /// from whichever box has Jamie in the room, the first to give one, and
    /// none after the wait when a box is slow: the join never waits on it.
    @Test func aBoxsJamieComesIntoACallOnlyWhenReadyAndGivesThePersonsTicket() async throws {
        let callServer = "127.0.0.1:7880"
        let call = try CallLink.new(server: callServer, audioOnly: true, encrypted: true), room = call.room
        let ticket = #"{"url":"ws://127.0.0.1:7880","room":"\#(room)","token":"t","identity":"box_0123456789abcdef0123456789abcdef","agent":"jamie_ab12"}"#
        let voice = { (ready: Bool, inRoom: Bool, slow: Bool) -> @Sendable (String) -> (Int, String) in
            { request in
                if request.hasPrefix("GET ") { return (200, #"{"group":\#(ready),"livekit":"ws://127.0.0.1:7880"}"#) }
                if request.contains("/voice/calls/ticket") {
                    if slow { Thread.sleep(forTimeInterval: 3) }
                    return inRoom && HTTPStub.jsonBody(of: request)?["room"] == room ? (200, ticket) : (404, #"{"error":"not in that call"}"#)
                }
                return (200, #"{"agent":"jamie-1","encrypted":true}"#)
            }
        }
        let renewed: @Sendable (String) -> (Int, String) = { _ in (200, BoxFixture.answer(token: "strut-person.renewed", exp: BoxFixture.later)) }
        let inCall = try await Self.strut(token: renewed, voice: voice(true, true, false))
        let slow = try await Self.strut(token: renewed, voice: voice(true, false, true))
        let loading = try await Self.strut(token: renewed, voice: voice(false, false, false))
        defer { [inCall, slow, loading].forEach { $0.stop() } }
        let profile = try profile()
        try BoxLink.write([inCall, slow, loading].map { BoxFixture.box("http://127.0.0.1:\($0.port)", renewedAt: Date(),
                                                                       exp: Date().addingTimeInterval(7 * 86_400)) }, to: profile.boxes)
        let boxes = boxes(on: profile, signed: OSAllocatedUnfairLock(initialState: 0))
        defer { boxes.close() }
        let (inCallBox, loadingBox) = (boxes.links[0], boxes.links[2])
        let link = try CallLink.new(server: callServer, audioOnly: true, encrypted: true)

        try await boxes.startCall(on: inCallBox, link: link, record: true, callServer: callServer)
        let asked = try #require(inCall.requests.last { $0.hasPrefix("POST /voice/calls ") })
        #expect(asked.contains("Bearer \(inCallBox.token)") && asked.contains(#""room":"\#(link.room)""#))
        #expect(boxes.calls[inCallBox.url]?.joins(callServer: callServer) == true)
        let refused = await #expect(throws: PeelError.self) {
            try await boxes.startCall(on: loadingBox, link: link, record: false, callServer: callServer)
        }
        #expect(refused?.description.contains("can't join calls yet") == true)
        #expect(!loading.requests.contains { $0.hasPrefix("POST ") })

        let clock = ContinuousClock()
        let started = clock.now
        let mine = await boxes.callTicket(for: call, name: "Ada", callServer: callServer)
        #expect(mine?.identity == "box_0123456789abcdef0123456789abcdef")
        // The box that gave it is the one whose Jamie's screen may be its app there.
        #expect(await boxes.screen(try #require(URL(string: "http://127.0.0.1:\(inCall.port)/?app=canvas")), in: call, from: "jamie_ab12") != nil)
        #expect(await boxes.screen(try #require(URL(string: "http://127.0.0.1:\(slow.port)/?app=canvas")), in: call, from: "jamie_ab12") == nil)
        let other = try CallLink.new(server: callServer, audioOnly: true, encrypted: true)
        #expect(await boxes.callTicket(for: other, name: "Ada", callServer: callServer, wait: .milliseconds(300)) == nil)
        #expect(clock.now - started < .seconds(2))
        // A box still loading, or on another call server's LiveKit, has no Jamie in this call: it is not told the room.
        #expect(!loading.requests.contains { $0.contains("/voice/calls/ticket") })
        let elsewhere = inCall.requests.count
        #expect(await boxes.callTicket(for: call, name: "Ada", callServer: "calls.example.com") == nil)
        #expect(inCall.requests.count == elsewhere)
    }

    /// A box that says it can't record on the canvas (stadeum
    /// plans/call-canvas.md §8) is not offered it, and a call asked to
    /// record there brings its Jamie without; one from before says nothing
    /// and is asked as before.
    @Test func aBoxThatCantRecordIsNeverAskedTo() async throws {
        let callServer = "127.0.0.1:7880"
        let voice = { (record: String) -> @Sendable (String) -> (Int, String) in
            { request in
                request.hasPrefix("GET ")
                    ? (200, #"{"group":true,"livekit":"ws://127.0.0.1:7880"\#(record)}"#)
                    : (200, #"{"agent":"jamie-1","encrypted":true}"#)
            }
        }
        let renewed: @Sendable (String) -> (Int, String) = { _ in (200, BoxFixture.answer(token: "strut-person.renewed", exp: BoxFixture.later)) }
        let cant = try await Self.strut(token: renewed, voice: voice(#","record":false"#))
        let older = try await Self.strut(token: renewed, voice: voice(""))
        defer { [cant, older].forEach { $0.stop() } }
        let profile = try profile()
        try BoxLink.write([cant, older].map { BoxFixture.box("http://127.0.0.1:\($0.port)", renewedAt: Date(),
                                                              exp: Date().addingTimeInterval(7 * 86_400)) }, to: profile.boxes)
        let boxes = boxes(on: profile, signed: OSAllocatedUnfairLock(initialState: 0))
        defer { boxes.close() }
        await boxes.readCalls()
        #expect(!boxes.records(on: boxes.links[0]) && boxes.records(on: boxes.links[1]))

        for (stub, (box, records)) in zip([cant, older], zip(boxes.links, [false, true])) {
            try await boxes.startCall(on: box, link: try CallLink.new(server: callServer, audioOnly: true, encrypted: true),
                                      record: true, callServer: callServer)
            let asked = try #require(stub.requests.last { $0.hasPrefix("POST /voice/calls ") })
            #expect(asked.contains(#""record":true"#) == records)
        }
    }

    /// Jamie's screen (stadeum plans/call-canvas.md §6.5) opens as the
    /// app it names on the linked box whose Jamie is in that call, shared
    /// by that Jamie, as the box's member: strut's UI showing that app alone
    /// at that view, the token as its bearer once the box takes it. Shared
    /// by anyone else (anyone can take Jamie's name and attributes), in any
    /// other call (the same room with another key, or none, included), or
    /// on any other address, it opens nothing and asks no box.
    @Test func jamiesScreenOpensOnTheBoxInTheCallAsItsMember() async throws {
        let renewed: @Sendable (String) -> (Int, String) = { _ in (200, BoxFixture.answer(token: "strut-person.renewed", exp: BoxFixture.later)) }
        let voice: @Sendable (String) -> (Int, String) = { request in
            request.hasPrefix("GET ") ? (200, #"{"group":true,"livekit":"ws://127.0.0.1:7880"}"#) : (200, #"{"agent":"jamie-1","encrypted":true}"#)
        }
        let stub = try await Self.strut(token: renewed, voice: voice)
        defer { stub.stop() }
        let profile = try profile()
        let kept = BoxFixture.box("http://127.0.0.1:\(stub.port)", renewedAt: Date(), exp: Date().addingTimeInterval(7 * 86_400))
        try BoxLink.write([kept], to: profile.boxes)
        let boxes = boxes(on: profile, signed: OSAllocatedUnfairLock(initialState: 0))
        defer { boxes.close() }
        let screen = try #require(URL(string: "http://127.0.0.1:\(stub.port)/?app=stadeum%2Fcanvas%2Fcanvas&input=present%3Dcall-1"))
        let link = try CallLink.new(server: "127.0.0.1:7880", audioOnly: true, encrypted: true)
        #expect(await boxes.screen(screen, in: link, from: "jamie-1") == nil)

        try await boxes.startCall(on: boxes.links[0], link: link, record: false, callServer: "127.0.0.1:7880")
        let page = try #require(await boxes.screen(screen, in: link, from: "jamie-1"))
        #expect(page.url.absoluteString == "http://127.0.0.1:\(stub.port)/?app=stadeum%2Fcanvas%2Fcanvas&input=present%3Dcall-1&solo=1")
        #expect(page.request.value(forHTTPHeaderField: "Authorization") == "Bearer \(kept.token)")
        #expect(boxes.shows(page))
        #expect(stub.requests.contains { $0.hasPrefix("GET /apps ") && $0.contains("Bearer \(kept.token)") })

        let asked = stub.requests.count
        let keyless = try #require(CallLink(link: link.url.absoluteString.components(separatedBy: "#")[0], server: "127.0.0.1:7880"))
        #expect(keyless.room == link.room && keyless.encryptionKey == nil)
        #expect(await boxes.screen(screen, in: link, from: "Jamie__a1b2") == nil)
        #expect(await boxes.screen(screen, in: keyless, from: "jamie-1") == nil)
        #expect(await boxes.screen(screen, in: try CallLink.new(server: "127.0.0.1:7880", audioOnly: true, encrypted: true), from: "jamie-1") == nil)
        #expect(await boxes.screen(try #require(URL(string: "https://strut.other.example/?app=canvas")), in: link, from: "jamie-1") == nil)
        #expect(stub.requests.count == asked)
    }

    /// A stand-in strut: a renewal's challenge for 127.0.0.1, `token`'s
    /// answer to `POST /people/token`, `apps`' to `GET /apps`, `places`'
    /// to `/people/places`, and `voice`'s to `/voice/calls` and its ticket.
    private static func strut(
        token: @escaping @Sendable (String) -> (Int, String),
        apps: @escaping @Sendable (String) -> (Int, String) = { _ in (200, #"{"apps":[]}"#) },
        places: @escaping @Sendable (String) -> (Int, String) = { _ in (404, #"{"error":"not here"}"#) },
        voice: @escaping @Sendable (String) -> (Int, String) = { _ in (404, #"{"error":"not here"}"#) }
    ) async throws -> HTTPStub {
        try await HTTPStub(respond: { _, request in
            let line = request.prefix(while: { $0 != "\r" })
            if line.contains(" /people/challenge ") || line.contains("/people/challenge HTTP") {
                let challenge = BoxFixture.challenge(host: "127.0.0.1", actor: nil, name: nil, exp: BoxFixture.later)
                return (200, #"{"challenge":"\#(challenge)","exp":1}"#)
            }
            if line.contains("/people/token") { return token(request) }
            if line.contains("/people/places") { return places(request) }
            if line.contains("/voice/calls") { return voice(request) }
            if line.contains("/apps") { return apps(request) }
            return (404, #"{"error":"not here"}"#)
        })
    }
}
