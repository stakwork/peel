import Foundation

enum JSON {
    /// `text` read as JSON into `T`; nil when there is none or it does not fit.
    static func decode<T: Decodable, S: StringProtocol>(_ type: T.Type, from text: S?) -> T? {
        text.flatMap { try? JSONDecoder().decode(type, from: Data($0.utf8)) }
    }
}
