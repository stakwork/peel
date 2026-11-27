import PeelAgent
import PeelCore
import PeelUI
import SwiftUI

/// The automations (`docs/phases/12-automations.md`), read from strut, as a
/// column beside the rail (Tom, 2026-11-27; the board's "Automations and
/// Segments"), as Payments' history is: yours (one-offs still to come, then
/// recurring ones, then one-offs done; made by asking the agent, so only
/// listed here), then the system ones strut ships and runs alone
/// (`docs/system-automations.md`), each with its switch. Beside it the one
/// picked, or an overview. ⌃⌘S puts the column away. Until the agent and
/// strut are set up, the page says what to set up instead.
struct AutomationsView: View {
    @Environment(AppModel.self) private var model
    /// MainView's: where the page's header starts when it starts at the rail.
    @Environment(\.headerLeadingInset) private var pageInset
    /// The chat list's width, so the column's edge holds still going between them.
    @AppStorage("sidebarWidth") private var columnWidth: Double = 260
    /// The column put away (⌃⌘S, `ColumnToggle`): the page full width.
    @AppStorage("automationsListHidden") private var listHidden = false

    var body: some View {
        let state = model.automations
        Group {
            if model.agent?.connection == nil {
                alone {
                    EmptyState(String(localized: "It runs your automations."), title: String(localized: "Set up Peel's agent")) {
                        AgentConnectButton(source: .automations, title: String(localized: "Set up"), variant: .primary)
                    }
                }
            } else if model.brain?.moved != nil {
                alone {
                    EmptyState(String(localized: "They run on your home server, which this Mac doesn't read."),
                               title: String(localized: "On your home server"))
                }
            } else if model.automationsClient == nil {
                alone { EmptyState(model.agentSetUp.line, title: String(localized: "Peel's strut isn't running")) }
            } else {
                HStack(spacing: 0) {
                    if !listHidden {
                        VStack(spacing: 0) {
                            ColumnHeader(title: String(localized: "Automations")) {
                                IconButton("plus", help: String(localized: "Ask Peel for a new one"), size: .sm) {
                                    model.destination = .agent
                                }
                            }
                            list(state)
                        }
                        .frame(width: columnWidth)
                        .background(Theme.sidebar)
                        PaneDivider(width: $columnWidth, range: 220...420, standard: 260, growsTo: .trailing)
                    }
                    Group {
                        if let picked = state.shown.first(where: { $0.id == model.openedAutomation }) {
                            AutomationPage(automation: picked, running: state.isRunning(picked))
                                .id(picked.id)
                        } else {
                            AutomationsOverview(state: state)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .environment(\.headerLeadingInset, listHidden ? pageInset : 0)
                }
            }
        }
        .task(id: model.automations.anyRunning) {
            // strut fires on its own: keep the list current while it shows,
            // and close to live while a run is going (or Run now is asking
            // for one): a run starting or ending starts it again.
            while !Task.isCancelled {
                await model.refreshAutomations()
                try? await Task.sleep(for: .seconds(model.automations.anyRunning ? 3 : 30))
            }
        }
        .onExitCommand { model.openedAutomation = nil }
    }

    /// The page with no column: what to set up first.
    private func alone(@ViewBuilder _ content: () -> some View) -> some View {
        VStack(spacing: 0) {
            DetailHeader(title: String(localized: "Automations"))
            content()
        }
    }

    private func list(_ state: AutomationsState) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                if state.loaded, state.yours.isEmpty {
                    Text("Ask Peel to remind you, or to do something on a schedule.")
                        .muted()
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 8)
                        .padding(.vertical, Theme.Space.sm)
                }
                group(String(localized: "Upcoming"), state.upcoming)
                group(String(localized: "Recurring"), state.recurring)
                group(String(localized: "Done"), state.done)
                group(String(localized: "System"), state.system)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, Theme.Space.sm)
        }
    }

    @ViewBuilder
    private func group(_ title: String, _ automations: [Automation]) -> some View {
        if !automations.isEmpty {
            SectionHeader(title)
                .padding(.horizontal, 8)
                .padding(.top, Theme.Space.md)
                .padding(.bottom, 4)
            ForEach(automations) { automation in
                AutomationRow(automation: automation, running: model.automations.isRunning(automation),
                              selected: model.openedAutomation == automation.id) {
                    model.openedAutomation = model.openedAutomation == automation.id ? nil : automation.id
                }
            }
        }
    }
}

/// strut could not be read, or its clock looks stopped: over what is beside the column.
private struct AutomationNotices: View {
    @Environment(AppModel.self) private var model
    let state: AutomationsState

    @ViewBuilder var body: some View {
        if let problem = state.problem {
            Callout(.attention, detail: problem, dismiss: { model.automations.problem = nil })
        } else if state.schedulerLooksOff() {
            Callout(.attention, String(localized: "Scheduled runs are paused"), detail: String(localized: "Run now still works.")) {
                EmptyView()
            }
        }
    }
}

/// Beside the column with none picked: how many there are, what failed,
/// what runs next, and the way to make one (asking Peel).
private struct AutomationsOverview: View {
    @Environment(AppModel.self) private var model
    let state: AutomationsState

    var body: some View {
        let next = state.yours.filter { $0.enabled && $0.nextRun != nil }.min { $0.nextRun! < $1.nextRun! }
        VStack(spacing: 0) {
            DetailHeader(title: String(localized: "Overview"))
            ScrollView {
                VStack(spacing: Theme.Space.lg) {
                    AutomationNotices(state: state)
                    HStack(spacing: 46) {
                        count(state.yours.count, String(localized: "yours"), attention: false)
                        count(state.system.filter(\.enabled).count, String(localized: "system on"), attention: false)
                        count(state.failed, String(localized: "didn't finish"), attention: state.failed > 0)
                    }
                    .padding(.top, 50)
                    if let next, let at = next.nextRun {
                        Text("Next: \(next.name), \(Formatting.dateAndTime(at))")
                            .font(Theme.font(13))
                            .foregroundStyle(Theme.secondaryText)
                    }
                    VStack(spacing: Theme.Space.sm) {
                        Button("Ask Peel for a new one") { model.destination = .agent }
                            .buttonStyle(.peel(.primary))
                        Text("Made by asking Peel: “every Monday at 9, send me…”").muted()
                    }
                    .padding(.top, Theme.Space.sm)
                }
                .frame(maxWidth: 520)
                .padding(.horizontal, Theme.Space.xl)
                .padding(.bottom, Theme.Space.xl)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func count(_ value: Int, _ label: String, attention: Bool) -> some View {
        VStack(spacing: 2) {
            Text(value, format: .number)
                .font(Theme.font(30, .bold))
                .monospacedDigit()
                .foregroundStyle(attention ? Theme.attention : Theme.text)
            Text(label)
                .font(Theme.font(12))
                .foregroundStyle(Theme.secondaryText)
        }
    }
}

/// An automation picked in the column, beside it: when it runs and how it
/// stands, then what it does and its runs. The person's own: its prompt,
/// editable, Pause and Run now, Delete under •••; a system one: its
/// workflow's description, its switch and Run now.
private struct AutomationPage: View {
    @Environment(AppModel.self) private var model
    let automation: Automation
    let running: Bool

    var body: some View {
        VStack(spacing: 0) {
            DetailHeader(title: automation.name, leading: { EmptyView() }) {
                if automation.isSystem {
                    PeelSwitch(isOn: enabled)
                        .accessibilityRepresentation { Toggle(automation.name, isOn: enabled) }
                } else {
                    MenuButton(systemImage: "ellipsis", help: String(localized: "More"), source: "automation-\(automation.id)") {
                        [.destructive("Delete", systemImage: "trash", confirm: String(localized: "Delete \u{201C}\(automation.name)\u{201D}")) {
                            model.openedAutomation = nil
                            Task { await model.deleteAutomation(automation) }
                        }]
                    }
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.lg) {
                    AutomationNotices(state: model.automations)
                    HStack(spacing: Theme.Space.md) {
                        Text(automation.summary).muted()
                        AutomationStatus(automation: automation, running: running)
                    }
                    if automation.isSystem {
                        VStack(alignment: .leading, spacing: Theme.Space.md) {
                            if let about = automation.about {
                                Text(about)
                                    .font(Theme.font(13))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            if let connection = model.agent?.connection {
                                Text("Runs on your connected model (\(connection.provider.modelName(connection.model))). Sends parts of your memory to \(connection.provider.name).")
                                    .muted()
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Button("Run now") { Task { await model.runAutomationNow(automation) } }
                                .buttonStyle(.peel(.outline, size: .sm))
                                .disabled(running)
                            AutomationRuns(automation: automation)
                        }
                        .task(id: automation.lastRun) { await model.refreshRuns(of: automation) }
                    } else {
                        AutomationDetail(automation: automation, running: running)
                    }
                }
                .frame(maxWidth: 640, alignment: .leading)
                .padding(.horizontal, Theme.Space.xl)
                .padding(.vertical, Theme.Space.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var enabled: Binding<Bool> {
        Binding(get: { automation.enabled }, set: { on in Task { await model.setAutomation(automation, enabled: on) } })
    }
}

/// One automation in the column: a dot for how it stands, its name, its
/// schedule and when it runs next or how it last ran; a system one's switch.
private struct AutomationRow: View {
    @Environment(AppModel.self) private var model
    let automation: Automation
    let running: Bool
    let selected: Bool
    let select: () -> Void

    var body: some View {
        ListRow(size: .md, selected: selected, action: select) {
            Circle()
                .fill(dot)
                .frame(width: 8, height: 8)
                .frame(width: 12)
                .accessibilityHidden(true)
        } title: {
            // As a chat's row: the name, and how it stands alone at the top right.
            HStack(spacing: 6) {
                Text(automation.name)
                    .font(Theme.font(13, .medium))
                    .foregroundStyle(automation.enabled ? Theme.text : Theme.secondaryText)
                    .lineLimit(1)
                Spacer(minLength: 4)
                AutomationStatus(automation: automation, running: running, compact: true)
                    .lineLimit(1)
                    .fixedSize()
            }
        } detail: {
            Text(automation.summary).muted().lineLimit(1)
        } trailing: {
            if automation.isSystem {
                PeelSwitch(isOn: enabled)
                    .accessibilityRepresentation { Toggle(automation.name, isOn: enabled) }
            }
        }
        .peelMenu { automation.isSystem ? [] : menu }
    }

    /// Red when it didn't finish, the accent while it runs, grey while off,
    /// green otherwise.
    private var dot: Color {
        if automation.lastRunFailed { return Theme.attention }
        if running { return Theme.accent }
        return automation.enabled ? Theme.confirmed : Theme.tertiaryText
    }

    private var enabled: Binding<Bool> {
        Binding(get: { automation.enabled }, set: { on in Task { await model.setAutomation(automation, enabled: on) } })
    }

    private var menu: [MenuEntry] {
        [
            .button(automation.enabled ? String(localized: "Pause") : String(localized: "Resume"), systemImage: automation.enabled ? "pause" : "play") {
                Task { await model.setAutomation(automation, enabled: !automation.enabled) }
            },
            .button("Run now", systemImage: "play.circle") {
                // Picked, so the run shows beside it.
                model.openedAutomation = automation.id
                Task { await model.runAutomationNow(automation) }
            },
            .divider,
            .destructive("Delete", systemImage: "trash", confirm: String(localized: "Delete \u{201C}\(automation.name)\u{201D}")) {
                if model.openedAutomation == automation.id { model.openedAutomation = nil }
                Task { await model.deleteAutomation(automation) }
            },
        ]
    }
}

/// The person's own automation, picked: its prompt, editable; its actions; its runs.
private struct AutomationDetail: View {
    @Environment(AppModel.self) private var model
    let automation: Automation
    let running: Bool
    @State private var editing: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            if let draft = editing {
                FormTextField(label: String(localized: "Prompt"), text: Binding(get: { draft }, set: { editing = $0 }), axis: .vertical,
                              focusOnAppear: true)
                HStack(spacing: Theme.Space.sm) {
                    Button("Save") {
                        let prompt = draft
                        editing = nil
                        Task { await model.updateAutomationPrompt(automation, to: prompt) }
                    }
                    .buttonStyle(.peel(.primary, size: .sm))
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draft == automation.prompt)
                    Button("Cancel") { editing = nil }.buttonStyle(.peel(.outline, size: .sm))
                }
            } else {
                Text(automation.prompt)
                    .font(Theme.font(13))
                    .foregroundStyle(Theme.text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: Theme.Space.sm) {
                    Button("Edit prompt") { editing = automation.prompt }.buttonStyle(.peel(.outline, size: .sm))
                    Button(automation.enabled ? String(localized: "Pause") : String(localized: "Resume")) {
                        Task { await model.setAutomation(automation, enabled: !automation.enabled) }
                    }
                    .buttonStyle(.peel(.outline, size: .sm))
                    Button("Run now") { Task { await model.runAutomationNow(automation) } }
                        .buttonStyle(.peel(.outline, size: .sm))
                        .disabled(running)
                }
                Text("To change when it runs, ask the agent.").muted()
            }
            AutomationRuns(automation: automation)
        }
        .task(id: automation.lastRun) { await model.refreshRuns(of: automation) }
    }
}

/// Where an automation stands, at the end of its row: when it runs next or
/// why it will not, a column of times; a system automation's, how it last
/// ran (its switch says whether it is on).
private struct AutomationStatus: View {
    let automation: Automation
    /// strut says it is, or Run now is asking for it.
    let running: Bool
    /// In the column: its times short ("16:00", "Fri 16:00", "2 Oct").
    var compact = false

    var body: some View {
        let system = automation.isSystem
        let (text, attention): (String, Bool) =
            if running { (String(localized: "Running…"), false) }
            else if !automation.enabled, !system { (String(localized: "Paused"), false) }
            else if automation.lastRunFailed { (String(localized: "Didn't finish"), true) }
            else if automation.isMissed, !system { (String(localized: "Missed"), false) }
            else if let next = automation.nextRun, !system { (when(next), false) }
            else if let last = automation.lastRun?.startedAt { (String(localized: "Ran \(when(last))"), false) }
            else { ("", false) }
        Text(text)
            .font(Theme.font(11))
            .monospacedDigit()
            .foregroundStyle(attention ? Theme.attention : Theme.secondaryText)
    }

    private func when(_ date: Date) -> String {
        compact ? Self.short(date) : Formatting.dateAndTime(date)
    }

    /// "16:00" the same day, "Fri 16:00" within a week either way, else "2 Oct".
    static func short(_ date: Date, now: Date = .now) -> String {
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) { return Formatting.time(date) }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? .max
        if abs(days) < 7 { return date.formatted(.dateTime.weekday(.abbreviated).hour().minute()) }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }
}

/// An automation's runs, newest first, as its opened row read them: what
/// each said, and for a system automation's what it cost.
private struct AutomationRuns: View {
    @Environment(AppModel.self) private var model
    let automation: Automation

    @ViewBuilder var body: some View {
        let runs = model.automations.runs[automation.id] ?? []
        // strut's newest run, going, before its runs list has it.
        let going = automation.lastRun.flatMap { last in
            last.status == "running" && !runs.contains { $0.id == last.runId } ? last : nil
        }
        if !runs.isEmpty || going != nil {
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                SectionHeader(String(localized: "Runs"))
                if let going {
                    row(going.startedAt) { Text("Running…").muted() }
                }
                ForEach(runs) { run in
                    row(run.startedAt) { outcome(run) }
                }
            }
        }
    }

    private func row(_ at: Date?, @ViewBuilder _ outcome: () -> some View) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.md) {
            Text(at.map { Formatting.dateAndTime($0) } ?? "")
                .font(Theme.font(11))
                .monospacedDigit()
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 110, alignment: .leading)
            outcome()
        }
    }

    @ViewBuilder
    private func outcome(_ run: AutomationRunRecord) -> some View {
        switch (run.status, run.reply?.status) {
        case ("success", nil) where run.text != nil || run.nothing || automation.isSystem:
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                if let text = run.text {
                    // strut's agent wrote it, not Peel's: its links open nothing in Peel.
                    MessageText(text: text, chat: nil, agentLinks: false)
                } else {
                    Text(automation.isSystem ? String(localized: "Finished") : String(localized: "Nothing to report")).muted()
                }
                if let cost = run.cost {
                    Text(cost.formatted(.currency(code: "USD").precision(.fractionLength(2...4)))).muted()
                }
            }
        case (_, .delivered?):
            MessageText(text: run.reply?.text ?? "", chat: nil, agentLinks: true)
        case (_, .nothing?):
            Text("Nothing to report").muted()
        case ("running", _):
            Text("Running…").muted()
        default:
            Text(run.failure)
                .font(Theme.font(12))
                .foregroundStyle(Theme.attention)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
