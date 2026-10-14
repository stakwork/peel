import PeelCore
import PeelUI
import PhotosUI
import SwiftUI

// A chat's details on the phone (`ChatsRoute.details`, opened by
// `PhoneRouter.openDetails` from the conversation's More), as the Mac's
// `ChatInfoPanel` and `TribeDetailsPanel` hold them, and a tribe's members
// as its `TribeMembersPanel`. Pushed over the conversation; Back returns
// to it.

/// A contact's details or a tribe's, by what the chat is.
struct ChatDetailsScreen: View {
    @Environment(AppModel.self) private var model
    let chat: String

    var body: some View {
        let conversation = model.conversations.first { $0.chat == chat }
        Group {
            if let conversation {
                if !conversation.isTribe {
                    ContactDetailsView(conversation: conversation)
                } else if let tribe = model.tribes[chat] {
                    TribeDetailsView(conversation: conversation, tribe: tribe)
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                // Removed meanwhile; the router takes it off the stack.
                Color.clear
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle(conversation?.isTribe == true ? "Tribe details" : "Details")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// The top of a details screen: the picture at 64 pt, the name, and the
/// lines under it, centred.
private struct DetailsHero<Picture: View, Lines: View>: View {
    let name: String
    @ViewBuilder let picture: Picture
    @ViewBuilder let lines: Lines

    var body: some View {
        VStack(spacing: Theme.Space.sm) {
            picture.accessibilityHidden(true)
            Text(name)
                .phoneFont(.title)
                .foregroundStyle(Theme.text)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 2) { lines }
                .phoneFont(.secondary)
                .foregroundStyle(Theme.tertiaryText)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - A contact

/// A contact: photo, name, since when and their local time; their key with
/// its QR code to copy or share; the time zone switch; and Remove contact,
/// confirmed in place with what it deletes.
private struct ContactDetailsView: View {
    @Environment(AppModel.self) private var model
    let conversation: Conversation

    @State private var local: LocalTime?
    @State private var since: Date?
    @State private var problem: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                DetailsHero(name: conversation.name) {
                    ConversationIcon(conversation: conversation, size: 64)
                } lines: {
                    if let since { Text("Contact since \(Formatting.date(since))") }
                    TimelineView(.everyMinute) { context in
                        if let line = model.localTimeLine(local, at: context.date) {
                            Text(line).monospacedDigit()
                        }
                    }
                }
                VStack(alignment: .leading, spacing: Theme.Space.md) {
                    PhoneSectionHeader("Public key")
                    ShareableCode(text: conversation.chat, label: "QR code of their public key",
                                  copyTitle: "Copy key", showsText: true)
                }
                TimeZoneSwitch(conversation: conversation, tribe: nil)
                VStack(alignment: .leading, spacing: Theme.Space.sm) {
                    ConfirmInPlace(
                        trigger: "Remove contact", explanation: "Remove \(conversation.name) and delete your chat?",
                        confirm: "Remove"
                    ) { await remove() }
                    if let problem { ProblemText(problem) }
                }
            }
            .padding(.horizontal, Theme.phoneGutter)
            .padding(.vertical, Theme.Space.lg)
        }
        .task(id: conversation.chat) {
            since = model.contactSince(conversation.chat)
            local = await model.localTime(of: conversation.chat, member: nil)
        }
    }

    /// Gone from the model, the router goes back to Chats (`follow`).
    private func remove() async {
        problem = nil
        do {
            try await model.deleteContact(conversation.chat, movesSelection: false)
        } catch {
            problem = PeelError.problem(error)
        }
    }
}

// MARK: - A tribe

/// A tribe: its image, name, kind and age, what it is about and its tags;
/// owner, members, prices and escrow; its link with a QR code; how you
/// appear in it; the time zone switch; for its owner Edit tribe; and Leave
/// (or Remove from Peel), confirmed in place. What only the registry knows
/// arrives when the tribes server answers.
private struct TribeDetailsView: View {
    @Environment(AppModel.self) private var model
    @Environment(PhoneRouter.self) private var router
    let conversation: Conversation
    let tribe: Tribe

    @State private var details: TribeDetails?
    @State private var problem: String?
    @State private var editing = false

    private var info: TribeInfo? { details?.info }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                hero
                facts
                if let link = tribe.link {
                    VStack(alignment: .leading, spacing: Theme.Space.md) {
                        PhoneSectionHeader("Tribe link")
                        ShareableCode(text: link, label: "QR code of the tribe link", copyTitle: "Copy link")
                    }
                }
                if tribe.canPost {
                    TribeIdentity(tribe: tribe)
                }
                TimeZoneSwitch(conversation: conversation, tribe: tribe)
                actions
            }
            .padding(.horizontal, Theme.phoneGutter)
            .padding(.vertical, Theme.Space.lg)
        }
        .sheet(isPresented: $editing) {
            SheetStack { TribeSettingsSheet(editing: tribe) }
        }
        .task(id: tribe.pubkey) { await load() }
        // The count is the model's (`knownMembers`), which the members
        // screen also keeps fresh; read at most once at a time.
        .task(id: tribe.pubkey) { await model.loadKnownMembers(tribe.pubkey) }
    }

    private var hero: some View {
        VStack(spacing: Theme.Space.md) {
            DetailsHero(name: tribe.displayName) {
                TribeIcon(name: tribe.displayName, url: tribe.photoURL, pubkey: tribe.pubkey, size: 64)
            } lines: {
                Text(tribe.detailsSubtitle(created: info?.created))
            }
            if let summary = (info?.summary ?? tribe.summary)?.trimmed.nilIfEmpty {
                Text(summary)
                    .phoneFont(.row)
                    .foregroundStyle(Theme.text)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let tags = info?.settings.tags, !tags.isEmpty {
                ChipFlow(spacing: 6) {
                    ForEach(tags.prefix(16), id: \.self) { tag in
                        Text(tag)
                            .phoneFont(.secondary)
                            .foregroundStyle(Theme.text)
                            .lineLimit(1)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .overlay(Capsule().strokeBorder(Theme.inputBorder))
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Tags: \(tags.joined(separator: ", "))")
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var facts: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            PhoneCard {
                VStack(alignment: .leading, spacing: Theme.Space.md) {
                    FactRow("Owner") { owner }
                    FactRow("To join") { known(info?.joinPrice.described) }
                    FactRow("Each message", tribe.messagePrice.described)
                    FactRow("Escrow", tribe.escrowLine(millis: info?.escrowMillis))
                }
                .padding(Theme.Space.md)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // Without its count until the list is read, or when it cannot
            // be: the members screen says why.
            let list = model.knownMembers[tribe.pubkey]
            PhoneCard {
                    Button { router.openMembers(tribe.pubkey) } label: {
                        HStack(spacing: Theme.Space.md) {
                            Image(systemName: "person.2")
                                .frame(width: 30)
                                .accessibilityHidden(true)
                            Text(list?.complete == false ? "Seen here" : "Members").phoneFont(.row)
                            Spacer(minLength: Theme.Space.sm)
                            Text(list?.countLabel ?? "")
                                .phoneFont(.row)
                                .monospacedDigit()
                                .foregroundStyle(Theme.secondaryText)
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(Theme.tertiaryText)
                                .accessibilityHidden(true)
                        }
                        .foregroundStyle(Theme.text)
                        .padding(.horizontal, Theme.Space.md)
                        .frame(minHeight: Theme.touchTarget)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
            }
            if let problem { ProblemText(problem) }
        }
    }

    @ViewBuilder private var owner: some View {
        if tribe.isOwner {
            let me = model.me(in: tribe.pubkey)
            HStack(spacing: 6) {
                Avatar(name: me.avatarName, url: me.photoURL, size: 20, hue: me.hue)
                Text("You")
            }
        } else if let alias = info?.ownerAlias?.nilIfEmpty {
            HStack(spacing: 6) {
                Avatar(name: alias, url: details?.ownerPhotoURL, size: 20,
                       hue: model.hue(pubkey: tribe.pubkey, alias: alias, inTribe: true))
                Text(alias).lineLimit(1)
            }
        } else {
            known(info == nil ? nil : "Not given")
        }
    }

    /// A value the registry gives: a dash until it answers.
    private func known(_ text: String?) -> some View {
        Text(text ?? "—").foregroundStyle(text == nil ? Theme.tertiaryText : Theme.text)
    }

    /// Edit tribe for its owner, then Leave or Remove from Peel, the one
    /// destructive action, last.
    private var actions: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            if tribe.canManage {
                Button { editing = true } label: {
                    Label("Edit tribe", systemImage: "slider.horizontal.3").frame(maxWidth: .infinity)
                }
                .buttonStyle(.peel(.outline, size: .touch))
            }
            if let exit = tribe.exit {
                ConfirmInPlace(trigger: exit.title, confirm: exit.confirm(conversation.name)) {
                    // Gone, the router goes back to Chats; a failure shows below.
                    await model.leave(tribe.pubkey)
                }
            }
            if let notice = model.conversationNotices[tribe.pubkey] {
                ProblemText(notice)
            }
        }
    }

    private func load() async {
        // A tribe found in history on another tribes server has no registry to ask.
        guard tribe.host != nil else { return }
        do {
            details = try await model.tribeDetails(tribe.pubkey)
            problem = nil
        } catch {
            problem = PeelError.problem(error, couldNot: "load tribe details")
        }
    }
}

/// "How you appear in #tribe": a name and a photo sent with your messages
/// there in place of your account's (`TribeIdentityDraft`, the Mac's
/// too). The photo is picked, never typed; Save sends neither until it is
/// tapped.
private struct TribeIdentity: View {
    @Environment(AppModel.self) private var model
    let tribe: Tribe

    @State private var draft = TribeIdentityDraft()
    @State private var photo: PhotosPickerItem?
    @State private var loaded = false

    private var accountName: String { model.myAlias?.nilIfEmpty ?? "you" }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            PhoneSectionHeader("How you appear in #\(tribe.displayName)")
            HStack(spacing: Theme.Space.md) {
                Avatar(name: draft.alias.trimmed.nilIfEmpty ?? accountName, url: draft.photoURL ?? model.myPhotoURL,
                       size: 56, hue: model.myHue)
                    .accessibilityHidden(true)
                PhotosPicker(selection: $photo, matching: .images) {
                    Text(draft.uploading ? "Uploading…" : "Photo")
                }
                .buttonStyle(.peel(.outline, size: .touch))
                .disabled(draft.uploading)
                .accessibilityLabel("Choose your photo for this tribe")
                if draft.photoURL != nil {
                    Button("Use mine") { draft.photoURL = nil }
                        .buttonStyle(.peel(.ghost, size: .touch))
                        .accessibilityHint("Uses your account's photo here")
                }
            }
            FieldLabel("Name") {
                NoteInput(label: "Name", prompt: accountName, text: Bindable(draft).alias)
                if let note = draft.problem ?? draft.note {
                    ProblemText(note)
                }
            }
            if draft.changed(from: tribe) {
                HStack(spacing: Theme.Space.md) {
                    Button { draft.reset(to: tribe) } label: { Text("Revert").frame(maxWidth: .infinity) }
                        .buttonStyle(.peel(.ghost, size: .touch))
                        .disabled(draft.saving)
                    Button { Task { await draft.save(in: tribe, with: model) } } label: {
                        Text("Save").frame(maxWidth: .infinity).buttonProgress(draft.saving)
                    }
                    .buttonStyle(.peel(.primary, size: .touch))
                    .disabled(draft.uploading)
                }
            }
        }
        // What the tribe has, once, and again when it changes (a save): not
        // on coming back from Members, which would drop what is typed.
        .onAppear {
            guard !loaded else { return }
            loaded = true
            draft.reset(to: tribe)
        }
        .onChange(of: [tribe.myAlias, tribe.myPhotoURL]) { draft.reset(to: tribe) }
        .onChange(of: photo) { _, item in
            guard let item else { return }
            photo = nil
            Task { await draft.upload { try await model.uploadPicture(item) } }
        }
    }
}

/// Whether your time zone goes with what you send here, under a "Time
/// zone" heading (`TimeZoneSharingSwitch`, the Mac's too). Nothing in a
/// public tribe: it never gets it.
private struct TimeZoneSwitch: View {
    @Environment(AppModel.self) private var model
    let conversation: Conversation
    let tribe: Tribe?

    @State private var zone = TimeZoneSharingSwitch()

    var body: some View {
        if conversation.offersTimeZoneSwitch(tribe: tribe) {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                PhoneSectionHeader("Time zone")
                if let sharing = zone.sharing {
                    SwitchRow(label: "Share my time zone with \(conversation.title)",
                              isOn: Binding { sharing } set: { on in
                                  Task { await zone.set(on, in: conversation.chat, with: model) }
                              })
                    if let problem = zone.problem { ProblemText(problem) }
                }
            }
            .task(id: conversation.chat) { await zone.load(conversation.chat, with: model) }
        }
    }
}

// MARK: - Members

/// Who is in a tribe. Only the owner gets the full list from the tribes
/// server, with requests to join first (Approve, Decline) and Remove on
/// each member (swipe, then confirm in place); everyone else sees who has
/// posted, and themself.
struct TribeMembersScreen: View {
    @Environment(AppModel.self) private var model
    let chat: String

    @State private var members: TribeMembers?
    @State private var problem: String?
    /// The member whose Remove is waiting for its confirm.
    @State private var removing: TribeMember.ID?
    @State private var kicking = false
    /// Requests answered here, until the list read again drops them.
    @State private var answering: Set<TribeMember.ID> = []

    private var tribe: Tribe? { model.tribes[chat] }
    private var name: String { model.conversations.first { $0.chat == chat }?.name ?? tribe?.displayName ?? "" }

    var body: some View {
        List {
            if let problem {
                Section { ProblemText(problem) }.phoneRows()
            }
            if let members {
                let pending = members.members.filter(\.pending)
                let confirmed = members.members.filter { !$0.pending }
                let canManage = tribe?.canManage == true
                if !pending.isEmpty {
                    Section {
                        PhoneSectionHeader("Waiting for approval").listRowSeparator(.hidden)
                        ForEach(pending) { member in
                            MemberRow(alias: member.alias, photoURL: member.photoURL, hue: model.hue(of: member)) {
                                if canManage { requestButtons(member) }
                            }
                        }
                    }
                    .phoneRows()
                }
                Section {
                    if !pending.isEmpty {
                        PhoneSectionHeader(members.complete ? "Members" : "Seen here").listRowSeparator(.hidden)
                    }
                    // The server's list includes this account; the seen list does not.
                    if !members.complete {
                        let me = model.me(in: chat)
                        MemberRow(alias: me.name, photoURL: me.photoURL, hue: me.hue, note: "you") { EmptyView() }
                    }
                    ForEach(confirmed) { member in
                        memberRow(member, canManage: canManage)
                    }
                }
                .phoneRows()
            }
        }
        .phoneList()
        .scrollEdges()
        .overlay {
            if members == nil, problem == nil { ProgressView() }
        }
        .refreshable { await load() }
        .navigationTitle(members?.complete == false ? "Seen in #\(name)" : "Members")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: chat) { await load() }
    }

    @ViewBuilder private func memberRow(_ member: TribeMember, canManage: Bool) -> some View {
        let isMe = member.pubkey != nil && member.pubkey == model.myPubkey
        let removable = canManage && !isMe && member.pubkey != nil
        VStack(alignment: .leading, spacing: 0) {
            MemberRow(alias: member.alias, photoURL: member.photoURL, hue: model.hue(of: member),
                      note: isMe ? "you, owner" : nil) { EmptyView() }
            if removing == member.id, let pubkey = member.pubkey {
                ConfirmPair(confirm: "Remove \(member.alias)", working: kicking,
                            cancel: { removing = nil }, run: { Task { await kick(pubkey) } })
                    .padding(.bottom, Theme.Space.sm)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if removable {
                Button("Remove", systemImage: "person.badge.minus") { removing = member.id }
                    .tint(Theme.destructive)
            }
        }
        .accessibilityActions {
            if removable {
                Button("Remove from tribe") { removing = member.id }
            }
        }
    }

    private func requestButtons(_ member: TribeMember) -> some View {
        HStack(spacing: Theme.Space.sm) {
            if answering.contains(member.id) {
                ProgressView()
            } else {
                Button("Decline") { Task { await answer(member, approve: false) } }
                    .buttonStyle(.peel(.ghost, size: .touch))
                Button("Approve") { Task { await answer(member, approve: true) } }
                    .buttonStyle(.peel(.primary, size: .touch))
            }
        }
        .fixedSize()
    }

    private func load() async {
        do {
            members = try await model.tribeMembers(chat)
            problem = nil
        } catch {
            problem = PeelError.problem(error, couldNot: "load the members")
        }
    }

    /// Each answer costs the tribe's price, so it goes once: the buttons
    /// stay off until the list read again drops the request.
    private func answer(_ member: TribeMember, approve: Bool) async {
        guard let pubkey = member.pubkey, answering.insert(member.id).inserted else { return }
        problem = nil
        do {
            try await model.answerJoinRequest(in: chat, .member(pubkey: pubkey, alias: member.alias), approve: approve)
            await load()
        } catch {
            problem = PeelError.problem(error, couldNot: approve ? "approve" : "decline")
            answering.remove(member.id)
        }
    }

    private func kick(_ pubkey: String) async {
        guard !kicking else { return }
        kicking = true
        defer { kicking = false }
        problem = nil
        do {
            try await model.kick(pubkey, from: chat)
            removing = nil
            await load()
        } catch {
            problem = PeelError.problem(error, couldNot: "remove the member")
        }
    }
}

/// One member: their photo, their name in their colour, a note ("you"),
/// and what can be done with them.
private struct MemberRow<Actions: View>: View {
    let alias: String
    let photoURL: String?
    let hue: PersonHue
    var note: String?
    @ViewBuilder let actions: Actions

    var body: some View {
        HStack(spacing: Theme.Space.md) {
            Avatar(name: alias, url: photoURL, size: 30, hue: hue)
                .accessibilityHidden(true)
            HStack(spacing: Theme.Space.sm) {
                Text(alias)
                    .phoneFont(.row)
                    .foregroundStyle(hue.name)
                    .lineLimit(1)
                if let note {
                    Text(note)
                        .phoneFont(.secondary)
                        .foregroundStyle(Theme.tertiaryText)
                }
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: Theme.Space.sm)
            actions
        }
        .padding(.vertical, 7)
        .frame(minHeight: Theme.touchTarget)
    }
}
