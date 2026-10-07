import Foundation
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
