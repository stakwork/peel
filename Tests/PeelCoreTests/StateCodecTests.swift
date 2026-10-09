import Foundation
import Sphinxrs
import Testing
@testable import PeelCore

struct StateCodecTests {
    @Test func emptyMapRoundTrips() throws {
        let encoded = StateCodec.encode([:])
        #expect(encoded == Data([0x80]))
        #expect(try StateCodec.decode(encoded) == [:])
    }

    @Test func roundTripsEveryLengthFamily() throws {
        // Fixstr, str8 and str16 keys; bin8, bin16 and bin32 values; map16 once
        // there are more than fifteen entries.
        var state: [String: Data] = [
            "my_scid": Data([1, 2, 3]),
            String(repeating: "k", count: 40): Data(repeating: 7, count: 300),
            String(repeating: "x", count: 300): Data(repeating: 9, count: 70_000),
            "empty": Data(),
        ]
        for index in 0..<20 {
            state["contact_\(index)"] = Data("value \(index)".utf8)
        }
        #expect(try StateCodec.decode(StateCodec.encode(state)) == state)
    }

    @Test func decodesTheCoreShape() throws {
        // fixmap(1) { fixstr "a": bin8 [0xFF] }
        let bytes = Data([0x81, 0xA1, 0x61, 0xC4, 0x01, 0xFF])
        #expect(try StateCodec.decode(bytes) == ["a": Data([0xFF])])
    }

    @Test func rejectsMalformedInput() {
        // Truncated value.
        #expect(throws: StateCodec.Malformed.self) {
            try StateCodec.decode(Data([0x81, 0xA1, 0x61, 0xC4, 0x02, 0xFF]))
        }
        // Trailing bytes.
        #expect(throws: StateCodec.Malformed.self) {
            try StateCodec.decode(Data([0x80, 0x00]))
        }
        // A string value where the core always writes binary.
        #expect(throws: StateCodec.Malformed.self) {
            try StateCodec.decode(Data([0x81, 0xA1, 0x61, 0xA1, 0x62]))
        }
        // Not a map.
        #expect(throws: StateCodec.Malformed.self) {
            try StateCodec.decode(Data([0x90]))
        }
        // Key that is not UTF-8.
        #expect(throws: StateCodec.Malformed.self) {
            try StateCodec.decode(Data([0x81, 0xA1, 0xFF, 0xC4, 0x00]))
        }
    }
}

/// What really arrived with a received payment (review F3): a live
/// message's topic, or the amounts beside the onions of a history page,
/// cap what the core reports from the sender's onion.
struct ArrivedAmountTests {
    /// One onion of a `batch` page as the server encodes it (`encode_onion`):
    /// the onion, then index, time and child index, and for a payment its
    /// amount and payment hash.
    private func onion(index: UInt64, paidMsat: UInt64?) -> Data {
        let number = { (n: UInt64) in Data((0..<8).reversed().map { UInt8(truncatingIfNeeded: n >> ($0 * 8)) }) }
        var data = Data(count: paidMsat == nil ? 1401 : 1366) + number(index) + number(7) + number(1)
        if let paidMsat { data += number(paidMsat) + Data(repeating: 0xAB, count: 32) }
        return data
    }

    /// A MessagePack fixarray of bin16 items.
    private func page(_ items: [Data]) -> Data {
        var out = Data([0x90 | UInt8(items.count)])
        for item in items { out += Data([0xC5, UInt8(item.count >> 8), UInt8(item.count & 0xFF)]) + item }
        return out
    }

    @Test func aHistoryPageGivesEachPaymentsAmountByIndex() {
        let amounts = StateCodec.paymentAmounts(inBatch: page([
            onion(index: 3, paidMsat: nil), onion(index: 4, paidMsat: 21_000), onion(index: 9, paidMsat: 1),
        ]))
        #expect(amounts == ["4": 21_000, "9": 1])
        #expect(StateCodec.paymentAmounts(inBatch: page([])) == [:])
        // Truncated, or not an array: nothing is believed.
        #expect(StateCodec.paymentAmounts(inBatch: page([onion(index: 4, paidMsat: 1)]).dropLast()) == nil)
        #expect(StateCodec.paymentAmounts(inBatch: Data([0x81])) == nil)
    }

    /// The page comes from the server: lengths that claim more than is
    /// there, and random bytes, are refused without a crash or a long loop.
    @Test func aMalformedPageIsRefusedSafely() {
        #expect(StateCodec.paymentAmounts(inBatch: Data()) == nil)
        // array32 of 4 billion items, then nothing.
        #expect(StateCodec.paymentAmounts(inBatch: Data([0xDD, 0xFF, 0xFF, 0xFF, 0xFF])) == nil)
        // One bin32 item claiming 4 GB.
        #expect(StateCodec.paymentAmounts(inBatch: Data([0x91, 0xC6, 0xFF, 0xFF, 0xFF, 0xFF, 0x00])) == nil)
        // A payment-sized item and trailing bytes.
        #expect(StateCodec.paymentAmounts(inBatch: page([onion(index: 4, paidMsat: 1)]) + Data([0x00])) == nil)
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<500 {
            let bytes = (0..<Int.random(in: 0...1600, using: &generator)).map { _ in UInt8.random(in: 0...255, using: &generator) }
            _ = StateCodec.paymentAmounts(inBatch: Data(bytes))
        }
    }

    @Test func aLiveMessagesTopicNamesWhatArrived() {
        let paid = "root/pk/2/res/dev/stream/41/1700000000000/\(uuid(1))/21000".split(separator: "/", omittingEmptySubsequences: false)
        #expect(Engine.arrivedMsat(kind: "stream", topic: paid, payload: Data()) == ["41": 21_000])
        let unpaid = "root/pk/2/res/dev/msg/41/1700000000000".split(separator: "/", omittingEmptySubsequences: false)
        #expect(Engine.arrivedMsat(kind: "msg", topic: unpaid, payload: Data()) == [:])
        #expect(Engine.arrivedMsat(kind: "ping", topic: paid, payload: Data()) == [:])
    }

    private func msg(index: String?, msat: UInt64?, fromMe: Bool? = false) -> Msg {
        Msg(message: nil, type: 5, uuid: nil, tag: nil, index: index, sender: nil, msat: msat, timestamp: nil,
            sentTo: nil, fromMe: fromMe, paymentHash: nil, error: nil)
    }

    /// A modified client can write any amount into its onion: Peel takes at
    /// most what arrived, and nothing when the server named nothing; also
    /// for a message the core calls ours, which a sender can arrange.
    @Test func aReceivedAmountIsNeverMoreThanArrived() {
        let capped = Engine.cappedToArrived([
            msg(index: "1", msat: 200_000),
            msg(index: "2", msat: 5_000),
            msg(index: "3", msat: 5_000),
            msg(index: nil, msat: 5_000, fromMe: nil),
            msg(index: "5", msat: 9_000, fromMe: true),
            msg(index: "6", msat: nil),
            msg(index: "7", msat: 9_000, fromMe: true),
        ], ["1": 1_000, "2": 8_000, "7": 2_000])
        #expect(capped.map(\.msat) == [1_000, 5_000, nil, nil, nil, nil, 2_000])
    }
}
