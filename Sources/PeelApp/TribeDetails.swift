import SwiftUI
import PeelCore

/// A tribe's details (the header's Tribe details, ⌘I, or a click on its
/// name): what it is, who owns it, what it costs, its link with a QR, its
/// app and second brain, how you appear in it, and the time zone switch.
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
        FormPopover(title: "Tribe details", close: done) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    hero
                    facts
                    if tribe.appURL != nil || tribe.secondBrainURL != nil {
                        pages
                    }
                    if let link = tribe.link {
                        share(link)
                    }
                    if tribe.canPost {
                        TribeIdentitySection(tribe: tribe)
                            .padding(.top, 18)
                    }
                    ChatTimeZoneSection(conversation: conversation, tribe: tribe)
                        .padding(.top, 18)
                }
                .padding(.bottom, 4)
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
            HStack(spacing: 12) {
                TribeIcon(name: tribe.displayName, url: tribe.photoURL, pubkey: tribe.pubkey, size: 56)
                VStack(alignment: .leading, spacing: 3) {
                    Text(tribe.displayName)
                        .font(Theme.font(16, .bold))
                        .lineLimit(2)
                    Text(subtitle)
                        .font(Theme.font(12))
                        .foregroundStyle(Theme.secondaryText)
                }
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
        .padding(.top, 12)
    }

    /// "Public tribe · Created 3 Oct 2026".
    private var subtitle: String {
        [
            tribe.isPrivate ? "Private tribe" : "Public tribe",
            info?.created.map { "Created \($0.formatted(.dateTime.day().month(.abbreviated).year()))" },
        ].compactMap { $0 }.joined(separator: " · ")
    }

    @ViewBuilder private var facts: some View {
        VStack(spacing: 0) {
            DetailRow("Owner") { owner }
            switch memberList {
            case nil: DetailRow("Members") { known(nil) }
            case .success(let members): DetailRow("Members") { Text(members.countLabel) }
            case .failure: EmptyView()
            }
            DetailRow("To join") { known(info?.joinPrice.described) }
            DetailRow("Each message") { Text(tribe.messagePrice.described) }
            DetailRow("Escrow", last: true) { Text(escrow) }
        }
        .formCard()
        .padding(.top, 14)
        if let problem {
            ProblemText(problem).padding(.top, 6)
        }
    }

    @ViewBuilder private var owner: some View {
        if tribe.isOwner {
            let me = model.me(in: tribe.pubkey)
            HStack(spacing: 6) {
                Avatar(name: me.avatarName, url: me.photoURL, size: 18, hue: me.hue)
                Text("You")
            }
        } else if let alias = info?.ownerAlias?.nilIfEmpty {
            HStack(spacing: 6) {
                Avatar(name: alias, url: details?.ownerPhotoURL, size: 18,
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

    /// "5 sats, back after 2 hours", or None.
    private var escrow: String {
        guard tribe.escrowMsat > 0 else { return "None" }
        let amount = Sats.exact(msat: tribe.escrowMsat)
        guard let millis = info?.escrowMillis, millis > 0 else { return amount }
        let hours = Sats.text(UInt64(millis), unit: Sats.millisecondsPerHour)
        return "\(amount), back after \(hours) \(hours == "1" ? "hour" : "hours")"
    }

    /// The tribe's app and second brain, opened in the web pane beside the chat.
    private var pages: some View {
        HStack(spacing: 8) {
            page("Tribe app", systemImage: "square.grid.2x2", address: tribe.appURL)
            page("Second brain", systemImage: "brain", address: tribe.secondBrainURL)
        }
        .padding(.top, 14)
    }

    @ViewBuilder private func page(_ title: String, systemImage: String, address: String?) -> some View {
        if let url = address.flatMap(URL.init(string:)) {
            Button {
                done()
                withAnimation(.easeOut(duration: 0.2)) { model.web.open(url) }
            } label: {
                Label(title, systemImage: systemImage)
            }
            .buttonStyle(FormButtonStyle())
            .help("Opens beside the chat")
        }
    }

    private func share(_ link: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            QRCodeTile(text: link, label: "QR code of the tribe link", size: 112)
            VStack(alignment: .leading, spacing: 8) {
                Text("Anyone with the link or the code can join.")
                    .font(Theme.font(12))
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                CopyButton("Copy link", text: link, systemImage: "link")
                CopyButton("Copy QR image", systemImage: "qrcode") { QRCode.copyImage(link) }
            }
            .buttonStyle(FormButtonStyle())
            Spacer(minLength: 0)
        }
        .padding(12)
        .formCard()
        .padding(.top, 14)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button("Members", action: members)
                .buttonStyle(FormButtonStyle())
            Spacer()
            if tribe.canManage {
                Button("Edit tribe…", action: edit)
                    .buttonStyle(FormButtonStyle())
            } else if tribe.canPost {
                InlineConfirm(trigger: "Leave tribe", confirm: "Leave") {
                    do {
                        try await model.leaveTribe(tribe.pubkey)
                        done()
                    } catch {
                        problem = "Could not leave: \(PeelError.readable(error))"
                    }
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
            problem = "The tribes server did not answer: \(PeelError.readable(error))"
        }
    }
}

extension TribeMembers {
    /// How many are in the tribe, counted as the Members panel lists them:
    /// for the owner, the tribes server's list ("12 members", requests to
    /// join not counted); for anyone else, who has posted and themself ("4
    /// seen", as its "Seen in #tribe"). Never the registry's `member_count`:
    /// an edit or pin from the official apps drops it, a kick after that
    /// counts down from nothing to 0, and a leave never counts down.
    var countLabel: String {
        guard complete else { return "\((members.count + 1).formatted()) seen" }
        let count = members.count { !$0.pending }
        return count == 1 ? "1 member" : "\(count.formatted()) members"
    }
}

/// One fact on the details card: its name in a column, the value beside it.
private struct DetailRow<Value: View>: View {
    let label: String
    var last = false
    @ViewBuilder let value: Value

    init(_ label: String, last: Bool = false, @ViewBuilder value: () -> Value) {
        self.label = label
        self.last = last
        self.value = value()
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(label)
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 100, alignment: .leading)
            value
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(Theme.font(13))
        .monospacedDigit()
        .padding(.horizontal, 12)
        .frame(minHeight: 36)
        .overlay(alignment: .bottom) {
            if !last { Theme.divider.frame(height: 1).padding(.leading, 12) }
        }
    }
}

/// "How you appear in #tribe": a name and a photo sent with your messages
/// there in place of your account's, as the official apps keep them. The
/// picture is picked, never typed; Save sends neither until it is clicked.
private struct TribeIdentitySection: View {
    @Environment(AppModel.self) private var model
    let tribe: Tribe

    @State private var alias = ""
    /// The tribe's own photo: nil while it uses the account's.
    @State private var photoURL: String?
    @State private var uploading = false
    @State private var saving = false
    @State private var problem: String?

    private var accountName: String { model.myAlias?.nilIfEmpty ?? "you" }
    private var changed: Bool {
        alias.trimmed.nilIfEmpty != tribe.myAlias || photoURL != tribe.myPhotoURL
    }

    var body: some View {
        FormSection("How you appear in #\(tribe.displayName)") {
            FormItem(label: "Name", helper: helper, problem: problem) {
                FormTextField(label: "Name", prompt: accountName, text: $alias)
            }
            FormItem(label: "Photo") {
                PictureField(
                    picture: Avatar(name: alias.trimmed.nilIfEmpty ?? accountName, url: photoURL ?? model.myPhotoURL,
                                    size: 40, hue: model.myHue),
                    upload: { photoURL = try await model.uploadPicture($0) },
                    remove: photoURL == nil ? nil : .now { photoURL = nil },
                    uploading: $uploading
                )
            }
            if changed {
                HStack {
                    Spacer()
                    Button("Revert") { reset() }
                        .buttonStyle(FormButtonStyle(kind: .ghost))
                        .disabled(saving)
                    Button { Task { await save() } } label: { Text("Save").buttonProgress(saving) }
                        .buttonStyle(FormButtonStyle(kind: .primary))
                        .disabled(uploading)
                }
            }
        }
        .onAppear(perform: reset)
        .onChange(of: alias) { problem = nil }
    }

    /// What members will read: the name as a tribe alias, which is only
    /// letters, digits and underscores.
    private var helper: String {
        let sent = tribeAlias(alias.trimmed.nilIfEmpty ?? model.myAlias ?? "")
        let empty = alias.trimmed.isEmpty ? " Empty uses your account's name and photo." : ""
        return "Members see \u{201C}\(sent)\u{201D} on what you send from now on.\(empty)"
    }

    private func reset() {
        alias = tribe.myAlias ?? ""
        photoURL = tribe.myPhotoURL
        problem = nil
    }

    private func save() async {
        guard !saving, !uploading else { return }
        saving = true
        defer { saving = false }
        do {
            try await model.setTribeIdentity(tribe.pubkey, alias: alias, photoURL: photoURL)
        } catch {
            problem = "Could not save: \(PeelError.readable(error))"
        }
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
                    let on = selection.wrappedValue.contains(tag)
                    Button {
                        if on { selection.wrappedValue.removeAll { $0 == tag } } else { selection.wrappedValue.append(tag) }
                    } label: {
                        chip(tag, on: on)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? [.isSelected] : [])
                } else {
                    chip(tag, on: false)
                }
            }
        }
    }

    private func chip(_ tag: String, on: Bool) -> some View {
        let shape = Capsule(style: .circular)
        return HStack(spacing: 4) {
            if on { Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)) }
            Text(tag).lineLimit(1).truncationMode(.tail)
        }
        .frame(maxWidth: 200)
        .font(Theme.font(12, .medium))
        .foregroundStyle(on ? Theme.selectionText : Theme.text)
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background {
            shape.fill(on ? Theme.selection : Theme.fieldFill)
                .overlay { shape.strokeBorder(on ? Theme.accent.opacity(0.6) : Theme.inputBorder) }
        }
        .contentShape(shape)
    }
}

/// Lays its views out in lines, left to right, starting a new line when
/// the next would not fit.
private struct ChipFlow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let frames = place(subviews, width: proposal.width ?? .infinity)
        let width = frames.map(\.maxX).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: frames.map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, frame) in zip(subviews, place(subviews, width: bounds.width)) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                          proposal: ProposedViewSize(frame.size))
        }
    }

    private func place(_ subviews: Subviews, width: CGFloat) -> [CGRect] {
        var frames: [CGRect] = []
        var point = CGPoint.zero
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if point.x > 0, point.x + size.width > width {
                point = CGPoint(x: 0, y: point.y + lineHeight + spacing)
                lineHeight = 0
            }
            frames.append(CGRect(origin: point, size: size))
            point.x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return frames
    }
}
