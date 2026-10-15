import PeelCore
import PeelUI
import SwiftUI

/// A thread over its chat (docs/design/iphone.md, screen 3): a sheet at the
/// large detent with a grabber; "Thread" and the chat's name, a glass close
/// button; the original, "4 replies" on a hairline, the replies
/// (`AppModel.threadRows`), and its own composer, placeholder "Reply". No
/// "Also send to channel". Its draft is the model's, kept per thread when
/// the sheet goes (`drafts[.thread(…)]`).
struct ThreadSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let thread: ThreadRef
    let conversation: Conversation?
    /// Where its list opens, worked out once, as its rows first load.
    @State private var start: MessageList.Start?

    private var loaded: Bool { model.thread != nil && model.openThread == thread }

    var body: some View {
        let composer = ComposerID.thread(thread)
        let canPost = model.tribes[thread.chat]?.canPost != false
        VStack(spacing: 0) {
            header
            Theme.divider.frame(height: 1)
            Group {
                // Open, with its rows, until the sheet has gone
                // (`PhoneRouter.threadDismissed`).
                if let start, loaded {
                    MessageList(rows: model.threadRows, composer: composer, start: start)
                        .id(thread)
                } else {
                    // Until its rows load, or if they never do: the sheet
                    // closes as ever.
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onChange(of: loaded, initial: true) { _, loaded in
                if loaded, start == nil { start = MessageList.start(of: composer, rows: model.threadRows, in: model) }
            }
            .floatingBar(.bottom) {
                VStack(spacing: Theme.Space.sm) {
                    // The chat's notice shows here too: the chat is covered.
                    if let notice = model.conversationNotices[thread.chat] {
                        NoticeBar(text: notice) { model.dismissNotice(in: thread.chat) }
                    }
                    if canPost {
                        PhoneComposer(
                            composer: composer, placeholder: "Reply",
                            loadMentionable: conversation?.isTribe == true ? model.mentionLoader(thread.chat) : nil
                        )
                    }
                }
            }
        }
        .background(Theme.background)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationBackground(Theme.background)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: Theme.Space.md) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Thread")
                    .phoneFont(.headline)
                    .foregroundStyle(Theme.text)
                if let conversation {
                    Text(conversation.title)
                        .phoneFont(.secondary)
                        .foregroundStyle(Theme.tertiaryText)
                        .lineLimit(1)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            GlassButton("xmark", label: "Close thread") { dismiss() }
        }
        .padding(.horizontal, Theme.phoneGutter)
        .padding(.top, 20)
        .padding(.bottom, Theme.Space.md)
    }
}
