import Foundation
import Testing
@testable import PeelCore

private let server = "chat.sphinx.chat"
private let room = "sphinx.call.781603422.512"
private let base = "https://chat.sphinx.chat/rooms/"

struct CallLinkTests {
    @Test(arguments: [
        // The Mac and iOS timestamp (seconds since 2001), Android's Unix milliseconds, Peel's random name.
        "sphinx.call.781603422.512", "sphinx.call.1728380000123", "sphinx.call.0123456789abcdef0123456789abcdef",
        // A Hive or second-brain tribe's room.
        "sphinx.call.-hive.example.com-.781603422.512",
    ])
    func readsTheRoomsTheAppsMake(room: String) throws {
        let link = try #require(CallLink(message: base + room, server: server))
        #expect(link.room == room)
        #expect(!link.audioOnly)
        #expect(link.url.absoluteString == base + room)
    }

    @Test func readsTheCallFormAndTheBareLink() throws {
        let bare = try #require(CallLink(message: " \(base)\(room)?startAudioOnly=true\n", server: server))
        let json = try #require(CallLink(
            message: #"call::{"link":"\#(base)\#(room)?startAudioOnly=true","recurring":false,"cron":""}"#, server: server
        ))
        #expect(bare == json)
        #expect(json.audioOnly)
        #expect(json.room == room)
        // Escaped slashes, as JSON encoders write them, read the same.
        #expect(CallLink(message: #"call::{"link":"https:\/\/chat.sphinx.chat\/rooms\/\#(room)"}"#, server: server)?.room == room)
    }

    @Test(arguments: [
        #"call::{"link":5}"#, #"call::{"url":"\#(base)\#(room)"}"#, "call::\(base)\(room)", #"call::{"link":"#,
        "\(base)\(room) join us", "join us \(base)\(room)", "",
    ])
    func refusesWhatIsNotOneLink(content: String) {
        #expect(CallLink(message: content, server: server) == nil)
    }

    @Test(arguments: [
        // Jitsi, and the official apps' substring checks.
        "https://jitsi.sphinx.chat/sphinx.call.781603422", "https://evil.example/rooms/sphinx.call.1?x=https://chat.sphinx.chat",
        "https://chat.sphinx.chat.evil.example/rooms/\(room)", "https://evilchat.sphinx.chat/rooms/\(room)",
        "https://evil.example/chat.sphinx.chat/rooms/\(room)", "https://chat.sphinx.chat@evil.example/rooms/\(room)",
        "https://user:pass@chat.sphinx.chat/rooms/\(room)", "https://chat%2esphinx.chat/rooms/\(room)",
        // Not https, another port, another path, a fragment.
        "http://chat.sphinx.chat/rooms/\(room)", "wss://chat.sphinx.chat/rooms/\(room)", "//chat.sphinx.chat/rooms/\(room)",
        "https://chat.sphinx.chat:8443/rooms/\(room)", "https://chat.sphinx.chat/room/\(room)",
        "https://chat.sphinx.chat/api/rooms/\(room)", "https://chat.sphinx.chat/rooms/\(room)#x",
        "https://chat.sphinx.chat/rooms/\(room)/x", "https://chat.sphinx.chat/rooms//\(room)",
    ])
    func refusesOtherHostsSchemesAndPaths(link: String) {
        #expect(CallLink(message: link, server: server) == nil)
    }

    @Test(arguments: [
        "sphinx.call.", "sphinx.call", "sphinx.call.a%2F..%2Fapi", "sphinx.call.a%26roomName%3Dother", "sphinx.call.a b",
        "sphinx.call.é", "sphinx.call.a;b", "Sphinx.call.1", "other.781603422", "sphinx.call." + String(repeating: "a", count: 129),
        "..%2Fsphinx.call.1", "sphinx.call.%00",
    ])
    func refusesInjectionInRoomNames(room: String) {
        #expect(CallLink(message: base + room, server: server) == nil)
    }

    @Test func theLongestRoomIsRead() {
        #expect(CallLink(message: base + "sphinx.call." + String(repeating: "a", count: 128), server: server) != nil)
    }

    @Test func keepsOnlyKnownQueryKeysAndEncodesTokensStrictly() throws {
        let link = try #require(CallLink(
            message: "\(base)\(room)?roomName=other&callKey=a+b/c%3D&isHost=true&hiveToken=x.y_z-1", server: server
        ))
        #expect(link.callKey == "a+b/c=")
        #expect(link.hiveToken == "x.y_z-1")
        #expect(link.url.absoluteString == "\(base)\(room)?callKey=a%2Bb%2Fc%3D&hiveToken=x.y_z-1")
        #expect(CallLink(message: link.url.absoluteString, server: server) == link)
    }

    @Test(arguments: [
        "startAudioOnly=true&startAudioOnly=false", "callKey=a&callKey=b", "callKey=a%20b", "callKey=a%26isHost%3Dtrue",
        "hiveToken=", "callKey=%zz", "callKey=" + String(repeating: "a", count: 2049),
    ])
    func refusesDuplicateOrUnsafeQueryValues(query: String) {
        #expect(CallLink(message: "\(base)\(room)?\(query)", server: server) == nil)
    }

    @Test func onlyTheAudioFlagSetToTrueMakesAnAudioCall() {
        #expect(CallLink(message: "\(base)\(room)?startAudioOnly=false", server: server)?.audioOnly == false)
        #expect(CallLink(message: "\(base)\(room)?startAudioOnly=TRUE", server: server)?.audioOnly == false)
        #expect(CallLink(message: "HTTPS://Chat.Sphinx.Chat:443/rooms/\(room)", server: server) != nil)
    }

    @Test func plainHTTPOnlyOnALoopbackCallServer() {
        let local = "127.0.0.1:7880"
        #expect(CallLink(message: "http://127.0.0.1:7880/rooms/\(room)", server: local)?.url.absoluteString
            == "http://127.0.0.1:7880/rooms/\(room)")
        #expect(CallLink(message: "https://127.0.0.1:7880/rooms/\(room)", server: local) == nil)
        #expect(CallLink(message: "http://127.0.0.1:7881/rooms/\(room)", server: local) == nil)
        #expect(CallLink(message: "http://127.0.0.1/rooms/\(room)", server: local) == nil)
        #expect(CallLink(message: "http://localhost:7880/rooms/\(room)", server: local) == nil)
        // A link to this machine on the production server is not a call.
        #expect(CallLink(message: "http://127.0.0.1:7880/rooms/\(room)", server: server) == nil)
    }

    @Test func refusesContentPastTheLimit() {
        let padded = base + room + String(repeating: " ", count: CallLink.maxContent)
        #expect(CallLink(message: padded, server: server) == nil)
    }

    @Test func newRoomsAreRandomAndReadBack() throws {
        let video = try CallLink.new(server: server, audioOnly: false)
        let audio = try CallLink.new(server: server, audioOnly: true)
        #expect(video.room.count == "sphinx.call.".count + 32)
        #expect(video.room.dropFirst("sphinx.call.".count).allSatisfy { $0.isHexDigit })
        #expect(video.room != audio.room)
        #expect(audio.url.absoluteString == "\(base)\(audio.room)?startAudioOnly=true")
        #expect(CallLink(message: video.message, server: server) == video)
        #expect(CallLink(message: audio.message, server: server) == audio)
        #expect(throws: (any Error).self) { try CallLink.new(server: "chat.sphinx.chat/x", audioOnly: false) }
    }

    /// The `call::` form as iOS and Android send it: valid JSON with all three fields.
    @Test func theCallFormIsTheAppsJSON() throws {
        let link = try CallLink.new(server: server, audioOnly: true)
        #expect(link.message.hasPrefix("call::"))
        let json = try #require(try JSONSerialization.jsonObject(with: Data(link.message.dropFirst(6).utf8)) as? [String: Any])
        #expect(json["link"] as? String == link.url.absoluteString)
        #expect(json["recurring"] as? Bool == false)
        #expect(json["cron"] as? String == "")
    }
}

struct CallPriceTests {
    @Test func aCallInAPaidTribePaysOnlyTheFloor() {
        let tribe = Tribe(pubkey: key2G, pricePerMessageMsat: 20_000, escrowMsat: 5_000)
        #expect(tribe.messageAmountMsat(type: MessageType.call) == 3_000)
        #expect(tribe.messageAmountMsat(type: MessageType.text) == 25_000)
        #expect(tribe.messageAmountMsat(type: MessageType.delete) == 25_000)
    }
}

struct StartCallTests {
    let profile = TempProfile()

    /// The core cannot send without a server's state, so `startCall` past
    /// its checks is verified on the local test server.
    private func engine(server address: String) throws -> Engine {
        let storage = try profile.storage()
        _ = try storage.apply(Storage.Commit(state: [:], settings: [.server: address]))
        return try testEngine(storage)
    }

    @Test func theCallServerDefaultsToTheAppsOwnButNotOnALocalServer() async throws {
        let production = try engine(server: "mqtts://lsp.example.com:8883")
        #expect(try await production.callServer() == "chat.sphinx.chat")
        try await production.setCallServer("Calls.Example.com:8443")
        #expect(try await production.callServer() == "calls.example.com:8443")
        await #expect(throws: (any Error).self) { try await production.setCallServer("calls.example.com/x") }
    }

    @Test func aLocalServerHasNoCallServerUnlessNamed() async throws {
        let local = try engine(server: "mqtt://127.0.0.1:1883")
        await #expect(throws: Engine.Failure.noCallServer) { try await local.callServer() }
        #expect(await local.callLink(in: .fixture(type: MessageType.call, content: "http://127.0.0.1/rooms/\(room)")) == nil)
    }

    @Test func aCallGoesOnlyToAChat() async throws {
        let engine = try engine(server: "mqtts://lsp.example.com:8883")
        await #expect(throws: Engine.Failure.notAChat) { try await engine.startCall(in: keyG, audioOnly: false) }
    }

    @Test func callLinkReadsOnlyCallsAndTextThatIsALink() async throws {
        let engine = try engine(server: "mqtts://lsp.example.com:8883")
        let content = "\(base)\(room)"
        #expect(await engine.callLink(in: .fixture(type: MessageType.call, content: content))?.room == room)
        #expect(await engine.callLink(in: .fixture(type: MessageType.text, content: content))?.room == room)
        #expect(await engine.callLink(in: .fixture(type: MessageType.attachment, content: content)) == nil)
        var deleted = Message.fixture(type: MessageType.call, content: content)
        deleted.deleted = true
        #expect(await engine.callLink(in: deleted) == nil)
    }
}

struct CallMessageTests {
    @Test func linkTextIsWhatAnInvalidCallShows() {
        #expect(CallLink.linkText(in: #"call::{"link":"https://meet.jit.si/x","recurring":false}"#) == "https://meet.jit.si/x")
        #expect(CallLink.linkText(in: " https://jitsi.sphinx.chat/sphinx.call.1 \n") == "https://jitsi.sphinx.chat/sphinx.call.1")
        #expect(CallLink.linkText(in: "call::not json") == nil)
        #expect(CallLink.linkText(in: String(repeating: "a", count: CallLink.maxContent + 1)) == nil)
    }

    @Test func aCallPreviewsAsItsMode() {
        let video = Message.fixture(type: MessageType.call, content: #"call::{"link":"\#(base)\#(room)"}"#)
        let audio = Message.fixture(type: MessageType.call, content: "\(base)\(room)?startAudioOnly=true")
        let jitsi = Message.fixture(type: MessageType.call, content: "https://jitsi.sphinx.chat/meet")
        #expect(video.preview == "Video call")
        #expect(audio.preview == "Audio call")
        #expect(jitsi.preview == "https://jitsi.sphinx.chat/meet")
        let form = Message.fixture(type: MessageType.call, content: #"call::{"link":"https://meet.jit.si/x"}"#)
        #expect(form.preview == "https://meet.jit.si/x")
        let failed = Message.fixture(type: MessageType.call, fromMe: true, content: "\(base)\(room)", status: "FAILED")
        #expect(failed.isDiscardable && !failed.isRetryable())
        // Text that is a call link keeps its words.
        #expect(Message.fixture(type: MessageType.text, content: "\(base)\(room)").preview == "\(base)\(room)")
    }

    @Test func callsShowCountAsUnreadAndStayOutOfContent() {
        #expect(MessageType.shownInChats.contains(MessageType.call))
        #expect(MessageType.unreadTypes.contains(MessageType.call))
        #expect(!MessageType.content.contains(MessageType.call))
        #expect(!MessageType.resendable.contains(MessageType.call))
        #expect(Message.fixture(serverIndex: 5, type: MessageType.call, content: "\(base)\(room)").countsAsUnread(after: 4))
        #expect(!Message.fixture(serverIndex: 5, type: MessageType.call, fromMe: true).countsAsUnread(after: 4))
    }

    @Test func aMessageIsACallOnlyAgainstTheCallServer() {
        let call = Message.fixture(type: MessageType.call, content: "\(base)\(room)")
        #expect(CallLink(in: call, server: server)?.room == room)
        #expect(CallLink(in: call, server: "calls.example.com") == nil)
        #expect(CallLink(in: .fixture(type: MessageType.text, content: "hello"), server: server) == nil)
    }
}
