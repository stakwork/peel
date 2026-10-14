import Foundation
import Testing
@testable import PeelCore
@testable import PeelTestSupport

// Regression tests for the network and calls audit
// (docs/reviews/2026-10-08-audit-network-calls.md). Each one pins a threat
// the audit found holding, or one it fixed. None of them reaches the network:
// every refusal checked here comes before a request would be made.

/// An engine whose account lives on `address`, with nothing else stored.
private func engine(_ profile: TempProfile, server address: String) throws -> Engine {
    let storage = try profile.storage()
    _ = try storage.apply(Storage.Commit(state: [:], settings: [.server: address]))
    return try testEngine(storage)
}

struct AuditTransportTests {
    /// T1.2: without a scheme only the exact loopback names go plaintext;
    /// anything that merely looks like this machine keeps TLS.
    @Test(arguments: [
        "localhost.example.com:1883", "127.0.0.2:1883", "LOCALHOST:1883", "127.0.0.1.nip.io:1883", "0.0.0.0:1883",
        "mqtt.sphinx.chat:8883",
    ])
    func onlyExactLoopbackSkipsTLS(string: String) throws {
        #expect(try #require(ServerAddress(string)).tls)
    }

    /// T1.3 (fixed): a server named by an invite or the public config may
    /// not ask for plaintext anywhere but this machine.
    @Test(arguments: ["mqtt://broker.example.com:1883", "tcp://broker.example.com:1883", "MQTT://10.0.0.1:1883"])
    func aNamedServerCannotTurnTLSOff(string: String) {
        #expect(throws: PeelError.self) { try ServerAddress.named(string) }
    }

    @Test func aNamedServerKeepsTLSAndLoopbackStillWorks() throws {
        #expect(try ServerAddress.named("broker.example.com:8883").tls)
        #expect(try ServerAddress.named("mqtts://broker.example.com:8883").tls)
        #expect(try !ServerAddress.named("mqtt://127.0.0.1:1883").tls)
        #expect(try !ServerAddress.named("localhost:1883").tls)
        #expect(throws: PeelError.self) { try ServerAddress.named("broker.example.com") }
    }

    /// T1.4: the tribes, memes and call hosts go over http only for this machine.
    @Test func plainHostsAreHTTPSExceptThisMachine() {
        #expect(TribeLink.baseURL("tribes.sphinx.chat")?.scheme == "https")
        #expect(TribeLink.baseURL("localhost.example.com:8000")?.scheme == "https")
        #expect(TribeLink.baseURL("127.0.0.1.nip.io")?.scheme == "https")
        #expect(TribeLink.baseURL("127.0.0.1:8000")?.scheme == "http")
        #expect(TribeLink.baseURL("localhost")?.scheme == "http")
        #expect(TribeLink.baseURL("tribes.example.com/x") == nil)
        #expect(TribeLink.baseURL("user@tribes.example.com") == nil)
    }

    /// T1.5: `Web.get` refuses before asking: plain http off this machine, and any address on this network.
    @Test(arguments: ["http://example.com/tribes/x", "https://192.168.1.1/tribes/x", "https://router.local/x", "ftp://example.com/x"])
    func webGetRefusesBeforeAnyRequest(string: String) async throws {
        let url = try #require(URL(string: string))
        await #expect(throws: PeelError.self) { try await Web.get(url, limit: 10, what: "the test") }
    }

    /// T1.6 (fixed): a tribe link naming this machine is refused on an
    /// account whose server is elsewhere, before anything is fetched.
    @Test(arguments: ["127.0.0.1:9", "localhost:9"])
    func aTribeLinkCannotPointARealAccountAtThisMachine(host: String) async throws {
        let profile = TempProfile()
        let engine = try engine(profile, server: "mqtts://lsp.example.com:8883")
        let link = "sphinx.chat://?action=tribeV2&pubkey=\(keyG)&host=\(host)"
        await #expect(throws: PeelError.self) { try await engine.tribeInfo(link: link) }
        await #expect(throws: PeelError.self) { try await engine.joinTribe(link: link, agreedJoinMsat: 1000) }
    }

    /// A link card reads a tribe only from the account's own tribes host:
    /// a host named in a message is never asked (nil comes back before any
    /// request; asking would fail here, offline).
    @Test(arguments: [nil, "tribes.example.com"])
    func aLinkCardNeverAsksAHostFromTheMessage(own: String?) async throws {
        let profile = TempProfile()
        let engine = try engine(profile, server: "mqtts://lsp.example.com:8883")
        if let own { try await engine.setTribeHost(own) }
        for host in ["evil.example.com", "127.0.0.1:9"] {
            let link = try #require(TribeLink("sphinx.chat://?action=tribeV2&pubkey=\(keyG)&host=\(host)"))
            #expect(try await engine.linkedTribeInfo(link) == nil)
        }
    }

    /// T1.7 (fixed): the memes server's redirects stay on https, keep the
    /// bearer token only on the host it was sent to, and reach plain http on
    /// this machine only from a memes server on this machine.
    @Test func memesRedirectsStayOnHTTPSAndDropTheToken() throws {
        func request(_ string: String, token: Bool = true) throws -> URLRequest {
            var request = URLRequest(url: try #require(URL(string: string)))
            if token { request.setValue("Bearer secret", forHTTPHeaderField: "Authorization") }
            return request
        }
        let production = try request("https://memes.sphinx.chat/file/x")
        let local = try request("http://127.0.0.1:5555/file/x")
        for target in ["http://127.0.0.1:8080/x", "http://localhost/x", "http://memes.sphinx.chat/file/x", "ftp://memes.sphinx.chat/x"] {
            #expect(MemesServer.redirect(try request(target), from: production) == nil)
        }
        let sameHost = try #require(MemesServer.redirect(try request("https://memes.sphinx.chat/file/y"), from: production))
        #expect(sameHost.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
        let elsewhere = try #require(MemesServer.redirect(try request("https://cdn.example.com/y"), from: production))
        #expect(elsewhere.value(forHTTPHeaderField: "Authorization") == nil)
        let otherPort = try #require(MemesServer.redirect(try request("https://memes.sphinx.chat:8443/y"), from: production))
        #expect(otherPort.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(MemesServer.redirect(try request("http://127.0.0.1:5555/file/y"), from: local) != nil)
    }
}

struct AuditCallTests {
    private let room = "sphinx.call.0123456789abcdef0123456789abcdef"

    /// T2.3: the media server allowlist is exact hosts only, never a
    /// wildcard or a suffix that would admit any LiveKit tenant. That any
    /// other host, and lookalikes of the recorded one, are refused is
    /// `CallTicketCheckTests.refusesAnyOtherMediaServer` and
    /// `refusesLookalikesOfTheOfficialMediaServer`.
    @Test func mediaHostsAreExactHosts() {
        #expect(CallServer.mediaHosts == ["chat.sphinx.chat": ["livekit.sphinx.chat"]])
        for (callServer, hosts) in CallServer.mediaHosts {
            #expect(TribeLink.isPlainHost(callServer))
            for host in hosts {
                #expect(TribeLink.isPlainHost(host) && !host.hasPrefix(".") && !host.hasPrefix("-"), "\(host)")
            }
        }
    }

    /// T2.1: the only metadata sent with a ticket request is the photo:
    /// no pubkey, no host flag.
    @Test func ticketMetadataIsThePhotoAlone() throws {
        let metadata = try #require(CallServer.metadata(photoURL: "https://memes.sphinx.chat/public/abc"))
        let fields = try #require(try JSONSerialization.jsonObject(with: Data(metadata.utf8)) as? [String: String])
        #expect(Set(fields.keys) == ["profilePictureUrl"])
        let link = try #require(CallLink(link: "https://chat.sphinx.chat/rooms/\(room)", server: "chat.sphinx.chat"))
        let url = try #require(CallServer.ticketURL(
            base: URL(string: "https://chat.sphinx.chat")!, link: link, participantName: "alice", photoURL: nil
        ))
        let names = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.map(\.name)
        #expect(names == ["roomName", "participantName"])
    }

    /// T2.4: Peel's own links are never Hive links and carry nothing but
    /// the room and the audio flag.
    @Test func newLinksCarryNoKeys() throws {
        let link = try CallLink.new(server: "chat.sphinx.chat", audioOnly: true)
        #expect(link.callKey == nil && link.hiveToken == nil)
        let query = URLComponents(url: link.url, resolvingAgainstBaseURL: false)?.queryItems?.map(\.name)
        #expect(query == ["startAudioOnly"])
        #expect(link.url.scheme == "https" && link.url.host == "chat.sphinx.chat")
    }

    /// T2.4: a Hive link on the call server is joined with its key, and
    /// the same link on any other host is only a link.
    @Test func hiveLinksAreJoinOnlyOnTheCallServer() throws {
        let hiveRoom = "sphinx.call.-hive.example.com-.781603422.512"
        let link = try #require(CallLink(
            message: "https://chat.sphinx.chat/rooms/\(hiveRoom)?callKey=abc", server: "chat.sphinx.chat"
        ))
        #expect(link.callKey == "abc")
        #expect(CallLink(message: "https://hive.example.com/rooms/\(hiveRoom)?callKey=abc", server: "chat.sphinx.chat") == nil)
        #expect(CallLink(message: "https://jitsi.sphinx.chat/\(hiveRoom)", server: "chat.sphinx.chat") == nil)
    }

    /// T2.2: a ticket or presence for a link on another call server is
    /// refused before any request, so a message cannot steer either.
    @Test func ticketsAndPresenceOnlyFromTheConfiguredServer() async throws {
        let profile = TempProfile()
        let engine = try engine(profile, server: "mqtts://lsp.example.com:8883")
        let elsewhere = try #require(CallLink(link: "https://calls.example.com/rooms/\(room)", server: "calls.example.com"))
        await #expect(throws: Engine.Failure.callOnAnotherServer) { try await engine.callTicket(for: elsewhere, in: nil) }
        await #expect(throws: Engine.Failure.callOnAnotherServer) { _ = try await engine.callPresence(of: elsewhere) }
    }

    /// T2.2: presence is never asked for a room that is not a call room;
    /// the stream ends at once and nothing is opened.
    @Test func presenceRefusesAnyOtherRoom() async throws {
        let server = try CallServer(host: "chat.sphinx.chat")
        for bad in ["", "other.room", "sphinx.call.a b", #"sphinx.call.x","action":"unsubscribe"#] {
            var updates = 0
            for await _ in await server.presence(room: bad) { updates += 1 }
            #expect(updates == 0)
        }
        await server.close()
    }
}

struct AuditPrivacyTests {
    /// T1.8: `setPushToken` must never be called; the server keeps one push
    /// token per account and would take notifications from the official app.
    /// Nothing outside the generated bindings names it.
    @Test func nothingCallsSetPushToken() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var checked = 0
        for folder in ["Sources/PeelCore", "Sources/PeelUI", "Sources/PeelApp", "Sources/peel"] {
            let directory = root.appendingPathComponent(folder)
            let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
            for file in files {
                let text = try String(contentsOf: file, encoding: .utf8)
                #expect(!text.contains("setPushToken"), "\(file.lastPathComponent)")
                checked += 1
            }
        }
        #expect(checked > 50)
    }

    /// T3.1: a tribe the core knows but whose record was never stored is
    /// not known to be private, so it never gets the offset.
    @Test func aTribeWithNoStoredRecordGetsNoOffset() async throws {
        let profile = TempProfile()
        let storage = try profile.storage()
        _ = try storage.apply(Storage.Commit(state: coreContact(key2G, contactKey: nil)))
        let engine = try testEngine(storage)
        #expect(try await engine.timeZoneSharing(in: key2G))
        #expect(try await engine.offsetShared(in: key2G) == nil)
    }
}
