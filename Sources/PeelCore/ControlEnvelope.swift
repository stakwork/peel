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
        /// stop a turn (`run`, or with neither the turn in flight).
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
    /// also its status); a status line its turn, state and text. A cancel
    /// names what it stops, or nothing for the turn in flight (Stop).
    var isComplete: Bool {
        switch op {
        case .request: id != nil && device != nil && kind != nil && notAfter != nil
        case .ack: re != nil
        case .result: re != nil && status != nil
        case .cancel: true
        case .status: run != nil && state != nil && text != nil
        }
    }

    /// Whether a request with this `not_after` is past it at `now`: its
    /// second gone by. The one rule for the device that answers and the
    /// rows that say how it ended.
    public static func isPast(_ notAfter: Int64, at now: Date) -> Bool {
        notAfter < Int64(now.timeIntervalSince1970)
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
              let peel = peel(in: body), peel["op"] != nil else { return nil }
        // Typed only once it is one.
        guard let data = try? JSONEncoder().encode(JSONValue.object(peel)),
              let envelope = try? JSONDecoder().decode(ControlEnvelope.self, from: data),
              envelope.isReadable else { return .unsupported }
        return .envelope(envelope)
    }

    /// The `peel` object in `body`'s metadata, untyped.
    static func peel(in body: String?) -> [String: JSONValue]? {
        guard let metadata = MessageMetadata.string(in: body),
              case .object(let fields)? = JSONValue(text: metadata), case .object(let peel)? = fields["peel"] else { return nil }
        return peel
    }
}

extension Message {
    /// What this message says on the device channel, if it is a control
    /// message: only text carries one.
    public var control: ControlMessage? {
        type == MessageType.text && !deleted ? ControlMessage.read(body) : nil
    }

    /// The tools an agent's reply ran, as the bridge lists them from the
    /// run's events (`metadata.peel.tools`, docs/agent-on-strut.md, "One
    /// conversation"); empty for anything else. Whoever sent the message
    /// wrote them: shown as plain words, never acted on.
    public var agentTools: [AgentToolLine] {
        guard case .array(let tools)? = talkExtra("tools") else { return [] }
        return tools.prefix(AgentToolLine.most).compactMap(AgentToolLine.init)
    }

    /// The job an agent's message is about (`metadata.peel.job`): its
    /// result, its question, or that it failed (docs/agent-on-strut.md, "A
    /// job's progress"). Nil for anything else.
    public var agentJob: AgentJob? { talkExtra("job").flatMap(AgentJob.init) }

    /// What an agent's message points to (`metadata.peel.artifacts`): a
    /// job's deliverables, a page, a link.
    public var agentArtifacts: [AgentArtifact] {
        guard case .array(let artifacts)? = talkExtra("artifacts") else { return [] }
        return artifacts.prefix(AgentArtifact.most).compactMap(AgentArtifact.init)
    }

    /// What a message points to from strut's own entries in its metadata,
    /// `metadata.strut` (`{ workspace, artifacts }`): Jamie's replies in a
    /// tribe carry them (docs/hive-tribes.md), and each is resolved against
    /// that workspace as a call's chat resolves Jamie's
    /// (`AgentArtifact(strutEntry:workspace:)`). Whoever sent the message
    /// wrote them, and in a tribe that is anyone: an entry opens only
    /// against the reader's own pairing with that workspace, never by itself.
    public var strutArtifacts: [AgentArtifact] {
        guard type == MessageType.text, !deleted, let body, body.contains("strut") || body.contains(#"\u"#),
              let metadata = MessageMetadata.string(in: body), case .object(let fields)? = JSONValue(text: metadata) else { return [] }
        return CallChatWire.artifacts(fields["strut"])
    }

    /// `key` in a talk message's extras: `metadata.peel` with no `op`.
    private func talkExtra(_ key: String) -> JSONValue? {
        guard type == MessageType.text, !deleted, let body, body.contains(key),
              let peel = ControlMessage.peel(in: body), peel["op"] == nil else { return nil }
        return peel[key]
    }
}

/// A job an agent's message is about: strut's job id, its title, and where
/// it stands as of this message.
public struct AgentJob: Sendable, Equatable {
    public enum State: String, Sendable {
        /// Started, or going on (a progress note).
        case working
        /// It needs your answer; your next message continues it.
        case asking
        case done
        case failed
    }

    public let id: String
    public let title: String?
    public let state: State?

    public init(id: String, title: String? = nil, state: State? = nil) {
        self.id = id
        self.title = title
        self.state = state
    }

    init?(_ value: JSONValue) {
        guard case .object(let fields) = value, case .string(let id)? = fields["id"], !id.isEmpty else { return nil }
        var title: String?
        if case .string(let text)? = fields["title"], !text.isEmpty { title = String(text.prefix(AgentToolLine.longest)) }
        var state: State?
        if case .string(let text)? = fields["state"] { state = State(rawValue: text) }
        self.init(id: String(id.prefix(AgentToolLine.longest)), title: title, state: state)
    }
}

/// Something an agent's message points to, as strut's reply shape gives it
/// (`{ id, title, kind?, label?, summary?, url? }`) and the bridge adds to
/// (`path` or `app`, stakwork/sphinx#391): shown by its title; opened by an
/// https link, or on Peel's own strut by its handle.
public struct AgentArtifact: Sendable, Equatable {
    /// The most read from one message.
    static let most = 20

    public let id: String
    public let title: String
    /// What it is to the reader: "Plan", "Page", "Screenshot".
    public let label: String?
    public let summary: String?
    /// An https link with a host and no user name in it, if it has one;
    /// anything else is dropped (`https://bank.com@evil.example` reads as the bank).
    public let url: URL?
    /// Where Peel's own strut shows it, if the bridge named a place strut
    /// would take; anything else is dropped.
    public let handle: Handle?

    public init(id: String, title: String, label: String? = nil, summary: String? = nil, url: URL? = nil,
                handle: Handle? = nil) {
        self.id = id
        self.title = title
        self.label = label
        self.summary = summary
        self.url = url
        self.handle = handle
    }

    init?(_ value: JSONValue) {
        guard case .object(let fields) = value, case .string(let title)? = fields["title"], !title.isEmpty else { return nil }
        func text(_ key: String) -> String? {
            if case .string(let text)? = fields[key], !text.isEmpty { String(text.prefix(AgentToolLine.longest)) } else { nil }
        }
        var url: URL?
        if case .string(let link)? = fields["url"], let parsed = URL(string: link), parsed.scheme == "https", parsed.host() != nil,
           parsed.user == nil, parsed.password == nil {
            url = parsed
        }
        var handle: Handle?
        if case .string(let path)? = fields["path"] {
            handle = Handle(path: path)
        } else if case .string(let app)? = fields["app"] {
            handle = Handle(app: app)
        }
        self.init(id: text("id") ?? title, title: String(title.prefix(AgentToolLine.longest)), label: text("label"),
                  summary: text("summary"), url: url, handle: handle)
    }
}

extension AgentArtifact {
    /// A deliverable on a strut, as strut's UI shows one alone (its
    /// `?artifact=` and `?app=`, strut's specs/API.md §14.3). Only these
    /// shapes: the words are a message's, and the page opened from them is
    /// loaded with strut's key.
    public enum Handle: Sendable, Equatable {
        /// A file strut serves: `/jobs/<job>/files/<file>` or
        /// `/artifacts/<run>/<file>`, behind at most three `/peers/<id>` (an
        /// org's, through strut's read-through: the org, its peer and that
        /// peer's `via`), each segment percent-encoded.
        case file(String)
        /// An app: `<name>`, or `@<id>/<name>` for an org's, with `@vN`
        /// after it to show that version rather than the live one.
        case app(String)

        /// The org it lives on, which the person reads as `@<id>`: the first
        /// hop; nil for one of this strut's own.
        public var peer: String? {
            switch self {
            case .file(let path):
                let parts = path.split(separator: "/", omittingEmptySubsequences: false)
                return parts.count > 2 && parts[1] == "peers" ? String(parts[2]) : nil
            case .app(let app):
                guard app.hasPrefix("@"), let slash = app.firstIndex(of: "/") else { return nil }
                return String(app[app.index(after: app.startIndex)..<slash])
            }
        }

        /// An app's name on its strut and the version it names, if any
        /// (`@acme/board@v3` is `board`, `v3`); nil for a file.
        public var app: (name: String, version: String?)? {
            guard case .app(let app) = self else { return nil }
            var name = Substring(app)
            if app.hasPrefix("@"), let slash = app.firstIndex(of: "/") { name = app[app.index(after: slash)...] }
            guard let at = name.lastIndex(of: "@") else { return (String(name), nil) }
            return (String(name[..<at]), String(name[name.index(after: at)...]))
        }

        /// A file's handle, if `path` is exactly one of those shapes: a path's
        /// characters only, no `.` or `..` segment however it is written, a
        /// run id with no `/` (only a job's holds one), and no escaped `/`,
        /// `\` or control character in the file's own segments.
        public init?(path: String) {
            guard path.utf8.count <= 512, path.hasPrefix("/"), path.unicodeScalars.allSatisfy(Self.pathCharacters.contains) else {
                return nil
            }
            var segments = path.dropFirst().split(separator: "/", omittingEmptySubsequences: false).map(String.init)[...]
            var hops = 0
            while segments.first == "peers" {
                guard hops < 3, segments.count > 1, Self.isPeerID(segments[segments.startIndex + 1]) else { return nil }
                segments = segments.dropFirst(2)
                hops += 1
            }
            let file: ArraySlice<String>
            switch segments.first {
            case "jobs" where segments.count > 3 && segments[segments.startIndex + 2] == "files":
                file = segments.dropFirst(3)
            case "artifacts" where segments.count > 2:
                file = segments.dropFirst(2)
            default:
                return nil
            }
            // The job or run id; a job's may hold an escaped `/` (`peer%2Fj-1`).
            guard let id = segments.dropFirst().first?.removingPercentEncoding, Self.isID(id),
                  segments.first == "jobs" || !id.contains("/") else { return nil }
            for segment in file {
                guard let plain = segment.removingPercentEncoding, !plain.isEmpty, plain != ".", plain != "..",
                      !plain.contains("/"), !plain.contains("\\"),
                      !plain.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
            }
            self = .file(path)
        }

        /// An app's handle, if `app` is a strut app name, behind `@<id>/` for
        /// an org's, and pinned to a version by `@vN` after it (strut's solo
        /// page shows that version, specs/API.md §14.3).
        public init?(app: String) {
            var name = Substring(app)
            if app.hasPrefix("@") {
                guard let slash = app.firstIndex(of: "/"), Self.isPeerID(String(app[app.index(after: app.startIndex)..<slash])) else {
                    return nil
                }
                name = app[app.index(after: slash)...]
            }
            if let at = name.lastIndex(of: "@") {
                guard name[name.index(after: at)...].range(of: #"^v[0-9]+$"#, options: .regularExpression) != nil else { return nil }
                name = name[..<at]
            }
            guard Self.isAppName(String(name)) else { return nil }
            self = .app(app)
        }

        /// A URL path's characters (RFC 3986's `pchar` and `/`): every other
        /// one is percent-encoded by whoever made the path.
        private static let pathCharacters = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~!$&'()*+,;=:@%/")

        /// strut's peer ids: letters, digits, `.`, `_` and `-`, a letter or
        /// digit first, at most 64 (the person reads one as `@<id>`).
        public static func isPeerID(_ id: String) -> Bool {
            id.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$"#, options: .regularExpression) != nil
        }

        /// strut's app names (`validateAppName`): `/`-separated segments of
        /// letters, digits, `_`, `.` and `-`, each starting with a letter or
        /// digit; never `@`, which pins a version, and no segment that reads
        /// as a version (`v2`) or is the app's database (`data.db`).
        public static func isAppName(_ name: String) -> Bool {
            name.count <= 120
                && name.range(of: #"^[A-Za-z0-9][A-Za-z0-9_.-]*(/[A-Za-z0-9][A-Za-z0-9_.-]*)*$"#, options: .regularExpression) != nil
                && !name.split(separator: "/").contains { $0 == "data.db" || $0.range(of: #"^v[0-9]+$"#, options: .regularExpression) != nil }
        }

        /// strut's job and run ids: `/`-separated segments of letters,
        /// digits, `.`, `_` and `-`, a letter or digit at each end, at most 120.
        static func isID(_ id: String) -> Bool {
            let segment = #"[A-Za-z0-9]([A-Za-z0-9._-]*[A-Za-z0-9])?"#
            return id.count <= 120 && id.range(of: "^\(segment)(/\(segment))*$", options: .regularExpression) != nil
        }
    }
}

/// One tool an agent's reply ran: its name as strut gives it
/// (`sphinx_unseen`), a line of what it was asked, and whether it failed.
public struct AgentToolLine: Sendable, Equatable {
    /// The most read from one reply (the bridge caps the list at 2 KB).
    static let most = 50
    /// The longest name or summary kept.
    static let longest = 200

    public let name: String
    public let summary: String
    public let failed: Bool

    public init(name: String, summary: String = "", failed: Bool = false) {
        self.name = name
        self.summary = summary
        self.failed = failed
    }

    init?(_ value: JSONValue) {
        guard case .object(let fields) = value, case .string(let name)? = fields["name"], !name.isEmpty else { return nil }
        var summary = ""
        if case .string(let text)? = fields["summary"] { summary = text }
        self.init(name: String(name.prefix(Self.longest)), summary: String(summary.prefix(Self.longest)),
                  failed: fields["failed"] == .bool(true))
    }
}

/// The agent's DM read as the agent chat (docs/agent-on-strut.md, "One
/// conversation"): the bridge answers each message of yours with one reply
/// that names it (`replyUUID`), "Stopped." included.
public enum AgentDM {
    /// Your message the agent is still answering, if any: your newest text
    /// that was not refused, unless a later message of the agent's answers
    /// it. Messages oldest first, as a timeline holds them.
    public static func unanswered(in messages: [Message]) -> Message? {
        var answered = Set<String>()
        for message in messages.reversed() where message.type == MessageType.text && !message.deleted {
            guard message.fromMe else {
                if let uuid = answer(message) { answered.insert(uuid) }
                continue
            }
            guard message.control == nil, !message.notSent else { continue }
            return message.uuid.flatMap { answered.contains($0) ? nil : message }
        }
        return nil
    }

    /// Whether the agent has answered your message `uuid` among `messages`.
    public static func answers(_ uuid: String, in messages: [Message]) -> Bool {
        messages.contains { answer($0) == uuid }
    }

    /// The message an agent's text answers, by uuid; nil for anything else.
    private static func answer(_ message: Message) -> String? {
        message.type == MessageType.text && !message.deleted && !message.fromMe ? message.replyUUID : nil
    }
}
