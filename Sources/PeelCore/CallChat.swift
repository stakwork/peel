import Foundation

/// One line of a call's chat: what a person typed, what Jamie answered, or
/// what Jamie heard a person say. In memory for the one call only.
public struct CallChatMessage: Sendable, Equatable, Identifiable {
    public let id: String
    public let timestamp: Date
    /// Markdown, as the sender wrote it (Jamie's replies are markdown).
    public let text: String
    /// The name the sender joined the call with; nil for Jamie's own messages.
    public let sender: String?
    /// A person's spoken command, echoed by Jamie as their row.
    public let isVoice: Bool
    /// What a reply of Jamie's points to, from strut's own entries beside it
    /// (`strut`); the same deliverables are links in `text` too (`shownText`).
    public let artifacts: [AgentArtifact]

    public init(id: String, timestamp: Date, text: String, sender: String?, isVoice: Bool = false,
                artifacts: [AgentArtifact] = []) {
        self.id = id
        self.timestamp = timestamp
        self.text = text
        self.sender = sender
        self.isVoice = isVoice
        self.artifacts = artifacts
    }

    /// Jamie's messages carry no sender.
    public var isFromJamie: Bool { sender?.isEmpty ?? true }

    /// The text to show: with `artifacts` under it, without the list of
    /// links (`- [Title](url)` lines) that names the same deliverables.
    public var shownText: String {
        guard !artifacts.isEmpty else { return text }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.range(of: #"^\s*[-*]\s+\[[^\]]*\]\([^)\s]+\)\s*$"#, options: .regularExpression) == nil }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// The call chat's wire format, the same one Sphinx Mac and Hive's voice
/// page speak on LiveKit's data channel: UTF-8 JSON on `topic`, reliable.
public enum CallChatWire {
    /// The data topic every chat message and Jamie's status rows travel on.
    public static let topic = "lk-chat-topic"

    /// What a payload on `topic` turned out to be.
    public enum Incoming: Sendable, Equatable {
        case message(CallChatMessage)
        /// Jamie is working on a request (`status: processing`). Not a chat
        /// message: never kept in the history.
        case status(id: String)
    }

    /// Every field the wire carries; unknown ones are ignored, and a field
    /// of the wrong shape (a control payload's, say) fails the decode.
    private struct Payload: Decodable {
        var id: String?
        var timestamp: Double?
        var message: String?
        var sender: String?
        var status: String?
        var voice: Bool?
        /// strut's entries for a reply and the workspace whose strut ran it:
        /// `{workspace, artifacts}` (sphinx-voice plans/call-artifacts.md).
        /// Any JSON, so a bad one never costs the message.
        var strut: JSONValue?
    }

    /// What Peel sends. The timestamp is a whole number of milliseconds.
    private struct Outgoing: Encodable {
        let id: String
        let timestamp: Int64
        let message: String
        let sender: String
    }

    /// A message as Peel sends it: `{id, timestamp (epoch ms), message, sender}`.
    public static func encode(id: String, timestamp: Date, text: String, sender: String) -> Data {
        let outgoing = Outgoing(
            id: id, timestamp: Int64((timestamp.timeIntervalSince1970 * 1000).rounded()), message: text, sender: sender
        )
        return (try? JSONEncoder().encode(outgoing)) ?? Data()
    }

    /// Nil for anything that is not a chat message or a status row: other
    /// payloads on the topic (`{"type":"tts-toggle"}`), malformed JSON and
    /// empty or whitespace-only text. A message's `strut` is read only
    /// `fromJamie`: what it names opens with this person's own access.
    public static func decode(_ data: Data, fromJamie: Bool = false) -> Incoming? {
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data),
              let id = payload.id, !id.isEmpty
        else { return nil }
        let time = Date(timeIntervalSince1970: (payload.timestamp ?? Date.now.timeIntervalSince1970 * 1000) / 1000)
        if let status = payload.status {
            return status == "processing" ? .status(id: id) : nil
        }
        guard let text = payload.message, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let sender = payload.sender?.trimmingCharacters(in: .whitespacesAndNewlines)
        return .message(CallChatMessage(
            id: id, timestamp: time, text: text, sender: sender?.isEmpty == false ? sender : nil,
            isVoice: payload.voice == true, artifacts: fromJamie ? artifacts(payload.strut) : []
        ))
    }

    /// strut's entries in `strut`, each resolved against its workspace.
    static func artifacts(_ strut: JSONValue?) -> [AgentArtifact] {
        guard case .object(let fields)? = strut, case .string(let workspace)? = fields["workspace"],
              case .array(let entries)? = fields["artifacts"] else { return [] }
        return entries.prefix(AgentArtifact.most).compactMap { AgentArtifact(strutEntry: $0, workspace: workspace) }
    }

    /// `text` with its last word, an `@` or the start of `@jamie` in any
    /// case (`@`, `@j`, `@JAM`, `@jamie`), completed to `@Jamie ` for the Tab
    /// key. Nil when the text does not end in such a word (a space after it,
    /// an address, or another name), so Tab then does what it always does.
    public static func completingJamie(_ text: String) -> String? {
        guard text.last?.isWhitespace == false else { return nil }
        let start = text.lastIndex(where: \.isWhitespace).map { text.index(after: $0) } ?? text.startIndex
        let word = text[start...]
        guard word.hasPrefix("@") else { return nil }
        let typed = word.dropFirst().lowercased()
        guard typed.count <= "jamie".count, "jamie".hasPrefix(typed) else { return nil }
        return String(text[..<start]) + "@Jamie "
    }

    /// Whether `text` asks Jamie: an `@jamie` (any case) at the start or
    /// after whitespace, and not the start of a longer word or an address.
    public static func mentionsJamie(_ text: String) -> Bool {
        text.range(of: #"(?i)(^|\s)@jamie\b"#, options: .regularExpression) != nil
    }
}

/// A call's chat as a value: the rows in order, what Jamie is doing, and the
/// rules that keep it bounded and free of repeats. The session owns one.
public struct CallChatLog: Sendable, Equatable {
    /// A row: the message, whether this side sent it and whether it never left.
    public struct Row: Sendable, Equatable, Identifiable {
        public let message: CallChatMessage
        /// Sent from this Mac, so aligned and marked as yours.
        public let isMine: Bool
        /// A send that could not be published; shown as "Not sent" with a retry.
        public var failed = false
        public var id: String { message.id }
    }

    /// The most rows kept; the oldest go first.
    public static let cap = 500

    public private(set) var rows: [Row] = []
    /// Jamie is working: set by a status row, cleared by the next message
    /// from Jamie (or by `stopThinking`).
    public private(set) var jamieThinking = false
    /// Bumped by each status row, so a timer can tell it is for the latest.
    public private(set) var thinkingSerial = 0

    public init() {}

    /// Whether `row` is Jamie's: it has no sender.
    public func isFromJamie(_ row: Row) -> Bool { row.message.isFromJamie }

    /// Adds a message this side sent, at once. False for an id already there.
    @discardableResult
    public mutating func appendLocal(_ message: CallChatMessage) -> Bool {
        append(Row(message: message, isMine: true))
    }

    /// Applies what arrived. Returns the row it added, or nil for a status
    /// row (which sets `jamieThinking`) and a repeated id.
    @discardableResult
    public mutating func receive(_ incoming: CallChatWire.Incoming) -> Row? {
        switch incoming {
        case .status:
            jamieThinking = true
            thinkingSerial += 1
            return nil
        case .message(let message):
            let row = Row(message: message, isMine: false)
            guard append(row) else { return nil }
            if message.isFromJamie { jamieThinking = false }
            return row
        }
    }

    /// Marks a local send failed, or sent again when `failed` is false.
    public mutating func mark(id: String, failed: Bool) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[index].failed = failed
    }

    /// Drops the thinking line: Jamie left, or it has taken too long.
    /// With `serial`, only if no newer status row came since.
    public mutating func stopThinking(ifSerial serial: Int? = nil) {
        if let serial, serial != thinkingSerial { return }
        jamieThinking = false
    }

    private mutating func append(_ row: Row) -> Bool {
        guard !rows.contains(where: { $0.id == row.id }) else { return false }
        rows.append(row)
        if rows.count > Self.cap { rows.removeFirst(rows.count - Self.cap) }
        return true
    }
}

extension AgentArtifact {
    /// One of strut's own entries (`GET …/runs/:runId/artifacts`, strut's
    /// specs/CALLBACKS.md §4) as a call's chat carries it, beside the
    /// workspace whose strut answered: its handle is resolved against that
    /// workspace, as strut's UI resolves a peer's (`linkOf`,
    /// `peerArtifactPath`). Nil for an entry with no title.
    init?(strutEntry value: JSONValue, workspace: String) {
        guard case .object(let fields) = value, let read = AgentArtifact(value) else { return nil }
        self.init(id: read.id, title: read.title, label: read.label, summary: read.summary, url: read.url,
                  handle: Handle.isPeerID(workspace) ? Self.handle(of: fields, on: workspace) : nil)
    }

    /// Where Peel's own strut shows the entry, through `/peers/<workspace>`:
    /// an app by name (and version); a peer's file by its peer, `via` and
    /// job; a strut-relative url behind the workspace. Nil for a peer's app,
    /// two hops off, which strut's `?app=` cannot name.
    private static func handle(of fields: [String: JSONValue], on workspace: String) -> Handle? {
        func text(_ key: String) -> String? {
            if case .string(let text)? = fields[key], !text.isEmpty { text } else { nil }
        }
        if case .object(let app)? = fields["app"] {
            guard text("peer") == nil, case .string(let name)? = app["name"] else { return nil }
            var pinned = ""
            if case .string(let version)? = app["version"], !version.isEmpty { pinned = "@" + version }
            return Handle(app: "@\(workspace)/\(name)\(pinned)")
        }
        if let peer = text("peer") {
            guard let job = text("job"), let path = text("path") else { return nil }
            let hops = [workspace, peer] + [text("via")].compactMap { $0 }
            guard hops.allSatisfy(Handle.isPeerID) else { return nil }
            let file = path.split(separator: "/").map { encoded(String($0)) }.joined(separator: "/")
            return Handle(path: hops.map { "/peers/\($0)" }.joined() + "/jobs/\(encoded(job))/files/" + file)
        }
        if let url = text("url"), url.hasPrefix("/"), !url.hasPrefix("//") {
            return Handle(path: "/peers/\(workspace)" + url)
        }
        return nil
    }

    /// `value` as one path segment, as `encodeURIComponent` writes it.
    private static func encoded(_ value: String) -> String {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")
        return value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }
}
