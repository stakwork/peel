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

    var body: some View {
        let composer = ComposerID.thread(thread)
        let canPost = model.tribes[thread.chat]?.canPost != false
        VStack(spacing: 0) {
            header
            Theme.divider.frame(height: 1)
            Group {
                if model.thread != nil, model.openThread == thread {
                    MessageList(rows: model.threadRows, composer: composer)
                        .id(thread)
                } else {
                    Color.clear
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
