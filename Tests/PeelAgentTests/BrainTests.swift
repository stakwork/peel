import Foundation
import Testing
import PeelCore
@testable import PeelAgent
@testable import PeelTestSupport

/// The account's brain (`Brain`): the pairing link `brain/setup.sh`
/// prints, what is kept, and how a home server's `/health` is read.
struct BrainTests {
    /// Made up for the tests, as `openssl rand -hex 32` makes one.
    static let key = String(repeating: "ab12", count: 16)

    /// A home server at `address`.
    static func server(_ address: String, key: String = key) throws -> MemoryServer {
        let url = try #require(URL(string: address))
        return try #require(MemoryServer(base: url, key: key, home: true))
    }

    @Test func aPairingLinkAsSetupPrintsIt() throws {
        let link = try #require(URL(string: "peel://brain?url=https%3A%2F%2Fbrain.tail1234.ts.net&key=\(Self.key)"))
        let server = try #require(Brain.pairing(link))
        #expect(server.base.absoluteString == "https://brain.tail1234.ts.net")
        #expect(server == (try Self.server("https://brain.tail1234.ts.net")))
    }

    @Test(arguments: [
        "peel://other?url=https%3A%2F%2Fb.example.com&key=k",            // not a brain link
        "https://brain?url=https%3A%2F%2Fb.example.com&key=k",           // not Peel's scheme
        "peel://brain?url=http%3A%2F%2Fb.example.com&key=k",             // plain http off Tailscale
        "peel://brain?url=https%3A%2F%2Fb.example.com",                  // no key
        "peel://brain?url=https%3A%2F%2Fb.example.com&key=",             // an empty key
        "peel://brain?url=https%3A%2F%2Fb.example.com&key=a%20b",        // a key with a space
        "peel://brain?url=https%3A%2F%2Fb.example.com&key=k&key=j",      // a name given twice
        "peel://brain?url=https%3A%2F%2Fb.example.com&url=https%3A%2F%2Fc.example.com&key=k",
        "peel://brain?url=https%3A%2F%2Fb.example.com&key=k&next=x",     // anything else
        "peel://brain?url=https%3A%2F%2Fb.example.com%2F%3Ft%3D1&key=k", // a query in the address
        "peel://brain/x?url=https%3A%2F%2Fb.example.com&key=k",
        "peel://brain?url=https%3A%2F%2Fb.example.com&key=k#x",
    ])
    func aLinkPeelCannotUse(link: String) throws {
        #expect(Brain.pairing(try #require(URL(string: link))) == nil)
    }

    /// Kept and read back; this Mac keeps nothing; a kept value Peel cannot
    /// read throws rather than being taken for this Mac, whose strut would
    /// then start in the home server's place.
    @Test func whatIsKept() throws {
        let profile = TempProfile()
        try FileManager.default.createDirectory(at: profile.url, withIntermediateDirectories: true)
        let item = FileItem(file: profile.url.appending(path: "brain"))
        #expect(try Brain.kept(in: item) == .thisMac)

        let home = Brain.homeServer(try Self.server("http://100.64.0.7:3000"))
        try home.keep(in: item)
        #expect(try Brain.kept(in: item) == home)

        try Brain.thisMac.keep(in: item)
        #expect(try item.read() == nil)

        try item.write(Data(#"{"url":"http://example.com","key":"k"}"#.utf8))
        #expect(throws: PeelError.self) { try Brain.kept(in: item) }
    }

    /// strut answers `/health` to anyone; only with its key does it say
    /// more than `ok`.
    @Test(arguments: [
        (#"{"ok":true,"dataDir":"/data","stepCount":40}"#, BrainStatus.connected),
        (#"{"ok":true}"#, .badKey),
    ])
    func whatHealthSays(reply: String, status: BrainStatus) async throws {
        let stub = try await HTTPStub { _ in reply }
        defer { stub.stop() }
        let server = try Self.server("http://127.0.0.1:\(stub.port)")
        #expect(await server.health() == status)
        let head = try #require(stub.requests.first)
        #expect(head.hasPrefix("GET /health ") && head.contains("Authorization: Bearer \(Self.key)"))
    }

    @Test func aHomeServerThatIsOffIsOffline() async throws {
        guard case .offline = await (try Self.server("https://127.0.0.1:1")).health() else {
            Issue.record("expected offline")
            return
        }
    }
}
