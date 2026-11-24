import Foundation

// Jamie from a box in a group call (docs/hive-calls.md, "From a box";
// stadeum plans/group-calls.md §5 and §7, call-canvas.md §4): the box's own
// voice service joins Peel's room itself with the call's key, hearing and
// speaking with the box's own models. Peel asks the box's strut as the
// person, with the token it holds for the box (`BoxLink`): whether its Jamie
// can join a call now (`GET /voice/calls`), to bring it into one
// (`POST /voice/calls`), and for the person's own ticket into a call it is
// in (`POST /voice/calls/ticket`), so what they ask runs as them.

/// What a box says of its group calls (`GET /voice/calls`).
public struct BoxCalls: Sendable, Equatable {
    /// Its Jamie can join a group call now: the box's streaming recognizer
    /// has answered once. False while it loads, and on a box from before
    /// group calls.
    public var group: Bool
    /// The LiveKit server the box joins, as LiveKit reads it (`wss://`, or
    /// `ws://`); nil when the box named none Peel can read.
    public var livekit: URL?

    public init(group: Bool, livekit: URL?) {
        self.group = group
        self.livekit = livekit
    }

    /// Nothing to offer: a box from before group calls, or no voice service.
    public static let noGroupCalls = BoxCalls(group: false, livekit: nil)

    /// Whether a call on `callServer` (`host[:port]`, this account's) may
    /// bring this box's Jamie: it is ready, and it joins a LiveKit server
    /// that call server's tickets may name (`CallServer.mediaURL`). A box on
    /// any other LiveKit would sit in a room nobody on the call is in.
    public func joins(callServer: String?) -> Bool {
        guard group, let livekit, let callServer, let base = TribeLink.baseURL(callServer) else { return false }
        return (try? CallServer.mediaURL(livekit.absoluteString, callServer: base)) != nil
    }
}

/// A ticket a box gave this device's person into a call its Jamie is in
/// (`POST /voice/calls/ticket`): the LiveKit server, a token under an
/// identity the box records against the person (`box_<32 hex>`), so a turn
/// from it runs as them. Checked as the call server's tickets are before it
/// is used (`Engine.callTicket`). In memory for one join; never described
/// with its token.
public struct BoxCallTicket: Sendable, CustomStringConvertible, CustomReflectable {
    public let url: String
    public let token: String
    public let identity: String

    public init(url: String, token: String, identity: String) {
        self.url = url
        self.token = token
        self.identity = identity
    }

    public var description: String { "BoxCallTicket(\(url), identity \(identity), token not shown)" }
    public var customMirror: Mirror { Mirror(self, children: ["url": url, "identity": identity]) }
}

extension BoxClient {
    /// What the box says of its group calls, asked as `person`. A strut or
    /// voice service from before them (404, 405), or a box with none set up
    /// or not answering it (403, 503), has nothing to offer; any other
    /// refusal throws, so what was read before stays. A token the box no
    /// longer takes (401) is `TokenRefused`.
    public func groupCalls(_ person: BoxLink) async throws -> BoxCalls {
        let (status, data) = try await asPerson("GET", "voice/calls", person, nil, timeout: 15)
        if [403, 404, 405, 503].contains(status) { return .noGroupCalls }
        guard status == 200 else { throw PeelError("\(host) could not say whether Jamie can join calls: \(Self.said(data) ?? "HTTP \(status)").") }
        struct Answer: Decodable { let group: Bool?; let livekit: String? }
        guard let answer = try? JSONDecoder().decode(Answer.self, from: data) else {
            throw PeelError(String(localized: "\(host)'s answer about calls could not be read.", table: "Shared"))
        }
        return BoxCalls(group: answer.group == true, livekit: answer.livekit.flatMap(TalkTicket.mediaURL))
    }

    /// Asks the box's Jamie into `link`'s call as `person`, its starter:
    /// `POST /voice/calls { mode: "group", room, key, record? }`. With
    /// `record`, Jamie records the call on the canvas from the start
    /// (call-canvas.md §4). Answers once Jamie is in the room, keyed with
    /// the call's key; a refusal throws in words the person can act on. A
    /// link with no key is never asked about: a box's Jamie joins only an
    /// encrypted call.
    public func startGroupCall(_ person: BoxLink, link: CallLink, record: Bool) async throws {
        guard let key = link.encryptionKey else {
            throw PeelError(String(localized: "Jamie from a box joins only an encrypted call.", table: "Shared"))
        }
        struct Body: Encodable { let mode = "group"; let room: String; let key: String; let record: Bool? }
        let body = try JSONEncoder.hive.encode(Body(room: link.room, key: key, record: record ? true : nil))
        // The box joins the room before it answers.
        let (status, data) = try await asPerson("POST", "voice/calls", person, body, timeout: 30)
        guard status == 200 else { throw groupCallFailure(status, data) }
        struct Answer: Decodable { let agent: String?; let encrypted: Bool?; let room: String? }
        guard let answer = try? JSONDecoder().decode(Answer.self, from: data),
              let agent = answer.agent, CallServer.isIdentity(agent) else {
            throw PeelError(String(localized: "\(host)'s answer about the call could not be read.", table: "Shared"))
        }
        // A voice service from before group calls takes the body for a call
        // of the person's own, in a room of its own: that Jamie is in no call here.
        guard answer.encrypted == true, answer.room == nil || answer.room == link.room else {
            throw PeelError(String(localized: "Jamie on \(host) can't join group calls yet: its voice service needs an update.", table: "Shared"))
        }
    }

    /// The person's own ticket into `room`, where the box's Jamie is, under
    /// `name`: `POST /voice/calls/ticket { room, name }`. Nil when the box's
    /// Jamie is not in that room (404).
    public func callTicket(_ person: BoxLink, room: String, name: String) async throws -> BoxCallTicket? {
        // The box counts a name's UTF-16 units, at most 128.
        var name = name
        while name.utf16.count > 128 { name.removeLast() }
        let body = try JSONEncoder.hive.encode(["room": room, "name": name])
        let (status, data) = try await asPerson("POST", "voice/calls/ticket", person, body, timeout: 15)
        if status == 404 { return nil }
        guard status == 200 else { throw PeelError("\(host) gave no call ticket: \(Self.said(data) ?? "HTTP \(status)").") }
        struct Answer: Decodable { let url: String; let room: String; let token: String; let identity: String }
        // `box_` and 32 hex, as the box mints one: never another participant's identity.
        guard let answer = try? JSONDecoder().decode(Answer.self, from: data), answer.room == room,
              answer.identity.range(of: #"^box_[0-9a-f]{32}$"#, options: .regularExpression) != nil else {
            throw PeelError(String(localized: "\(host)'s call ticket could not be read.", table: "Shared"))
        }
        return BoxCallTicket(url: answer.url, token: answer.token, identity: answer.identity)
    }

    /// The box's refusal to bring Jamie into a call, in words.
    func groupCallFailure(_ status: Int, _ data: Data) -> PeelError {
        let said = Self.said(data)
        switch status {
        case 409:
            return PeelError(String(localized: "Jamie from \(host) is already in this call.", table: "Shared"))
        case 503:
            return PeelError(String(localized: "Jamie from \(host) can't join a call right now: \(said ?? "it isn't ready").", table: "Shared"))
        case 403:
            return PeelError(String(localized: "\(host) takes calls only from a person's sign-in.", table: "Shared"))
        case 429:
            return busy
        default:
            return PeelError("\(host) could not bring Jamie into the call: \(said ?? "HTTP \(status)").")
        }
    }
}
