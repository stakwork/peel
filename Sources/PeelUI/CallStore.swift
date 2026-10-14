import Foundation
import PeelCore

extension CallPresence {
    /// Someone is on it.
    public var isLive: Bool { !(people ?? []).isEmpty }
}

/// Calls: who is on the ones being watched, the recent calls across chats
/// and in the open chat, and the call this device is on, with joining,
/// starting and leaving. `AppModel` holds one (`calls`), attaches it with
/// the account and says when the app locks and what the open chat shows.
@MainActor @Observable
public final class CallStore {
    /// The call server links are checked against (`Engine.callServer`);
    /// nil when the account has none, and then no message is a call.
    public private(set) var server: String?
    /// Who is on each call being watched, by room: the recent calls across
    /// chats (`watches`), and those a card or the header shows.
    public internal(set) var presence: [String: CallPresence] = [:] {
        didSet { refreshLiveCounts() }
    }
    /// The views and model watches on each room and the chat each shows it
    /// in; not observed, so a card scrolling in or out redraws nothing.
    @ObservationIgnored private var watchers: [String: [UUID: String]] = [:]
    /// The messages that may be recent calls, across chats, from storage.
    @ObservationIgnored private var recentMessages: [Message] = []
    /// The store's own watch of each `WatchedCall`, by chat and room,
    /// whatever chat is open, and the wake-up for the next change.
    @ObservationIgnored private var watches: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var watchExpiry: Task<Void, Never>?
    /// The open chat's newest calls under 12 hours, at most three, newest
    /// first: what the header watches. Set with the rows, when it changes.
    public private(set) var recent: [CallLink] = []
    /// The call this device is on, and its window.
    public internal(set) var call: (any OngoingCall)?
    /// The goodbye of the calls left, which a quit waits for.
    @ObservationIgnored public private(set) var leaving: Task<Void, Never>?
    /// How many are on each chat's watched calls (the busiest), for chats
    /// with someone on one: the sidebar's green phone, with the call you
    /// are on (`liveCount(in:)`). Kept apart so a presence tick that
    /// changes no count redraws no row.
    public private(set) var liveCounts: [String: Int] = [:]
    /// Why the last join of a room failed, shown beside its Join.
    public private(set) var failures: [String: String] = [:]
    /// The room being joined and the chat a call is being started in, for
    /// the spinner inside the button clicked.
    public private(set) var joiningRoom: String?
    public private(set) var startingIn: String?
    /// Whether the recent calls across chats are watched: while the app is
    /// unlocked. Locked, no call is watched.
    @ObservationIgnored var watchesRecent = false {
        didSet { if watchesRecent != oldValue { refreshWatches() } }
    }
    /// The notices shown inside chats (`AppModel.conversationNotices`),
    /// changed by a join or start from the header, whose card may be out
    /// of sight: the chat, and what its notice becomes from what it was.
    @ObservationIgnored var chatNotice: (_ chat: String, _ change: (String?) -> String?) -> Void = { _, _ in }
    /// A chat's title for the call window ("#tribe" or the contact's name),
    /// looked up when a call is joined, so a rejoin shows a rename.
    @ObservationIgnored var chatTitle: (_ chat: String) -> String = { _ in "Call" }

    @ObservationIgnored private let provider: any CallProvider
    @ObservationIgnored private var engine: Engine?

    public init(provider: any CallProvider) {
        self.provider = provider
    }

    // MARK: Account

    /// The account's engine and call server, once it opens.
    func attach(_ engine: Engine, server: String?) {
        self.engine = engine
        self.server = server
    }

    /// The account is gone: no watch, no failure, and the call is left.
    func reset() {
        engine = nil
        server = nil
        presence = [:]
        watchers = [:]
        recentMessages = []
        refreshWatches()
        failures = [:]
        joiningRoom = nil
        startingIn = nil
        leave()
    }

    // MARK: Presence

    public func presence(of room: String) -> CallPresence {
        presence[room] ?? .unknown
    }

    /// Whether you are on the call in `room`, or joining it.
    public func isOnCall(_ room: String) -> Bool {
        call?.link.room == room && call?.isOn == true
    }

    /// How many are on a call in `chat` now, for its sidebar row: its
    /// busiest watched call, or the one you are on there.
    public func liveCount(in chat: String) -> Int {
        let yours = call.flatMap { $0.chat == chat && $0.isOn ? $0.people.count : nil } ?? 0
        return max(liveCounts[chat] ?? 0, yours)
    }

    private func refreshLiveCounts() {
        var counts: [String: Int] = [:]
        for (room, presence) in presence {
            guard presence.isLive, let count = presence.people?.count else { continue }
            for chat in Set(watchers[room, default: [:]].values) { counts[chat] = max(counts[chat] ?? 0, count) }
        }
        if counts != liveCounts { liveCounts = counts }
    }

    /// Who is on `link`'s call, kept in `presence` until the task watching
    /// is cancelled (a card scrolled away, the chat closed, a watch of the
    /// store's stopped by `refreshWatches`). The engine shares one
    /// subscription per room between watchers.
    public func watch(_ link: CallLink, in chat: String) async {
        guard let engine else { return }
        let room = link.room, id = UUID()
        watchers[room, default: [:]][id] = chat
        // A room already known lights its new chat at once.
        refreshLiveCounts()
        defer {
            watchers[room]?[id] = nil
            if watchers[room]?.isEmpty != false {
                watchers[room] = nil
                // Its didSet works the counts out again.
                presence[room] = nil
            } else {
                refreshLiveCounts()
            }
        }
        guard let stream = try? await engine.callPresence(of: link) else { return }
        for await presence in stream where !Task.isCancelled && self.presence[room] != presence {
            self.presence[room] = presence
        }
    }

    // MARK: Recent calls

    /// Follows the messages that may be recent calls, in every chat;
    /// throws when storage cannot read them.
    func observeRecent(_ storage: Storage) async throws {
        for try await messages in storage.recentCallMessages() where !Task.isCancelled {
            recentMessages = messages
            refreshWatches()
        }
    }

    /// Watches the newest recent call in each chat (`WatchedCall.watched`,
    /// at most eight) while the app is unlocked, whatever chat is open, so
    /// the sidebar knows and a card shows its count at once. A watch stops
    /// when its call ages out (a wake-up at the soonest), its chat is left
    /// or deleted (it drops out of storage's list), on lock and on an
    /// account change (`reset`). The call server reconnects a dropped feed
    /// with backoff.
    private func refreshWatches() {
        let messages = watchesRecent ? recentMessages : []
        let calls = WatchedCall.watched(in: messages, server: server)
        // One watch per call and chat: the same link posted in two chats lights both.
        let wanted = Dictionary(calls.map { ("\($0.chat) \($0.link.room)", $0) }, uniquingKeysWith: { first, _ in first })
        for (key, task) in watches where wanted[key] == nil {
            task.cancel()
            watches[key] = nil
        }
        for (key, watched) in wanted where watches[key] == nil {
            watches[key] = Task {
                await self.watch(watched.link, in: watched.chat)
                // Ended on its own (no engine, a refusal, the feed closed):
                // the next refresh starts it again, never in a loop.
                if !Task.isCancelled { self.watches[key] = nil }
            }
        }
        watchExpiry?.cancel()
        watchExpiry = WatchedCall.nextChange(of: calls, in: messages).map { next in
            Task {
                try? await Task.sleep(for: .seconds(max(1, next.timeIntervalSinceNow)))
                if !Task.isCancelled { refreshWatches() }
            }
        }
    }

    /// The open chat's recent calls, from its rows.
    func refreshRecent(from rows: [ChatRow]) {
        let now = Date.now
        // A row's date is its newest message's, never older than its call.
        // Presence is asked only for calls that may be live (`CallLink.mayBeLive`).
        // A plain loop, run on every change of the rows: a chain of lazy
        // collections here costs a busy chat milliseconds per message.
        var calls: [CallLink] = []
        for row in rows.reversed() {
            guard calls.count < 3, now.timeIntervalSince(row.date) < CallLink.liveAge else { break }
            if let call = row.call, CallLink.mayBeLive(row.message, now: now) { calls.append(call) }
        }
        if calls != recent { recent = calls }
    }

    // MARK: The call you are on

    /// Runs a join or a start, then brings the call window up if there is
    /// a call to show (joining one you are on just opens it). The view
    /// passes the window opening in.
    public func openingWindow(_ open: @escaping @MainActor () -> Void, after action: @escaping @MainActor () async -> Bool) {
        Task { if await action() { open() } }
    }

    /// The chat of the call you are on, when it is not `room`'s: joining
    /// or starting another asks in place first ("Leave the call in #design
    /// and join?"), never leaving it silently.
    public func otherCall(than room: String?) -> String? {
        guard let call, call.isOn, call.link.room != room else { return nil }
        return call.title
    }

    /// Joins a call: a ticket from the call server, then the call window's
    /// room, titled with the chat, with the microphone on and the camera off
    /// unless `camera`. Returns whether there is a call to show; on failure
    /// the reason shows beside the card's Join, or as the chat's notice for
    /// a join or start from the header (`failureInChat`), whose card may be
    /// out of sight. The call you were on (its leaving already confirmed)
    /// goes only once the ticket has come, so a failed join leaves you on it.
    public func join(_ link: CallLink, in chat: String, camera: Bool = false, failureInChat: Bool = false) async -> Bool {
        if isOnCall(link.room) { return true }
        if let reason = provider.unavailable {
            if failureInChat { chatNotice(chat) { _ in reason } } else { failures[link.room] = reason }
            return false
        }
        guard joiningRoom == nil, let engine else { return false }
        joiningRoom = link.room
        defer { joiningRoom = nil }
        failures[link.room] = nil
        // Only a failure of its own: the chat may be showing another notice.
        if failureInChat {
            chatNotice(chat) { $0?.hasPrefix("Could not join the call") == true ? nil : $0 }
        }
        do {
            let ticket = try await engine.callTicket(for: link, in: chat)
            guard self.engine === engine else { return false }
            leave()
            call = try provider.join(ticket, link: link, chat: chat, title: chatTitle(chat), camera: camera)
            return true
        } catch {
            if failureInChat {
                let notice = PeelError.problem(error, couldNot: "join the call")
                chatNotice(chat) { _ in notice }
            } else {
                failures[link.room] = PeelError.problem(error)
            }
            return false
        }
    }

    /// Starts a call in `chat` (the call message, free in a DM and 3 sats
    /// in a tribe) and joins it, with your camera on for a video call.
    /// Nothing is sent while a join or another start runs.
    public func start(in chat: String, audioOnly: Bool) async -> Bool {
        // Nothing posted (a call message costs 3 sats in a tribe) for a
        // call this device could not join.
        if let reason = provider.unavailable {
            chatNotice(chat) { _ in reason }
            return false
        }
        guard startingIn == nil, joiningRoom == nil, let engine else { return false }
        startingIn = chat
        defer { startingIn = nil }
        do {
            let link = try await engine.startCall(in: chat, audioOnly: audioOnly).link
            return await join(link, in: chat, camera: !audioOnly, failureInChat: true)
        } catch {
            let notice = PeelError.problem(error, couldNot: "start the call")
            chatNotice(chat) { _ in notice }
            return false
        }
    }

    /// Leaves the call you are on; its window closes. The room says
    /// goodbye in the background (`leaving`).
    public func leave() {
        guard let call else { return }
        self.call = nil
        let earlier = leaving
        leaving = Task {
            await earlier?.value
            await call.leave()
        }
    }

    /// Leaves, and waits until every room left has said goodbye: when Peel quits.
    public func end() async {
        leave()
        await leaving?.value
    }

    /// A call whose connection was lost, joined again with a new ticket.
    public func rejoin() {
        guard let call, !call.isOn else { return }
        Task { _ = await join(call.link, in: call.chat, camera: call.wantsCamera) }
    }
}
