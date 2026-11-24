import Foundation
import PeelDiagnostics

extension Engine {
    // MARK: - Calls

    /// The account's call server: the one recorded, else the official apps'
    /// own, except on a local test server, which has none unless named.
    public func callServer() throws -> String {
        guard let host = try configuredHost(.callServer, default: Self.defaultCallServer) else { throw Failure.noCallServer }
        return host
    }

    /// Starts a call in a contact's chat or a tribe: a new room with a random
    /// name on the call server, posted as a call message in the `call::`
    /// form (`postCall`). With `hiveLink`, the call Hive made with Jamie in
    /// it is posted in place of a new room, once it passes the same checks
    /// (`CallLink.hive`). Joining is the caller's.
    public func startCall(
        in pubkey: String, audioOnly: Bool, hiveLink: String? = nil
    ) async throws -> (link: CallLink, tag: String?) {
        try checkCallChat(pubkey)
        let link = try hiveLink.map { try CallLink.hive($0, server: callServer(), audioOnly: audioOnly) }
            ?? CallLink.new(server: callServer(), audioOnly: audioOnly)
        return (link, try await postCall(link, in: pubkey))
    }

    /// A new call in a contact's chat or a tribe, not posted yet: a room on
    /// the call server, with a fresh end-to-end key when `encrypted`. Throws
    /// as `postCall` would, so a box's Jamie is never asked into a call that
    /// could not be posted (docs/hive-calls.md, "From a box").
    public func newCall(in pubkey: String, audioOnly: Bool, encrypted: Bool) throws -> CallLink {
        try checkCallChat(pubkey)
        let link = try CallLink.new(server: callServer(), audioOnly: audioOnly, encrypted: encrypted)
        guard transport != nil else { throw Failure.notConnected }
        return link
    }

    /// Posts `link` as a call message in a contact's chat or a tribe, which
    /// takes only the 3-sat floor for it. Only while connected, since a call
    /// message is never sent again (its room would be stale); a publish that
    /// fails all the same is reported as a send status for the tag returned,
    /// like any send's. A link on another call server is refused.
    public func postCall(_ link: CallLink, in pubkey: String) async throws -> String? {
        try checkCallChat(pubkey)
        guard link.server == (try callServer()) else { throw Failure.callOnAnotherServer }
        guard transport != nil else { throw Failure.notConnected }
        return try await deliver(body: Self.json(["content": link.message]), to: pubkey, type: MessageType.call, replacing: nil)
    }

    /// A call goes only to an open tribe or a person's chat.
    private func checkCallChat(_ pubkey: String) throws {
        let tribe = try openTribe(pubkey)
        guard tribe != nil || Self.isPerson(pubkey, in: state) == true else { throw Failure.notAChat }
    }

    /// The call a message links to, checked against this account's call
    /// server: a call message, or text that is only a call link (the Mac
    /// app reads both as calls). Nil for anything else, and on an account
    /// with no call server.
    public func callLink(in message: Message) -> CallLink? {
        guard let server = try? callServer() else { return nil }
        return CallLink(in: message, server: server)
    }

    /// Where a paired device asks Hive for its ticket to a call Hive made
    /// (`HiveClient.callTicket`, through Stadeum): the room, the name and
    /// the metadata the call server would get.
    public typealias HiveTicketSource = @Sendable (
        _ room: String, _ participantName: String, _ metadata: String?
    ) async throws -> HiveCallTicket

    /// Where a device linked to boxes asks for its ticket into an encrypted
    /// call (`Boxes.callTicket`): the room and the name. Nil when none of
    /// the boxes has its Jamie in that room.
    public typealias BoxTicketSource = @Sendable (_ room: String, _ participantName: String) async throws -> BoxCallTicket?

    /// A ticket to join a call: the LiveKit server and a token, asked of
    /// this account's call server under the name `chat` knows this account
    /// by (the tribe alias in a tribe), with its photo and a Hive link's
    /// key. Memory only; never store or log it.
    ///
    /// With `hive`, a room Hive made (`CallLink.isHive`) is asked of Hive
    /// first, with the same name and photo: its ticket names this device's
    /// person, so what they ask Jamie runs as them (docs/hive-calls.md, "Who
    /// is speaking"). It is checked as the call server's would be, and any
    /// failure joins through the call server as before, as the call's starter.
    ///
    /// With `box`, an encrypted call is asked of the boxes this device is
    /// linked to in the same way (docs/hive-calls.md, "From a box"): the one
    /// whose Jamie is in the room gives a ticket under an identity it runs
    /// as this person. Its name only: a box's ticket carries no photo.
    public func callTicket(
        for link: CallLink, in chat: String?, hive: HiveTicketSource? = nil, box: BoxTicketSource? = nil
    ) async throws -> CallTicket {
        let tribe = chat.flatMap { tribes[$0] }
        // A blank account name joins as "Peel user", not the tribes' "Unknown",
        // which the call chat and Jamie would take for the speaker.
        let name = tribe?.sentAlias(account: alias)
            ?? (alias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Peel user" : alias)
        let photo = (tribe?.sentPhoto(account: photoURL) ?? photoURL).httpsOnly
        let server = try await callConnection(for: link)
        var ticket: CallTicket?
        if let hive, link.isHive {
            do {
                let answer = try await hive(link.room, name, photo.flatMap(CallServer.metadata(photoURL:)))
                ticket = try await server.ticket(fromHive: answer, room: link.room, participantName: name)
            } catch {
                // A join given up while Hive answered stays given up; URLSession
                // reports that as its own error, not a CancellationError.
                try Task.checkCancellation()
                Diagnostics.note(error: error)
            }
        }
        if ticket == nil, let box, link.encryptionKey != nil {
            do {
                if let answer = try await box(link.room, name) {
                    let checked = try await server.ticket(fromBox: answer, room: link.room, participantName: name)
                    ticket = checked
                }
            } catch {
                try Task.checkCancellation()
                Diagnostics.note(error: error)
            }
        }
        var joined: CallTicket
        if let ticket { joined = ticket } else { joined = try await server.ticket(for: link, participantName: name, photoURL: photo) }
        // Either way, so a device of this account that joins later can take the call over.
        joined.handoff = CallHandoff(seed: seed)
        return joined
    }

    /// Who is on a call, from the call server's presence feed, until the
    /// stream is dropped. Ask only for recent calls (`CallLink.mayBeLive`),
    /// and only a few: each subscription tells the call server a room you
    /// watch (`WatchedCall.limit` across chats, plus what is on screen).
    public func callPresence(of link: CallLink) async throws -> AsyncStream<CallPresence> {
        try await callConnection(for: link).presence(room: link.room)
    }

    /// The engine's one connection to its call server, made again when the
    /// setting changes. A link from another server is refused: a ticket is
    /// only ever asked of the configured server.
    private func callConnection(for link: CallLink) async throws -> CallServer {
        guard !closed else { throw Failure.accountClosed }
        let host = try callServer()
        guard link.server == host else { throw Failure.callOnAnotherServer }
        if let calls, calls.host == host { return calls }
        let old = calls
        let server = try CallServer(host: host)
        calls = server
        await old?.close()
        return server
    }
}
