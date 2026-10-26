import Foundation

enum JSON {
    /// `text` read as JSON into `T`; nil when there is none or it does not fit.
    static func decode<T: Decodable, S: StringProtocol>(_ type: T.Type, from text: S?) -> T? {
        text.flatMap { try? JSONDecoder().decode(type, from: Data($0.utf8)) }
    }
}

/// A JSON Web Token, read without checking its signature (Peel holds no key).
enum JWT {
    /// The payload of `header.payload.signature` as `T`; nil for anything
    /// longer than 8 KB, not in three parts, or not fitting `T`.
    static func payload<T: Decodable>(_ type: T.Type, of token: String) -> T? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard token.utf8.count <= 8192, parts.count == 3,
              let payload = MediaToken.base64URLDecode(String(parts[1])) else { return nil }
        return try? JSONDecoder().decode(type, from: payload)
    }
}

extension Sequence<UInt8> {
    /// Lowercase hex, two characters a byte.
    public var hex: String { map { String(format: "%02x", $0) }.joined() }
}

extension Data {
    /// The bytes `hex` spells, two characters a byte; nil for anything else.
    init?(hex: String) {
        let digits = Array(hex.utf8)
        guard digits.count.isMultiple(of: 2), hex.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }
        var bytes = Data(capacity: digits.count / 2)
        for index in stride(from: 0, to: digits.count, by: 2) {
            guard let byte = UInt8(String(decoding: digits[index...index + 1], as: UTF8.self), radix: 16) else { return nil }
            bytes.append(byte)
        }
        self = bytes
    }
}

extension Date {
    /// An ISO 8601 date as strut and Hive write one, with or without a
    /// fraction of a second; nil for anything else.
    public init?(iso8601 text: String) {
        guard let date = (try? Date(text, strategy: .iso8601.year().month().day().time(includingFractionalSeconds: true)))
            ?? (try? Date(text, strategy: .iso8601)) else { return nil }
        self = date
    }
}
