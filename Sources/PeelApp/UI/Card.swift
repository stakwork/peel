import SwiftUI

/// A card: shadcn's `Card`, the box under a group of rows or a preview.
/// `.raised` lifts it off a popover or a page (a switch row, the tribe's
/// facts, the Account's sections); `.inset` sits it in a chat (a call card,
/// a link card, a payment request). The content brings its own padding.
///
/// ```swift
/// Card { rows.padding(Theme.Space.md) }
/// Card(.inset) { callCard.padding(.horizontal, 14).padding(.vertical, Theme.Space.md) }
/// ```
struct Card<Content: View>: View {
    enum Style {
        /// `menu` with a `formEdge` hairline, and `sectionShadow` in light.
        case raised
        /// `quote` with a `divider` hairline: a raised fill on the conversation.
        case inset
    }

    private let style: Style
    private let content: Content

    init(_ style: Style = .raised, @ViewBuilder content: () -> Content) {
        self.style = style
        self.content = content()
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
        content
            .background {
                switch style {
                case .raised: shape.fill(Theme.menu).shadow(color: Theme.sectionShadow, radius: 1, y: 1)
                case .inset: shape.fill(Theme.quote)
                }
            }
            .overlay(shape.strokeBorder(style == .raised ? Theme.formEdge : Theme.divider))
    }
}

/// A callout: shadcn's `Alert`, a line or a short note in a box. With a
/// title it is a note, its actions (a link) under its words: an invoice
/// that has expired, not enough sats. Without one it is a bar, its actions
/// and its dismiss at the end: a chat's notice, a tribe you cannot post
/// in, a download.
///
/// ```swift
/// Callout(.attention, "Not enough sats", detail: "…") { Button("Receive sats", action: receive).buttonStyle(.peel(.link)) }
/// Callout(detail: notice, icon: .problem, dismiss: dismiss)
/// ```
struct Callout<Actions: View>: View {
    enum Tone {
        /// `panel` with a `divider` hairline; the icon carries any colour.
        case neutral
        /// `attention` at 7% with a 28% hairline: something blocks the
        /// next step. Never red: nothing was lost.
        case attention
    }

    enum Icon {
        /// An amber `exclamationmark.circle`: a problem.
        case problem
        /// The small spinner: something under way.
        case progress
        case symbol(String, Color)
    }

    private let tone: Tone
    private let title: String?
    private let detail: String
    private let icon: Icon?
    private let oneLine: Bool
    private let dismiss: (() -> Void)?
    private let actions: Actions

    /// An `.attention` callout shows `.problem` unless given an icon. A
    /// note's words wrap in full; a bar's take three lines at most, or one
    /// with `oneLine`, cut in the middle so a file name keeps its extension.
    init(
        _ tone: Tone = .neutral, _ title: String? = nil, detail: String, icon: Icon? = nil,
        oneLine: Bool = false, dismiss: (() -> Void)? = nil, @ViewBuilder actions: () -> Actions
    ) {
        self.tone = tone
        self.title = title
        self.detail = detail
        self.icon = icon ?? (tone == .attention ? .problem : nil)
        self.oneLine = oneLine
        self.dismiss = dismiss
        self.actions = actions()
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.sm) {
            if let icon { image(icon) }
            VStack(alignment: .leading, spacing: 3) {
                if let title {
                    Text(title).font(Theme.font(13, .semibold))
                }
                Text(detail)
                    .font(Theme.font(12))
                    .monospacedDigit()
                    .foregroundStyle(Theme.secondaryText)
                    .textSelection(.enabled)
                    .lineLimit(oneLine ? 1 : title == nil ? 3 : nil)
                    .truncationMode(oneLine ? .middle : .tail)
                    .fixedSize(horizontal: false, vertical: !oneLine)
                if title != nil { actions }
            }
            Spacer(minLength: 8)
            if title == nil { actions }
            if let dismiss {
                IconButton("xmark", help: "Dismiss", size: .sm, action: dismiss)
                    // Its hover square reaches into the padding, so a one-line bar keeps its height.
                    .padding(.vertical, -6)
            }
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.vertical, 10)
        .background(tone == .attention ? Theme.attention.opacity(0.07) : Theme.panel, in: shape)
        .overlay(shape.strokeBorder(tone == .attention ? Theme.attention.opacity(0.28) : Theme.divider))
    }

    @ViewBuilder private func image(_ icon: Icon) -> some View {
        switch icon {
        case .problem:
            symbol("exclamationmark.circle", Theme.attention)
        case .progress:
            ProgressView()
                .controlSize(.small)
                // A spinner has no baseline: centre it on the first line's.
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
        case .symbol(let name, let color):
            symbol(name, color)
        }
    }

    private func symbol(_ name: String, _ color: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: 13))
            .foregroundStyle(color)
    }
}

extension Callout where Actions == EmptyView {
    init(
        _ tone: Tone = .neutral, _ title: String? = nil, detail: String, icon: Icon? = nil,
        oneLine: Bool = false, dismiss: (() -> Void)? = nil
    ) {
        self.init(tone, title, detail: detail, icon: icon, oneLine: oneLine, dismiss: dismiss, actions: { EmptyView() })
    }
}
