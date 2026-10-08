import Foundation
import Network
import os
import Testing
@testable import PeelCore

private let room = "sphinx.call.0123456789abcdef0123456789abcdef"
private let production = URL(string: "https://chat.sphinx.chat")!
private let local = URL(string: "http://127.0.0.1:7880")!

/// A checked link to `room` on `server`, with `query` after it.
private func link(on server: String, _ query: String = "") -> CallLink {
    let scheme = server.hasPrefix("127.0.0.1") ? "http" : "https"
    return CallLink(link: "\(scheme)://\(server)/rooms/\(room)\(query)", server: server)!
}

/// An unsigned LiveKit-shaped token with these claims.
private func token(_ claims: [String: Any]) -> String {
    let body = MediaToken.base64URLEncode(try! JSONSerialization.data(withJSONObject: claims)).replacingOccurrences(of: "=", with: "")
    return "eyJhbGciOiJIUzI1NiJ9.\(body).c2lnbmF0dXJl"
}

private func claims(room: String = room, exp: Double = Date.now.timeIntervalSince1970 + 3600) -> [String: Any] {
    ["sub": "alice-1", "exp": exp, "video": ["room": room, "roomJoin": true]]
}

struct CallTicketRequestTests {
    private func query(_ url: URL?) -> [String] {
        url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.percentEncodedQuery }?
            .split(separator: "&").map(String.init) ?? []
    }

    @Test func encodesEveryValueStrictly() throws {
        let url = CallServer.ticketURL(
            base: production, link: link(on: "chat.sphinx.chat", "?callKey=ab+c/d=&hiveToken=eyJ.eyJ.s-_"),
            participantName: "Al ice+1&isHost=true", photoURL: "https://x.io/a.jpg?s=1&t=2"
        )
        #expect(url?.path == "/api/connection-details")
        #expect(url?.host == "chat.sphinx.chat")
        #expect(query(url) == [
            "roomName=\(room)",
            "participantName=Al%20ice%2B1%26isHost%3Dtrue",
            "metadata=%7B%22profilePictureUrl%22%3A%22https%3A%2F%2Fx.io%2Fa.jpg%3Fs%3D1%26t%3D2%22%7D",
            "callKey=ab%2Bc%2Fd%3D",
            "hiveToken=eyJ.eyJ.s-_",
        ])
        // Decoded as a server would, the values come back exactly, and no `isHost` is ever asked for.
        let parts = try #require(url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) })
        let items = parts.queryItems ?? []
        #expect(items.first { $0.name == "callKey" }?.value == "ab+c/d=")
        #expect(items.first { $0.name == "metadata" }?.value == #"{"profilePictureUrl":"https://x.io/a.jpg?s=1&t=2"}"#)
        #expect(!items.contains { $0.name == "isHost" })
    }

    @Test func leavesOutWhatIsNotThere() {
        let url = CallServer.ticketURL(base: local, link: link(on: "127.0.0.1:7880"), participantName: "bob", photoURL: nil)
        #expect(url?.absoluteString == "http://127.0.0.1:7880/api/connection-details?roomName=\(room)&participantName=bob")
    }
}

struct CallTicketCheckTests {
    @Test func acceptsTheCallServerItself() throws {
        let ticket = try CallServer.ticket(serverURL: "wss://chat.sphinx.chat", token: token(claims()), room: room, callServer: production)
        #expect(ticket.serverURL.absoluteString == "wss://chat.sphinx.chat")
        #expect(ticket.identity == "alice-1")
        #expect(!ticket.roomAdmin)
        #expect(try CallServer.mediaURL("wss://CHAT.sphinx.chat:443/rtc", callServer: production).host == "CHAT.sphinx.chat")
        #expect(try CallServer.mediaURL("ws://127.0.0.1:7880", callServer: local).port == 7880)
    }

    @Test(arguments: [
        "wss://evil.example.com", "wss://chat.sphinx.chat.evil.com", "wss://x.chat.sphinx.chat", "wss://sphinx.livekit.cloud",
        "ws://chat.sphinx.chat", "https://chat.sphinx.chat", "wss://chat.sphinx.chat:7880", "wss://u:p@chat.sphinx.chat",
        "wss://chat.sphinx.chat?x=1", "wss://chat.sphinx.chat#x", "", "not a url",
    ])
    func refusesAnyOtherMediaServer(serverURL: String) {
        #expect(throws: CallServer.Failure.self) {
            try CallServer.ticket(serverURL: serverURL, token: token(claims()), room: room, callServer: production)
        }
    }

    @Test(arguments: ["ws://127.0.0.1:7881", "ws://localhost:7880", "wss://127.0.0.1:7881", "ws://127.0.0.1"])
    func refusesAnotherPortOrHostOnALocalServer(serverURL: String) {
        #expect(throws: CallServer.Failure.self) { try CallServer.mediaURL(serverURL, callServer: local) }
    }

    @Test func namesTheRefusedHostOnlyWhenPlain() {
        #expect(throws: CallServer.Failure.mediaHostNotAllowed("abc.livekit.cloud:443")) {
            try CallServer.mediaURL("wss://abc.livekit.cloud", callServer: production)
        }
        #expect(throws: CallServer.Failure.mediaHostNotAllowed(nil)) {
            try CallServer.mediaURL("wss://a%1Bb.example", callServer: production)
        }
    }

    @Test func checksTheTokensClaims() {
        func check(_ token: String) throws { _ = try CallServer.ticket(serverURL: "wss://chat.sphinx.chat", token: token, room: room, callServer: production) }
        #expect(throws: CallServer.Failure.tokenForAnotherRoom) { try check(token(claims(room: "sphinx.call.other"))) }
        #expect(throws: CallServer.Failure.tokenForAnotherRoom) { try check(token(["sub": "a", "exp": 4e9])) }
        #expect(throws: CallServer.Failure.tokenExpired) { try check(token(claims(exp: Date.now.timeIntervalSince1970 - 1))) }
        #expect(throws: CallServer.Failure.malformedToken) { try check(token(["exp": 4e9, "video": ["room": room]])) }
        #expect(throws: CallServer.Failure.malformedToken) { try check(token(["sub": "a", "video": ["room": room]])) }
        #expect(throws: CallServer.Failure.malformedToken) { try check(token(["sub": "a\u{1B}[2J", "exp": 4e9, "video": ["room": room]])) }
        #expect(throws: CallServer.Failure.malformedToken) { try check("abc.def") }
        #expect(throws: CallServer.Failure.malformedToken) { try check("a.!!!.c") }
        #expect(throws: CallServer.Failure.malformedToken) { try check("a.\(MediaToken.base64URLEncode(Data("[1]".utf8))).c") }
    }

    @Test func readsTheAdminGrant() throws {
        var admin = claims()
        admin["video"] = ["room": room, "roomAdmin": true]
        #expect(try CallServer.ticket(serverURL: "wss://chat.sphinx.chat", token: token(admin), room: room, callServer: production).roomAdmin)
    }

    @Test func neverDescribesTheToken() throws {
        let secret = token(claims())
        let ticket = try CallServer.ticket(serverURL: "wss://chat.sphinx.chat", token: secret, room: room, callServer: production)
        var dumped = ""
        dump(ticket, to: &dumped)
        for text in ["\(ticket)", String(describing: ticket), String(reflecting: ticket), dumped] {
            #expect(!text.contains(secret))
            #expect(!text.contains(secret.split(separator: ".")[1]))
        }
    }

    @Test func errorsNeverCarryTheURL() async throws {
        // Nothing listens on port 1; the Hive key must not reach the error.
        let server = try CallServer(host: "127.0.0.1:1")
        await #expect(throws: CallServer.Failure.unreachable) {
            try await server.ticket(for: link(on: "127.0.0.1:1", "?callKey=SECRETKEY"), participantName: "a", photoURL: nil)
        }
    }
}

struct CallPresenceTests {
    private let alice = CallParticipant(identity: "alice-1", nickname: "Alice", avatarURL: URL(string: "https://example.com/a.jpg"))
    private let bob = CallParticipant(identity: "bob-2", nickname: "Bob", avatarURL: nil)

    @Test func readsEachMessageTheAppsRead() {
        let current = #"{"type":"current_participants","roomName":"\#(room)","participants":[{"identity":"alice-1","nickname":"Alice","avatarUrl":"https://example.com/a.jpg"},{"nickname":"no identity"}]}"#
        #expect(CallServer.update(from: current)?.change == .current([alice]))
        #expect(CallServer.update(from: current)?.room == room)
        let nested = #"{"type":"participant_joined","roomName":"\#(room)","participant":{"identity":"bob-2","nickname":"Bob"}}"#
        #expect(CallServer.update(from: nested)?.change == .joined(bob))
        let flat = #"{"type":"participant_joined","roomName":"\#(room)","identity":"bob-2","nickname":"Bob"}"#
        #expect(CallServer.update(from: flat)?.change == .joined(bob))
        #expect(CallServer.update(from: #"{"type":"participant_left","roomName":"\#(room)","identity":"bob-2"}"#)?.change == .left("bob-2"))
        #expect(CallServer.update(from: #"{"type":"room_finished","roomName":"\#(room)"}"#)?.change == .finished)
    }

    @Test(arguments: [
        #"{"type":"something_else","roomName":"\#(room)"}"#,
        #"{"type":"room_finished","roomName":"not.a.call"}"#,
        #"{"type":"room_finished"}"#,
        #"{"type":"participant_left","roomName":"\#(room)"}"#,
        #"{"type":"participant_joined","roomName":"\#(room)","participant":{"nickname":"x"}}"#,
        #"[1,2]"#, "", "not json",
    ])
    func ignoresWhatItCannotRead(text: String) {
        #expect(CallServer.update(from: text) == nil)
    }

    @Test(arguments: [
        "http://example.com/a.jpg", "https://192.168.1.1/a.jpg", "https://127.0.0.1/a.jpg", "https://printer.local/a.jpg",
        "https://u:p@example.com/a.jpg", "javascript:alert(1)", "file:///etc/passwd",
    ])
    func keepsOnlyPublicHTTPSPhotos(url: String) {
        #expect(CallServer.participant(["identity": "x", "avatarUrl": url])?.avatarURL == nil)
    }

    @Test func readsRoomParticipants() {
        let photo = #"{"profilePictureUrl":"https://example.com/a.jpg"}"#
        let person = CallParticipant(identity: "x", name: "Al\u{1B}ice\n", metadata: photo)
        #expect(person?.nickname == "Alice")
        #expect(person?.avatarURL?.absoluteString == "https://example.com/a.jpg")
        #expect(CallParticipant(identity: "x", name: nil, metadata: #"{"profilePictureUrl":"https://10.0.0.1/a.jpg"}"#)?.avatarURL == nil)
        #expect(CallParticipant(identity: "x", name: nil, metadata: "not json")?.avatarURL == nil)
        #expect(CallParticipant(identity: "x", name: nil, metadata: nil)?.nickname == "")
        #expect(CallParticipant(identity: "x\u{07}", name: "a", metadata: nil) == nil)
    }

    @Test func cleansNames() {
        let long = String(repeating: "a", count: 500)
        #expect(CallServer.participant(["identity": "x", "nickname": "Mal\u{1B}[2Jlory\n"])?.nickname == "Mal[2Jlory")
        #expect(CallServer.participant(["identity": "x", "nickname": long])?.nickname.count == CallServer.maxName)
        #expect(CallServer.participant(["identity": "x"])?.nickname == "")
        #expect(CallServer.participant(["identity": ""]) == nil)
        // An identity is matched exactly, so one that would need cleaning is refused.
        #expect(CallServer.participant(["identity": "x\u{1B}]0;pwned\u{07}"]) == nil)
        #expect(CallServer.participant(["identity": String(repeating: "i", count: 257)]) == nil)
        #expect(CallServer.update(from: #"{"type":"participant_left","roomName":"\#(room)","identity":"x\u001b"}"#) == nil)
    }

    @Test func followsJoinsLeavesAndTheEnd() {
        typealias S = CallServer
        // Joins and leaves before the first list say nothing about who else is there.
        #expect(S.applying(.joined(alice), to: .unknown) == .unknown)
        #expect(S.applying(.left("alice-1"), to: .unknown) == .unknown)
        let renamedFirst = CallParticipant(identity: "alice-1", nickname: "Old", avatarURL: nil)
        #expect(S.applying(.current([renamedFirst, bob, alice]), to: .unknown) == .live([bob, alice]))
        var presence = S.applying(.current([alice]), to: .unknown)
        presence = S.applying(.joined(bob), to: presence)
        #expect(presence == .live([alice, bob]))
        // The same identity again replaces the old entry.
        let renamed = CallParticipant(identity: "alice-1", nickname: "Al", avatarURL: nil)
        #expect(S.applying(.joined(renamed), to: presence) == .live([bob, renamed]))
        presence = S.applying(.left("alice-1"), to: presence)
        #expect(presence == .live([bob]))
        presence = S.applying(.finished, to: presence)
        #expect(presence == .ended)
        #expect(S.applying(.left("bob-2"), to: .ended) == .ended)
        #expect(S.applying(.joined(alice), to: .ended) == .live([alice]))
    }
}

/// A ticket fetched from a loopback HTTP stub, as the app would: it must
/// leave nothing in the shared URL cache and send no cookie back.
struct CallTicketFetchTests {
    @Test func fetchesWithoutCacheOrCookies() async throws {
        let secret = token(claims())
        let stub = try await HTTPStub { port in
            #"{"serverUrl":"ws://127.0.0.1:\#(port)","participantToken":"\#(secret)"}"#
        }
        defer { stub.stop() }
        let server = try CallServer(host: "127.0.0.1:\(stub.port)")
        for _ in 0..<2 {
            let ticket = try await server.ticket(for: link(on: "127.0.0.1:\(stub.port)", "?callKey=k+"), participantName: "a", photoURL: nil)
            #expect(ticket.serverURL.port == Int(stub.port))
            #expect(ticket.token == secret)
        }
        let requests = stub.requests
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { !$0.lowercased().contains("\r\ncookie:") })
        #expect(requests.first?.contains("&callKey=k%2B HTTP/1.1") == true)
        let base = try #require(URL(string: "http://127.0.0.1:\(stub.port)"))
        let url = try #require(CallServer.ticketURL(
            base: base, link: link(on: "127.0.0.1:\(stub.port)", "?callKey=k+"), participantName: "a", photoURL: nil
        ))
        #expect(URLCache.shared.cachedResponse(for: URLRequest(url: url)) == nil)
    }
}

/// A loopback HTTP server that answers every request with one cacheable,
/// cookie-setting JSON reply, and records each request's head. Also serves
/// the tribes registry in `AuditMoneyTests`.
final class HTTPStub: Sendable {
    private let listener: NWListener
    private let heads = OSAllocatedUnfairLock(initialState: [String]())
    let port: UInt16

    var requests: [String] { heads.withLock { $0 } }

    init(body: @escaping @Sendable (UInt16) -> String) async throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let record: @Sendable (String) -> Void = { [heads] head in heads.withLock { $0.append(head) } }
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
                record(String(decoding: data ?? Data(), as: UTF8.self))
                let body = body(listener.port?.rawValue ?? 0)
                let response = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n"
                    + "Cache-Control: max-age=3600\r\nSet-Cookie: stub=1; Path=/\r\nConnection: close\r\n\r\n" + body
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        port = try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    continuation.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: .global())
        }
        self.listener = listener
    }

    func stop() { listener.cancel() }
}

