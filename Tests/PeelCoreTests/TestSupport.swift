import Foundation
import Sphinxrs
import Testing
@testable import PeelCore
@testable import PeelTestSupport

// Fixtures the PeelCore tests alone use. The ones the PeelAgent tests share
// (`TempProfile`, `rows`, `uuid`, `dm`, `Message.fixture`, `sender`, the
// keys, `registeredStorage`, `withTestEngine`) live in Tests/PeelTestSupport.

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
