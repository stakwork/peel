import Foundation

/// One write to the agent's records: the only way anything changes. The
/// record and link tables are a view of the event log and can be rebuilt
/// from it.
///
/// The JSON encoding is a contract with the official Sphinx apps, versioned
/// by `v`. Keys are snake_case and sorted, with no whitespace:
///
/// ```
/// {"device":"mac-1","event_id":"<uuid>","fields":{…},"op":"add",
///  "ref_id":"<uuid>","ts":{"counter":0,"device":"mac-1","wall_ms":1760000000000},"v":1}
/// ```
///
/// `fields` by `op`:
/// - `add`: `type`, `name`, `created_by` (strings); `body`, `source`
///   (string or null); `props` (an object).
/// - `update`: any of `type`, `name`, `body`, `source`, `props`;
///   `deleted_ms: null` restores a forgotten record.
/// - `link`: `type`, `from`, `to` (record ref_ids), `created_by`, `props`;
///   `ref_id` is the link's own.
/// - `unlink`, `forget`: nothing needed; `reason` (a string) may say why.
///
/// `add`, `update` and `forget` are for records, `link` and `unlink` for
/// links: a link's ends and type do not change (a new link replaces it).
/// `device` is always `ts.device`; an event where they differ is refused.
///
/// Each top-level field, and each key inside `props`, is its own value: the
/// one with the latest `ts` wins (ties, which only a replayed event can
/// make, go to the higher `event_id`). A props key set to null is removed.
public struct Event: Codable, Sendable, Equatable {
    public static let version = 1

    public enum Op: String, Codable, Sendable {
        case add, update, link, unlink, forget
    }

    public var v: Int
    public var eventId: String
    public var op: Op
    public var refId: String
    public var fields: [String: JSONValue]
    public var ts: HLC
    public var device: String

    public init(
        v: Int = Event.version, eventId: String = UUID().uuidString.lowercased(), op: Op, refId: String,
        fields: [String: JSONValue] = [:], ts: HLC
    ) {
        self.v = v
        self.eventId = eventId
        self.op = op
        self.refId = refId
        self.fields = fields
        self.ts = ts
        device = ts.device
    }

    enum CodingKeys: String, CodingKey {
        case v, eventId = "event_id", op, refId = "ref_id", fields, ts, device
    }

    /// The event's stable JSON (see above).
    public func encoded() throws -> Data { try StableJSON.encode(self) }

    public static func decode(_ data: Data) throws -> Event {
        try JSONDecoder().decode(Event.self, from: data)
    }
}

/// The one JSON encoding AgentKit writes: keys sorted, slashes as they are,
/// so the same value always gives the same bytes.
enum StableJSON {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    static func string<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try encode(value), as: UTF8.self)
    }
}
