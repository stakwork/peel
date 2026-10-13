import Foundation

/// What a LiveKit client needs to join one call: the media server's address
/// and an access token for the room. It lives in memory for one join and is
/// never stored, logged or shown; its descriptions leave the token out.
public struct CallTicket: Sendable, CustomStringConvertible, CustomReflectable {
    /// The LiveKit server, `wss://` on a host the call server may name.
    public let serverURL: URL
    /// The LiveKit access token (a JWT), a bearer credential until `expires`.
    public let token: String
    public let room: String
    /// The participant identity the call server chose (the token's `sub`).
    public let identity: String
    public let expires: Date
    /// Whether the token grants room admin, which Peel never asks for.
    public let roomAdmin: Bool

    public var description: String {
        "CallTicket(\(serverURL.absoluteString), room \(room), identity \(identity), token not shown)"
    }
    public var customMirror: Mirror {
        Mirror(self, children: ["serverURL": serverURL, "room": room, "identity": identity, "expires": expires])
    }
}

/// Someone on a call, as the call server's presence feed reports them.
/// Everything here is what the joiner sent: names are self-declared and
/// never an identity, and the photo is kept only when it is public https.
public struct CallParticipant: Sendable, Equatable, Identifiable {
    public let identity: String
    public let nickname: String
    public let avatarURL: URL?
    public var id: String { identity }
}

extension CallParticipant {
    /// Someone in the media room itself, from the name and metadata
    /// (`{"profilePictureUrl":…}`) they joined with, cleaned as the
    /// presence feed's are. Nil for an identity the feed would refuse.
    public init?(identity: String, name: String?, metadata: String?) {
        var fields: [String: Any] = ["identity": identity]
        fields["nickname"] = name
        if let metadata, metadata.utf8.count <= 4096,
           let json = try? JSONSerialization.jsonObject(with: Data(metadata.utf8)) as? [String: Any] {
            fields["avatarUrl"] = json["profilePictureUrl"]
        }
        guard let participant = CallServer.participant(fields) else { return nil }
        self = participant
    }
}

/// Who is on a call, as far as the call server says.
public enum CallPresence: Sendable, Equatable {
    /// No answer from the call server yet, or the connection to it dropped.
    case unknown
    /// The people on the call now; empty when no one is.
    case live([CallParticipant])
    /// The call server closed the room. It opens again if someone joins.
    case ended

    /// Who is on it, when the call server has said.
    public var people: [CallParticipant]? {
        if case .live(let people) = self { people } else { nil }
    }
}

/// One account's call server: the ticket request (`GET
/// /api/connection-details`) and the presence feed (`/ws`), as the
/// official apps use them. Neither is authenticated: the room name is the
/// only secret. Every request goes through an ephemeral session with no
/// cache and no cookies that follows no redirect, so a token never lands in
/// `Cache.db`. Errors never carry the request's URL, whose query holds the
/// Hive key.
actor CallServer {
    /// `host[:port]`, as in the `callServer` setting.
    nonisolated let host: String
    /// https, or http for this machine.
    private let base: URL
    private static let session = Web.session(requestTimeout: 15, resourceTimeout: 30) { _, _ in nil }
    /// The presence feed stays open for as long as a card shows: no
    /// resource limit, and pings (`keepAlive`) well inside the idle one.
    private static let socketSession = Web.session(requestTimeout: 90, resourceTimeout: .infinity) { _, _ in nil }

    enum Failure: Error, CustomStringConvertible, Equatable {
        case unreachable
        case refused(Int)
        case unreadableReply
        case mediaHostNotAllowed(String?)
        case malformedToken
        case tokenForAnotherRoom
        case tokenExpired

        var description: String {
            switch self {
            case .unreachable: "the call server did not answer"
            case .refused(let status): "the call server refused the call ticket (HTTP \(status))"
            case .unreadableReply: "the call server's reply was unreadable"
            case .mediaHostNotAllowed(let host): "the call server named a media server Peel does not know (\(host ?? "an unreadable address"))"
            case .malformedToken: "the call server's token was unreadable"
            case .tokenForAnotherRoom: "the call server's token is for another room"
            case .tokenExpired: "the call server's token has already expired"
            }
        }
    }

    init(host: String) throws {
        guard let base = TribeLink.baseURL(host) else { throw Engine.Failure.unreadableCallServer(host) }
        self.host = host
        self.base = base
    }

    // MARK: - The ticket

    /// The LiveKit media servers each call server may name besides itself,
    /// on port 443, by exact host, never a suffix (`*.livekit.cloud` would
    /// admit any LiveKit tenant). The official apps' call server names
    /// `livekit.sphinx.chat` (seen 2026-10-12). A ticket naming any other
    /// host is refused, and the error names it.
    static let mediaHosts: [String: [String]] = [
        "chat.sphinx.chat": ["livekit.sphinx.chat"],
    ]

    /// Asks for a token to join `link`'s room as `participantName`, with
    /// the account's photo and a Hive link's key passed on. Never `isHost`.
    func ticket(for link: CallLink, participantName: String, photoURL: String?) async throws -> CallTicket {
        guard let url = Self.ticketURL(base: base, link: link, participantName: participantName, photoURL: photoURL) else {
            throw PeelError("could not build the call ticket request")
        }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data: Data
        do {
            data = try await Web.Transfer(limit: 64_000, what: "the call ticket", progress: nil)
                .run(Self.session.dataTask(with: request)).0
        } catch Web.Failure.refused(_, let status) {
            throw Failure.refused(status)
        } catch is Web.Failure, is TooLarge {
            throw Failure.unreadableReply
        } catch {
            // A URLError's description holds the whole URL.
            throw Failure.unreachable
        }
        struct Reply: Decodable { let serverUrl: String; let participantToken: String }
        guard let reply = try? JSONDecoder().decode(Reply.self, from: data) else { throw Failure.unreadableReply }
        return try Self.ticket(serverURL: reply.serverUrl, token: reply.participantToken, room: link.room, callServer: base)
    }

    /// `GET /api/connection-details` with every value percent-encoded to
    /// unreserved characters, as the official apps' `urlEncode` does, so a
    /// `+` arrives as `+` and never as a space.
    static func ticketURL(base: URL, link: CallLink, participantName: String, photoURL: String?) -> URL? {
        guard var parts = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        parts.percentEncodedPath = "/api/connection-details"
        var items = [("roomName", link.room), ("participantName", participantName)]
        if let photoURL, let metadata = metadata(photoURL: photoURL) { items.append(("metadata", metadata)) }
        if let callKey = link.callKey { items.append(("callKey", callKey)) }
        if let hiveToken = link.hiveToken { items.append(("hiveToken", hiveToken)) }
        parts.percentEncodedQueryItems = items.map { URLQueryItem(name: $0, value: CallLink.encoded($1)) }
        return parts.url
    }

    /// `{"profilePictureUrl":"<url>"}`, the only metadata Peel sends (no
    /// pubkey: others could read it but not check it).
    static func metadata(photoURL: String) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        return (try? encoder.encode(["profilePictureUrl": photoURL])).map { String(decoding: $0, as: UTF8.self) }
    }

    /// The ticket in a reply, checked: the media server must be `wss://`
    /// (or `https://`, read as it) on the call server's own host or one recorded for it in `mediaHosts`
    /// (`ws://` only when the call server is this machine), and the token
    /// must be for `room` and not yet expired. Its signature is the media
    /// server's to check.
    static func ticket(serverURL text: String, token: String, room: String, callServer: URL, now: Date = .now) throws -> CallTicket {
        let serverURL = try mediaURL(text, callServer: callServer)
        let claims = try claims(of: token)
        guard claims.video?.room == room else { throw Failure.tokenForAnotherRoom }
        guard let identity = claims.sub, isIdentity(identity), let exp = claims.exp else { throw Failure.malformedToken }
        let expires = Date(timeIntervalSince1970: exp)
        guard expires > now else { throw Failure.tokenExpired }
        return CallTicket(
            serverURL: serverURL, token: token, room: room, identity: identity, expires: expires,
            roomAdmin: claims.video?.roomAdmin == true
        )
    }

    static func mediaURL(_ text: String, callServer: URL) throws -> URL {
        guard text.utf8.count <= 2048, var parts = URLComponents(string: text),
              let given = parts.scheme?.lowercased(), let host = parts.percentEncodedHost?.lowercased(),
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil
        else { throw Failure.mediaHostNotAllowed(nil) }
        // LiveKit reads `https://` as `wss://` and `http://` as `ws://`; the
        // official call server has answered with `https://` since 2026-10-13.
        let scheme = ["https": "wss", "http": "ws"][given] ?? given
        parts.scheme = scheme
        guard let url = parts.url else { throw Failure.mediaHostNotAllowed(nil) }
        let named = endpoint(host, parts.port, secure: scheme != "ws")
        let loopback = callServer.scheme == "http"
        let ownHost = callServer.host?.lowercased() ?? ""
        let allowed = [endpoint(ownHost, callServer.port, secure: !loopback)]
            // Only the call server itself on its default port: not another one on the same host.
            + (callServer.port == nil ? mediaHosts[ownHost] ?? [] : []).map { endpoint($0, nil, secure: true) }
        guard scheme == "wss" || (scheme == "ws" && loopback), allowed.contains(named) else {
            throw Failure.mediaHostNotAllowed(TribeLink.isPlainHost(named) ? named : nil)
        }
        return url
    }

    /// `host:port`, with the scheme's default port written out.
    private static func endpoint(_ host: String, _ port: Int?, secure: Bool) -> String {
        host.contains(":") && port == nil ? host : "\(host):\(port ?? (secure ? 443 : 80))"
    }

    /// The parts of a LiveKit token Peel reads, decoded without checking
    /// the signature (Peel has no key).
    struct Claims: Decodable {
        struct Video: Decodable {
            let room: String?
            let roomAdmin: Bool?
        }
        let sub: String?
        let exp: Double?
        let video: Video?
    }

    static func claims(of token: String) throws -> Claims {
        guard let claims = JWT.payload(Claims.self, of: token) else { throw Failure.malformedToken }
        return claims
    }

    // MARK: - Presence

    private struct Room {
        var listeners: [UUID: AsyncStream<CallPresence>.Continuation] = [:]
        var presence = CallPresence.unknown
    }

    private var rooms: [String: Room] = [:]
    private var socket: URLSessionWebSocketTask?
    private var reconnect: Task<Void, Never>?
    private var pings: Task<Void, Never>?
    private var failures = 0
    private var closed = false
    /// Rooms whose list is asked for again (`askAgain`).
    private var askingAgain = Set<String>()

    /// Who is on the call in `room`, now and as it changes, starting with
    /// `.unknown`. The first listener for a room subscribes on the one
    /// socket (opening it if need be); the last one to stop unsubscribes,
    /// and the socket closes when no room is left.
    func presence(room: String) -> AsyncStream<CallPresence> {
        let (stream, continuation) = AsyncStream.makeStream(of: CallPresence.self, bufferingPolicy: .bufferingNewest(1))
        guard !closed, CallLink.isRoom(room) else {
            continuation.finish()
            return stream
        }
        let id = UUID()
        continuation.onTermination = { [weak self] _ in
            Task { await self?.stopListening(id, to: room) }
        }
        var entry = rooms[room] ?? Room()
        let isNew = entry.listeners.isEmpty
        entry.listeners[id] = continuation
        rooms[room] = entry
        continuation.yield(entry.presence)
        if isNew {
            if let socket {
                send(["action": "subscribe", "roomName": room], on: socket)
            } else if reconnect == nil {
                // While a reconnect waits out its backoff, it subscribes this room with the rest.
                connect()
            }
        }
        return stream
    }

    /// Closes the socket and ends every stream. The server drops the
    /// subscriptions with the connection.
    func close() {
        closed = true
        let listeners = rooms.values.flatMap(\.listeners.values)
        rooms = [:]
        disconnect()
        for listener in listeners { listener.finish() }
    }

    private func stopListening(_ id: UUID, to room: String) async {
        guard rooms[room]?.listeners.removeValue(forKey: id) != nil, rooms[room]?.listeners.isEmpty == true else { return }
        rooms[room] = nil
        guard let socket else { return }
        try? await socket.send(.string(Self.json(["action": "unsubscribe", "roomName": room])))
        // Another room may have been asked for while the unsubscribe went out.
        if rooms.isEmpty, self.socket === socket { disconnect() }
    }

    private func connect() {
        reconnect = nil
        guard !closed, socket == nil, !rooms.isEmpty, var parts = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return }
        parts.scheme = base.scheme == "http" ? "ws" : "wss"
        parts.percentEncodedPath = "/ws"
        guard let url = parts.url else { return }
        let socket = Self.socketSession.webSocketTask(with: url)
        socket.maximumMessageSize = 256 * 1024
        self.socket = socket
        socket.resume()
        for room in rooms.keys { send(["action": "subscribe", "roomName": room], on: socket) }
        Task { await self.receive(on: socket) }
        pings = Task { await self.keepAlive(socket) }
    }

    /// A ping every 30 seconds keeps a quiet feed open, and a connection
    /// that no longer answers is dropped (and reconnected) rather than
    /// trusted.
    private func keepAlive(_ socket: URLSessionWebSocketTask) async {
        while (try? await Task.sleep(for: .seconds(30))) != nil {
            guard self.socket === socket else { return }
            socket.sendPing { error in
                if error != nil { socket.cancel(with: .goingAway, reason: nil) }
            }
        }
    }

    private func disconnect() {
        reconnect?.cancel()
        reconnect = nil
        pings?.cancel()
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
    }

    private func receive(on socket: URLSessionWebSocketTask) async {
        while true {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await socket.receive()
            } catch {
                return dropped(socket)
            }
            guard self.socket === socket else { return }
            failures = 0
            if case .string(let text) = message, let update = Self.update(from: text),
               let presence = rooms[update.room]?.presence {
                set(Self.applying(update.change, to: presence), in: update.room)
                if case .joined(let participant) = update.change, participant.nickname.isEmpty, presence != .unknown {
                    askAgain(update.room, on: socket)
                }
            }
        }
    }

    /// The room's list again in two seconds, for someone who joined with
    /// no name yet, as the official Mac app does: a second subscribe
    /// answers with `current_participants`.
    /// One at a time per room, however many join unnamed.
    private func askAgain(_ room: String, on socket: URLSessionWebSocketTask) {
        guard askingAgain.insert(room).inserted else { return }
        Task {
            try? await Task.sleep(for: .seconds(2))
            askingAgain.remove(room)
            guard self.socket === socket, rooms[room] != nil else { return }
            send(["action": "subscribe", "roomName": room], on: socket)
        }
    }

    /// Every room is unknown until the socket is back; it reconnects after
    /// 1, 2, 4 … up to 30 seconds and subscribes to them all again.
    private func dropped(_ socket: URLSessionWebSocketTask) {
        guard self.socket === socket else { return }
        self.socket = nil
        pings?.cancel()
        for room in rooms.keys { set(.unknown, in: room) }
        guard !closed, !rooms.isEmpty else { return }
        let delay = min(30, 1 << min(failures, 5))
        failures += 1
        reconnect = Task {
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self.connect()
        }
    }

    private func send(_ fields: [String: String], on socket: URLSessionWebSocketTask) {
        // A failed send shows up as a failed receive, which reconnects.
        socket.send(.string(Self.json(fields))) { _ in }
    }

    /// What a room's presence becomes after one message of the feed. A
    /// participant with no name is left out, as the official Mac app leaves
    /// them out (`NewChatTableDataSource+CellDelegateExtension.swift`): the
    /// room's recorder or agent, or someone whose name LiveKit has not
    /// passed on yet (`receive` asks again for those).
    static func applying(_ change: Change, to presence: CallPresence) -> CallPresence {
        switch (change, presence) {
        case (.current(let participants), _):
            // Someone unnamed here keeps the name they had: earlier in this
            // list (a second session), or before it (their client reconnected).
            let known = Dictionary(((presence.people ?? []) + participants.filter { !$0.nickname.isEmpty })
                .map { ($0.identity, $0) }, uniquingKeysWith: { $1 })
            // One entry per identity, the last word kept, as for a join.
            var seen = Set<String>()
            return .live(Array(participants.reversed().compactMap { person -> CallParticipant? in
                guard seen.insert(person.identity).inserted else { return nil }
                return person.nickname.isEmpty ? known[person.identity] : person
            }.reversed()))
        case (.joined(let participant), _) where participant.nickname.isEmpty:
            return presence
        case (.joined(let participant), .live(var participants)):
            participants.removeAll { $0.identity == participant.identity }
            if participants.count < maxParticipants { participants.append(participant) }
            return .live(participants)
        case (.joined(let participant), .ended):
            // The room opens again with the first to join.
            return .live([participant])
        case (.left(let identity), .live(var participants)):
            participants.removeAll { $0.identity == identity }
            return .live(participants)
        case (.finished, _):
            return .ended
        default:
            // A join or leave before the first list says nothing about the rest.
            return presence
        }
    }

    private func set(_ presence: CallPresence, in room: String) {
        guard var entry = rooms[room], entry.presence != presence else { return }
        entry.presence = presence
        rooms[room] = entry
        for listener in entry.listeners.values { listener.yield(presence) }
    }

    private static func json(_ fields: [String: String]) -> String {
        String(decoding: (try? JSONEncoder().encode(fields)) ?? Data(), as: UTF8.self)
    }

    // MARK: - Reading the feed

    enum Change: Equatable {
        case current([CallParticipant])
        case joined(CallParticipant)
        case left(String)
        case finished
    }

    static let maxParticipants = 500
    static let maxName = 100

    /// One message of the presence feed, as the official Mac app reads it
    /// (`CallParticipantsSocketManager.swift`): `current_participants`,
    /// `participant_joined` (the participant nested or at the top level),
    /// `participant_left` and `room_finished`, each naming its room. Nil
    /// for anything else.
    static func update(from text: String) -> (room: String, change: Change)? {
        guard let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let type = json["type"] as? String, let room = json["roomName"] as? String, CallLink.isRoom(room) else { return nil }
        switch type {
        case "current_participants":
            let list = (json["participants"] as? [[String: Any]]) ?? []
            return (room, .current(list.prefix(maxParticipants).compactMap(participant)))
        case "participant_joined":
            return participant((json["participant"] as? [String: Any]) ?? json).map { (room, .joined($0)) }
        case "participant_left":
            return (json["identity"] as? String).flatMap { isIdentity($0) ? (room, .left($0)) : nil }
        case "room_finished":
            return (room, .finished)
        default:
            return nil
        }
    }

    static func participant(_ fields: [String: Any]) -> CallParticipant? {
        guard let identity = fields["identity"] as? String, isIdentity(identity) else { return nil }
        // Control characters out, so a name cannot rewrite a terminal line;
        // a name of only spaces is none.
        let nickname = (fields["nickname"] as? String).map {
            String($0.withoutControlCharacters.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxName))
        }
        let avatar = (fields["avatarUrl"] as? String).flatMap { $0.utf8.count <= 2048 ? URL(string: $0) : nil }
            .flatMap { Web.isPublic($0) ? $0 : nil }
        return CallParticipant(identity: identity, nickname: nickname ?? "", avatarURL: avatar)
    }

    /// An identity is matched exactly (a leave names it), so one with a
    /// control character is refused rather than cleaned.
    static func isIdentity(_ identity: String) -> Bool {
        (1...256).contains(identity.utf8.count) && identity == identity.withoutControlCharacters
    }
}
