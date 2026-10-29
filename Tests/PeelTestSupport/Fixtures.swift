import Foundation
import GRDB
@testable import PeelCore

// Fixtures shared by the PeelCore and PeelAgent tests; each test target
// imports this module @testable. The PeelCore tests keep their own in
// Tests/PeelCoreTests/TestSupport.swift.

/// A fresh profile directory per test, removed afterwards.
final class TempProfile {
    let url: URL

    init() {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PeelTests-\(UUID().uuidString)", isDirectory: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    func storage(readOnly: Bool = false) throws -> Storage {
        try Storage(directory: url, readOnly: readOnly)
    }

    /// The database file, opened directly, bypassing Storage.
    func queue() throws -> DatabaseQueue {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return try DatabaseQueue(path: url.appendingPathComponent("peel.sqlite").path)
    }
}

/// Reads rows straight from the database file, bypassing Storage.
func rows(_ profile: TempProfile, _ sql: String) throws -> [Row] {
    try profile.queue().read { try Row.fetchAll($0, sql: sql) }
}

/// A uuid as the core issues them: 64 hex characters.
func uuid(_ n: Int) -> String { String(format: "%064x", n) }

/// A direct-message chat for tests.
let dm = "02aa"

extension Message {
    static func fixture(
        uuid: String? = "uuid-1",
        serverIndex: Int64? = nil,
        type: Int = MessageType.text,
        chat: String = "02aa",
        fromMe: Bool = false,
        sender: String? = nil,
        body: String? = nil,
        content: String? = "hi",
        msat: Int64? = nil,
        timestamp: Int64? = 1_000,
        tag: String? = nil,
        paymentHash: String? = nil,
        status: String? = nil,
        replyUUID: String? = nil,
        threadUUID: String? = nil,
        amountMsat: Int64? = nil
    ) -> Message {
        Message(
            id: nil, uuid: uuid, serverIndex: serverIndex, type: type, chat: chat, fromMe: fromMe,
            sender: sender, body: body, content: content, msat: msat, timestamp: timestamp, tag: tag,
            paymentHash: paymentHash, status: status, replyUUID: replyUUID, threadUUID: threadUUID,
            amountMsat: amountMsat
        )
    }
}

/// Sender details as the core and a tribes server put them on a message.
func sender(
    _ pubkey: String = "02cc", alias: String? = nil, photo: String? = nil, host: String? = nil, role: Int? = nil
) -> String {
    struct Fields: Encodable {
        let pubkey: String
        let alias: String?
        let photo_url: String?
        let host: String?
        let role: Int?
    }
    let fields = Fields(pubkey: pubkey, alias: alias, photo_url: photo, host: host, role: role)
    return String(decoding: try! JSONEncoder().encode(fields), as: UTF8.self)
}

let abandon = Array(repeating: "abandon", count: 11) + ["about"]

/// An engine for the "abandon ... about" words on `storage`.
func testEngine(_ storage: Storage) throws -> Engine {
    try Engine(mnemonic: abandon.joined(separator: " "), storage: storage)
}

func hex(_ text: String) -> Data {
    var data = Data()
    var index = text.startIndex
    while index < text.endIndex {
        let next = text.index(index, offsetBy: 2)
        data.append(UInt8(text[index..<next], radix: 16)!)
        index = next
    }
    return data
}

/// A number as the core's state stores it: eight bytes, big-endian.
func be64(_ n: UInt64) -> Data { withUnsafeBytes(of: n.bigEndian) { Data($0) } }

/// Real curve points (G, 2G, 3G), for the keys the core parses.
let keyG = "0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798"
let key2G = "02c6047f9441ed7d6d3045406e95c07cd85c778e4b8cef3ca7abac09b95c709ee5"
let key3G = "02f9308a019258c31049344f85f89d5229b531c845836f99b08601f113bce036f9"
/// A well-formed key no fixture puts in the core's state.
let strangerKey = "03c6047f9441ed7d6d3045406e95c07cd85c778e4b8cef3ca7abac09b95c709ee5"

/// A contact record as the core stores it (`rmp_utils::serialize_contact`):
/// version, child index, LSP key, scid and, once the key exchange is done,
/// the contact key. A person has one; a tribe never does.
func coreContact(_ pubkey: String, contactKey: String?, lsp: String = key3G, index: UInt64 = 1) -> [String: Data] {
    ["c/\(pubkey)": Data([0]) + be64(index) + hex(lsp) + be64(0) + (contactKey.map(hex) ?? Data())]
}

/// What the core needs in its state to make payments and invites with no
/// server: the account's short channel id, the server's key (`key3G`), a
/// block height and the device id its topics carry.
let registeredState: [String: Data] = [
    "my_scid": be64(1), "server_pubkey": hex(key3G), "blockheight": be64(800_000), "device": Data("dev".utf8),
]

/// A file of `size` zero bytes at `url`, sparse, so a large one costs no disk.
@discardableResult
func sparseFile(_ url: URL, size: Int) throws -> URL {
    FileManager.default.createFile(atPath: url.path, contents: nil)
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.truncate(atOffset: UInt64(size))
    return url
}

/// A registered account (`registeredState`) on a server nothing dials, with
/// `contact` as a ready contact at child index 1, and what else `commit` holds.
func registeredStorage(
    _ profile: TempProfile, contact: String? = nil, _ commit: Storage.Commit = Storage.Commit()
) throws -> Storage {
    let storage = try profile.storage()
    var commit = commit
    commit.state = registeredState.merging(contact.map { coreContact($0, contactKey: key3G) } ?? [:]) { $1 }
    commit.settings[.server] = "mqtt://127.0.0.1:1"
    commit.contacts = contact.map { [($0, true)] }
    _ = try storage.apply(commit)
    return storage
}

/// Runs `body` on an engine for `storage` on `transport`, and disconnects
/// after, even when it throws: that shuts the transport's client down,
/// which mqtt-nio requires before one is freed.
func withTestEngine(_ storage: Storage, on transport: Transport, _ body: (Engine) async throws -> Void) async throws {
    let engine = try testEngine(storage)
    await engine.useTransportForTesting(transport)
    do {
        try await body(engine)
    } catch {
        await engine.disconnect()
        throw error
    }
    await engine.disconnect()
}
