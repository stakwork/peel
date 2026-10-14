import PeelCore
import PeelUI
import SwiftUI
import UIKit

/// What a row offers on the phone (docs/design/iphone.md, "iOS patterns"),
/// by the Mac's rules (`MessageMenu`): undelivered, Retry and Discard;
/// otherwise Reply in thread, Boost <your amount> (someone else's message
/// not yet boosted, `ChatRow.canBoost`), Copy, Copy link, and Delete for
/// one you may delete. The long-press menu, the swipe and VoiceOver's
/// custom actions all read it.
@MainActor
struct MessageActions {
    let row: ChatRow
    let composer: ComposerID
    /// Nil for a payment or a request: copying its note is all they offer.
    let model: AppModel?
    var now = Date.now

    private var message: Message { row.message }

    var isRetryable: Bool { model != nil && message.isRetryable(now: now) }

    /// Reply in thread: a message that can carry a reply, not undelivered.
    var canReply: Bool { model != nil && !isRetryable && !message.deleted && message.isLinkable(inTribe: row.inTribe) }

    var canBoost: Bool { model != nil && !isRetryable && row.canBoost }

    var text: String? {
        if message.deleted { return nil }
        if row.kind == .payment { return message.content?.trimmed.nilIfEmpty }
        return message.shownText.nilIfEmpty
    }

    /// The link a message carries: its call's, else the first https link in its text.
    var link: URL? {
        if message.deleted { return nil }
        if let call = row.call { return call.url }
        guard let text else { return nil }
        for inline in MessageMarkup.inlines(text) {
            switch inline.kind {
            case .link(let url), .namedLink(let url): return url
            default: continue
            }
        }
        return nil
    }

    /// Reply in thread: the thread sheet. Inside the sheet, a reply to one
    /// of its messages quotes it there (the Mac's `startReply`).
    func reply() {
        guard let model else { return }
        if composer.thread != nil {
            model.reply(to: message, in: composer)
        } else {
            model.openThread(of: message)
        }
    }

    func boost() {
        guard let model else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        Task { await model.quickBoost(message) }
    }

    func copy(_ text: String) {
        Clipboard.copy(text)
        CopyFeedback.announce()
    }

    func retry() {
        guard let model else { return }
        Task { await model.resend(message) }
    }

    func discard() {
        guard let model else { return }
        Task { await model.discard(message) }
    }
}

/// The menu's Delete, asked of the model (it reads the thread's size)
/// only when the menu is drawn, never per row.
private struct DeleteItem: View {
    @Environment(AppModel.self) private var model
    let row: ChatRow

    var body: some View {
        if row.images.count < 2, model.canDelete(row.message, inTribe: row.inTribe) {
            Button("Delete", systemImage: "trash", role: .destructive) {
                Task { await model.delete(row.message) }
            }
        }
    }
}

extension View {
    /// The row's long-press menu, its swipe right to reply in the thread,
    /// and for VoiceOver one element, `spoken`, with the menu as actions
    /// (a payment's or a request's: its own words and buttons combined).
    func messageActions(_ actions: MessageActions, spoken: String = "") -> some View {
        modifier(MessageActionsModifier(actions: actions, spoken: spoken))
    }
}

private struct MessageActionsModifier: ViewModifier {
    let actions: MessageActions
    let spoken: String

    @ViewBuilder func body(content: Content) -> some View {
        let menued = content
            .contextMenu { MenuItems(actions: actions, forVoiceOver: false) }
            .modifier(SwipeToReply(enabled: actions.canReply, reply: actions.reply))
        if actions.model == nil {
            // A payment or a request: its words and its own buttons (Retry
            // through `PaymentAttempt`) as one element.
            menued.accessibilityElement(children: .combine)
        } else {
            menued
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(spoken)
                .accessibilityActions { MenuItems(actions: actions, forVoiceOver: true) }
        }
    }
}

/// The menu's entries, once for the long press and once as VoiceOver's
/// actions. Its own view, so the row draws none of it (the text's link,
/// the boost amount) until the menu or VoiceOver asks. VoiceOver gets
/// Open thread; Delete stays in the menu, where the model is asked
/// whether it may.
private struct MenuItems: View {
    @Environment(AppModel.self) private var model
    let actions: MessageActions
    let forVoiceOver: Bool

    var body: some View {
        let message = actions.row.message
        if actions.isRetryable {
            Button(message.uploadState == .failed ? "Retry upload" : "Retry sending",
                   systemImage: "arrow.clockwise", action: actions.retry)
            if message.isDiscardable {
                Button("Discard, never sent", systemImage: "xmark", role: .destructive, action: actions.discard)
            }
        }
        if actions.canReply {
            Button(actions.composer.thread == nil ? "Reply in thread" : "Reply",
                   systemImage: "arrowshape.turn.up.left", action: actions.reply)
        }
        if forVoiceOver, let summary = actions.row.summary {
            Button("Open thread") { model.openThread(ThreadRef(chat: summary.chat, uuid: summary.uuid)) }
        }
        if actions.canBoost {
            Button(model.quickBoostLabel, systemImage: "bolt.fill", action: actions.boost)
        }
        if let text = actions.text {
            Button("Copy", systemImage: "doc.on.doc") { actions.copy(text) }
        }
        if let link = actions.link {
            Button("Copy link", systemImage: "link") { actions.copy(link.absoluteString) }
        }
        if !forVoiceOver, actions.model != nil, !actions.isRetryable {
            Section { DeleteItem(row: actions.row) }
        }
    }
}

/// Swipe right on a message to reply in its thread: the row follows the
/// finger (resisting past the mark), an arrow shows behind it, and letting
/// go past the mark replies. Vertical drags are left to the list.
private struct SwipeToReply: ViewModifier {
    let enabled: Bool
    let reply: () -> Void

    @State private var offset: CGFloat = 0
    @State private var armed = false

    private static let mark: CGFloat = 64

    func body(content: Content) -> some View {
        if enabled {
            content
                .offset(x: offset)
                .background(alignment: .leading) {
                    Image(systemName: "arrowshape.turn.up.left.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(armed ? Theme.accent : Theme.secondaryText)
                        .padding(.leading, Theme.phoneGutter)
                        .opacity(min(1, offset / Self.mark))
                        .accessibilityHidden(true)
                }
                .simultaneousGesture(drag)
        } else {
            content
        }
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { value in
                let x = value.translation.width, y = value.translation.height
                // Only a mostly sideways drag to the right.
                guard x > 0, abs(x) > abs(y) * 2 || offset > 0 else { return }
                offset = x < Self.mark ? x : Self.mark + (x - Self.mark) * 0.3
                armed = offset >= Self.mark
            }
            .onEnded { _ in
                if armed { reply() }
                armed = false
                withAnimation(.spring(duration: 0.25, bounce: 0)) { offset = 0 }
            }
    }
}
