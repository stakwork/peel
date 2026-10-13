import Foundation
import PeelCore

extension CallPresence {
    /// Someone is on it.
    var isLive: Bool { !(people ?? []).isEmpty }
}

extension AppModel {
    func presence(of room: String) -> CallPresence {
        callPresence[room] ?? .unknown
    }

    /// Whether you are on the call in `room`, or joining it.
    func isOnCall(_ room: String) -> Bool {
        call?.link.room == room && call?.isOn == true
    }

    /// Runs a join or a start, then brings the call window up if there is
    /// a call to show (joining one you are on just opens it). The view
    /// passes the window opening in.
    func openingCallWindow(_ open: @escaping @MainActor () -> Void, after action: @escaping @MainActor () async -> Bool) {
        Task { if await action() { open() } }
    }

    func refreshLiveCallCounts() {
        var counts: [String: Int] = [:]
        for (room, presence) in callPresence {
            guard presence.isLive, let count = presence.people?.count else { continue }
            for chat in Set(callWatchers[room, default: [:]].values) { counts[chat] = max(counts[chat] ?? 0, count) }
        }
        if counts != liveCallCounts { liveCallCounts = counts }
    }

    /// How many are on a call in `chat` now, for its sidebar row: its
    /// busiest watched call, or the one you are on there.
    func liveCallCount(in chat: String) -> Int {
        let yours = call.flatMap { $0.chat == chat && $0.isOn ? $0.people.count : nil } ?? 0
        return max(liveCallCounts[chat] ?? 0, yours)
    }

    /// Follows the messages that may be recent calls, in every chat.
    func observeRecentCalls(_ storage: Storage) async {
        do {
            for try await messages in storage.recentCallMessages() where !Task.isCancelled {
                recentCallMessages = messages
                refreshCallWatches()
            }
        } catch {
            if !Task.isCancelled { notice = PeelError.problem(error, couldNot: "load recent calls") }
        }
    }

    /// Watches the newest recent call in each chat (`WatchedCall.watched`,
    /// at most eight) while the app is unlocked, whatever chat is open, so
    /// the sidebar knows and a card shows its count at once. A watch stops
    /// when its call ages out (a wake-up at the soonest), its chat is left
    /// or deleted (it drops out of storage's list), on lock and on an
    /// account change (`stopWatchingCalls`). The call server reconnects a
    /// dropped feed with backoff.
    func refreshCallWatches() {
        let messages = phase == .ready ? recentCallMessages : []
        let calls = WatchedCall.watched(in: messages, server: callServer)
        // One watch per call and chat: the same link posted in two chats lights both.
        let wanted = Dictionary(calls.map { ("\($0.chat) \($0.link.room)", $0) }, uniquingKeysWith: { first, _ in first })
        for (key, task) in callWatches where wanted[key] == nil {
            task.cancel()
            callWatches[key] = nil
        }
        for (key, watched) in wanted where callWatches[key] == nil {
            callWatches[key] = Task {
                await self.watchCall(watched.link, in: watched.chat)
                // Ended on its own (no engine, a refusal, the feed closed):
                // the next refresh starts it again, never in a loop.
                if !Task.isCancelled { self.callWatches[key] = nil }
            }
        }
        callWatchExpiry?.cancel()
        callWatchExpiry = WatchedCall.nextChange(of: calls, in: messages).map { next in
            Task {
                try? await Task.sleep(for: .seconds(max(1, next.timeIntervalSinceNow)))
                if !Task.isCancelled { refreshCallWatches() }
            }
        }
    }

    func stopWatchingCalls() {
        recentCallMessages = []
        refreshCallWatches()
    }

    func refreshRecentCalls() {
        let now = Date.now
        // A row's date is its newest message's, never older than its call.
        // Presence is asked only for calls that may be live (`CallLink.mayBeLive`).
        // A plain loop, run on every change of the rows: a chain of lazy
        // collections here costs a busy chat milliseconds per message.
        var calls: [CallLink] = []
        for row in chatRows.reversed() {
            guard calls.count < 3, now.timeIntervalSince(row.date) < CallLink.liveAge else { break }
            if let call = row.call, CallLink.mayBeLive(row.message, now: now) { calls.append(call) }
        }
        if calls != recentCalls { recentCalls = calls }
    }

    /// Who is on `link`'s call, kept in `callPresence` until the task
    /// watching is cancelled (a card scrolled away, the chat closed, a
    /// model watch stopped by `refreshCallWatches`). The
    /// engine shares one subscription per room between watchers.
    func watchCall(_ link: CallLink, in chat: String) async {
        guard let engine else { return }
        let room = link.room, id = UUID()
        callWatchers[room, default: [:]][id] = chat
        // A room already known lights its new chat at once.
        refreshLiveCallCounts()
        defer {
            callWatchers[room]?[id] = nil
            if callWatchers[room]?.isEmpty != false {
                callWatchers[room] = nil
                // Its didSet works the counts out again.
                callPresence[room] = nil
            } else {
                refreshLiveCallCounts()
            }
        }
        guard let stream = try? await engine.callPresence(of: link) else { return }
        for await presence in stream where !Task.isCancelled && callPresence[room] != presence {
            callPresence[room] = presence
        }
    }


    /// The chat of the call you are on, when it is not `room`'s: joining
    /// or starting another asks in place first ("Leave the call in #design
    /// and join?"), never leaving it silently.
    func otherCall(than room: String?) -> String? {
        guard let call, call.isOn, call.link.room != room else { return nil }
        return call.title
    }

    /// Joins a call: a ticket from the call server, then the call window's
    /// room, with the microphone on and the camera off unless `camera`.
    /// Returns whether there is a call to show; on failure the reason shows
    /// beside the card's Join, or as the chat's notice for a join or start
    /// from the header (`failureInChat`), whose card may be out of sight. The call
    /// you were on (its leaving already confirmed) goes only once the
    /// ticket has come, so a failed join leaves you on it.
    func joinCall(_ link: CallLink, in chat: String, camera: Bool = false, failureInChat: Bool = false) async -> Bool {
        if isOnCall(link.room) { return true }
        guard joiningRoom == nil, let engine else { return false }
        joiningRoom = link.room
        defer { joiningRoom = nil }
        callFailures[link.room] = nil
        // Only a failure of its own: the chat may be showing another notice.
        if failureInChat, conversationNotices[chat]?.hasPrefix("Could not join the call") == true {
            conversationNotices[chat] = nil
        }
        do {
            let ticket = try await engine.callTicket(for: link, in: chat)
            guard self.engine === engine else { return false }
            leaveCall()
            call = platform.calls.join(ticket, link: link, chat: chat, title: chatTitle(chat), camera: camera)
            return true
        } catch {
            if failureInChat {
                conversationNotices[chat] = PeelError.problem(error, couldNot: "join the call")
            } else {
                callFailures[link.room] = PeelError.problem(error)
            }
            return false
        }
    }

    /// Starts a call in `chat` (the call message, free in a DM and 3 sats
    /// in a tribe) and joins it, with your camera on for a video call.
    /// Nothing is sent while a join or another start runs.
    func startCall(in chat: String, audioOnly: Bool) async -> Bool {
        guard startingCallIn == nil, joiningRoom == nil, let engine else { return false }
        startingCallIn = chat
        defer { startingCallIn = nil }
        do {
            let link = try await engine.startCall(in: chat, audioOnly: audioOnly).link
            return await joinCall(link, in: chat, camera: !audioOnly, failureInChat: true)
        } catch {
            conversationNotices[chat] = PeelError.problem(error, couldNot: "start the call")
            return false
        }
    }

    /// Leaves the call you are on; its window closes. The room says
    /// goodbye in the background (`callLeaving`).
    func leaveCall() {
        guard let call else { return }
        self.call = nil
        let earlier = callLeaving
        callLeaving = Task {
            await earlier?.value
            await call.leave()
        }
    }

    /// Leaves, and waits until every room left has said goodbye: when Peel quits.
    func endCall() async {
        leaveCall()
        await callLeaving?.value
    }

    /// A call whose connection was lost, joined again with a new ticket.
    func rejoinCall() {
        guard let call, !call.isOn else { return }
        Task { _ = await joinCall(call.link, in: call.chat, camera: call.wantsCamera) }
    }

    /// Someone on a call: their name ("Guest" when they sent none) and
    /// photo as they sent them, a hue keyed as for a tribe member, and you
    /// as yourself.
    func avatar(of person: CallParticipant) -> Sender {
        avatar(
            fromMe: person.identity == call?.identity, alias: person.nickname.isEmpty ? "Guest" : person.nickname,
            photoURL: person.avatarURL?.absoluteString, chat: person.identity, inTribe: true
        )
    }

    /// "#tribe" or the contact's name, for the call window.
    func chatTitle(_ chat: String) -> String {
        conversations.first { $0.chat == chat }?.title ?? "Call"
    }
}
