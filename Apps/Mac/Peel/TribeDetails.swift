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
    /// Opens the members panel or the edit form in this panel's place.
    let members: () -> Void
    let edit: () -> Void
    let done: () -> Void

    @State private var details: TribeDetails?
    @State private var problem: String?
    /// Who is in it, as the Members panel lists them; the row goes when
    /// they cannot be read.
    @State private var memberList: Result<TribeMembers, any Error>?

    private var info: TribeInfo? { details?.info }

    var body: some View {
        Panel("Tribe details", close: done) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
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
                    if tribe.canPost {
                        TribeIdentitySection(tribe: tribe)
                            .padding(.top, 18)
                    }
                    ChatTimeZoneSection(conversation: conversation, tribe: tribe)
                        .padding(.top, 18)
                }
                .padding(.bottom, Theme.Space.xs)
                .endsEditingOnClick()
            }
            .frame(maxHeight: 560)
            .fixedSize(horizontal: false, vertical: true)
            // More below: the content fades into the footer rather than stopping at it.
            .overlay(alignment: .bottom) {
                LinearGradient(colors: [Theme.sidebar.opacity(0), Theme.sidebar], startPoint: .top, endPoint: .bottom)
                    .frame(height: 14)
                    .allowsHitTesting(false)
            }
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
        .padding(.top, Theme.Space.md)
    }

    /// "Public tribe · Created 3 Oct 2026".
    private var subtitle: String { tribe.detailsSubtitle(created: info?.created) }

    @ViewBuilder private var facts: some View {
        FactList {
            Fact("Owner") { owner }
            switch memberList {
            case nil: Fact("Members") { known(nil) }
            case .success(let members): Fact("Members") { Text(members.countLabel) }
            case .failure: EmptyView()
            }
            Fact("To join") { known(info?.joinPrice.described) }
            Fact("Each message") { Text(tribe.messagePrice.described) }
            Fact("Escrow") { Text(tribe.escrowLine(millis: info?.escrowMillis)) }
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
            known(info == nil ? nil : "Not given")
        }
    }

    /// A value the registry gives: a dash until it answers.
    private func known(_ text: String?) -> some View {
        Text(text ?? "—").foregroundStyle(text == nil ? Theme.tertiaryText : Theme.text)
    }

    /// The tribe's pages (`Tribe.pages`, in the More menu's order), opened
    /// in the web pane beside the chat.
    private var pages: some View {
        HStack(spacing: Theme.Space.sm) {
            ForEach(tribe.pages, id: \.kind) { page in
                Button {
                    done()
                    model.web.open(page)
                } label: {
                    Label(page.title, systemImage: page.systemImage)
                }
                .buttonStyle(.peel(.outline))
                .help("Opens beside the chat")
            }
        }
        .padding(.top, 14)
    }

    private func share(_ link: String) -> some View {
        Card {
            HStack(alignment: .top, spacing: 14) {
                QRCodeTile(text: link, label: "QR code of the tribe link", size: 112)
                VStack(alignment: .leading, spacing: Theme.Space.sm) {
                    CopyButton("Copy link", text: link, systemImage: "link")
                    CopyButton("Copy QR image", systemImage: "qrcode") { QRCode.copyImage(link) }
                }
                .buttonStyle(.peel(.outline))
                Spacer(minLength: 0)
            }
            .padding(Theme.Space.md)
        }
        .padding(.top, 14)
    }

    /// Where to go on the left; Leave, the one destructive action, on the right.
    private var footer: some View {
        HStack(spacing: Theme.Space.sm) {
            Button("Members", action: members)
                .buttonStyle(.peel(.outline))
            if tribe.canManage {
                Button("Edit tribe…", action: edit)
                    .buttonStyle(.peel(.outline))
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
            problem = PeelError.problem(error, couldNot: "load tribe details")
        }
    }
}

/// "Jamie", for the tribe's owner (docs/hive-tribes.md): which of your
/// Stadeum orgs answers `@jamie` here, as you: one of them or No Jamie,
/// as Hive has it (`TribeJamiePicker`), and with no Jamie yet the org the
/// tribe's app or second brain is on, in one click. Unpaired, Connect
/// Stadeum pairs this Mac from here.
private struct TribeJamieSection: View {
    @Environment(AppModel.self) private var model
    let tribe: Tribe

    @State private var picker = TribeJamiePicker()

    var body: some View {
        let stadeum = model.stadeum
        let connected = stadeum.status == .connected
        FormSection("Jamie") {
            switch stadeum.status {
            case .off, .needsPairing:
                FormItem(label: "Stadeum", helper: model.brain == .thisMac
                         ? "Connect Stadeum to let one of your orgs answer @jamie here."
                         : "Your assistant runs on your home server. Turn off Always on to connect Stadeum.",
                         problem: stadeum.problem) {
                    if model.brain == .thisMac {
                        Button(stadeum.status == .off ? "Connect Stadeum" : "Connect again") { model.connectHive() }
                            .buttonStyle(.peel(.outline))
                    }
                }
            case .pairing(let pairing):
                FormItem(label: "Pair this Mac") {
                    HStack(alignment: .top) {
                        StadeumPairingCode(pairing: pairing)
                        Spacer(minLength: 0)
                        Button("Cancel") { model.cancelHivePairing() }
                            .buttonStyle(.peel(.ghost))
                    }
                }
            case .connected:
                if let pick = stadeum.jamiePick(of: tribe.pubkey) {
                    FormItem(label: "Answers from", helper: TribeJamiePicker.helper(pick: pick, in: tribe, stadeum: stadeum),
                             problem: picker.problem ?? model.othersJamie(in: tribe.pubkey)) {
                        HStack(spacing: Theme.Space.sm) {
                            PeelDropdown(selection: pick, options: stadeum.jamieOptions(for: tribe.pubkey).map { (value: $0.id, label: $0.name) }) { id in
                                Task { await picker.pick(id, for: tribe, with: model) }
                            }
                            .fixedSize()
                            .disabled(picker.working)
                            if let suggested = model.jamieSuggestion(for: tribe) {
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
                } else {
                    FormItem(label: "Answers from", helper: stadeum.jamieProblem == nil ? "Asking Stadeum…" : nil,
                             problem: stadeum.jamieProblem) {
                        if stadeum.jamieProblem != nil {
                            Button("Try again") { Task { await stadeum.readJamieLinks() } }
                                .buttonStyle(.peel(.outline))
                        }
                    }
                }
            }
        }
        // Read again each time the details open (the other device may have changed it), and once paired.
        .task(id: connected) {
            if connected { await stadeum.readJamieLinks() }
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
        FormSection("How you appear in #\(tribe.displayName)") {
            FormItem(label: "Name", helper: draft.note, problem: draft.problem) {
                FormTextField(label: "Name", prompt: accountName, text: $draft.alias)
            }
            FormItem(label: "Photo") {
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
