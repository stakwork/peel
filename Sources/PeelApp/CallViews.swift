import SwiftUI
import PeelCore

extension CallPresence {
    /// Who is on it, when the call server has said.
    var people: [CallParticipant]? {
        if case .live(let people) = self { people } else { nil }
    }

    /// Someone is on it.
    var isLive: Bool { !(people ?? []).isEmpty }
}

// MARK: - The model's calls

extension AppModel {
    /// Presence is asked only for calls younger than this: older ones are
    /// over, and each subscription tells the call server what you watch.
    static let presenceAge: TimeInterval = 12 * 60 * 60

    func isRecent(_ date: Date, now: Date = .now) -> Bool {
        now.timeIntervalSince(date) < Self.presenceAge
    }

    func presence(of room: String) -> CallPresence {
        callPresence[room] ?? .unknown
    }

    /// Whether you are on the call in `room`, or joining it.
    func isOnCall(_ room: String) -> Bool {
        call?.link.room == room && call?.isOn == true
    }

    /// Runs a join or a start, then brings the call window up if there is
    /// a call to show (joining one you are on just opens it).
    func openingCallWindow(_ openWindow: OpenWindowAction, after action: @escaping @MainActor () async -> Bool) {
        Task { if await action() { openWindow(id: CallWindow.id) } }
    }

    func refreshLiveCallChats() {
        var chats = Set(callPresence.filter(\.value.isLive).flatMap { callWatchers[$0.key]?.values ?? [:].values })
        if let call { chats.insert(call.chat) }
        if chats != liveCallChats { liveCallChats = chats }
    }

    func refreshRecentCalls() {
        let now = Date.now
        // A row's date is its newest message's, never older than its call.
        let recent = chatRows.reversed().lazy.prefix { self.isRecent($0.date, now: now) }
        let calls = Array(recent.filter { self.isRecent($0.message.date, now: now) }.compactMap(\.call).prefix(3))
        if calls != recentCalls { recentCalls = calls }
    }

    /// Who is on `link`'s call, kept in `callPresence` until the task
    /// watching is cancelled (a card scrolled away, the chat closed). The
    /// engine shares one subscription per room between watchers.
    func watchCall(_ link: CallLink, in chat: String) async {
        guard let engine else { return }
        let room = link.room, id = UUID()
        callWatchers[room, default: [:]][id] = chat
        defer {
            callWatchers[room]?[id] = nil
            if callWatchers[room]?.isEmpty != false {
                callWatchers[room] = nil
                callPresence[room] = nil
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
    /// beside Join. The call you were on (its leaving already confirmed)
    /// goes only once the ticket has come, so a failed join leaves you on it.
    func joinCall(_ link: CallLink, in chat: String, camera: Bool = false) async -> Bool {
        if isOnCall(link.room) { return true }
        guard joiningRoom == nil, let engine else { return false }
        joiningRoom = link.room
        defer { joiningRoom = nil }
        callFailures[link.room] = nil
        do {
            let ticket = try await engine.callTicket(for: link, in: chat)
            guard self.engine === engine else { return false }
            leaveCall()
            call = CallSession(ticket: ticket, link: link, chat: chat, title: chatTitle(chat), camera: camera)
            return true
        } catch {
            callFailures[link.room] = PeelError.readable(error).capitalizedFirst
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
            return await joinCall(link, in: chat, camera: !audioOnly)
        } catch {
            conversationNotices[chat] = "Could not start the call: \(PeelError.readable(error))"
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
    func avatar(of person: CallParticipant) -> (name: String, photoURL: String?, hue: PersonHue) {
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

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

// MARK: - The card (C1)

/// A call in the timeline, under its sender's run header: audio or video,
/// who is on it, and Join. Colour shows only while someone is on it; with
/// no word from the call server (or an old call) there is no count at all,
/// never a guessed zero.
struct CallCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    let row: ChatRow
    let link: CallLink
    /// The call you are on elsewhere, while Join asks to leave it (C5).
    @State private var leaving: String?

    static let width: CGFloat = 320

    var body: some View {
        let message = row.message
        let presence = model.presence(of: link.room)
        let onIt = model.isOnCall(link.room)
        let notSent = message.fromMe && message.delivery == .failed
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 7) {
                        Image(systemName: link.audioOnly ? "phone" : "video")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.secondaryText)
                        Text(link.audioOnly ? "Audio call" : "Video call")
                            .font(Theme.font(14, .semibold))
                    }
                    if notSent {
                        line("Not sent")
                    } else if onIt {
                        who(presence.people ?? [], "You're on this call")
                    } else {
                        switch presence {
                        case .live(let people) where !people.isEmpty:
                            who(people, "\(people.count) on the call")
                        case .live: line("No one on the call")
                        case .ended: line("Call ended")
                        case .unknown: EmptyView()
                        }
                    }
                }
                Spacer(minLength: 0)
                if notSent {
                    // Never sent again: its room would be stale. Start a new one.
                    Button("Discard") { Task { await model.discard(message) } }
                        .buttonStyle(GhostButtonStyle())
                        .help("Remove this call, which was never sent")
                } else if leaving == nil {
                    button(onIt)
                }
            }
            if let leaving {
                VStack(spacing: 0) {
                    Theme.divider.frame(height: 1).padding(.bottom, 10)
                    CallSwitchConfirm(
                        other: leaving, joining: true, working: model.joiningRoom == link.room,
                        cancel: { self.leaving = nil }, confirm: join
                    )
                }
                .padding(.top, 2)
            }
            if let failure = model.callFailures[link.room] {
                Text(failure)
                    .font(Theme.font(12))
                    .foregroundStyle(Theme.secondaryText)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: Self.width, alignment: .leading)
        .background(Theme.quote, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.divider) }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(link.audioOnly ? "Audio call" : "Video call")
        // Only while the card is drawn, and only for a recent call.
        .task(id: link.room) {
            guard model.isRecent(message.date), !notSent else { return }
            await model.watchCall(link, in: message.chat)
        }
    }

    private func line(_ text: String) -> some View {
        Text(text)
            .font(Theme.font(12.5))
            .foregroundStyle(Theme.secondaryText)
            .frame(minHeight: 24)
    }

    private func who(_ people: [CallParticipant], _ text: String) -> some View {
        HStack(spacing: 7) {
            if !people.isEmpty { CallPeopleStack(people: people, size: 24, border: Theme.quote) }
            OnlineDot()
            Text(text)
                .font(Theme.font(12.5))
                .monospacedDigit()
                .foregroundStyle(Theme.text)
        }
        .frame(minHeight: 24)
    }

    @ViewBuilder private func button(_ onIt: Bool) -> some View {
        if onIt {
            Button("Open") { openWindow(id: CallWindow.id) }
                .buttonStyle(GhostButtonStyle())
                .help("Bring the call window forward")
        } else {
            let joining = model.joiningRoom == link.room
            Button {
                if let other = model.otherCall(than: link.room) { leaving = other } else { join() }
            } label: {
                Text("Join").buttonProgress(joining)
            }
            .buttonStyle(GhostButtonStyle(prominent: true))
            .disabled(model.joiningRoom != nil && !joining)
            .help("Join with your microphone and camera off")
        }
    }

    private func join() {
        model.openingCallWindow(openWindow) {
            let joined = await model.joinCall(link, in: row.message.chat)
            leaving = nil
            return joined
        }
    }

    /// The call's part of its message menu: the link as it was sent, and
    /// what having it means.
    static func menuEntries(_ link: CallLink) -> [MenuEntry] {
        [
            .copy("Copy call link", text: link.url.absoluteString, systemImage: "link"),
            .view(AnyView(
                Text("Anyone with the link can join")
                    .font(Theme.font(11))
                    .foregroundStyle(Theme.secondaryText)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
            )),
        ]
    }
}

/// The green dot of someone on a call (`#49C998`, Sphinx's online green).
/// Grey (`secondaryText`) for a call that is not connected.
struct OnlineDot: View {
    var color = Theme.confirmed

    var body: some View {
        Circle().fill(color).frame(width: 7, height: 7).accessibilityHidden(true)
    }
}

/// Up to three people on a call, overlapping, then "+N". Names and photos
/// are what each joiner sent: shown as given, never matched to a contact.
/// You are told apart by the ticket's identity.
struct CallPeopleStack: View {
    @Environment(AppModel.self) private var model
    let people: [CallParticipant]
    let size: CGFloat
    let border: Color

    var body: some View {
        HStack(spacing: -7) {
            ForEach(people.prefix(3)) { person in
                let shown = model.avatar(of: person)
                Avatar(name: shown.name, url: shown.photoURL, size: size, hue: shown.hue)
                .padding(2)
                .background(border, in: Circle())
                .help(shown.name)
            }
            if people.count > 3 {
                Text("+\(people.count - 3)")
                    .font(Theme.font(12))
                    .monospacedDigit()
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize()
                    .padding(.leading, 11)
            }
        }
        .padding(-2)
        .accessibilityHidden(true)
    }
}

// MARK: - The header (C2)

/// The call button in a chat's header: a menu with Audio call (⌥⌘A) and
/// Video call (⌥⌘V). While a recent call here has someone on it, "● Join · N"
/// joins the newest such call instead, with "Start a new call" behind its
/// chevron. On another call, either asks in place to leave it first (C5).
struct CallHeaderButton: View {
    @Environment(AppModel.self) private var model
    @Environment(\.menuPresenter) private var presenter
    @Environment(\.openWindow) private var openWindow
    let chat: String

    @State private var frame: CGRect = .zero
    /// What waits for "Leave and join" (or start), and the call it leaves.
    @State private var pending: (action: Pending, other: String)?

    private enum Pending {
        case join(CallLink)
        case start(audioOnly: Bool)
    }

    var body: some View {
        // An account with no call server has no calls to start.
        if model.callServer != nil { content }
    }

    @ViewBuilder private var content: some View {
        let recent = model.recentCalls
        let live = recent.first { model.presence(of: $0.room).isLive }
        HStack(spacing: 8) {
            if let pending {
                let joining: Bool = if case .join = pending.action { true } else { false }
                CallSwitchConfirm(
                    other: pending.other, joining: joining, inline: true,
                    working: model.joiningRoom != nil || model.startingCallIn == chat,
                    cancel: { self.pending = nil }, confirm: { run(pending.action) }
                )
            } else if let live {
                if let failure = model.callFailures[live.room] {
                    Text(failure)
                        .font(Theme.font(12))
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 260, alignment: .trailing)
                        .help(failure)
                }
                pill(live)
            } else {
                HeaderButton(systemImage: "phone", help: "Start a call", working: model.startingCallIn == chat) {
                    showMenu(header: false)
                }
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
            }
        }
        .background {
            // ⌥⌘A and ⌥⌘V start a call from anywhere in the chat.
            Group {
                Button("") { start(audioOnly: true) }.keyboardShortcut("a", modifiers: [.option, .command])
                Button("") { start(audioOnly: false) }.keyboardShortcut("v", modifiers: [.option, .command])
            }
            .opacity(0)
            .frame(width: 0, height: 0)
            .disabled(model.startingCallIn != nil)
            .accessibilityHidden(true)
        }
        // A tribe's header is kept when another tribe opens: a question
        // asked in one chat is never answered in the next.
        .onChange(of: chat) { pending = nil }
        // The header's own watch, while the chat is open.
        .task(id: recent.map(\.room)) {
            await withTaskGroup(of: Void.self) { group in
                for link in recent {
                    group.addTask { await model.watchCall(link, in: chat) }
                }
            }
        }
    }

    private func pill(_ live: CallLink) -> some View {
        let count = model.presence(of: live.room).people?.count ?? 0
        let onIt = model.isOnCall(live.room)
        let joining = model.joiningRoom == live.room
        return HStack(spacing: 0) {
            Button {
                ask(.join(live), leaving: model.otherCall(than: live.room))
            } label: {
                HStack(spacing: 7) {
                    OnlineDot()
                    Text("\(onIt ? "Open" : "Join") · \(count)")
                        .font(Theme.font(13, .semibold))
                        .monospacedDigit()
                }
                .buttonProgress(joining || model.startingCallIn == chat)
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(model.joiningRoom != nil && !joining)
            .help(onIt ? "Bring the call window forward" : "Join the newest live call")
            .accessibilityLabel(onIt ? "Open the call, \(count) on it" : "Join the call, \(count) on it")
            Theme.divider.frame(width: 1, height: 28)
            Button { showMenu(header: true) } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.secondaryText)
                    .frame(width: 24, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Start a new call")
            .accessibilityLabel("More call options")
        }
        .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.divider) }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
    }

    private func showMenu(header: Bool) {
        let items: [MenuEntry] = [
            .button("Audio call", systemImage: "phone", shortcut: .optionCommand("a")) { start(audioOnly: true) },
            .button("Video call", systemImage: "video", shortcut: .optionCommand("v")) { start(audioOnly: false) },
        ]
        presenter?.show((header ? [.header("Start a new call")] : []) + items, at: frame, source: "call-\(chat)")
    }

    private func start(audioOnly: Bool) {
        ask(.start(audioOnly: audioOnly), leaving: model.otherCall(than: nil))
    }

    /// Runs `action` at once, or first asks to leave the call you are on.
    private func ask(_ action: Pending, leaving other: String?) {
        if let other { pending = (action, other) } else { run(action) }
    }

    private func run(_ action: Pending) {
        model.openingCallWindow(openWindow) {
            let done = switch action {
            case .join(let link): await model.joinCall(link, in: chat)
            case .start(let audioOnly): await model.startCall(in: chat, audioOnly: audioOnly)
            }
            pending = nil
            return done
        }
    }
}

// MARK: - Switching calls (C5)

/// The in-place confirm when joining or starting a call while on another:
/// "Leave the call in #design and join?", Cancel and the blue commit.
struct CallSwitchConfirm: View {
    let other: String
    /// Joining a call, or else starting one.
    let joining: Bool
    /// One line, for the header; the card stacks it.
    var inline = false
    let working: Bool
    let cancel: () -> Void
    let confirm: () -> Void

    var body: some View {
        let text = Text("Leave the call in ") + Text(other).fontWeight(.semibold)
            + Text(joining ? " and join?" : " and start a new one?")
        let commit = joining ? "Leave and join" : "Leave and start"
        let buttons = HStack(spacing: 8) {
            Button("Cancel", action: cancel)
                .buttonStyle(GhostButtonStyle())
            Button(action: confirm) { Text(commit).buttonProgress(working) }
                .buttonStyle(GhostButtonStyle(prominent: true))
                .disabled(working)
        }
        Group {
            if inline {
                HStack(spacing: 10) {
                    text.lineLimit(1).truncationMode(.middle)
                    buttons
                }
            } else {
                VStack(alignment: .leading, spacing: 9) {
                    text.fixedSize(horizontal: false, vertical: true)
                    buttons.frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        }
        .font(Theme.font(13.5))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Switch calls")
    }
}

// MARK: - On a call (C4)

/// At the foot of the sidebar while you are on a call, like a huddle bar:
/// the chat, the running time, who is on it, Mute and "Return to call".
struct OnCallBar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    let call: CallSession

    var body: some View {
        let people = call.people
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                OnlineDot(color: call.state == .connected ? Theme.confirmed : Theme.secondaryText)
                ChatTitle(title: call.title)
                    .font(Theme.font(13, .bold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                CallStatusText(call: call, size: 12)
            }
            HStack(spacing: 7) {
                CallPeopleStack(people: people, size: 20, border: Theme.quote)
                Text(people.count == 1 ? "Only you" : "\(people.count) on the call")
                    .font(Theme.font(12.5))
                    .monospacedDigit()
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
            }
            .frame(minHeight: 20)
            HStack(spacing: 6) {
                let label = call.micOn ? "Mute" : "Unmute"
                Button(action: call.toggleMicrophone) {
                    Image(systemName: call.micOn ? "mic" : "mic.slash")
                        .font(.system(size: 13))
                        .foregroundStyle(call.micOn ? Theme.text : Theme.secondaryText)
                        .frame(width: 30, height: 30)
                        .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.divider) }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(call.micAccess == .refused)
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .help("\(label) (⌘⇧A)")
                .accessibilityLabel(label)
                Button { openWindow(id: CallWindow.id) } label: {
                    Label("Return to call", systemImage: "arrow.up.forward.square")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(GhostButtonStyle())
                .help("Bring the call window forward")
            }
        }
        .padding(.vertical, 10)
        .padding(.leading, 12)
        .padding(.trailing, 10)
        .background(Theme.quote, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.divider) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("On a call in \(call.title)")
    }
}
