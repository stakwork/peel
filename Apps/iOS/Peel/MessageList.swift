import PeelCore
import PeelUI
import SwiftUI

/// A conversation's or a thread's rows, newest at the bottom. Where it goes
/// is `ChatListController`'s, as on the Mac: it opens at a message asked
/// for, else where it last stood (`AppModel.anchor(of:)`), else at "New
/// messages", else at its newest, and is shown only once it is there.
/// Others' messages take it down only while it follows the newest (yours
/// always do); scrolled up, what arrives below is counted on the pill. Near
/// the top a chat asks the model for an older page. The table under it is
/// `MessageTable`, which reaches under the header and the composer and
/// keeps their room (and the keyboard's) as its content's insets.
struct MessageList: View {
    @Environment(AppModel.self) private var model
    let rows: [ChatRow]
    let composer: ComposerID
    /// False while its screen goes (popped, or under another tab) or waits
    /// for a reload, showing the rows it last had: it keeps its place and
    /// tells the model nothing.
    var live = true

    @State private var link = PhoneListLink()
    /// On the screen: the room between the bars (above the keyboard), and
    /// all the table covers, under them. The bars' room is the difference.
    @State private var safe = CGRect.zero
    @State private var full = CGRect.zero

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.clear
                .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { safe = $0 }
            MessageTable(
                model: model, rows: rows, composer: composer, live: live, focus: live ? focusTarget : nil,
                // A thread's list always ends at its newest; the chat's unless a
                // jump's window stops short of it.
                reachesNewest: composer.thread != nil || model.timelineReachesNewest,
                hasOlder: composer.thread == nil && model.mayHaveOlder,
                insets: barsRoom, link: link
            )
            .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { full = $0 }
            .ignoresSafeArea(.all, edges: .vertical)
            if let controller = link.controller {
                JumpPill(controller: controller)
            }
        }
    }

    /// The header's room above the rows and the composer's (and the
    /// keyboard's) below them, as the table's content insets.
    private var barsRoom: EdgeInsets {
        guard !safe.isEmpty, !full.isEmpty else { return EdgeInsets() }
        return EdgeInsets(top: max(0, safe.minY - full.minY), leading: 0,
                          bottom: max(0, full.maxY - safe.maxY), trailing: 0)
    }

    /// The model's focused message, when it belongs in this list.
    private var focusTarget: FocusTarget? {
        guard let target = model.focus, target.message.chat == composer.chat,
              composer.thread.map({ $0 == target.message.threadRoot }) ?? !target.inThread,
              !rows.isEmpty else { return nil }
        return target
    }
}

/// The controller's pill over the list: an arrow, "N new messages", or the
/// way back to the newest from a jump's window.
private struct JumpPill: View {
    let controller: ChatListController

    var body: some View {
        let pill = controller.pill
        ZStack {
            if let pill {
                JumpToNewest(count: pill.count) { controller.jumpToPresent() }
                    .padding(.bottom, Theme.Space.sm)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .animation(.easeOut(duration: 0.2), value: pill == nil)
    }
}

private extension ListPill {
    /// The messages below it counts, 0 for none.
    var count: Int {
        if case .count(let count) = self { count } else { 0 }
    }
}

/// Over the composer: once messages have come in below, a blue "3 new
/// messages" pill; scrolled up with nothing new, a round glass arrow.
private struct JumpToNewest: View {
    let count: Int
    let action: () -> Void

    var body: some View {
        if count > 0 {
            let words = Formatting.count(count, .newMessage, shown: Badge.text(count))
            Button(action: action) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down").font(.system(size: 13, weight: .semibold))
                    Text(words).phoneFont(PhoneFont.secondary.weight(.semibold)).monospacedDigit()
                }
                .foregroundStyle(Theme.buttonText)
                .padding(.horizontal, 14)
                .frame(minHeight: 36)
                .background(Theme.button, in: Capsule())
                .shadow(color: Theme.menuShadow, radius: 10, y: 4)
                .frame(minHeight: Theme.touchTarget)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Jump to newest, \(words)")
        } else {
            GlassButton("arrow.down", label: String(localized: "Jump to newest"), action: action)
        }
    }
}
