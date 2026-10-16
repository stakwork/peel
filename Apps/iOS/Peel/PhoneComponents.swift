import PeelCore
import PeelUI
import SwiftUI

// The phone's shared rows and boxes (docs/design/iphone.md, "Components"),
// for Chats, the conversation, Payments and You. Each follows the Mac's
// piece; the Mac's own plain-SwiftUI pieces (`Badge`, `Card`, `Callout`,
// `PeelButton`, `MessageText`) compile into the phone as they are.
// Nothing here has a fixed height: rows grow with Dynamic Type.

/// A count in a capsule, 22 tall at least: unread in the accent, gold for a
/// mention of you, orange for waiting on you (`Badge.Style`'s colours).
struct CountBadge: View {
    let count: Int
    var style = Badge.Style.default

    var body: some View {
        Text(Badge.text(count))
            .phoneFont(.badge)
            .monospacedDigit()
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(style.foreground)
            .padding(.horizontal, 7)
            .frame(minWidth: 22, minHeight: 22)
            .background(style.fill, in: Capsule())
    }
}

/// A section's header: 13 semibold in the quiet grey of its surface, a
/// heading for VoiceOver. With `expanded` the whole width is a 44 pt
/// button that folds the section, a chevron after the title.
struct PhoneSectionHeader: View {
    let title: String
    var expanded: Binding<Bool>?
    @Environment(\.surface) private var surface

    init(_ title: String, expanded: Binding<Bool>? = nil) {
        self.title = title
        self.expanded = expanded
    }

    var body: some View {
        if let expanded {
            Button {
                expanded.wrappedValue.toggle()
            } label: {
                label(open: expanded.wrappedValue)
                    .frame(minHeight: Theme.touchTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(.isHeader)
            .accessibilityValue(expanded.wrappedValue ? "Expanded" : "Collapsed")
        } else {
            label(open: nil)
                .accessibilityAddTraits(.isHeader)
        }
    }

    private func label(open: Bool?) -> some View {
        HStack(spacing: 6) {
            Text(title).phoneFont(.sectionHeader)
            if let open {
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .bold))
                    .rotationEffect(.degrees(open ? 0 : -90))
                    .accessibilityHidden(true)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(Theme.quietText(on: surface))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A sidebar-style row at the top of Chats (Automations, Threads,
/// Mentions): a 19 pt symbol in the avatars' 30 pt column, then the name,
/// bold with a count when there is something new, `secondaryText` when
/// not. The caller wraps it in its `NavigationLink`.
struct NavRow: View {
    let title: String
    let systemImage: String
    var count = 0
    var countStyle = Badge.Style.default

    var body: some View {
        let lit = count > 0
        RowLayout {
            Image(systemName: systemImage)
                .font(.system(size: 19))
                .frame(width: 30)
                .accessibilityHidden(true)
        } title: {
            Text(title).phoneFont(PhoneFont.row.weight(lit ? .semibold : .regular))
        } trailing: {
            if lit { CountBadge(count: count, style: countStyle) }
        }
        .foregroundStyle(lit ? Theme.text : Theme.secondaryText)
        .accessibilityElement(children: .combine)
        .accessibilityValue(lit ? "\(count) new" : "")
    }
}

/// A chat in a list: its icon (a tribe a rounded square, a person round),
/// the name, and what it holds for you. Read: the name in
/// `secondaryText`; unread: `text`, semibold, with the count in blue, or
/// gold when it mentions you; orange while the agent waits on you. AGENT
/// after the agent's name. The caller wraps it in its `NavigationLink`
/// and adds the swipe actions.
struct ChatListRow: View {
    let conversation: Conversation
    /// `model.readStates[chat]`.
    let state: ChatReadState?
    /// The agent's chat: AGENT after its name, a rounded square.
    var isAgent = false
    /// How many of the agent's cards wait on you: an orange count.
    var waiting = 0

    var body: some View {
        let level = state?.mute ?? .all
        let unread = state?.sidebarCount ?? 0
        let mentionsYou = (state?.mentions ?? 0) > 0
        let lit = unread > 0 || waiting > 0
        RowLayout {
            icon
        } title: {
            HStack(spacing: 6) {
                Text(conversation.name)
                    .phoneFont(PhoneFont.row.weight(lit ? .semibold : .regular))
                    .foregroundStyle(lit ? Theme.text : Theme.secondaryText)
                    .lineLimit(1)
                if isAgent { AgentTag() }
            }
        } trailing: {
            if waiting > 0 {
                CountBadge(count: waiting, style: .attention)
            } else if unread > 0 {
                CountBadge(count: unread, style: mentionsYou ? .mention : .default)
            } else if state?.isNew == true {
                // Someone who added you; nothing to answer.
                Badge("New")
            } else if level == .muted {
                Image(systemName: "bell.slash").foregroundStyle(Theme.secondaryText)
            } else if level == .mentionsOnly {
                Image(systemName: "at").foregroundStyle(Theme.secondaryText)
            }
        }
        .opacity(level == .muted && !lit ? 0.6 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(conversation.name + (isAgent ? ", agent" : ""))
        .accessibilityValue(spoken(unread: unread, mentionsYou: mentionsYou, level: level))
    }

    @ViewBuilder private var icon: some View {
        if isAgent {
            // A rounded square on its key's colour, as a tribe's is.
            TribeIcon(name: conversation.name, url: conversation.photoURL, pubkey: conversation.chat, size: 30)
        } else {
            ConversationIcon(conversation: conversation, size: 30)
        }
    }

    /// "3 unread, mentions you", "waiting on you", "muted".
    private func spoken(unread: Int, mentionsYou: Bool, level: MuteLevel) -> String {
        if waiting > 0 { return "waiting on you" }
        var parts: [String] = []
        if unread > 0 { parts.append("\(unread) unread") }
        if mentionsYou, unread > 0 { parts.append("mentions you") }
        if state?.isNew == true, unread == 0 { parts.append("new") }
        if level == .muted { parts.append("muted") } else if level == .mentionsOnly { parts.append("mentions only") }
        return parts.joined(separator: ", ")
    }
}

/// A row's layout: the icon column, the title, then what sits at its end.
/// 44 tall at least (a list puts `Theme.phoneGutter` at its sides); at
/// accessibility text sizes the end goes under the title rather than clipping it.
private struct RowLayout<Leading: View, Title: View, Trailing: View>: View {
    @ViewBuilder let leading: Leading
    @ViewBuilder let title: Title
    @ViewBuilder let trailing: Trailing
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        HStack(spacing: Theme.Space.md) {
            leading
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    title
                    trailing
                }
                Spacer(minLength: 0)
            } else {
                title
                Spacer(minLength: Theme.Space.sm)
                trailing
            }
        }
        .padding(.vertical, 7)
        .frame(minHeight: Theme.touchTarget)
    }
}

/// A group of cells or a result on the phone: the Mac's `Card(.inset)`
/// (`quote`, a `divider` hairline) at radius 12, telling what is inside
/// that it sits on a raised surface (`Theme.quietText`).
struct PhoneCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        Card(.inset, radius: Theme.Radius.panel) {
            content.environment(\.surface, .raised)
        }
    }
}
