import SwiftUI
import PeelCore
import PeelUI

/// A tribe's details (the header's Tribe details, ⌘I, or a click on its
/// name): what it is, who owns it, what it costs, its link with a QR, its
/// app and second brain, for its owner its Jamie, how you appear in it,
/// and the time zone switch.
/// What only the registry knows (owner, created, price to join, tags)
/// arrives when the tribes server answers, the member count with the
/// Members panel's list (`TribeMembers.countLabel`); the rest is stored.
struct TribeDetailsPanel: View {
    @Environment(AppModel.self) private var model
    let conversation: Conversation
    let tribe: Tribe
    let done: () -> Void

    /// Members and Edit tribe… open below their buttons.
    @State private var showsMembers = false
    @State private var showsEdit = false

    @State private var details: TribeDetails?
    @State private var problem: String?
    /// Who is in it, as the Members panel lists them; the row goes when
    /// they cannot be read.
    @State private var memberList: Result<TribeMembers, any Error>?

    private var info: TribeInfo? { details?.info }

    var body: some View {
        DockedPanel(title: String(localized: "Tribe details"), close: done) {
            hero
            facts
            if !tribe.pages.isEmpty {
                pages
            }
            if let link = tribe.link {
                share(link)
            }
            if model.offersJamie(in: tribe) {
                TribeJamieSection(tribe: tribe)
                    .padding(.top, 18)
            }
            if !model.stadeum.live.isEmpty {
                TribeCallOrgSection(tribe: tribe)
                    .padding(.top, 18)
            }
            if tribe.canPost {
                TribeIdentitySection(tribe: tribe)
                    .padding(.top, 18)
            }
            ChatTimeZoneSection(conversation: conversation, tribe: tribe)
                .padding(.top, 18)
        } footer: {
            footer
        }
        .task(id: tribe.pubkey) { await load() }
        .task(id: tribe.pubkey) {
            do {
                memberList = .success(try await model.tribeMembers(tribe.pubkey))
            } catch {
                memberList = .failure(error)
            }
        }
    }

    // MARK: Parts

    private var hero: some View {
        VStack(alignment: .leading, spacing: 10) {
            PanelHero(name: tribe.displayName) {
                TribeIcon(name: tribe.displayName, url: tribe.photoURL, pubkey: tribe.pubkey, size: Theme.AvatarSize.xl)
            } lines: {
                Text(subtitle)
            }
            if let summary = (info?.summary ?? tribe.summary)?.trimmed.nilIfEmpty {
                Text(summary)
                    .font(Theme.font(13))
                    .foregroundStyle(Theme.text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let tags = info?.settings.tags, !tags.isEmpty {
                TagChips(tags: tags)
            }
        }
    }

    /// "Public tribe · Created 3 Oct 2026".
    private var subtitle: String { tribe.detailsSubtitle(created: info?.created) }

    @ViewBuilder private var facts: some View {
        FactList {
            Fact(String(localized: "Owner")) { owner }
            switch memberList {
            case nil: Fact(String(localized: "Members")) { known(nil) }
            case .success(let members): Fact(String(localized: "Members")) { Text(members.countLabel) }
            case .failure: EmptyView()
            }
            Fact(String(localized: "To join")) { known(info?.joinPrice.described) }
            Fact(String(localized: "Each message")) { Text(tribe.messagePrice.described) }
            Fact(String(localized: "Escrow")) { Text(tribe.escrowLine(millis: info?.escrowMillis)) }
        }
        .monospacedDigit()
        .padding(.top, 14)
        if let problem {
            ProblemText(problem).padding(.top, 6)
        }
    }

    @ViewBuilder private var owner: some View {
        if tribe.isOwner {
            let me = model.me(in: tribe.pubkey)
            HStack(spacing: 6) {
                Avatar(name: me.avatarName, url: me.photoURL, size: Theme.AvatarSize.sm, hue: me.hue)
                Text("You")
            }
        } else if let alias = info?.ownerAlias?.nilIfEmpty {
            HStack(spacing: 6) {
                Avatar(name: alias, url: details?.ownerPhotoURL, size: Theme.AvatarSize.sm,
                       hue: model.hue(pubkey: tribe.pubkey, alias: alias, inTribe: true))
                Text(alias).lineLimit(1)
            }
        } else {
            known(info == nil ? nil : String(localized: "Not given"))
        }
    }

    /// A value the registry gives: a dash until it answers.
    private func known(_ text: String?) -> some View {
        Text(text ?? "—").foregroundStyle(text == nil ? Theme.tertiaryText : Theme.text)
    }

    /// The tribe's pages (`Tribe.pages`, in the More menu's order), opened
    /// in the web pane beside the chat.
    private var pages: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Theme.Space.sm) { pageButtons }
            VStack(alignment: .leading, spacing: Theme.Space.sm) { pageButtons }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 14)
    }

    @ViewBuilder private var pageButtons: some View {
        ForEach(tribe.pages, id: \.kind) { page in
            Button {
                done()
                model.web.open(page)
            } label: {
                Label(page.title, systemImage: page.systemImage)
                    .lineLimit(1)
            }
            .buttonStyle(.peel(.outline))
            .help("Opens beside the chat")
        }
    }

    private func share(_ link: String) -> some View {
        Card {
            // Side by side while they fit, the buttons under the code when not.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 14) {
                    QRCodeTile(text: link, label: String(localized: "QR code of the tribe link"), size: 112)
                    shareButtons(link)
                    Spacer(minLength: 0)
                }
                VStack(alignment: .leading, spacing: 14) {
                    QRCodeTile(text: link, label: String(localized: "QR code of the tribe link"), size: 112)
                    shareButtons(link)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Space.md)
        }
        .padding(.top, 14)
    }

    private func shareButtons(_ link: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            CopyButton("Copy link", text: link, systemImage: "link")
            CopyButton("Copy QR image", systemImage: "qrcode") { QRCode.copyImage(link) }
        }
        .buttonStyle(.peel(.outline))
    }

    /// Where to go on the left; Leave, the one destructive action, on the right.
    private var footer: some View {
        HStack(spacing: Theme.Space.sm) {
            Button("Members") { showsMembers = true }
                .buttonStyle(.peel(.outline))
                .peelPopover(isPresented: $showsMembers) {
                    TribeMembersPanel(conversation: conversation, tribe: tribe) { showsMembers = false }
                }
            if tribe.canManage {
                Button("Edit tribe…") { showsEdit = true }
                    .buttonStyle(.peel(.outline))
                    .peelPopover(isPresented: $showsEdit) {
                        TribeSettingsForm(editing: tribe) { showsEdit = false }
                    }
            }
            Spacer()
            if let exit = tribe.exit {
                InlineConfirm(trigger: exit.title, confirm: exit.confirm(conversation.name)) {
                    await model.leave(tribe.pubkey)
                    done()
                }
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
            problem = PeelError.problem(error, couldNot: String(localized: "load tribe details"))
        }
    }
}

/// "Jamie", for the tribe's owner (docs/hive-tribes.md): which of your
/// Stadeum orgs or linked boxes answers `@jamie` here: one of them or No
/// Jamie, as Hive and each box have it (`TribeJamiePicker`), and with no
/// Jamie yet the org or box the tribe's app or second brain is on, in one
/// click; once Jamie is in, whether it knows who is speaking (the members
/// list's word, and your switch). Unpaired, Connect Stadeum pairs this Mac
/// from here, unless a box already offers Jamie.
private struct TribeJamieSection: View {
    @Environment(AppModel.self) private var model
    let tribe: Tribe

    @State private var picker = TribeJamiePicker()

    var body: some View {
        let stadeum = model.stadeum
        let connected = stadeum.status == .connected
        let choices = model.jamieChoices
        FormSection("Jamie") {
            if choices.offers(in: tribe.pubkey) {
                answersFrom(choices)
            }
            switch stadeum.status {
            case .connected, .off where choices.offersBoxes(in: tribe.pubkey):
                EmptyView()
            case .off, .needsPairing:
                FormItem(label: "Hive", helper: model.brain == .thisMac
                         ? String(localized: "Connect Hive to let one of your workspaces answer @jamie here.")
                         : String(localized: "Your assistant runs on your home server. Turn off Always on to connect Hive."),
                         problem: stadeum.problem) {
                    if model.brain == .thisMac {
                        Button(stadeum.status == .off ? String(localized: "Connect Hive") : String(localized: "Connect again")) { model.connectHive() }
                            .buttonStyle(.peel(.outline))
                    }
                }
            case .pairing(let pairing):
                FormItem(label: String(localized: "Pair this Mac")) {
                    HStack(alignment: .top) {
                        StadeumPairingCode(pairing: pairing)
                        Spacer(minLength: 0)
                        Button("Cancel") { model.cancelHivePairing() }
                            .buttonStyle(.peel(.ghost))
                    }
                }
            }
        }
        // Read again each time the details open (the other device may have changed it), once paired, and for each box linked.
        .task(id: connected) {
            if connected { await stadeum.readJamieLinks() }
        }
        .task(id: model.boxes.links.map(\.url)) { await model.boxes.readPlaces() }
    }

    /// "Answers from": the pick and what else there is, once every source has said.
    @ViewBuilder private func answersFrom(_ choices: JamieChoices) -> some View {
        if let pick = choices.pick(of: tribe.pubkey) {
            let seesSenders = model.jamieSeesSenders(in: tribe.pubkey)
            FormItem(label: String(localized: "Answers from"),
                     helper: TribeJamiePicker.helper(pick: pick, in: tribe, choices: choices, seesSenders: seesSenders),
                     problem: picker.problem ?? model.jamieTwice(in: tribe.pubkey) ?? model.othersJamie(in: tribe.pubkey) ?? model.jamieProblem) {
                HStack(spacing: Theme.Space.sm) {
                    PeelDropdown(selection: pick.id, options: choices.options(for: tribe.pubkey).map { (value: $0.id, label: $0.name) }) { id in
                        Task { await picker.pick(id, for: tribe, with: model) }
                    }
                    .fixedSize()
                    .disabled(picker.working)
                    if let suggested = choices.suggestion(for: tribe) {
                        Button { Task { await picker.pick(suggested.id, for: tribe, with: model) } } label: {
                            Text("Add Jamie from \(suggested.name)").buttonProgress(picker.working)
                        }
                        .buttonStyle(.peel(.outline))
                        .disabled(picker.working)
                    } else if picker.working {
                        ProgressView().controlSize(.small)
                    }
                }
            }
            if let seesSenders {
                FormSwitchRow(label: TribeJamiePicker.showsSenders, detail: model.jamieMarkNotes[tribe.pubkey],
                              isOn: Binding(get: { seesSenders }, set: { on in
                                  Task { await picker.showSenders(on, in: tribe, with: model) }
                              }))
                    .disabled(picker.working)
            }
        } else {
            let problem = model.jamieProblem
            FormItem(label: String(localized: "Answers from"),
                     helper: problem == nil ? model.jamieAskingBox.map { String(localized: "Asking \($0)…") } ?? String(localized: "Asking Hive…") : nil,
                     problem: problem) {
                if problem != nil {
                    Button("Try again") { Task { await model.readJamies() } }
                        .buttonStyle(.peel(.outline))
                }
            }
        }
    }
}

/// "How you appear in #tribe": a name and a photo sent with your messages
/// there in place of your account's, as the official apps keep them. The
/// picture is picked, never typed; Save sends neither until it is clicked.
private struct TribeIdentitySection: View {
    @Environment(AppModel.self) private var model
    let tribe: Tribe

    /// What is shown, and Save (`TribeIdentityDraft`).
    @State private var draft = TribeIdentityDraft()

    private var accountName: String { model.myAlias?.nilIfEmpty ?? "you" }

    var body: some View {
        @Bindable var draft = draft
        FormSection(String(localized: "How you appear in #\(tribe.displayName)")) {
            FormItem(label: String(localized: "Name"), helper: draft.note, problem: draft.problem) {
                FormTextField(label: String(localized: "Name"), prompt: accountName, text: $draft.alias)
            }
            FormItem(label: String(localized: "Photo")) {
                PictureField(
                    picture: Avatar(name: draft.alias.trimmed.nilIfEmpty ?? accountName, url: draft.photoURL ?? model.myPhotoURL,
                                    size: Theme.AvatarSize.xl, hue: model.myHue),
                    upload: { draft.photoURL = try await model.uploadPicture($0) },
                    remove: draft.photoURL == nil ? nil : .now { draft.photoURL = nil },
                    uploading: $draft.uploading
                )
            }
            if draft.changed(from: tribe) {
                HStack {
                    Spacer()
                    Button("Revert") { draft.reset(to: tribe) }
                        .buttonStyle(.peel(.ghost))
                        .disabled(draft.saving)
                    Button { Task { await draft.save(in: tribe, with: model) } } label: {
                        Text("Save").buttonProgress(draft.saving)
                    }
                    .buttonStyle(.peel(.primary))
                    .disabled(draft.uploading)
                }
            }
        }
        .onAppear { draft.reset(to: tribe) }
    }
}

/// A tribe's tags as chips. With `selection`, each one turns on and off
/// (the edit form); without, they only show (the details).
struct TagChips: View {
    let tags: [String]
    var selection: Binding<[String]>?

    var body: some View {
        // The registry's tags are anyone's words: a few, each kept short.
        ChipFlow(spacing: 6) {
            ForEach(tags.prefix(16), id: \.self) { tag in
                if let selection {
                    Chip(tag, selected: Binding {
                        selection.wrappedValue.contains(tag)
                    } set: { on in
                        if on { selection.wrappedValue.append(tag) } else { selection.wrappedValue.removeAll { $0 == tag } }
                    })
                } else {
                    Chip(tag)
                }
            }
        }
    }
}

/// "Call workspace" — the Stadeum workspace that calls started in
/// this tribe default to, on this device.
private struct TribeCallOrgSection: View {
    @Environment(AppModel.self) private var model
    let tribe: Tribe

    var body: some View {
        let orgs = model.stadeum.live
        let currentId = model.calls.tribeOrgs[tribe.pubkey]
        let options: [(value: String, label: String)] = [("", String(localized: "No default"))]
            + orgs.map { (value: $0.id, label: $0.name) }
        FormSection(String(localized: "Call workspace")) {
            FormItem(
                label: String(localized: "Default workspace"),
                helper: String(localized: "Calls started in this tribe will use this workspace by default.")
            ) {
                PeelDropdown(
                    selection: currentId ?? "",
                    options: options
                ) { id in
                    let peer = orgs.first { $0.id == id }
                    model.calls.setTribeOrg(peer, for: tribe.pubkey)
                }
                .fixedSize()
            }
        }
    }
}
