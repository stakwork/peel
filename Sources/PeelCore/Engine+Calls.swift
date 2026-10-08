import Foundation

extension Engine {
    // MARK: - Calls

    /// The account's call server: the one recorded, else the official apps'
    /// own, except on a local test server, which has none unless named.
    public func callServer() throws -> String {
        if let host = try storage.value(for: .callServer) { return host }
        guard let server, !ServerAddress.isLoopback(host: server.host) else { throw Failure.noCallServer }
        return Self.defaultCallServer
    }

    /// Starts a call in a contact's chat or a tribe: a new room with a random
    /// name on the call server, posted as a call message in the `call::`
    /// form. A tribe takes only the 3-sat floor for it. Only while connected,
    /// since a call message is never sent again (its room would be stale);
    /// a publish that fails all the same is reported as a send status for
    /// the tag returned, like any send's. Joining is the caller's.
    public func startCall(in pubkey: String, audioOnly: Bool) async throws -> (link: CallLink, tag: String?) {
        let tribe = try openTribe(pubkey)
        guard tribe != nil || Self.isPerson(pubkey, in: state) == true else { throw Failure.notAChat }
        let link = try CallLink.new(server: callServer(), audioOnly: audioOnly)
        guard transport != nil else { throw Failure.notConnected }
        let tag = try await deliver(body: Self.json(["content": link.message]), to: pubkey, type: MessageType.call, replacing: nil)
        return (link, tag)
    }

    /// The call a message links to, checked against this account's call
    /// server: a call message, or text that is only a call link (the Mac
    /// app reads both as calls). Nil for anything else, and on an account
    /// with no call server.
    public func callLink(in message: Message) -> CallLink? {
        guard let server = try? callServer() else { return nil }
        return CallLink(in: message, server: server)
    }

    /// A ticket to join a call: the LiveKit server and a token, asked of
    /// this account's call server under the name `chat` knows this account
    /// by (the tribe alias in a tribe), with its photo and a Hive link's
    /// key. Memory only; never store or log it.
    public func callTicket(for link: CallLink, in chat: String?) async throws -> CallTicket {
        let name = chat.flatMap { tribes[$0] } != nil || alias.isEmpty ? tribeAlias(alias) : alias
        return try await callConnection(for: link).ticket(for: link, participantName: name, photoURL: myPhotoURL)
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
