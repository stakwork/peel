import PeelCore
import PeelUI
import SwiftUI

/// Past Talk sessions for one workspace, newest first. Reachable from the
/// TalkRow context menu in AppsScreen. Each row shows date/time and a
/// preview of the first line; tapping opens the full saved transcript.
/// A toolbar button starts a new conversation; each row also offers Resume.
struct TalkHistoryScreen: View {
    let home: TalkHome
    @Environment(AppModel.self) private var model
    @State private var sessions: [TalkSavedSession] = []

    var body: some View {
        List {
            ForEach(sessions) { session in
                NavigationLink(destination: TalkHistorySessionScreen(session: session, home: home)) {
                    HistoryRow(session: session)
                }
                .swipeActions(edge: .trailing) {
                    Button("Resume", systemImage: "mic") {
                        model.talk.talk(to: home)
                    }
                    .tint(Theme.accent)
                }
            }
        }
        .phoneList()
        .navigationTitle("Conversations")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("New conversation", systemImage: "mic") {
                    model.talk.talk(to: home)
                }
            }
        }
        .overlay {
            if sessions.isEmpty {
                ContentUnavailableView {
                    Label("No conversations yet", systemImage: "clock.arrow.circlepath")
                } description: {
                    Text("Past conversations with Jamie on \(home.name) will appear here after a call ends.")
                }
            }
        }
        .onAppear { sessions = TalkHistoryStore.sessions(for: home.id) }
    }
}

/// One row in the history list: date/time and a preview of the first line.
private struct HistoryRow: View {
    let session: TalkSavedSession

    private static let dateStyle = Date.FormatStyle()
        .month(.abbreviated).day().year(.twoDigits).hour().minute()

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(session.date.formatted(Self.dateStyle))
                .phoneFont(.row)
                .foregroundStyle(Theme.text)
            if let preview = session.preview {
                Text(preview)
                    .phoneFont(.secondary)
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(2)
            } else {
                Text("No transcript")
                    .phoneFont(.secondary)
                    .foregroundStyle(Theme.tertiaryText)
            }
        }
        .padding(.vertical, 4)
    }
}

/// The full saved transcript for one session.
struct TalkHistorySessionScreen: View {
    let session: TalkSavedSession
    let home: TalkHome
    @Environment(AppModel.self) private var model

    private static let titleStyle = Date.FormatStyle()
        .month(.abbreviated).day().hour().minute()

    var body: some View {
        List {
            ForEach(session.lines) { line in
                VStack(alignment: .leading, spacing: 2) {
                    Text(line.speaker == .you ? "You" : "Jamie")
                        .phoneFont(.secondary)
                        .foregroundStyle(Theme.secondaryText)
                    Text(line.text)
                        .phoneFont(.row)
                        .foregroundStyle(Theme.text)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                .padding(.vertical, 2)
            }
        }
        .phoneList()
        .navigationTitle(session.date.formatted(Self.titleStyle))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Resume", systemImage: "mic") {
                    model.talk.talk(to: home)
                }
            }
        }
    }
}
