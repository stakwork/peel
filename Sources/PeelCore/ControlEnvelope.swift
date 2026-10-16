import Foundation

// The device channel (docs/agent-on-strut.md, "The device channel"): the
// agent and your devices talk in the agent's DM with control messages,
// ordinary text messages whose `metadata` carries a `peel` envelope beside
// the time zone's `tz`. Their content is one readable line, which the
// official apps show; Peel never shows a control message as a bubble.

/// A message's `metadata`: a JSON object the sender wrote into the body as a
/// string (`sphinx/src/msg/mod.rs`), which the official apps carry along.
enum MessageMetadata {
    /// The longest metadata read from a message; a device's answer with a
    /// catch-up in it is about 20 KB.
    static let maxLength = 64 * 1024

    private struct Field: Decodable { let metadata: String? }

    /// The metadata string in `body`, if it has one no longer than `maxLength`.
    static func string(in body: String?) -> String? {
        guard let metadata = JSON.decode(Field.self, from: body)?.metadata,
              metadata.utf8.count <= maxLength else { return nil }
        return metadata
    }

    /// `body` (one of Peel's own, a JSON object of strings) with `key` set
    /// to `value` in its metadata, or taken out when `value` is nil. The
    /// other keys stay; metadata left with none goes.
    static func setting(_ key: String, to value: JSONValue?, in body: String) throws -> String {
        guard value != nil || body.contains("\"metadata\""),
              var fields = JSON.decode([String: String].self, from: body) else { return body }
        var metadata: [String: JSONValue] = [:]
        if case .object(let existing)? = fields["metadata"].flatMap(JSONValue.init(text:)) { metadata = existing }
        metadata[key] = value
        fields["metadata"] = metadata.isEmpty ? nil : try JSONValue.object(metadata).text
        return try Engine.json(fields)
    }
}

/// One control message's envelope, `metadata.peel` (docs/agent-on-strut.md,
/// "The envelope"). Whoever sent the message wrote it: read it with
/// `Message.control`, which checks the version and the fields each `op` needs.
public struct ControlEnvelope: Codable, Sendable, Equatable {
    /// The version this Peel reads and writes.
    public static let version = 1

    public enum Op: String, Codable, Sendable {
        /// Agent to device: do this.
        case request
        /// Device to agent: stored, working on it.
        case ack
        /// Device to agent: done, with `status`.
        case result
        /// Either way: the agent no longer needs a request (`re`), or you
        /// stop a turn (`run`).
        case cancel
        /// Agent to device: a line for a person ("Waiting for your Mac").
        case status
    }

    /// How a request ended, on its result.
    public enum Status: String, Codable, Sendable {
        case done, denied, expired, failed, unknown
    }

    public var v: Int
    public var op: Op
    /// On a request: its id, which every answer names in `re`.
    public var id: String?
    /// On a request: the device it is for.
    public var device: String?
    /// On a request: what to do (`chats.unseen`, `send`, …).
    public var kind: String?
    public var args: JSONValue?
    /// On a request: seconds since 1970 after which it is never done.
    public var notAfter: Int64?
    /// On an answer or a cancel: the request it is about.
    public var re: String?
    public var status: Status?
    public var result: JSONValue?
    public var error: String?
    /// On a cancel or a status line: the agent's turn.
    public var run: String?
    public var state: String?
    public var text: String?

    enum CodingKeys: String, CodingKey {
        case v, op, id, device, kind, args, re, status, result, error, run, state, text
        case notAfter = "not_after"
    }

    public init(
        op: Op, id: String? = nil, device: String? = nil, kind: String? = nil, args: JSONValue? = nil,
        notAfter: Int64? = nil, re: String? = nil, status: Status? = nil, result: JSONValue? = nil,
        error: String? = nil, run: String? = nil, state: String? = nil, text: String? = nil
    ) {
        self.v = Self.version
        self.op = op
        self.id = id
        self.device = device
        self.kind = kind
        self.args = args
        self.notAfter = notAfter
        self.re = re
        self.status = status
        self.result = result
        self.error = error
        self.run = run
        self.state = state
        self.text = text
    }

    /// Whether the fields `op` needs are there: a request names its id,
    /// device, kind and expiry; an ack or result its request (a result
    /// also its status); a cancel the request or the turn; a status line
    /// its turn, state and text.
    var isComplete: Bool {
        switch op {
        case .request: id != nil && device != nil && kind != nil && notAfter != nil
        case .ack: re != nil
        case .result: re != nil && status != nil
        case .cancel: re != nil || run != nil
        case .status: run != nil && state != nil && text != nil
        }
    }

    /// Whether this Peel reads it: its version, and the fields its `op` needs.
    public var isReadable: Bool { v == Self.version && isComplete }

    /// `body` (one of Peel's own) carrying this envelope in its metadata,
    /// beside whatever else is there (`tz`).
    func adding(to body: String) throws -> String {
        try MessageMetadata.setting("peel", to: JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(self)), in: body)
    }
}

/// What a control message says, as this Peel reads it.
public enum ControlMessage: Sendable, Equatable {
    case envelope(ControlEnvelope)
    /// A control message this Peel cannot read: a version or `op` it does
    /// not know, or fields that do not fit. Shown as its text, never acted on.
    case unsupported

    /// The control message in `body`: one whose metadata's `peel` is an
    /// object with an `op`. A `peel` without one is a talk message's extras
    /// (its tool rows, an automation's name), and nil.
    static func read(_ body: String?) -> ControlMessage? {
        // Cheap first: the keys as they appear inside the metadata string,
        // or an escape that could spell them.
        guard let body, body.contains(#"\"peel\""#) && body.contains(#"\"op\""#) || body.contains(#"\u"#),
              let metadata = MessageMetadata.string(in: body),
              case .object(let fields)? = JSONValue(text: metadata), case .object(let peel)? = fields["peel"],
              peel["op"] != nil else { return nil }
        // Typed only once it is one.
        guard let data = try? JSONEncoder().encode(JSONValue.object(peel)),
              let envelope = try? JSONDecoder().decode(ControlEnvelope.self, from: data),
              envelope.isReadable else { return .unsupported }
        return .envelope(envelope)
    }
}

extension Message {
    /// What this message says on the device channel, if it is a control
    /// message: only text carries one.
    public var control: ControlMessage? {
        type == MessageType.text && !deleted ? ControlMessage.read(body) : nil
    }
}
