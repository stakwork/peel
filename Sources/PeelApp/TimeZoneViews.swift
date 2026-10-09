import SwiftUI
import PeelCore

// Time zones in the app (`docs/design/README.md`, "Time zones", boards T1,
// T2, T3a and T6; Account's group, T4, is in `AccountView`). Shown quietly:
// their local time once per run, in the DM header, on hover; never a second
// timestamp on every message, and nothing at all when it is not known.

extension Formatting {
    /// A time of day in `zone`, in the user's format.
    static func time(_ date: Date, in zone: TimeZone) -> String {
        var style = Date.FormatStyle.dateTime.hour().minute()
        style.timeZone = zone
        return date.formatted(style)
    }

    /// "6 h ahead", "6 h 30 min behind", "30 min ahead"; nil when the same.
    static func offset(_ seconds: Int) -> String? {
        let minutes = abs(seconds) / 60
        guard minutes > 0 else { return nil }
        let (hours, rest) = (minutes / 60, minutes % 60)
        let amount = [hours > 0 ? "\(hours) h" : nil, rest > 0 ? "\(rest) min" : nil].compactMap { $0 }.joined(separator: " ")
        return "\(amount) \(seconds > 0 ? "ahead" : "behind")"
    }
}

// MARK: - The run header's local time (T3a)

/// "· 14:05 local" after a run's time, in tertiary grey: the sender's time
/// when they wrote, only when their offset was not yours. The words and the
/// offset are in the tooltip and the accessibility label.
struct RunLocalTime: View {
    let date: Date
    let zone: TimeZone
    let name: String

    var body: some View {
        let time = Formatting.time(date, in: zone)
        Text("· \(time) local")
            .font(Theme.font(12))
            .monospacedDigit()
            .foregroundStyle(Theme.tertiaryText)
            .lineLimit(1)
            .fixedSize()
            .help("\(time) local time for \(name) · \(TimeZoneOffset.format(zone, at: date))")
            .accessibilityLabel("\(time) local time for \(name)")
    }
}

// MARK: - The hover card (T2)

/// Who a hover card is about: a contact (the chat's key) or a tribe member.
struct PersonRef: Hashable {
    let chat: String
    /// A tribe member's alias; nil for a contact.
    let alias: String?
    let name: String
    let photoURL: String?
    let hue: PersonHue

    /// From a row: someone else's message, in a DM or by a named member.
    init?(_ row: ChatRow) {
        guard !row.message.fromMe, !row.inTribe || row.member != nil else { return nil }
        alias = row.member
        chat = row.message.chat
        name = row.sender.name
        photoURL = row.sender.photoURL
        hue = row.sender.hue
    }
}

extension View {
    /// The person's hover card over this view, when there is someone to show.
    @ViewBuilder func personCard(_ person: PersonRef?) -> some View {
        if let person {
            peelHoverCard(person) { PersonCard(person: person) }
        } else {
            self
        }
    }
}

/// Photo, name (and a contact's short key), then their local time and how
/// far ahead or behind, with the offset they sent and when. No time line
/// when they have not shared one.
struct PersonCard: View {
    @Environment(AppModel.self) private var model
    let person: PersonRef

    @State private var local: LocalTime?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Avatar(name: person.name, url: person.photoURL, size: 48, hue: person.hue)
                VStack(alignment: .leading, spacing: 2) {
                    Text(person.name)
                        .font(Theme.font(15, .bold))
                        .lineLimit(1)
                    if person.alias == nil {
                        Text(Formatting.shortKey(person.chat))
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(Theme.secondaryText)
                    }
                }
            }
            .padding(14)
            if let local {
                Theme.divider.frame(height: 1).padding(.horizontal, 14)
                TimelineView(.everyMinute) { context in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: "clock")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.secondaryText)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            let time = Text(Formatting.time(context.date, in: local.zone)).bold()
                            let offset = Formatting.offset(model.difference(local.zone, at: context.date))
                            Text("\(time) local time · \(offset ?? "same as yours")")
                                .font(Theme.font(13.5))
                            Text("\(local.sent) · sent \(Formatting.relative(local.seen, now: context.date))")
                                .font(Theme.font(12))
                                .foregroundStyle(Theme.secondaryText)
                        }
                        .monospacedDigit()
                    }
                    .padding(14)
                }
            }
        }
        .frame(width: 280, alignment: .leading)
        .task { local = await model.localTime(of: person.chat, member: person.alias) }
    }
}

// MARK: - The DM header (T1)

/// A direct message's header: under the name, "02:14 local time · 6 h
/// ahead" while their offset is not yours, moving on with the minute; and
/// the chat's details.
struct DirectHeader: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    let conversation: Conversation

    @State private var local: LocalTime?
    @State private var showingInfo = false

    var body: some View {
        TimelineView(.everyMinute) { context in
            DetailHeader(title: conversation.name, subtitle: model.localTimeLine(local, at: context.date)) {
                ConversationIcon(conversation: conversation, size: 32)
            } trailing: {
                HStack(spacing: 4) {
                    SearchHeaderButton(chat: conversation.chat)
                    CallHeaderButton(chat: conversation.chat)
                    HeaderMoreButton(chat: conversation.chat, details: { showingInfo = true }) {
                        .sections(
                            WebMenuEntries.entries(for: nil, pane: model.web, open: openURL),
                            [HeaderMoreButton.details { showingInfo = true },
                             ConversationMenu.notifications(for: conversation, model: model)]
                        )
                    }
                    .peelPopover(isPresented: $showingInfo) {
                        ChatInfoPanel(conversation: conversation, tribe: nil)
                    }
                }
            }
        }
        // Details opened for one contact never open over the next.
        .onChange(of: conversation.chat) { showingInfo = false }
        // Asked again when a message of theirs brings an offset.
        .task(id: model.timeline.messages.last { !$0.fromMe && $0.senderTZ != nil }?.id) {
            local = await model.localTime(of: conversation.chat, member: nil)
        }
    }
}

// MARK: - The per-chat switch (T6)

/// A chat's details: who or what it is, and whether your time zone goes
/// with what you send there. A public tribe has no switch: it never gets it.
/// A contact's also show since when, their full key with its QR code, and
/// Remove, confirmed in place.
struct ChatInfoPanel: View {
    @Environment(AppModel.self) private var model
    let conversation: Conversation
    let tribe: Tribe?

    /// A contact's local time.
    @State private var local: LocalTime?
    @State private var sharing: Bool?
    @State private var offset: String?
    @State private var chatZone: String?
    @State private var problem: String?
    /// A contact's oldest message here: since when they are a contact.
    @State private var since: Date?
    @State private var removeProblem: String?

    private var isPublicTribe: Bool { conversation.isTribe && tribe?.isPrivate != true }
    private var target: String { conversation.title }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(spacing: 6) {
                ConversationIcon(conversation: conversation, size: conversation.isTribe ? 56 : 64)
                Text(conversation.name)
                    .font(Theme.font(16, .bold))
                    .lineLimit(1)
                if conversation.isTribe {
                    Text(tribe?.isPrivate == true ? "Private tribe" : "Public tribe")
                        .font(Theme.font(12))
                        .foregroundStyle(Theme.secondaryText)
                } else {
                    if let since {
                        Text("Contact since \(since.formatted(.dateTime.day().month(.wide).year()))")
                            .font(Theme.font(12))
                            .foregroundStyle(Theme.secondaryText)
                    }
                    TimelineView(.everyMinute) { context in
                        if let line = model.localTimeLine(local, at: context.date) {
                            Text(line)
                                .font(Theme.font(12))
                                .monospacedDigit()
                                .foregroundStyle(Theme.secondaryText)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)
            if !conversation.isTribe {
                ContactKeyCard(pubkey: conversation.chat)
            }
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("Time zone")
                if isPublicTribe {
                    Text("Your time zone is never sent in public tribes.")
                        .font(Theme.font(13))
                    note("You still see the local time of members who share theirs.")
                } else if let sharing {
                    Toggle(isOn: Binding(get: { sharing }, set: { on in Task { await set(on) } })) {
                        Text("Share my time zone with \(target)")
                            .font(Theme.font(13))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .tint(Theme.accent)
                    note(sharingNote(sharing))
                    if let chatZone {
                        note("Uses \(chatZone), set on another device.")
                    }
                    if let problem {
                        ProblemText(problem)
                    }
                }
            }
            if !conversation.isTribe {
                VStack(alignment: .leading, spacing: 8) {
                    FormDestructiveSection(
                        trigger: "Remove contact…", explanation: removeExplanation, confirm: "Remove"
                    ) { await remove() }
                    if let removeProblem {
                        ProblemText(removeProblem)
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 300)
        .task(id: conversation.chat) { await load() }
    }

    /// What Remove deletes, and what it leaves, in plain words.
    private var removeExplanation: String {
        let name = conversation.name
        let call = model.call?.chat == conversation.chat ? " Your call here ends." : ""
        return "Deletes your chat with \(name) from this Mac and from your server: messages, files and requests. "
            + "Payment history stays. \(name) is not told and keeps their copy; you can add each other again.\(call)"
    }

    private func remove() async {
        removeProblem = nil
        do {
            try await model.deleteContact(conversation.chat)
        } catch {
            removeProblem = Formatting.sentence(error)
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(Theme.font(12))
            .monospacedDigit()
            .foregroundStyle(Theme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func sharingNote(_ on: Bool) -> String {
        let offset = offset.map { "your offset, \($0)," } ?? "your offset"
        let tribe = conversation.isTribe
        let keeps = tribe ? "members keep" : "\(conversation.name) keeps"
        guard on else {
            return "Off: messages you send here carry no offset. \(tribe ? "Members keep" : keeps) any you sent before."
        }
        let audience = tribe ? ", to every member and the tribe's server" : ""
        return "Sends \(offset) with each message you send here\(audience). Turning it off stops sending; \(keeps) the last one you sent."
    }

    private func load() async {
        guard let engine = model.engine else { return }
        let chat = conversation.chat
        sharing = (try? await engine.timeZoneSharing(in: chat)) ?? true
        offset = (try? await engine.timeZone(for: chat)).map { TimeZoneOffset.format($0) }
        chatZone = try? engine.storage.chatTimeZone(chat)?.identifier
        if !conversation.isTribe {
            since = (try? engine.storage.firstMessageTime(in: chat)).flatMap { $0 }.map(Date.init(millisecondsSince1970:))
            local = await model.localTime(of: chat, member: nil)
        }
    }

    private func set(_ on: Bool) async {
        let was = sharing
        sharing = on
        problem = nil
        do {
            try await model.signedIn().setTimeZoneSharing(on, in: conversation.chat)
        } catch {
            sharing = was
            problem = "Could not change it: \(PeelError.readable(error))"
        }
    }
}


/// A contact's full public key, which names them everywhere: its QR code,
/// the key itself (selectable), and copying either.
private struct ContactKeyCard: View {
    let pubkey: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                QRCodeTile(text: pubkey, label: "QR code of their public key", size: 92, inset: 6)
                VStack(alignment: .leading, spacing: 4) {
                    SectionLabel("Public key")
                    Text(pubkey)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.text)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 8) {
                CopyButton("Copy key", text: pubkey)
                CopyButton("Copy QR", systemImage: "qrcode") { QRCode.copyImage(pubkey) }
            }
            .buttonStyle(FormButtonStyle())
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .formCard()
    }
}
