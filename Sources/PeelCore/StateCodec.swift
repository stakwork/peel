import Foundation

/// The core hands its state to the client as a MessagePack map of string keys to
/// binary values, and expects the whole map back on every call
/// (`serialize_simple_state_map` in the sphinx crate). This codec handles exactly
/// that shape and rejects anything else.
enum StateCodec {
    struct Malformed: Error, CustomStringConvertible {
        let description: String
    }

    static func encode(_ state: [String: Data]) -> Data {
        var out = Data()
        writeLength(state.count, fix: 0x80, fixMax: 15, marker8: nil, marker16: 0xDE, marker32: 0xDF, to: &out)
        for (key, value) in state {
            let keyBytes = Data(key.utf8)
            writeLength(keyBytes.count, fix: 0xA0, fixMax: 31, marker8: 0xD9, marker16: 0xDA, marker32: 0xDB, to: &out)
            out.append(keyBytes)
            writeLength(value.count, fix: nil, fixMax: 0, marker8: 0xC4, marker16: 0xC5, marker32: 0xC6, to: &out)
            out.append(value)
        }
        return out
    }

    static func decode(_ data: Data) throws -> [String: Data] {
        var reader = Reader(bytes: [UInt8](data))
        let count = try reader.length(fix: 0x80...0x8F, marker8: nil, marker16: 0xDE, marker32: 0xDF, of: "map")
        var state: [String: Data] = [:]
        state.reserveCapacity(count)
        for _ in 0..<count {
            let keyLength = try reader.length(fix: 0xA0...0xBF, marker8: 0xD9, marker16: 0xDA, marker32: 0xDB, of: "key")
            guard let key = String(bytes: try reader.take(keyLength), encoding: .utf8) else {
                throw Malformed(description: "state key is not UTF-8")
            }
            let valueLength = try reader.length(fix: nil, marker8: 0xC4, marker16: 0xC5, marker32: 0xC6, of: "value")
            state[key] = Data(try reader.take(valueLength))
        }
        guard reader.isAtEnd else {
            throw Malformed(description: "trailing bytes after state map")
        }
        return state
    }

    private static func writeLength(
        _ length: Int, fix: UInt8?, fixMax: Int, marker8: UInt8?, marker16: UInt8, marker32: UInt8, to out: inout Data
    ) {
        if let fix, length <= fixMax {
            out.append(fix | UInt8(length))
        } else if let marker8, length <= 0xFF {
            out.append(marker8)
            out.append(UInt8(length))
        } else if length <= 0xFFFF {
            out.append(marker16)
            out.append(UInt8(length >> 8))
            out.append(UInt8(length & 0xFF))
        } else {
            out.append(marker32)
            for shift in [24, 16, 8, 0] {
                out.append(UInt8((length >> shift) & 0xFF))
            }
        }
    }

    private struct Reader {
        let bytes: [UInt8]
        var offset = 0

        var isAtEnd: Bool { offset == bytes.count }

        mutating func take(_ count: Int) throws -> ArraySlice<UInt8> {
            guard count >= 0, offset + count <= bytes.count else {
                throw Malformed(description: "state map is truncated")
            }
            defer { offset += count }
            return bytes[offset..<offset + count]
        }

        mutating func integer(width: Int) throws -> Int {
            try take(width).reduce(0) { ($0 << 8) | Int($1) }
        }

        mutating func length(
            fix: ClosedRange<UInt8>?, marker8: UInt8?, marker16: UInt8, marker32: UInt8, of what: String
        ) throws -> Int {
            let marker = try integer(width: 1)
            if let fix, fix.contains(UInt8(marker)) { return marker - Int(fix.lowerBound) }
            if let marker8, marker == Int(marker8) { return try integer(width: 1) }
            if marker == Int(marker16) { return try integer(width: 2) }
            if marker == Int(marker32) { return try integer(width: 4) }
            throw Malformed(description: "unexpected marker 0x\(String(marker, radix: 16)) for state \(what)")
        }
    }
}
