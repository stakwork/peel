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
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
