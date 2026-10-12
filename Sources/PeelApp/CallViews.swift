import SwiftUI
import PeelCore

// MARK: - The card (C1)

/// A call in the timeline, under its sender's run header: audio or video,
/// who is on it, and Join. Colour shows only while someone is on it; with
/// no word from the call server (or an old call) there is no count at all,
/// never a guessed zero; a recent call keeps the line's room empty meanwhile.
struct CallCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    let row: ChatRow
    let link: CallLink
    /// The call you are on elsewhere, while Join asks to leave it (C5).
    @State private var leaving: String?

    static let width: CGFloat = 320
    /// The status line's height, kept empty until the call server answers.
    private static let lineHeight: CGFloat = 24

    var body: some View {
        let message = row.message
        let presence = model.presence(of: link.room)
        let onIt = model.isOnCall(link.room)
        let notSent = message.notSent
        Card(.inset) {
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                HStack(spacing: Theme.Space.md) {
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
                            case .unknown:
                                // So the card does not grow under the reader when it does.
                                if CallLink.isRecent(message.date) { Color.clear.frame(height: Self.lineHeight) }
                            }
                        }
                    }
                    Spacer(minLength: 0)
                    if notSent {
                        // Never sent again: its room would be stale. Start a new one.
                        Button("Discard") { Task { await model.discard(message) } }
                            .buttonStyle(.peel(.outline, size: .sm))
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
                        .muted()
                        .textSelection(.enabled)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, Theme.Space.md)
            .frame(width: Self.width, alignment: .leading)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(link.audioOnly ? "Audio call" : "Video call")
        // Only while the card is drawn, and only for a recent call.
        .task(id: link.room) {
            guard CallLink.mayBeLive(message) else { return }
            await model.watchCall(link, in: message.chat)
        }
    }

    private func line(_ text: String) -> some View {
        Text(text)
            .font(Theme.font(12))
            .foregroundStyle(Theme.secondaryText)
            .frame(minHeight: Self.lineHeight)
    }

    private func who(_ people: [CallParticipant], _ text: String) -> some View {
        HStack(spacing: 7) {
            if !people.isEmpty { CallPeopleStack(people: people, size: Theme.AvatarSize.md, border: Theme.quote) }
            OnlineDot()
            Text(text)
                .font(Theme.font(12))
                .monospacedDigit()
                .foregroundStyle(Theme.text)
        }
        .frame(minHeight: Self.lineHeight)
    }

    @ViewBuilder private func button(_ onIt: Bool) -> some View {
        if onIt {
            Button("Open") { openWindow(id: CallWindow.id) }
                .buttonStyle(.peel(.outline, size: .sm))
                .help("Bring the call window forward")
        } else {
            let joining = model.joiningRoom == link.room
            Button {
                if let other = model.otherCall(than: link.room) { leaving = other } else { join() }
            } label: {
                Text("Join").buttonProgress(joining)
            }
            .buttonStyle(.peel(.primary, size: .sm))
            .disabled(model.joiningRoom != nil && !joining)
            .help("Join with your microphone and camera off")
        }
    }

    private func join() {
        model.openingCallWindow({ openWindow(id: CallWindow.id) }) {
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
                Avatar(name: shown.avatarName, url: shown.photoURL, size: size, hue: shown.hue)
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

    /// The phone button's, and the split Join's chevron's: one per trigger.
    @State private var anchor = MenuAnchor()
    @State private var chevron = MenuAnchor()
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
        HStack(spacing: Theme.Space.sm) {
            if let pending {
                let joining: Bool = if case .join = pending.action { true } else { false }
                CallSwitchConfirm(
                    other: pending.other, joining: joining, inline: true,
                    working: model.joiningRoom != nil || model.startingCallIn == chat,
                    cancel: { self.pending = nil }, confirm: { run(pending.action) }
                )
            } else if let live {
                pill(live)
            } else {
                IconButton("phone", help: "Start a call", lit: menuOpen, working: model.startingCallIn == chat) {
                    showMenu(header: false)
                }
                .menuAnchor(anchor)
            }
        }
        // ⌥⌘A and ⌥⌘V start a call from anywhere in the chat.
        .hiddenShortcut(KeyboardShortcut("a", modifiers: [.option, .command]), enabled: model.startingCallIn == nil) {
            start(audioOnly: true)
        }
        .hiddenShortcut(KeyboardShortcut("v", modifiers: [.option, .command]), enabled: model.startingCallIn == nil) {
            start(audioOnly: false)
        }
        // A tribe's header is kept when another tribe opens: a question
        // asked in one chat is never answered in the next.
        .onChange(of: chat) { pending = nil }
        // The header's own watch, while the chat is open: the model watches
        // only each chat's newest call (`refreshCallWatches`), this the next two.
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
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
        // One outline box split in two: Join as a ghost `.sm` button, the
        // chevron as a ghost icon button.
        return HStack(spacing: 0) {
            Button {
                ask(.join(live), leaving: model.otherCall(than: live.room))
            } label: {
                HStack(spacing: 7) {
                    OnlineDot()
                    Text("\(onIt ? "Open" : "Join") · \(count)")
                        .monospacedDigit()
                }
                .buttonProgress(joining || model.startingCallIn == chat)
            }
            .buttonStyle(.peel(.ghost, size: .sm))
            .disabled(model.joiningRoom != nil && !joining)
            .help(onIt ? "Bring the call window forward" : "Join the newest live call")
            .accessibilityLabel(onIt ? "Open the call, \(count) on it" : "Join the call, \(count) on it")
            Theme.inputBorder.frame(width: 1, height: PeelButton.Size.sm.height)
            IconButton(help: "Start a new call", lit: menuOpen) {
                showMenu(header: true)
            } label: {
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
            }
            .menuAnchor(chevron)
        }
        .background(Theme.fieldFill, in: shape)
        .overlay { shape.strokeBorder(Theme.inputBorder) }
    }

    private var menuSource: AnyHashable { "call-\(chat)" }

    /// Its menu is open: the button that opened it is lit.
    private var menuOpen: Bool { presenter?.isOpen(from: menuSource) == true }

    private func showMenu(header: Bool) {
        let items: [MenuEntry] = [
            .button("Audio call", systemImage: "phone", shortcut: .optionCommand("a")) { start(audioOnly: true) },
            .button("Video call", systemImage: "video", shortcut: .optionCommand("v")) { start(audioOnly: false) },
        ]
        presenter?.show((header ? [.header("Start a new call")] : []) + items, at: header ? chevron : anchor, source: menuSource)
    }

    private func start(audioOnly: Bool) {
        ask(.start(audioOnly: audioOnly), leaving: model.otherCall(than: nil))
    }

    /// Runs `action` at once, or first asks to leave the call you are on.
    private func ask(_ action: Pending, leaving other: String?) {
        if let other { pending = (action, other) } else { run(action) }
    }

    private func run(_ action: Pending) {
        model.openingCallWindow({ openWindow(id: CallWindow.id) }) {
            let done = switch action {
            case .join(let link): await model.joinCall(link, in: chat, failureInChat: true)
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
        let buttons = HStack(spacing: Theme.Space.sm) {
            Button("Cancel", action: cancel)
                .buttonStyle(.peel(.outline, size: .sm))
            Button(action: confirm) { Text(commit).buttonProgress(working) }
                .buttonStyle(.peel(.primary, size: .sm))
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
        .font(Theme.font(13))
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
        Card(.inset) {
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
                    CallPeopleStack(people: people, size: Theme.AvatarSize.sm, border: Theme.quote)
                    Text(people.count == 1 ? "Only you" : "\(people.count) on the call")
                        .font(Theme.font(12))
                        .monospacedDigit()
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                }
                .frame(minHeight: 20)
                HStack(spacing: 6) {
                    let label = call.micOn ? "Mute" : "Unmute"
                    IconButton(help: "\(label) (⌘⇧A)", variant: .outline, action: call.toggleMicrophone) {
                        Image(systemName: call.micOn ? "mic" : "mic.slash")
                            .foregroundStyle(call.micOn ? Theme.text : Theme.secondaryText)
                    }
                    .disabled(call.micAccess == .refused)
                    .keyboardShortcut("a", modifiers: [.command, .shift])
                    Button { openWindow(id: CallWindow.id) } label: {
                        Label("Return to call", systemImage: "arrow.up.forward.square")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.peel(.outline, size: .sm))
                    .help("Bring the call window forward")
                }
            }
            .padding(.vertical, 10)
            .padding(.leading, Theme.Space.md)
            .padding(.trailing, 10)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("On a call in \(call.title)")
    }
}
