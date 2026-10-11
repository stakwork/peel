import Foundation
import GRDB

// Time zones, as the official apps share them (`docs/design/README.md`, "Time
// zones"): a message's JSON may carry `"metadata": "{\"tz\":\"GMT+1\"}"`, the
// sender's offset when they sent it. Peel sends its own in direct messages and
// private tribes unless that chat's switch is off, and never in a public
// tribe; it reads anyone's.

/// The offsets on the wire: what Peel sends, and its own reading of what
/// arrives. Never `TimeZone(abbreviation:)`, which turns `EST` or `BST` into a
/// city with summer time.
public enum TimeZoneOffset {
    /// The types that carry the sender's offset: text, attachments and
    /// payments (for their notes). Never deletes, boosts or membership messages.
    static let carriedBy = [MessageType.text, MessageType.attachment, MessageType.directPayment]

    /// The longest `tz` value kept from a message; a real one is a dozen characters.
    static let maxLength = 64

    /// `zone`'s offset at `date`, summer time included, in the official apps'
    /// form: "GMT+1", "GMT-5", "GMT+5:30", "GMT+0".
    public static func format(_ zone: TimeZone, at date: Date = .now) -> String {
        let minutes = zone.secondsFromGMT(for: date) / 60
        let sign = minutes < 0 ? "-" : "+"
        let (hours, rest) = (abs(minutes) / 60, abs(minutes) % 60)
        return rest == 0 ? "GMT\(sign)\(hours)" : "GMT\(sign)\(hours):\(rest < 10 ? "0" : "")\(rest)"
    }

    /// The zone a received value names: `GMT` or `UTC`, alone or with `±H` or
    /// `±H:MM` (up to 14 hours), as a fixed offset; or an IANA name this Mac
    /// knows (`Europe/London`). Anything else is nil.
    public static func zone(_ text: String) -> TimeZone? {
        guard text.utf8.count <= maxLength else { return nil }
        if text.contains("/") {
            // Only what a zone name is made of: never a path.
            guard text.utf8.allSatisfy(isNameByte), !text.contains(".."), !text.hasPrefix("/") else { return nil }
            return TimeZone(identifier: text)
        }
        guard text.hasPrefix("GMT") || text.hasPrefix("UTC") else { return nil }
        let offset = text.dropFirst(3)
        guard let sign = offset.first else { return TimeZone(secondsFromGMT: 0) }
        guard sign == "+" || sign == "-" else { return nil }
        let parts = offset.dropFirst().split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count <= 2, let hours = number(parts[0], digits: 1...2), hours <= 14 else { return nil }
        let minutes = parts.count == 2 ? number(parts[1], digits: 2...2) : 0
        guard let minutes, minutes < 60, hours * 60 + minutes <= 14 * 60 else { return nil }
        return TimeZone(secondsFromGMT: (hours * 3600 + minutes * 60) * (sign == "-" ? -1 : 1))
    }

    /// ASCII letters, digits, `/`, `_`, `-` and `+`.
    private static func isNameByte(_ byte: UInt8) -> Bool {
        (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte) || "/_-+".utf8.contains(byte)
    }

    private static func number(_ text: Substring, digits: ClosedRange<Int>) -> Int? {
        guard digits.contains(text.count), text.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(text)
    }

    /// `body` (one of Peel's own, a JSON object of strings) with `metadata`
    /// set to `offset`, or taken out when `offset` is nil, so a message sent
    /// again follows the switch as it is now.
    static func setting(_ offset: String?, in body: String) throws -> String {
        guard offset != nil || body.contains("\"metadata\""),
              var fields = JSON.decode([String: String].self, from: body) else { return body }
        fields["metadata"] = try offset.map { try Engine.json(["tz": $0]) }
        return try Engine.json(fields)
    }
}

/// Someone's local time, from the offset on their latest message.
public struct LocalTime: Sendable, Equatable {
    /// Their zone: a fixed offset, or the named zone if they sent a name.
    public let zone: TimeZone
    /// The value as they sent it ("GMT+1").
    public let sent: String
    /// When the message that carried it was sent.
    public let seen: Date
    /// Their offset minus this account's, in seconds: positive when they are ahead.
    public let difference: Int
}

extension Message {
    /// The sender's zone when they sent this, if they shared it.
    public var senderTimeZone: TimeZone? { senderTZ.flatMap(TimeZoneOffset.zone) }
}

extension Storage {
    /// The time zone item set for `chat`, here or on another device; nil
    /// where none is, which means sharing, as in the official apps.
    public func chatTimeZone(_ chat: String) throws -> TimeZoneSharing? {
        try preference(.timeZoneSharing, for: chat)
    }

    /// The newest offset someone sent in `chat` from `since` (milliseconds)
    /// on that `zone(_:)` can read: in a direct message the contact's, in a
    /// tribe the member's, by alias (the tribe server makes aliases unique
    /// and strips members' keys from what it forwards).
    func newestTimeZone(
        in chat: String, member alias: String?, since: Int64
    ) throws -> (zone: TimeZone, sent: String, timestamp: Int64)? {
        let member = alias == nil ? "" : "AND (CASE WHEN json_valid(sender) THEN json_extract(sender, '$.alias') END) = ?"
        return try pool.read { db in
            let rows = try Row.fetchCursor(
                db,
                sql: """
                    SELECT senderTZ, timestamp FROM message
                    WHERE chat = ? AND senderTZ IS NOT NULL AND timestamp >= ? AND fromMe = 0 \(member)
                    ORDER BY timestamp DESC
                    """,
                arguments: alias.map { [chat, since, $0] } ?? [chat, since]
            )
            while let row = try rows.next() {
                let sent: String = row["senderTZ"]
                if let zone = TimeZoneOffset.zone(sent) { return (zone, sent, row["timestamp"]) }
            }
            return nil
        }
    }

    /// For each of `wanted`, a sender at a moment (milliseconds): the newest
    /// offset they sent in `chat` at or before it, no older than
    /// `Engine.timeZoneFreshness`, that `zone(_:)` reads (among their five
    /// newest there), by index into `wanted`. In a tribe the sender is a
    /// member by alias; in a direct message the contact (`alias` unused).
    /// One query however many are asked, for a page of rows.
    public func senderTimeZones(
        in chat: String, inTribe: Bool, wanted: [(alias: String?, timestamp: Int64)]
    ) throws -> [Int: TimeZone] {
        guard !wanted.isEmpty else { return [:] }
        let member = inTribe ? "AND (CASE WHEN json_valid(m.sender) THEN json_extract(m.sender, '$.alias') END) = w.alias" : ""
        var arguments: [(any DatabaseValueConvertible)?] = []
        for (index, point) in wanted.enumerated() { arguments += [index, point.alias, point.timestamp] }
        arguments += [chat, Int64(Engine.timeZoneFreshness * 1000)]
        return try pool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    WITH w(i, alias, at) AS (VALUES \(Array(repeating: "(?, ?, ?)", count: wanted.count).joined(separator: ", ")))
                    SELECT w.i, (
                        SELECT json_group_array(tz) FROM (
                            SELECT m.senderTZ AS tz FROM message m
                            WHERE m.chat = ? AND m.senderTZ IS NOT NULL AND m.fromMe = 0
                              AND m.timestamp <= w.at AND m.timestamp >= w.at - ? \(member)
                            ORDER BY m.timestamp DESC LIMIT 5
                        )
                    ) AS tz FROM w
                    """,
                arguments: StatementArguments(arguments)
            )
            var zones: [Int: TimeZone] = [:]
            for row in rows {
                guard let list: String = row["tz"],
                      let sent = JSON.decode([String].self, from: list) else { continue }
                if let zone = sent.lazy.compactMap(TimeZoneOffset.zone).first { zones[row["i"]] = zone }
            }
            return zones
        }
    }
}

extension Engine {
    /// How long a received offset counts; older, their time is unknown.
    public static let timeZoneFreshness: TimeInterval = 90 * 24 * 3600

    /// The zone chosen for this account, an IANA name; nil means automatic
    /// (this Mac's).
    public func chosenTimeZone() throws -> String? {
        try storage.preference(.timeZone).flatMap(\.nilIfEmpty)
    }

    /// Chooses this account's zone, an IANA name (or a fixed `GMT±H`), or
    /// nil for automatic.
    public func setTimeZone(_ identifier: String?) throws {
        if let identifier, TimeZoneOffset.zone(identifier) == nil {
            throw Failure.unknownTimeZone(identifier)
        }
        try set(.timeZone, identifier ?? "")
    }

    /// The zone this account's offset comes from in `chat`: the one set for
    /// that chat on another device, else the account's, else this Mac's.
    public func timeZone(for chat: String? = nil) throws -> TimeZone {
        let chatIdentifier = try chat.flatMap { try storage.chatTimeZone($0)?.identifier }
        return [chatIdentifier, try chosenTimeZone()].lazy.compactMap { $0.flatMap(TimeZoneOffset.zone) }.first
            ?? .autoupdatingCurrent
    }

    /// Whether the switch is on in `chat`: on unless turned off. A public
    /// tribe never gets the offset whatever this says (`offsetShared`).
    public func timeZoneSharing(in chat: String) throws -> Bool {
        try storage.chatTimeZone(chat)?.enabled ?? true
    }

    /// The offset a message of `type` to `chat` carries, what `deliver`
    /// sets: nil when the switch is off, and nil unless the chat is a person
    /// the core holds or a tribe whose stored record says private (kept
    /// fresh by the registry refresh on connect and `recheckIfStale` after
    /// sends; never asked here, so a send never waits).
    public func offsetShared(in chat: String, type: Int = MessageType.text, at now: Date = .now) throws -> String? {
        guard knownTribe(chat).map(\.isPrivate) ?? isContact(chat) else { return nil }
        return try sharedOffset(in: chat, type: type, at: now)
    }

    /// Turns sharing this account's offset on or off in a direct message or
    /// a private tribe. Turning it off stops sending; what was sent stays
    /// with them. Either way the chat's `timezone` preference records the
    /// choice, keeping a zone set for the chat on another device.
    public func setTimeZoneSharing(_ enabled: Bool, in chat: String) throws {
        guard chat.isPubkey else { throw Failure.notAChat }
        if enabled {
            if let tribe = knownTribe(chat) {
                guard tribe.isPrivate else { throw Failure.publicTribeTimeZone }
            } else {
                guard isContact(chat) else { throw Failure.notAChat }
            }
        }
        let zone = try storage.chatTimeZone(chat)?.identifier
        try set(.timeZoneSharing, TimeZoneSharing(enabled: enabled, identifier: zone), for: chat)
    }

    /// Someone's local time: a contact's, or with `member` a tribe member's
    /// (by alias), from the newest offset they sent within
    /// `timeZoneFreshness` of `now`. Nil when they have not shared one.
    public func localTime(of pubkey: String, member alias: String? = nil, at now: Date = .now) throws -> LocalTime? {
        if alias == nil, knownTribe(pubkey) != nil {
            throw Failure.memberNeeded
        }
        let since = now.addingTimeInterval(-Self.timeZoneFreshness).millisecondsSince1970
        guard let found = try storage.newestTimeZone(in: pubkey, member: alias, since: since) else { return nil }
        return LocalTime(
            zone: found.zone, sent: found.sent, seen: Date(millisecondsSince1970: found.timestamp),
            difference: found.zone.secondsFromGMT(for: now) - (try timeZone().secondsFromGMT(for: now))
        )
    }

    /// The offset a message of `type` to `chat` would carry by the chat's
    /// switch alone; `offsetShared` also asks whether the chat is private.
    func sharedOffset(in chat: String, type: Int, at now: Date = .now) throws -> String? {
        guard TimeZoneOffset.carriedBy.contains(type), try timeZoneSharing(in: chat) else { return nil }
        return TimeZoneOffset.format(try timeZone(for: chat), at: now)
    }
}
