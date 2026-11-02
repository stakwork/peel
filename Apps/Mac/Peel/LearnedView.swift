import PeelAgent
import PeelCore
import PeelUI
import SwiftUI

/// "What it learned" (docs/learned.md): a Mac screen of its own, not an app a
/// workspace serves. The same way of grouping a repeated slip into a habit
/// that Hive's Glimmer uses, but on the person's own memory, on this Mac,
/// and only theirs. Opening it runs the check, which saves nothing; nothing
/// is saved until the person approves (`LearnedModel`).
struct LearnedView: View {
    /// Its place among Apps: a built-in, with no workspace.
    static let appName = "what-it-learned"
    /// Its card's and header's words under the title.
    static let source = "On this Mac \u{00B7} only you"
    static let about = "Habits your assistant noticed from the times you corrected it. You decide what it keeps in mind."

    enum Tab: Hashable { case habits, waiting, inUse }

    @Environment(AppModel.self) private var model
    @State private var tab = Tab.habits

    private var learned: LearnedModel { model.macAgent.learned }

    var body: some View {
        let waiting = learned.report.groupings.count + learned.report.habits.count + learned.report.concepts.count
        let live = learned.concepts.filter(\.live)
        VStack(spacing: 0) {
            DetailHeader(title: "What it learned", subtitle: Self.source) {
                Image(systemName: "lightbulb")
                    .font(.system(size: 17))
                    .foregroundStyle(Theme.secondaryText)
                    .frame(width: Theme.AvatarSize.lg, height: Theme.AvatarSize.lg)
            } trailing: {
                IconButton("arrow.clockwise", help: "Check again", working: learned.phase == .checking) {
                    learned.open()
                }
                .disabled(learned.phase == .checking)
            }
            HStack(spacing: Theme.Space.md) {
                SegmentedChoice(selection: $tab, options: [
                    (.habits, "Habits"),
                    (.waiting, waiting == 0 ? "Waiting for you" : "Waiting for you \(waiting)"),
                    (.inUse, "In use"),
                ])
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.Space.xl)
            .padding(.top, Theme.Space.md)
            daily
            if case .unavailable(let words) = learned.phase {
                Callout(.attention, detail: words) { EmptyView() }
                    .padding(.horizontal, Theme.Space.xl)
                    .padding(.top, Theme.Space.md)
            } else if let problem = learned.problem {
                Callout(.attention, detail: problem) { EmptyView() }
                    .padding(.horizontal, Theme.Space.xl)
                    .padding(.top, Theme.Space.md)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.md) {
                    switch tab {
                    case .habits: habits
                    case .waiting: waitingForYou
                    case .inUse: liveConcepts(live)
                    }
                }
                .padding(Theme.Space.xl)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        // Opening the screen runs the check: a dry run, nothing saved.
        .task { learned.open() }
    }

    // MARK: The daily check

    /// Its switch and Run now: strut runs the check on its schedule once the person turns it on.
    /// Opening this screen never does; the check only proposes, never makes anything live.
    @ViewBuilder private var daily: some View {
        if let schedule = learned.schedule {
            HStack(spacing: Theme.Space.md) {
                Toggle("Check every day", isOn: Binding(get: { schedule.enabled }, set: { learned.setDaily($0) }))
                    .toggleStyle(.switch)
                    .disabled(learned.schedulePending)
                Text(schedule.enabled ? schedule.summary : "Off. Runs \(schedule.summary.lowercased()) when on.").muted()
                Spacer(minLength: 0)
                Button("Run now") { learned.runDailyNow() }
                    .buttonStyle(.peel(.outline, size: .sm))
                    .disabled(learned.schedulePending || schedule.running)
            }
            .padding(.horizontal, Theme.Space.xl)
            .padding(.top, Theme.Space.sm)
        }
    }

    // MARK: Habits

    @ViewBuilder private var habits: some View {
        let themes = learned.themes, loose = learned.loose
        if themes.isEmpty && loose.isEmpty {
            EmptyState(learned.phase == .checking ? "Looking at what you corrected…"
                       : "When you say no to your assistant or fix what it did, what it notices shows up here for you to keep or not.",
                       title: "Nothing kept yet")
        }
        ForEach(themes) { theme in
            Card {
                VStack(alignment: .leading, spacing: Theme.Space.sm) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(theme.parent.statement).font(Theme.font(14, .semibold))
                        Spacer(minLength: 0)
                        Badge(Formatting.count(theme.children.count, "example"), .outline)
                    }
                    if let mechanism = theme.parent.mechanism { Text(mechanism).muted() }
                    ForEach(theme.children) { Examples(habit: $0) }
                    HStack {
                        if let concept = theme.concept {
                            Badge(concept.live ? "In use" : "Not in use", concept.live ? .success : .outline)
                        }
                        Spacer(minLength: 0)
                        Button("Take apart") { learned.answer(theme.id) { try await $0.undo(theme: theme.parent) } }
                            .buttonStyle(.peel(.outline, size: .sm))
                            .disabled(learned.working.contains(theme.id))
                    }
                }
                .padding(Theme.Space.md)
            }
        }
        ForEach(loose) { habit in
            Card {
                VStack(alignment: .leading, spacing: Theme.Space.sm) {
                    Text(habit.statement).font(Theme.font(14, .semibold))
                    Examples(habit: habit)
                }
                .padding(Theme.Space.md)
            }
        }
    }

    // MARK: Waiting for you

    @ViewBuilder private var waitingForYou: some View {
        let report = learned.report
        if report.isEmpty {
            EmptyState(learned.phase == .checking ? "Looking at what you corrected…" : "Nothing is waiting for you.",
                       title: learned.phase == .checking ? nil : "All caught up")
        } else {
            Text("Nothing is saved until you approve it.").muted()
        }
        ForEach(report.groupings) { grouping in
            let id = grouping.id
            Waiting(title: "These look like one habit", words: grouping.theme.existing == nil ? grouping.theme.statement
                    : "They fit a habit you already have", detail: grouping.theme.mechanism, working: learned.working.contains(id),
                    approve: { learned.answer(id) { try await $0.approve(grouping: grouping) } },
                    reject: { learned.answer(id) { try await $0.reject(grouping: grouping) } }) {
                ForEach(grouping.leaves) { Examples(habit: $0) }
            }
        }
        ForEach(report.habits) { habit in
            Waiting(title: "A habit it noticed", words: habit.statement, detail: nil, working: learned.working.contains(habit.id),
                    approve: { learned.answer(habit.id) { try await $0.approve(habit: habit) } },
                    reject: { learned.answer(habit.id) { try await $0.reject(habit: habit) } }) {
                Examples(habit: habit)
            }
        }
        ForEach(report.concepts) { concept in
            Waiting(title: "Something to keep in mind", words: concept.name, detail: concept.statement,
                    working: learned.working.contains(concept.id),
                    approve: { learned.answer(concept.id) { try await $0.approve(concept: concept) } },
                    reject: { learned.answer(concept.id) { try await $0.reject(concept: concept) } }) {
                Text("For: \(concept.theme.statement)").muted()
            }
        }
    }

    // MARK: Live

    @ViewBuilder private func liveConcepts(_ live: [PersonalConcept]) -> some View {
        if live.isEmpty {
            EmptyState("What you approve for your assistant to keep in mind shows up here, with Undo.", title: "Nothing in use")
        }
        ForEach(live) { concept in
            Card {
                VStack(alignment: .leading, spacing: Theme.Space.sm) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(concept.name).font(Theme.font(14, .semibold))
                        Spacer(minLength: 0)
                        Badge("In use", .success)
                    }
                    Text(concept.statement).font(Theme.font(13)).foregroundStyle(Theme.secondaryText)
                    if let prior = concept.prior { Text("Before: \(prior.statement)").muted() }
                    HStack {
                        Spacer(minLength: 0)
                        Button("Undo") { learned.answer(concept.id) { try await $0.undo(concept: concept) } }
                            .buttonStyle(.peel(.outline, size: .sm))
                            .disabled(learned.working.contains(concept.id))
                    }
                }
                .padding(Theme.Space.md)
            }
        }
    }
}

/// What showed a habit: the words from your own side of the chat with your assistant, trimmed.
private struct Examples: View {
    let habit: PersonalCause

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(habit.evidence.enumerated()), id: \.offset) { _, evidence in
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.sm) {
                    Text("\u{201C}\(evidence.excerpt)\u{201D}")
                        .font(Theme.font(13))
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(2)
                    Text(evidence.turnAt.map { $0.formatted(.relative(presentation: .named)) } ?? "").muted()
                }
            }
        }
    }
}

/// One thing waiting on the person: its words, what showed it, Approve and Reject.
private struct Waiting<Content: View>: View {
    let title: String
    let words: String
    let detail: String?
    let working: Bool
    let approve: () -> Void
    let reject: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                HStack {
                    Badge(title, .attention)
                    Spacer(minLength: 0)
                }
                Text(words).font(Theme.font(14, .semibold))
                if let detail { Text(detail).font(Theme.font(13)).foregroundStyle(Theme.secondaryText) }
                content
                HStack(spacing: Theme.Space.sm) {
                    Spacer(minLength: 0)
                    Button("Reject", action: reject).buttonStyle(.peel(.outline, size: .sm))
                    Button("Approve", action: approve).buttonStyle(.peel(.primary, size: .sm))
                }
                .disabled(working)
            }
            .padding(Theme.Space.md)
        }
    }
}

/// Apps' card for it: next to the apps, with the source in the foot.
struct LearnedCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button {
            model.destination = .app(peer: nil, name: LearnedView.appName)
        } label: {
            Card {
                VStack(alignment: .leading, spacing: Theme.Space.sm) {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "lightbulb")
                            .font(.system(size: 15))
                            .foregroundStyle(Theme.secondaryText)
                            .frame(width: Theme.AvatarSize.md, height: Theme.AvatarSize.md)
                            .background(Theme.input, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                        Text("What it learned").font(Theme.font(14, .semibold)).frame(minHeight: Theme.AvatarSize.md)
                    }
                    Text(LearnedView.about)
                        .font(Theme.font(13))
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(3, reservesSpace: true)
                    Spacer(minLength: 0)
                    Text(LearnedView.source)
                        .font(Theme.font(12))
                        .foregroundStyle(Theme.tertiaryText)
                        .lineLimit(1)
                        .frame(height: 24, alignment: .leading)
                }
                .padding(Theme.Space.md)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(LearnedView.about)
    }

    /// Whether a search for `query` finds it.
    static func matches(_ query: String) -> Bool {
        let words = query.lowercased().split(separator: " ")
        let text = "what it learned habits assistant on this mac only you"
        return words.allSatisfy { text.contains($0) }
    }
}
