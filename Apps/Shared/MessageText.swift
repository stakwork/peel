import AgentKit
import SwiftUI
import PeelCore
import PeelUI

// Message text, for the Mac and the iPhone: the iPhone app compiles this
// file too (docs/design/iphone.md, "Components"). Plain SwiftUI over
// `MessageMarkup`, `Theme` and the model; nothing AppKit or UIKit.

/// Message text as `MessageMarkup` reads it: links, mentions, inline code
/// and emphasis marked, list items with a hanging indent, headings larger,
/// quotes behind a bar, ``` blocks as code. Its own view, so hovering the
/// row does not redo the parsing.
struct MessageText: View {
    @Environment(AppModel.self) private var model
    let text: String
    /// Where it was said, for what a mention of you looks like there; nil
    /// in the agent chat.
    let chat: String?
    /// The agent's reply: its links to messages open them (`LinkText`).
    let agentLinks: Bool
    /// Experiment: right-aligned, ragged-left paragraphs for yours (design
    /// README, "Flat rows"; not part of that decision, just trying it).
    var rightAligned: Bool = false
    /// The body's size: 14 on the Mac, 15 on the iPhone, where it scales
    /// with Dynamic Type. Code, list numbers and headings are sized from it.
    #if os(iOS)
    @ScaledMetric private var size: CGFloat
    #else
    private let size: CGFloat
    #endif

    init(text: String, chat: String?, agentLinks: Bool = false, rightAligned: Bool = false, size: CGFloat = 14) {
        self.text = text
        self.chat = chat
        self.agentLinks = agentLinks
        self.rightAligned = rightAligned
        #if os(iOS)
        _size = ScaledMetric(wrappedValue: size, relativeTo: .body)
        #else
        self.size = size
        #endif
    }

    var body: some View {
        let blocks = MessageMarkup.blocks(text)
        let myAliases = chat.map(model.mentionAliases(in:)) ?? []
        let found = model.search.flatMap { chat != nil && $0.chat == chat ? $0.query?.terms : nil } ?? []
        VStack(alignment: rightAligned ? .trailing : .leading, spacing: Theme.Space.xs) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .paragraph(let line):
                    styled(line, myAliases, found)
                case .item(let line):
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Space.sm) {
                        Text("•").foregroundStyle(Theme.secondaryText)
                        styled(line, myAliases, found)
                    }
                    .padding(.leading, Theme.Space.xs)
                case .numbered(let number, let line):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(number).")
                            .font(Theme.font(size))
                            .monospacedDigit()
                            .foregroundStyle(Theme.secondaryText)
                        styled(line, myAliases, found)
                    }
                    .padding(.leading, Theme.Space.xs)
                case .heading(let level, let line):
                    styled(line, myAliases, found, font: Theme.font(size + (level == 1 ? 6 : level == 2 ? 3 : 1), .semibold))
                        .padding(.top, 2)
                case .quote(let line):
                    styled(line, myAliases, found)
                        .padding(.leading, Theme.Space.md)
                        .overlay(alignment: .leading) {
                            Capsule().fill(Theme.secondaryText.opacity(0.4)).frame(width: 3)
                        }
                case .code(let code):
                    Text(AttributedString(code).highlighting(found))
                        .font(Theme.code(size - 1))
                        .lineSpacing(2)
                        .foregroundStyle(Theme.text)
                        .selectableOnMac()
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 10)
                        .padding(.vertical, Theme.Space.sm)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.codeFill, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                }
            }
        }
    }

    /// A line of text, with what the chat's search `found` lit.
    private func styled(_ line: String, _ myAliases: Set<String>, _ found: [String], font: Font? = nil) -> some View {
        Text(LinkText.attributed(line, myAliases: myAliases, agentLinks: agentLinks, size: size).highlighting(found))
            .font(font ?? Theme.font(size))
            .multilineTextAlignment(rightAligned ? .trailing : .leading)
            .lineSpacing(3)
            .foregroundStyle(Theme.text)
            .selectableOnMac()
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Styles the inline markup of message text (`MessageMarkup.inlines`): https
/// links clickable, mentions and inline code set apart, emphasis in bold,
/// italic or struck through. Anything else stays plain text.
enum LinkText {
    /// Mentions as a soft chip, gold when it names you (by one of `myAliases`,
    /// `AppModel.mentionAliases`) or @all; inline code in a monospaced face
    /// on a soft fill, without its backticks; https links in the link
    /// colour, as `MessageMarkup.linkLabel` words them (the host always
    /// whole; the full address is what opens); a `[text](https://…)` link as
    /// its text with its host beside it, so where it goes is never hidden.
    /// With `agentLinks`, in the agent's replies, a link to a message
    /// (`AgentMessageLink`) shows its text alone: it opens in Peel. `size`
    /// is the text's, which a mention matches and code sits a point under.
    static func attributed(_ text: String, myAliases: Set<String>, agentLinks: Bool = false,
                           size: CGFloat = 14) -> AttributedString {
        var result = AttributedString()
        for inline in MessageMarkup.inlines(text) {
            var shown = AttributedString(inline.text)
            switch inline.kind {
            case nil:
                break
            case .mention:
                let you = mentions(inline.text, aliases: myAliases)
                shown.font = Theme.font(size, you ? .semibold : .medium)
                shown.foregroundColor = you ? Theme.mentionYouText : Theme.mentionText
                shown.backgroundColor = you ? Theme.mentionYouFill : Theme.mentionFill
            case .code:
                shown.font = Theme.code(size - 1)
                shown.backgroundColor = Theme.codeFill
            case .link(let url):
                shown = AttributedString(MessageMarkup.linkLabel(inline.text, url: url))
                shown.link = url
                shown.foregroundColor = Theme.link
            case .namedLink(let url) where agentLinks && AgentMessageLink(url) != nil:
                shown.foregroundColor = Theme.link
                shown.link = url
            case .namedLink(let url):
                shown.foregroundColor = Theme.link
                // Isolated left to right, so a direction override in the
                // text before it cannot turn the host around.
                var host = AttributedString(" (\u{2066}\(MessageMarkup.host(of: url) ?? url.absoluteString)\u{2069})")
                host.foregroundColor = Theme.secondaryText
                shown += host
                shown.link = url
            }
            var intent: InlinePresentationIntent = []
            if inline.emphasis.contains(.bold) { intent.insert(.stronglyEmphasized) }
            if inline.emphasis.contains(.italic) { intent.insert(.emphasized) }
            if inline.emphasis.contains(.strikethrough) { intent.insert(.strikethrough) }
            if !intent.isEmpty { shown.inlinePresentationIntent = intent }
            result += shown
        }
        return result
    }
}

private extension View {
    /// Selectable on the Mac. On the iPhone a long press opens the
    /// message's menu, which has Copy (docs/design/iphone.md, "iOS patterns").
    @ViewBuilder func selectableOnMac() -> some View {
        #if os(macOS)
        textSelection(.enabled)
        #else
        self
        #endif
    }
}

extension AttributedString {
    /// With every occurrence of each of `terms` behind the search
    /// highlight, found as the index finds them (case and accents aside).
    func highlighting(_ terms: [String]) -> AttributedString {
        var result = self
        for term in terms where !term.isEmpty {
            var start = result.startIndex
            while start < result.endIndex,
                  let range = result[start...].range(of: term, options: MessageQuery.compareOptions) {
                result[range].backgroundColor = Theme.searchMatch
                start = range.upperBound
            }
        }
        return result
    }
}
