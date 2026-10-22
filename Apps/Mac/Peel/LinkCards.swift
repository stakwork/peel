import SwiftUI
import PeelCore
import PeelUI

/// A tribe link in a message: the tribe's image, name, description and
/// price when the account's own tribes host lists it (its members only
/// once joined), and Join through
/// the Join form (its lookup, its price and its confirmation), or Open for a
/// tribe this account is in.
struct TribeLinkCard: View {
    @Environment(AppModel.self) private var model
    let link: TribeLink
    var rightAligned = false
    @State private var joining = false

    var body: some View {
        let known = model.tribes[link.pubkey]
        let read = model.linkedTribes[link]
        let info = read?.info
        let name = info?.name.trimmed.nilIfEmpty ?? known?.name?.trimmed.nilIfEmpty
        let member = known.map { !$0.left && ($0.status == .active || $0.status == .pending) } ?? false
        let deleted = read == .deleted || known?.status == .deleted
        LinkCardLayout(
            title: name ?? (read == nil || read == .loading ? "Loading tribe" : "Tribe on \(link.host)"),
            detail: detail(read, info: info, known: known, deleted: deleted),
            detailLines: 2,
            placeholder: name == nil && (read == nil || read == .loading),
            faded: deleted,
            rightAligned: rightAligned
        ) {
            if let name {
                TribeIcon(name: name, url: info?.img ?? known?.photoURL, pubkey: link.pubkey, size: linkCardIconSize)
            } else {
                LinkCardGlyph(systemName: "person.3.fill", shape: .roundedSquare)
            }
        } facts: {
            facts(read, info: info, known: known, member: member, deleted: deleted)
        } action: {
            if member {
                Button("Open") { model.destination = .chat(link.pubkey) }
                    .buttonStyle(.peel(.outline, size: .sm))
                    .help("Open this tribe")
            } else if !deleted {
                Button("Join") { joining = true }
                    .buttonStyle(.peel(.primary, size: .sm))
                    .help(info == nil ? "Look up this tribe, then join" : "See the price, then join")
                    .peelPopover(isPresented: $joining) {
                        JoinTribeForm(link: link.text, info: info) { joining = false }
                    }
            }
        }
        .accessibilityLabel("Tribe link: \(name ?? link.host)")
        .task(id: link) { await model.loadLinkedTribe(link) }
        .task(id: joined) {
            if joined { await model.loadKnownMembers(link.pubkey) }
        }
    }

    /// In the tribe, not only asking: its members are counted as in its
    /// details (`TribeMembers.countLabel`). Not otherwise: the registry's
    /// count is not kept up.
    private var joined: Bool {
        model.tribes[link.pubkey].map { !$0.left && $0.status == .active } ?? false
    }

    private func detail(_ read: LinkedTribe?, info: TribeInfo?, known: Tribe?, deleted: Bool) -> String? {
        if deleted { return "This tribe has been deleted." }
        if let problem = read?.problem { return problem }
        if let summary = (info?.summary ?? known?.summary)?.trimmed.nilIfEmpty { return summary }
        return read == nil || read == .loading ? "Loading…" : link.host
    }

    @ViewBuilder private func facts(
        _ read: LinkedTribe?, info: TribeInfo?, known: Tribe?, member: Bool, deleted: Bool
    ) -> some View {
        let members = joined ? model.knownMembers[link.pubkey]?.countLabel : nil
        if deleted {
            EmptyView()
        } else if member {
            HStack(spacing: 5) {
                if known?.status == .pending {
                    Text("Asked to join")
                } else {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.confirmed)
                    Text("Joined")
                }
                if let members { Text("· \(members)") }
            }
        } else if let info {
            Text([info.isPrivate == true ? "Private" : nil, "\(info.joinPrice.text) to join"]
                .compactMap { $0 }.joined(separator: " · "))
        } else if read?.problem != nil {
            Button("Try again") { Task { await model.loadLinkedTribe(link, again: true) } }
                .buttonStyle(.peel(.link, size: .sm))
        } else if read == .elsewhere {
            Text(Formatting.shortKey(link.pubkey))
        }
    }
}

/// A contact link in a message: who it is when they are already a contact
/// (their photo and name) and Open chat, else their short key and Add
/// through the Add contact form (its name field and its 5-sat check).
struct ContactLinkCard: View {
    @Environment(AppModel.self) private var model
    /// `pubkey_lsp_scid`, as `MessageLink` read it.
    let info: String
    var rightAligned = false
    @State private var adding = false

    var body: some View {
        let pubkey = String(info.prefix(66))
        let isMe = pubkey == model.myPubkey
        let contact = model.conversations.first { $0.chat == pubkey && !$0.isTribe }
        let name = isMe ? "You" : contact.map(\.name) ?? "New contact"
        LinkCardLayout(
            title: name,
            detail: Formatting.shortKey(pubkey),
            detailLines: 1,
            monospacedDetail: true,
            rightAligned: rightAligned
        ) {
            if isMe || contact != nil {
                Avatar(
                    name: isMe ? model.myAlias ?? "" : contact?.name ?? "",
                    url: isMe ? model.myPhotoURL : contact?.photoURL,
                    size: linkCardIconSize,
                    hue: model.hue(pubkey: pubkey, alias: nil, inTribe: false)
                )
            } else {
                LinkCardGlyph(systemName: "person.fill.badge.plus", shape: .circle)
            }
        } facts: {
            if isMe {
                Text("Your contact info")
            } else if contact != nil {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.confirmed)
                    Text("In your contacts")
                }
            } else {
                Text("Adding costs \(Sats.format(msat: Engine.keyExchangeMsat))")
            }
        } action: {
            if contact != nil, !isMe {
                Button("Open chat") { model.destination = .chat(pubkey) }
                    .buttonStyle(.peel(.outline, size: .sm))
            } else if !isMe {
                Button("Add") { adding = true }
                    .buttonStyle(.peel(.primary, size: .sm))
                    .help("Add as a contact")
                    .peelPopover(isPresented: $adding) {
                        AddContactForm(code: info) { adding = false }
                    }
            }
        }
        .accessibilityLabel("Contact link: \(name)")
    }
}

/// The photo or icon on a link card.
private let linkCardIconSize = Theme.AvatarSize.xl

/// The frame both link cards share: an icon, a title, a few lines about it,
/// and a line of facts with the action beside it. One size whatever is
/// known yet (the lines are reserved), so nothing moves when a tribe's
/// details arrive.
private struct LinkCardLayout<Icon: View, Facts: View, Action: View>: View {
    let title: String
    let detail: String?
    let detailLines: Int
    /// Still reading: the words are shown as soft bars.
    var placeholder = false
    var faded = false
    var monospacedDetail = false
    /// Experiment: the icon past the words, facts and action swapped, for
    /// a card in one of yours.
    var rightAligned = false
    @ViewBuilder let icon: Icon
    @ViewBuilder let facts: Facts
    @ViewBuilder let action: Action

    var body: some View {
        Card(.inset) {
            HStack(alignment: .top, spacing: Theme.Space.md) {
                if !rightAligned { iconView }
                VStack(alignment: rightAligned ? .trailing : .leading, spacing: 3) {
                    Text(title)
                        .font(Theme.font(14, .semibold))
                        .foregroundStyle(faded ? Theme.secondaryText : Theme.text)
                        .lineLimit(1)
                        .redacted(reason: placeholder ? .placeholder : [])
                    Text(detail ?? " ")
                        .font(monospacedDetail ? Theme.code(12) : Theme.font(12))
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(detailLines, reservesSpace: true)
                        .redacted(reason: placeholder ? .placeholder : [])
                    HStack(spacing: Theme.Space.sm) {
                        if rightAligned { action }
                        if rightAligned { Spacer(minLength: 0) }
                        facts
                            .font(Theme.font(12))
                            .monospacedDigit()
                            .foregroundStyle(Theme.tertiaryText)
                            .lineLimit(1)
                        if !rightAligned { Spacer(minLength: 0) }
                        if !rightAligned { action }
                    }
                    .frame(height: 28)
                    .padding(.top, 3)
                }
                if rightAligned { iconView }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, Theme.Space.md)
            .frame(width: CallCard.width, alignment: rightAligned ? .trailing : .leading)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
    }

    private var iconView: some View {
        icon
            .frame(width: linkCardIconSize, height: linkCardIconSize)
            .opacity(faded ? 0.5 : 1)
    }
}

/// Someone or a tribe not known yet: a quiet glyph where the photo goes.
private struct LinkCardGlyph: View {
    let systemName: String
    let shape: Avatar.Shape

    var body: some View {
        let size = linkCardIconSize
        ZStack {
            if shape == .circle {
                Circle().fill(Theme.hover)
            } else {
                RoundedRectangle(cornerRadius: size * 0.25, style: .continuous).fill(Theme.hover)
            }
            Image(systemName: systemName)
                .font(.system(size: size * 0.36))
                .foregroundStyle(Theme.secondaryText)
        }
        .frame(width: size, height: size)
    }
}
