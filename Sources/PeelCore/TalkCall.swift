import Foundation

// Talk to Jamie (strut's plans/private-voice.md, steps 1 and 2; docs/talk.md): a
// live voice call with an org's agent. Peel asks the org's own strut, its
// home, with the person's token (`POST /voice/calls`), and joins the LiveKit
// room the home names. Not a call link: no call server, no chat message, no
// `CallLink`, and none of `CallServer`'s rule that media sits on the call
// server's own host, since the home named it in answer to the person's own
// authenticated request. The media stays in the apps (`TalkSession`).
//
// Every call is end-to-end encrypted (step 2): Peel makes a fresh key for it,
// sends it to the home with the call, and joins the room with it, as the
// home's agent does. The LiveKit server forwards what it cannot read.

/// Where Talk calls: an org's strut and the person's token for it. Never
/// described with its token.
public struct TalkHome: Sendable, Equatable, Identifiable, CustomStringConvertible, CustomReflectable {
    /// The org's peer id (`HivePeer.id`), or `development` for the dev setting.
    public let id: String
    /// What the person reads.
    public let name: String
    /// The home's strut: https anywhere, http only on this machine (`Web.isStrut`).
    public let url: URL
    /// The person token for it (strut's `peer:person` scope).
    let token: String

    /// The dev setting's id, never a peer id strut gives (those are slugs).
    public static let development = "@development"

    init(id: String, name: String, url: URL, token: String) {
        self.id = id
        self.name = name
        self.url = url
        self.token = token
    }

    /// A paired org's home: its strut and the person's token from Stadeum.
    /// Nil when its address is not one Peel may send the token to.
    public init?(peer: HivePeer) {
        guard let url = try? peer.strut, !peer.token.isEmpty else { return nil }
        self.init(id: peer.id, name: peer.name, url: url, token: peer.token)
    }

    /// The dev setting: a local home for a development profile, as
    /// `-hiveURL` is (`-talkHome http://127.0.0.1:3000 -talkHomeToken <token>`,
    /// the token from strut's `POST /peers/tokens`). Nil for the app's own
    /// profile, without both, or for an address that is not https or this
    /// machine's http.
    public static func development(for profile: Profile, defaults: UserDefaults = .standard) -> TalkHome? {
        guard profile.kind == .development else { return nil }
        return development(url: defaults.string(forKey: "talkHome"), token: defaults.string(forKey: "talkHomeToken"))
    }

    static func development(url text: String?, token: String?) -> TalkHome? {
        guard let text, let url = URL(string: text), Web.isStrut(url),
              let token = token?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty
        else { return nil }
        return TalkHome(id: development, name: url.host ?? "This Mac", url: url, token: token)
    }

    public var description: String { "TalkHome(\(id), \(url.absoluteString), token not shown)" }
    public var customMirror: Mirror { Mirror(self, children: ["id": id, "name": name, "url": url]) }

    /// The most `POST /voice/calls` may answer: a few short strings and a JWT.
    static let replyLimit = 64 * 1024

    /// Starts a call with the home's agent in `voice`: `POST /voice/calls`
    /// with the person's token and a fresh key for the call, answered with
    /// the room to join. A refusal throws `TalkRefusal` in the home's own
    /// words (400 for a voice it does not know).
    public func startCall(voice: TalkVoice? = nil) async throws -> TalkTicket {
        let key = Self.newKey()
        let (status, data) = try await Web.requestStrut(
            "POST", url.appending(path: "voice/calls"), json: Self.callBody(key: key, voice: voice), bearer: token,
            limit: Self.replyLimit, what: "\(name)'s answer", timeout: 30
        )
        guard status == 200 else { throw TalkRefusal(status: status, reply: data, home: name) }
        return try TalkTicket(reply: data, home: name, key: key)
    }

    /// A call's key: 32 random bytes as base64, made for one call and never
    /// kept. LiveKit keys the room with this string's UTF-8 bytes, on the
    /// phone (`BaseKeyProvider(sharedKey:)`) and in the home's agent alike.
    static func newKey() -> String {
        MediaCrypto.randomBytes(32).base64EncodedString()
    }

    /// `POST /voice/calls`'s body: `{ "key": "<base64>", "voice": "am_michael" }`.
    static func callBody(key: String, voice: TalkVoice?) throws -> Data {
        struct Body: Encodable { let key: String; let voice: String? }
        return try JSONEncoder().encode(Body(key: key, voice: voice?.rawValue))
    }
}

/// Jamie's voice on a Talk call (docs/talk.md): one of the voice service's,
/// female `af_heart` (the default) or male `am_michael`. The member picks it
/// on the call screen; it is kept on this device (`UserDefaults`, `talkVoice`),
/// asked for in `POST /voice/calls`, and switched mid-call by the member's
/// participant attribute `voice`, from the agent's next sentence.
public enum TalkVoice: String, Sendable, CaseIterable {
    case female = "af_heart"
    case male = "am_michael"

    /// Where the choice is kept, per device.
    public static let defaultsKey = "talkVoice"
    /// The member's participant attribute that switches it mid-call.
    public static let attribute = "voice"

    /// The voice kept on this device: female when none is, or one this Peel
    /// does not know.
    public static func stored(in defaults: UserDefaults = .standard) -> TalkVoice {
        defaults.string(forKey: defaultsKey).flatMap(TalkVoice.init(rawValue:)) ?? .female
    }

    public func store(in defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.defaultsKey)
    }

    /// The other voice: what the toggle switches to.
    public var flipped: TalkVoice { self == .female ? .male : .female }

    /// The toggle's face: ♀ or ♂, with the text variation selector (U+FE0E)
    /// so it never shows as an emoji.
    public var glyph: String { self == .female ? "\u{2640}\u{FE0E}" : "\u{2642}\u{FE0E}" }

    /// What VoiceOver says of the toggle.
    public var accessibilityLabel: String { "Jamie's voice: \(self == .female ? "female" : "male")" }
}

/// What a home answers to `POST /voice/calls`: the LiveKit room to join and
/// the person's token for it, with the call's key. In memory for one join,
/// never stored, logged or described with its token or key.
public struct TalkTicket: Sendable, Equatable, CustomStringConvertible, CustomReflectable {
    /// The LiveKit server: `wss://`, or `ws://` on this machine.
    public let url: URL
    public let room: String
    /// The LiveKit access token (a JWT) for `room`.
    public let token: String
    /// The person's identity in the room, random per call.
    public let identity: String
    /// The agent's identity in the room, random per call.
    public let agent: String
    /// The voice in effect, as the home answered; nil when it named none, or
    /// one this Peel does not know.
    public let voice: TalkVoice?
    /// The call's end-to-end encryption key, as sent to the home: the room's
    /// shared key.
    public let key: String

    public var description: String { "TalkTicket(\(url.absoluteString), room \(room), token and key not shown)" }
    public var customMirror: Mirror { Mirror(self, children: ["url": url, "room": room, "identity": identity, "agent": agent, "voice": voice as Any]) }

    /// The reply read and checked: a LiveKit server Peel may connect to,
    /// a token for the room named, two identities, and the home's word that
    /// its agent joined with `key`.
    init(reply data: Data, home: String, key: String) throws {
        struct Reply: Decodable {
            let url: String
            let room: String
            let token: String
            let identity: String
            let agent: String
            let encrypted: Bool?
            let voice: String?
        }
        guard let reply = try? JSONDecoder().decode(Reply.self, from: data) else {
            throw PeelError("\(home)'s answer could not be read.")
        }
        guard let url = Self.mediaURL(reply.url) else {
            throw PeelError("\(home) named a call server Peel can't use: only wss://, or ws:// on this device.")
        }
        // A home whose agent did not take the key (a voice service from
        // before step 2) answers without `encrypted: true`. Never a call in
        // the clear: refused.
        guard reply.encrypted == true else {
            throw PeelError("\(home) can't make an encrypted call yet: its voice service needs an update.")
        }
        guard [reply.room, reply.identity, reply.agent].allSatisfy(CallServer.isIdentity) else {
            throw PeelError("\(home)'s answer could not be read.")
        }
        guard (try? CallServer.claims(of: reply.token))?.video?.room == reply.room else {
            throw PeelError("\(home)'s call token is not for the room it named.")
        }
        self.url = url
        room = reply.room
        token = reply.token
        identity = reply.identity
        agent = reply.agent
        voice = reply.voice.flatMap(TalkVoice.init(rawValue:))
        self.key = key
    }

    /// The LiveKit server, as LiveKit takes it: `wss://`, or `ws://` only on
    /// this machine (LiveKit reads `https://` and `http://` as those). No
    /// user, query or fragment. Nil for anything else.
    static func mediaURL(_ text: String) -> URL? {
        guard text.utf8.count <= 2048, var parts = URLComponents(string: text),
              let given = parts.scheme?.lowercased(), let host = parts.host?.lowercased(), !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil
        else { return nil }
        let scheme = ["https": "wss", "http": "ws"][given] ?? given
        // An IPv6 host comes bracketed ("[::1]").
        let loopback = ServerAddress.isLoopback(host: host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")))
        guard scheme == "wss" || (scheme == "ws" && loopback) else { return nil }
        parts.scheme = scheme
        return parts.url
    }
}

/// A home's refusal of a call (`POST /voice/calls`), in its own words.
public enum TalkRefusal: Error, Equatable, CustomStringConvertible, LocalizedError {
    /// 402 (step 3 on): the person's balance is below the call's minimum, in sats.
    case balanceTooLow(balance: Int, minimum: Int)
    /// Any other status, with the home's `error` cleaned, if it gave one.
    case refused(status: Int, words: String?, home: String)

    init(status: Int, reply data: Data, home: String) {
        struct Reply: Decodable {
            let error: String?
            let balance: Int?
            let minimum: Int?
        }
        let reply = try? JSONDecoder().decode(Reply.self, from: data)
        if status == 402, let balance = reply?.balance, let minimum = reply?.minimum {
            self = .balanceTooLow(balance: balance, minimum: minimum)
            return
        }
        let words = reply?.error.map { TextLine.clean($0, max: 300) }
        self = .refused(status: status, words: words?.isEmpty == false ? words : nil, home: home)
    }

    public var description: String {
        switch self {
        case .balanceTooLow(let balance, let minimum):
            let sats = { (sats: Int) in Sats.format(msat: min(UInt64(clamping: sats), UInt64.max / 1000) * 1000) }
            return "Not enough sats to talk: you have \(sats(balance)), and a call needs \(sats(minimum))."
        case .refused(let status, let words, let home):
            let lead = switch status {
            case 400: "\(home) could not start the call"
            case 401: "\(home) did not accept your sign-in"
            case 403: "\(home) takes calls only from a person's sign-in"
            case 503: "Jamie can't take calls on \(home) right now"
            default: "\(home) could not start the call (HTTP \(status))"
            }
            return words.map { "\(lead): \($0)" } ?? "\(lead)."
        }
    }

    public var errorDescription: String? { description }
}
