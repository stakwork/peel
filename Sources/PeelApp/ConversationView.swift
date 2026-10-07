import SwiftUI
import PeelCore

struct ConversationView: View {
    @Environment(AppModel.self) private var model
    let conversation: Conversation

    @State private var draft = ""
    @State private var focusRequest = 0

    var body: some View {
        VStack(spacing: 0) {
            if conversation.isTribe {
                TribeHeader(conversation: conversation, tribe: model.selectedTribe)
            } else {
                DetailHeader(title: conversation.name) {
                    ConversationIcon(conversation: conversation, size: 32)
                }
            }
            MessageList(messages: model.messages, inTribe: conversation.isTribe)
            if let notice = model.conversationNotices[conversation.chat] {
                ConversationNotice(text: notice) { model.dismissNotice(in: conversation.chat) }
            }
            Composer(
                draft: $draft,
                placeholder: conversation.isTribe ? "Message #\(conversation.name)" : "Message \(conversation.name)",
                focusRequest: focusRequest,
                send: send
            )
        }
        .onAppear { focusRequest += 1 }
        .onChange(of: conversation.chat) { focusRequest += 1 }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        Task { await model.send(text) }
    }
}

/// An error that belongs to this conversation, such as a send the server
/// refused. Quiet, not red: nothing was destroyed.
struct ConversationNotice: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.circle")
                .foregroundStyle(Theme.attention)
            Text(text)
                .font(Theme.font(12))
                .foregroundStyle(Theme.secondaryText)
                .textSelection(.enabled)
                .lineLimit(3)
            Spacer(minLength: 8)
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.secondaryText)
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.divider))
        .padding(.horizontal, 20)
        .padding(.top, 6)
    }
}


/// A tribe's name, what it is about and what a message costs, with the
/// members panel behind the people button.
struct TribeHeader: View {
    let conversation: Conversation
    let tribe: Tribe?

    @State private var showingMembers = false

    private var subtitle: String? {
        guard let tribe else { return nil }
        return [tribe.summary?.trimmed.nilIfEmpty, "\(Formatting.sats(msat: tribe.messageAmountMsat)) a message"]
            .compactMap { $0 }.joined(separator: " · ")
    }

    var body: some View {
        DetailHeader(title: conversation.name, subtitle: subtitle) {
            ConversationIcon(conversation: conversation, size: 32)
        } trailing: {
            Button {
                showingMembers = true
            } label: {
                Image(systemName: "person.2")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.secondaryText)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Members")
            .popover(isPresented: $showingMembers, arrowEdge: .bottom) {
                TribeMembersPanel(conversation: conversation, tribe: tribe) { showingMembers = false }
            }
        }
    }
}

/// Who is in the tribe, its link, and leaving it. Only the owner gets the
/// full list from the tribes server; everyone else sees who has posted.
struct TribeMembersPanel: View {
    @Environment(AppModel.self) private var model
    let conversation: Conversation
    let tribe: Tribe?
    let done: () -> Void

    @State private var members: TribeMembers?
    @State private var problem: String?
    @State private var confirmingLeave = false
    @State private var leaving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(members?.complete == false ? "Seen in #\(conversation.name)" : "Members")
                    .font(Theme.font(15, .bold))
                if members?.complete == false {
                    Text("Only the tribe's owner gets the full member list.")
                        .font(Theme.font(12))
                        .foregroundStyle(Theme.secondaryText)
                }
            }
            memberList
            Theme.divider.frame(height: 1)
            HStack(spacing: 8) {
                if let link = tribe?.link {
                    Button("Copy link") { Clipboard.copy(link) }
                }
                Spacer()
                leaveControl
            }
            if let problem {
                ProblemText(problem)
            }
        }
        .padding(16)
        .frame(width: 300)
        .task(id: conversation.chat) { await load() }
    }

    @ViewBuilder private var memberList: some View {
        if let members {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    // The server's list includes this account; the seen list does not.
                    if !members.complete {
                        MemberRow(alias: model.myAlias ?? "You", photoURL: nil, note: "you")
                    }
                    ForEach(members.members) { member in
                        MemberRow(alias: member.alias, photoURL: member.photoURL, note: member.pending ? "waiting for approval" : nil)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 280)
            .fixedSize(horizontal: false, vertical: true)
        } else if problem == nil {
            HStack {
                ProgressView().controlSize(.small)
                Text("Asking the tribes server…")
                    .font(Theme.font(12))
                    .foregroundStyle(Theme.secondaryText)
            }
        }
    }

    /// Leaving is confirmed right here, next to the button, not in a dialog.
    @ViewBuilder private var leaveControl: some View {
        if confirmingLeave {
            Text("Leave #\(conversation.name)?")
                .font(Theme.font(12))
                .foregroundStyle(Theme.secondaryText)
            Button("Cancel") { confirmingLeave = false }
                .disabled(leaving)
            Button {
                Task { await leave() }
            } label: {
                Text("Leave").foregroundStyle(Theme.destructive)
            }
            .disabled(leaving)
        } else {
            Button("Leave tribe") { confirmingLeave = true }
        }
    }

    private func load() async {
        do {
            members = try await model.tribeMembers(conversation.chat)
        } catch {
            problem = "Could not load members: \(error)"
        }
    }

    private func leave() async {
        leaving = true
        defer { leaving = false }
        do {
            try await model.leaveTribe(conversation.chat)
            done()
        } catch {
            problem = "Could not leave: \(error)"
            confirmingLeave = false
        }
    }
}

struct MemberRow: View {
    let alias: String
    let photoURL: String?
    let note: String?

    var body: some View {
        HStack(spacing: 9) {
            Avatar(name: alias, url: photoURL, size: 24)
            Text(alias)
                .font(Theme.font(13))
                .lineLimit(1)
            if let note {
                Text(note)
                    .font(Theme.font(12))
                    .foregroundStyle(Theme.secondaryText)
            }
        }
    }
}

struct MessageList: View {
    let messages: [Message]
    var inTribe = false

    var body: some View {
        let layout = Self.layout(messages, inTribe: inTribe)
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(zip(messages, layout)), id: \.0.id) { message, place in
                        if place.startsDay {
                            DayDivider(date: message.date)
                        }
                        Group {
                            if message.type == MessageType.text {
                                MessageRow(
                                    message: message,
                                    endsRun: place.endsRun,
                                    sender: inTribe && !message.fromMe ? (place.startsRun ? .named : .indented) : .none
                                )
                            } else {
                                MembershipNote(message: message)
                            }
                        }
                        .id(message.id)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: messages.last?.id) { _, last in
                if let last {
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last, anchor: .bottom) }
                }
            }
        }
    }

    private struct Place {
        var startsDay: Bool
        var startsRun: Bool
        var endsRun = true
    }

    /// A run is one sender's messages a few minutes apart on one day. Its
    /// last message shows the time under it (the others on hover); in a tribe
    /// its first shows the member's name and photo. Worked out in one pass,
    /// reading each member's name once.
    private static func layout(_ messages: [Message], inTribe: Bool) -> [Place] {
        var places: [Place] = []
        places.reserveCapacity(messages.count)
        var previousAlias: String?
        for (index, message) in messages.enumerated() {
            let alias = inTribe && !message.fromMe ? message.senderAlias : nil
            guard index > 0 else {
                places.append(Place(startsDay: true, startsRun: true))
                previousAlias = alias
                continue
            }
            let previous = messages[index - 1]
            let startsDay = !Calendar.current.isDate(message.date, inSameDayAs: previous.date)
            let startsRun = startsDay || message.type != MessageType.text || previous.type != MessageType.text
                || previous.fromMe != message.fromMe
                || message.date.timeIntervalSince(previous.date) > 5 * 60 || alias != previousAlias
            places[index - 1].endsRun = startsRun
            places.append(Place(startsDay: startsDay, startsRun: startsRun))
            previousAlias = alias
        }
        return places
    }
}

/// "Name joined" or "Name left", between the messages of a tribe.
struct MembershipNote: View {
    let message: Message

    private var text: String {
        let who = message.fromMe ? "You" : message.senderAlias ?? "Someone"
        return message.type == MessageType.groupLeave ? "\(who) left" : "\(who) joined"
    }

    var body: some View {
        Text(text)
            .font(Theme.font(12))
            .foregroundStyle(Theme.secondaryText)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 2)
    }
}

struct DayDivider: View {
    let date: Date

    var body: some View {
        HStack(spacing: 12) {
            Theme.divider.frame(height: 1)
            Text(Formatting.dayHeading(date))
                .font(Theme.font(12))
                .foregroundStyle(Theme.secondaryText)
                .padding(.horizontal, 10)
                .padding(.vertical, 2)
                .overlay(Capsule().strokeBorder(Theme.divider))
                .fixedSize()
            Theme.divider.frame(height: 1)
        }
        .padding(.vertical, 8)
    }
}

/// One message: theirs on the left, yours on the right. The time sits under
/// the last message of a run and appears beside any bubble on hover, without
/// moving anything. In a tribe, theirs sit beside the member's photo, with
/// the name over the first of a run.
struct MessageRow: View {
    /// The column beside a member's message in a tribe.
    enum Sender {
        case none
        /// Lined up under the run's photo.
        case indented
        /// The member's photo, and their name over the message.
        case named
    }

    let message: Message
    let endsRun: Bool
    var sender: Sender = .none

    @State private var hovering = false

    private static let avatarSize: CGFloat = 28

    var body: some View {
        // A pending send becomes retryable after a timeout, with no change to
        // the row itself, so those rows redraw once when it passes.
        if message.delivery == .pending {
            TimelineView(.explicit([message.date.addingTimeInterval(Message.confirmationTimeout + 0.5)])) { context in
                row(now: context.date)
            }
        } else {
            row(now: .now)
        }
    }

    private func row(now: Date) -> some View {
        let retryable = message.isRetryable(now: now)
        return HStack(alignment: .top, spacing: 8) {
            switch sender {
            case .none: EmptyView()
            case .indented: Color.clear.frame(width: Self.avatarSize, height: 1)
            case .named: Avatar(name: message.senderAlias ?? "?", url: message.senderPhotoURL, size: Self.avatarSize)
            }
            HStack(alignment: .center, spacing: 8) {
                if message.fromMe {
                    Spacer(minLength: 80)
                    hoverTime
                }
                VStack(alignment: message.fromMe ? .trailing : .leading, spacing: 3) {
                    if sender == .named {
                        Text(message.senderAlias ?? "Unknown")
                            .font(Theme.font(12, .medium))
                            .foregroundStyle(Theme.secondaryText)
                            .padding(.leading, 4)
                    }
                    MessageBubble(message: message)
                        .opacity(message.delivery == .pending && !retryable ? 0.6 : 1)
                    if retryable {
                        UndeliveredActions(message: message)
                    } else if endsRun {
                        MessageMeta(message: message)
                    }
                }
                if !message.fromMe {
                    hoverTime
                    Spacer(minLength: 80)
                }
            }
        }
        .padding(.bottom, endsRun ? 6 : 0)
        .onHover { hovering = $0 }
    }

    /// Always laid out, so hovering never shifts the row; only its opacity changes.
    private var hoverTime: some View {
        MessageMeta(message: message)
            .opacity(hovering && !endsRun ? 1 : 0)
            .accessibilityHidden(true)
    }
}

/// Its own view, so hovering the row does not redo link detection.
struct MessageBubble: View {
    let message: Message

    var body: some View {
        Text(LinkText.attributed(message.content ?? "", onSentBubble: message.fromMe))
            .font(Theme.font(14))
            .lineSpacing(2)
            .textSelection(.enabled)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                message.fromMe ? Theme.sentBubble : Theme.receivedBubble,
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
            .foregroundStyle(message.fromMe ? Theme.sentText : Theme.text)
            .help(message.date.formatted(date: .complete, time: .shortened))
    }
}

/// The time, and for a message of ours the server's confirmation: a green
/// bolt, as in the official apps.
struct MessageMeta: View {
    let message: Message

    var body: some View {
        HStack(spacing: 4) {
            if message.fromMe, message.delivery == .delivered {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.confirmed)
                    .help("Delivered")
            }
            Text(message.date, format: .dateTime.hour().minute())
                .monospacedDigit()
        }
        .font(Theme.font(11))
        .foregroundStyle(Theme.secondaryText)
        .fixedSize()
    }
}

/// "Not delivered" with Retry and Discard. Discard asks once, in place.
struct UndeliveredActions: View {
    @Environment(AppModel.self) private var model
    let message: Message

    @State private var confirmingDiscard = false

    var body: some View {
        HStack(spacing: 10) {
            if confirmingDiscard {
                Text("Discard this message?")
                    .foregroundStyle(Theme.secondaryText)
                Button("Discard") { Task { await model.discard(message) } }
                    .foregroundStyle(Theme.destructive)
                Button("Keep") { confirmingDiscard = false }
                    .foregroundStyle(Theme.accent)
            } else {
                Text("Not delivered")
                    .foregroundStyle(Theme.secondaryText)
                Button("Retry") { Task { await model.resend(message) } }
                    .foregroundStyle(Theme.accent)
                Button("Discard") { confirmingDiscard = true }
                    .foregroundStyle(Theme.secondaryText)
            }
        }
        .buttonStyle(.plain)
        .font(Theme.font(11, .medium))
    }
}

/// Makes web links in message text clickable. Only https links: anything
/// else stays plain text.
enum LinkText {
    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    static func attributed(_ text: String, onSentBubble: Bool) -> AttributedString {
        var result = AttributedString(text)
        guard let detector else { return result }
        let range = NSRange(text.startIndex..., in: text)
        for match in detector.matches(in: text, range: range) {
            guard let url = match.url, url.scheme?.lowercased() == "https",
                  let textRange = Range(match.range, in: text),
                  let start = AttributedString.Index(textRange.lowerBound, within: result),
                  let end = AttributedString.Index(textRange.upperBound, within: result) else { continue }
            result[start..<end].link = url
            result[start..<end].underlineStyle = .single
            // The accent blue is too faint on the sent bubble; keep the text colour there.
            result[start..<end].foregroundColor = onSentBubble ? Theme.sentText : Theme.accent
        }
        return result
    }
}

struct Composer: View {
    @Binding var draft: String
    let placeholder: String
    let focusRequest: Int
    let send: () -> Void

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @ViewBuilder private var field: some View {
        #if os(macOS)
        ComposerField(text: $draft, placeholder: placeholder, focusRequest: focusRequest, submit: send)
        #else
        TextField(placeholder, text: $draft, axis: .vertical)
            .lineLimit(1...8)
            .onSubmit(send)
        #endif
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            field
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Theme.input, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.divider))
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 28))
            }
            .buttonStyle(.plain)
            .foregroundStyle(canSend ? Theme.accent : Theme.secondaryText.opacity(0.5))
            .disabled(!canSend)
            .keyboardShortcut(.return, modifiers: .command)
            .help("Send (Return). Shift-Return for a new line.")
        }
        .padding(.horizontal, 20)
        .padding(.top, 6)
        .padding(.bottom, 16)
    }
}
