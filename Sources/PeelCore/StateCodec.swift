import Foundation

/// The core hands its state to the client as a MessagePack map of string keys to
/// binary values, and expects the whole map back on every call
/// (`serialize_simple_state_map` in the sphinx crate). This codec handles exactly
/// that shape and rejects anything else.
enum StateCodec {
    struct Malformed: Error, CustomStringConvertible {
        let description: String
    }

    /// The marker bytes of one MessagePack length-prefixed family.
    private struct Family {
        let fix: ClosedRange<UInt8>?
        let marker8: UInt8?
        let marker16: UInt8
        let marker32: UInt8

        static let map = Family(fix: 0x80...0x8F, marker8: nil, marker16: 0xDE, marker32: 0xDF)
        static let str = Family(fix: 0xA0...0xBF, marker8: 0xD9, marker16: 0xDA, marker32: 0xDB)
        static let bin = Family(fix: nil, marker8: 0xC4, marker16: 0xC5, marker32: 0xC6)
        static let array = Family(fix: 0x90...0x9F, marker8: nil, marker16: 0xDC, marker32: 0xDD)
    }

    static func encode(_ state: [String: Data]) -> Data {
        var out = Data()
        out.reserveCapacity(state.reduce(16) { $0 + $1.key.utf8.count + $1.value.count + 10 })
        write(state.count, as: .map, to: &out)
        for (key, value) in state {
            let keyBytes = Data(key.utf8)
            write(keyBytes.count, as: .str, to: &out)
            out.append(keyBytes)
            write(value.count, as: .bin, to: &out)
            out.append(value)
        }
        return out
    }

    static func decode(_ data: Data) throws -> [String: Data] {
        var reader = Reader(data: data)
        let count = try reader.length(of: .map, "map")
        var state: [String: Data] = [:]
        state.reserveCapacity(count)
        for _ in 0..<count {
            let keyLength = try reader.length(of: .str, "key")
            guard let key = String(bytes: try reader.take(keyLength), encoding: .utf8) else {
                throw Malformed(description: "state key is not UTF-8")
            }
            let valueLength = try reader.length(of: .bin, "value")
            state[key] = try reader.take(valueLength)
        }
        guard reader.isAtEnd else {
            throw Malformed(description: "trailing bytes after state map")
        }
        return state
    }

    /// What really arrived with each payment on a page of history (the
    /// `batch` payload), in msat by message index. The server sends a
    /// MessagePack array of onions, each followed by its index, time and
    /// child index and, for a payment, its amount and payment hash
    /// (`encode_onion` in the core's `ping/onion.rs`); the core reports the
    /// amount the sender wrote in the onion instead. Messages without a
    /// payment are left out; nil when the page cannot be read.
    static func paymentAmounts(inBatch data: Data) -> [String: UInt64]? {
        // ping/onion.rs: a 1366-byte onion, then id, ts, key index and amount (8 bytes each), then the hash.
        let onion = 1366, paymentLength = 1430
        var reader = Reader(data: data)
        guard let count = try? reader.length(of: .array, "array") else { return nil }
        var amounts: [String: UInt64] = [:]
        for _ in 0..<count {
            guard let length = try? reader.length(of: .bin, "onion"), let item = try? reader.take(length) else { return nil }
            guard length == paymentLength else { continue }
            let bytes = [UInt8](item)
            let number = { (at: Int) in bytes[at..<at + 8].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) } }
            amounts[String(number(onion))] = number(onion + 24)
        }
        return reader.isAtEnd ? amounts : nil
    }

    private static func write(_ length: Int, as family: Family, to out: inout Data) {
        if let fix = family.fix, length < fix.count {
            out.append(fix.lowerBound | UInt8(length))
        } else if let marker8 = family.marker8, length <= 0xFF {
            out.append(marker8)
            out.append(UInt8(length))
        } else if length <= 0xFFFF {
            out.append(family.marker16)
            out.append(UInt8(length >> 8))
            out.append(UInt8(length & 0xFF))
        } else {
            out.append(family.marker32)
            for shift in [24, 16, 8, 0] {
                out.append(UInt8((length >> shift) & 0xFF))
            }
        }
    }

    private struct Reader {
        let data: Data
        var offset: Int

        init(data: Data) {
            self.data = data
            offset = data.startIndex
        }

        var isAtEnd: Bool { offset == data.endIndex }

        mutating func take(_ count: Int) throws -> Data {
            guard count >= 0, data.endIndex - offset >= count else {
                throw Malformed(description: "state map is truncated")
            }
            defer { offset += count }
            return data.subdata(in: offset..<offset + count)
        }

        mutating func integer(width: Int) throws -> Int {
            try take(width).reduce(0) { ($0 << 8) | Int($1) }
        }

        mutating func length(of family: Family, _ what: String) throws -> Int {
            let marker = try integer(width: 1)
            if let fix = family.fix, fix.contains(UInt8(marker)) { return marker - Int(fix.lowerBound) }
            if let marker8 = family.marker8, marker == Int(marker8) { return try integer(width: 1) }
            if marker == Int(family.marker16) { return try integer(width: 2) }
            if marker == Int(family.marker32) { return try integer(width: 4) }
            throw Malformed(description: "unexpected marker 0x\(String(marker, radix: 16)) for state \(what)")
        }
    }
}
