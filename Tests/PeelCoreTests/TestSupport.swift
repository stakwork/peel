import Foundation
import Sphinxrs
import Testing
@testable import PeelCore

// Fixtures shared by the PeelCore tests. `TempProfile` lives in
// StorageTests.swift; `uuid`, `dm` and `Message.fixture` in MessageTests.swift.

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

/// Someone's text message, numbered for its uuid and time.
func text(_ n: Int, chat: String = dm, fromMe: Bool = false) -> Message {
    .fixture(uuid: uuid(n), chat: chat, fromMe: fromMe, content: "m\(n)", timestamp: Int64(n) * 1_000)
}

/// BOLT 11's own test vectors: 2,500 µBTC for "1 cup coffee", expired in
/// 2017, and a donation that names no amount.
let coffee = "lnbc2500u1pvjluezsp5zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zygspp5qqqsyqcyq5rqwzqfqqqsyqcyq5rqwzqfqqqsyqcyq5rqwzqfqypqdq5xysxxatsyp3k7enxv4jsxqzpu9qrsgquk0rl77nj30yxdy8j9vdx85fkpmdla2087ne0xh8nhedh8w27kyke0lp53ut353s06fv3qfegext0eh0ymjpf39tuven09sam30g4vgpfna3rh"
let donation = "lnbc1pvjluezsp5zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zygspp5qqqsyqcyq5rqwzqfqqqsyqcyq5rqwzqfqqqsyqcyq5rqwzqfqypqdpl2pkx2ctnv5sxxmmwwd5kgetjypeh2ursdae8g6twvus8g6rfwvs8qun0dfjkxaq9qrsgq357wnc5r2ueh7ck6q93dj32dlqnls087fxdwk8qakdyafkq3yap9us6v52vjjsrvywa6rt52cm9r9zqt8r2t7mlcwspyetp5h2tztugp9lfyql"
let coffeeHash = "0001020304050607080900010203040506070809000102030405060708090102"
let coffeePayee = "03e7156ae33b0a208d0744199163177e909e80176e55d97a2f221ede0f934dd9ad"

/// A payment request for `coffee`: ours in `dm`, or the payee's in theirs.
func request(fromMe: Bool, id: Int = 1, chat: String? = nil) -> Message {
    .fixture(
        uuid: uuid(id), type: MessageType.invoice, chat: chat ?? (fromMe ? dm : coffeePayee), fromMe: fromMe,
        body: #"{"content":"coffee","invoice":"\#(coffee)"}"#, content: "coffee", paymentHash: coffeeHash,
        amountMsat: 250_000_000
    )
}

/// What the core needs in its state to make payments and invites with no
/// server: the account's short channel id, the server's key (`key3G`), a
/// block height and the device id its topics carry.
let registeredState: [String: Data] = [
    "my_scid": be64(1), "server_pubkey": hex(key3G), "blockheight": be64(800_000), "device": Data("dev".utf8),
]

/// An invoice the core makes for another account (payee and server alike,
/// `registeredState`), valid for an hour.
func madeInvoice(msat: UInt64 = 10_000) throws -> Invoice {
    let seed = try Sphinxrs.mnemonicToSeed(
        mnemonic: "legal winner thank year wave sausage worth useful legal winner thank yellow"
    )
    return try Invoice(try #require(try Sphinxrs.makeInvoice(
        seed: seed, uniqueTime: String(Date().millisecondsSince1970), state: StateCodec.encode(registeredState),
        amtMsat: msat, description: "test"
    ).invoice))
}

/// A transport that never connected: to the engine, a connection that has
/// just gone, so every publish throws `notConnected`. Nothing dials it.
func goneTransport() -> Transport {
    Transport(
        server: ServerAddress("mqtt://127.0.0.1:1")!, clientID: "test", username: "test", password: "test",
        allowUntrustedCertificate: false
    )
}

/// A core result with only the publish fields, the messages (with a total,
/// a page of history), a page of payment history, the server's records and state set.
func coreResult(
    settle: String? = nil, register: String? = nil, newChildIdx: UInt64? = nil,
    asyncpay: String? = nil, topics: [String] = [], asyncpayTag: String? = nil, payments: String? = nil,
    tags: String? = nil, msgs: [Msg] = [], msgsTotal: UInt64? = nil, state: [String: Data]? = nil
) -> RunReturn {
    RunReturn(
        msgs: msgs, msgsTotal: msgsTotal, msgsCounts: nil, subscriptionTopics: [],
        settleTopic: settle, settlePayload: settle.map { _ in Data([1]) },
        asyncpayTopic: asyncpay, asyncpayPayload: asyncpay.map { _ in Data([2]) },
        registerTopic: register, registerPayload: register.map { _ in Data() },
        topics: topics, payloads: topics.map { _ in Data([3]) },
        stateMp: state.map(StateCodec.encode), stateToDelete: [], newBalance: nil, myContactInfo: nil, sentStatus: nil,
        settledStatus: nil, registerResponse: nil, asyncpayTag: asyncpayTag, error: nil, newTribe: nil,
        tribeMembers: nil, newInvite: nil, inviterContactInfo: nil, inviterAlias: nil, initialTribe: nil,
        lspHost: nil, invoice: nil, route: nil, node: nil, lastRead: nil, muteLevels: nil, payments: payments,
        paymentsTotal: nil, tags: tags, deletedMsgs: nil, newChildIdx: newChildIdx, ping: nil
    )
}

extension Msg {
    /// A message as the core reports one.
    static func fixture(
        type: UInt8? = 0, message: String? = nil, uuid: String? = nil, index: String? = nil, sender: String? = nil,
        msat: UInt64? = nil, timestamp: UInt64? = nil, sentTo: String? = nil, fromMe: Bool? = false
    ) -> Msg {
        Msg(message: message, type: type, uuid: uuid, tag: nil, index: index, sender: sender, msat: msat,
            timestamp: timestamp, sentTo: sentTo, fromMe: fromMe, paymentHash: nil, error: nil)
    }
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

/// One onion of a page of history as the server frames it (`encode_onion`):
/// the onion (`data`, zeros by default), then its index, time and child
/// index 1, and for a payment its amount and payment hash.
func batchOnion(index: UInt64, paidMsat: UInt64? = nil, data: Data? = nil) -> Data {
    var onion = (data ?? Data(count: paidMsat == nil ? 1401 : 1366)) + be64(index) + be64(7) + be64(1)
    if let paidMsat { onion += be64(paidMsat) + Data(repeating: 0xAB, count: 32) }
    return onion
}

/// A page of history: a MessagePack fixarray of bin16 onions.
func batchPage(_ onions: [Data]) -> Data {
    var out = Data([0x90 | UInt8(onions.count)])
    for onion in onions { out += Data([0xC5, UInt8(onion.count >> 8), UInt8(onion.count & 0xFF)]) + onion }
    return out
}
