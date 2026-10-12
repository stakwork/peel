import Foundation

/// Reading, writing and writing out JSON values: what the model clients and
/// tools need to build request bodies and read streamed events.
extension JSONValue {
    /// Reads JSON text. Throws on anything that is not one whole JSON value.
    public init(parsing text: String) throws {
        self = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    /// Any Codable value as JSON: a record's props.
    public init(encoding value: some Encodable) throws {
        self = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
    }

    /// Read back as `type`.
    public func decoded<T: Decodable>(as type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: JSONEncoder().encode(self))
    }

    /// Compact JSON text in AgentKit's stable encoding (`StableJSON`).
    public var jsonString: String {
        // Encoding a JSONValue cannot fail: every case maps to plain JSON.
        (try? StableJSON.string(self)) ?? "null"
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let object) = self { object[key] } else { nil }
    }

    public var string: String? {
        if case .string(let value) = self { value } else { nil }
    }

    public var int: Int? {
        if case .number(let value) = self, let int = Int(exactly: value.rounded(.towardZero)) { int } else { nil }
    }

    public var array: [JSONValue]? {
        if case .array(let value) = self { value } else { nil }
    }
}

// No ExpressibleByNilLiteral: with it, `condition ? nil : value` quietly
// becomes `.null` rather than an absent value. Write `.null`.
extension JSONValue: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral
{
    public init(stringLiteral value: String) { self = .string(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}
