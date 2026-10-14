import PeelAgent
import PeelCore
import PeelUI
import SwiftUI

/// The automations (`docs/phases/12-automations.md`), read from strut, in
/// two tabs. Yours: what the agent runs on its own, one-offs still to come,
/// then recurring ones, then one-offs done; made by asking the agent, so
/// the page only lists them. System: the ones strut ships and runs alone
/// (`docs/system-automations.md`), each turned on or off here. Until the
/// agent and strut are set up, it says what to set up instead.
struct AutomationsView: View {
    enum Tab: Hashable { case yours, system }

    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let state = model.automations
        VStack(spacing: 0) {
            DetailHeader(title: "Automations")
            if model.agent?.connection == nil {
                EmptyState("It runs your automations.", title: "Set up Peel's agent") {
                    AgentConnectButton(source: .automations, title: "Set up", variant: .primary)
                }
            } else if model.automationsClient == nil {
                EmptyState("It keeps the schedule.", title: "Connect strut") {
                    Button("Open Account") { model.openAgentSettings() }.buttonStyle(.peel(.primary))
                }
            } else {
                SegmentedChoice(selection: $model.automationsTab, options: [(.yours, "Yours"), (.system, "System")])
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Theme.Space.lg)
                    .padding(.top, Theme.Space.md)
                switch model.automationsTab {
                case .yours: yours(state)
                case .system: system(state)
                }
            }
        }
        .task {
            // strut fires on its own: keep the list current while it shows,
            // and close to live while a run is going.
            while !Task.isCancelled {
                await model.refreshAutomations()
                try? await Task.sleep(for: .seconds(model.automations.list.contains(where: \.running) ? 3 : 30))
            }
        }
    }

    @ViewBuilder
    private func yours(_ state: AutomationsState) -> some View {
        if state.loaded, state.yours.isEmpty, state.problem == nil {
            EmptyState("Ask Peel to remind you, or to do something on a schedule.", title: "No automations") {
                Button("Ask Peel") { model.destination = .agent }.buttonStyle(.peel(.outline))
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.lg) {
                    notices(state)
                    group("Upcoming", state.upcoming)
                    group("Recurring", state.recurring)
                    group("Done", state.done)
                }
                .padding(Theme.Space.lg)
            }
        }
    }

    @ViewBuilder
    private func system(_ state: AutomationsState) -> some View {
        if state.loaded, state.system.isEmpty, state.problem == nil {
            EmptyState("This strut ships none. A newer one will.", title: "No system automations")
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.lg) {
                    notices(state)
                    VStack(alignment: .leading, spacing: 2) {
                        if let connection = model.agent?.connection {
                            Text("Runs on your connected model (\(connection.provider.modelName(connection.model))). "
                                + "Sends parts of your memory to \(connection.provider.name).")
                                .muted()
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, Theme.Space.sm)
                                .padding(.bottom, Theme.Space.sm)
                        }
                        ForEach(state.system) { automation in
                            SystemAutomationRow(automation: automation, expanded: model.openedAutomation == automation.id) {
                                model.openedAutomation = model.openedAutomation == automation.id ? nil : automation.id
                            }
                        }
                    }
                }
                .padding(Theme.Space.lg)
            }
        }
    }

    @ViewBuilder
    private func notices(_ state: AutomationsState) -> some View {
        if let problem = state.problem {
            Callout(.attention, detail: problem, dismiss: { model.automations.problem = nil })
        } else if state.schedulerLooksOff() {
            Callout(.attention, "Scheduled runs are paused", detail: "Run now still works.") {
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private func group(_ title: String, _ automations: [Automation]) -> some View {
        if !automations.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                SectionHeader(title).padding(.horizontal, Theme.Space.sm).padding(.bottom, Theme.Space.xs)
                ForEach(automations) { automation in
                    AutomationRow(automation: automation, expanded: model.openedAutomation == automation.id) {
                        model.openedAutomation = model.openedAutomation == automation.id ? nil : automation.id
                    }
                }
            }
        }
    }
}

/// One automation: its name and schedule, and when it runs next or how it
/// last ran; opened, what it does and what it said.
private struct AutomationRow: View {
    @Environment(AppModel.self) private var model
    let automation: Automation
    let expanded: Bool
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ListRow(size: .md, selected: expanded, action: toggle) {
                Image(systemName: automation.isOnce ? "alarm" : "repeat")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondaryText)
                    .frame(width: 20)
            } title: {
                Text(automation.name)
                    .font(Theme.font(13, .medium))
                    .foregroundStyle(automation.enabled ? Theme.text : Theme.secondaryText)
            } detail: {
                Text(automation.summary).muted()
            } trailing: {
                AutomationStatus(automation: automation)
            }
            .peelMenu { menu }
            if expanded {
                AutomationDetail(automation: automation)
                    .padding(.leading, 44)
                    .padding(.trailing, Theme.Space.md)
                    .padding(.vertical, Theme.Space.sm)
            }
        }
    }


    private var menu: [MenuEntry] {
        [
            .button(automation.enabled ? "Pause" : "Resume", systemImage: automation.enabled ? "pause" : "play") {
                Task { await model.setAutomation(automation, enabled: !automation.enabled) }
            },
            .button("Run now", systemImage: "play.circle") { Task { await model.runAutomationNow(automation) } },
            .divider,
            .destructive("Delete", systemImage: "trash", confirm: "Delete \u{201C}\(automation.name)\u{201D}") {
                Task { await model.deleteAutomation(automation) }
            },
        ]
    }
}

/// An opened automation: its prompt, editable; its actions; its runs.
private struct AutomationDetail: View {
    @Environment(AppModel.self) private var model
    let automation: Automation
    @State private var editing: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            if let draft = editing {
                FormTextField(label: "Prompt", text: Binding(get: { draft }, set: { editing = $0 }), axis: .vertical,
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
                    Button(automation.enabled ? "Pause" : "Resume") {
                        Task { await model.setAutomation(automation, enabled: !automation.enabled) }
                    }
                    .buttonStyle(.peel(.outline, size: .sm))
                    Button("Run now") { Task { await model.runAutomationNow(automation) } }
                        .buttonStyle(.peel(.outline, size: .sm))
                        .disabled(automation.running)
                }
                Text("To change when it runs, ask the agent.").muted()
            }
            AutomationRuns(automation: automation)
        }
        .task(id: automation.lastRun) { await model.refreshRuns(of: automation) }
    }
}

/// A system automation: its name and its workflow's description, how it
/// last ran and its switch; opened, when it runs, Run now and its runs. Its
/// prompt is the workflow's, edited in strut, and it is never deleted.
private struct SystemAutomationRow: View {
    @Environment(AppModel.self) private var model
    let automation: Automation
    let expanded: Bool
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ListRow(size: .md, selected: expanded, action: toggle) {
                Image(systemName: "gearshape")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondaryText)
                    .frame(width: 20)
            } title: {
                Text(automation.name)
                    .font(Theme.font(13, .medium))
                    .foregroundStyle(automation.enabled ? Theme.text : Theme.secondaryText)
            } detail: {
                Text(automation.about ?? automation.summary).muted()
            } trailing: {
                HStack(spacing: Theme.Space.md) {
                    AutomationStatus(automation: automation)
                    PeelSwitch(isOn: enabled)
                        .accessibilityRepresentation { Toggle(automation.name, isOn: enabled) }
                }
            }
            if expanded {
                VStack(alignment: .leading, spacing: Theme.Space.md) {
                    Text(automation.summary)
                        .font(Theme.font(13))
                        .foregroundStyle(Theme.text)
                    Button("Run now") { Task { await model.runAutomationNow(automation) } }
                        .buttonStyle(.peel(.outline, size: .sm))
                        .disabled(automation.running)
                    AutomationRuns(automation: automation)
                }
                .task(id: automation.lastRun) { await model.refreshRuns(of: automation) }
                .padding(.leading, 44)
                .padding(.trailing, Theme.Space.md)
                .padding(.vertical, Theme.Space.sm)
            }
        }
    }

    private var enabled: Binding<Bool> {
        Binding(get: { automation.enabled }, set: { on in Task { await model.setAutomation(automation, enabled: on) } })
    }
}

/// Where an automation stands, at the end of its row: when it runs next or
/// why it will not, a column of times; a system automation's, how it last
/// ran (its switch says whether it is on).
private struct AutomationStatus: View {
    let automation: Automation

    var body: some View {
        let system = automation.isSystem
        let (text, attention): (String, Bool) =
            if automation.running { ("Running…", false) }
            else if !automation.enabled, !system { ("Paused", false) }
            else if automation.lastRunFailed { ("Didn't finish", true) }
            else if automation.isMissed, !system { ("Missed", false) }
            else if let next = automation.nextRun, !system { (Formatting.dateAndTime(next), false) }
            else if let last = automation.lastRun?.startedAt { ("Ran " + Formatting.dateAndTime(last), false) }
            else { ("", false) }
        Text(text)
            .font(Theme.font(11))
            .monospacedDigit()
            .foregroundStyle(attention ? Theme.attention : Theme.secondaryText)
    }
}

/// An automation's runs, newest first, as its opened row read them: what
/// each said, and for a system automation's what it cost.
private struct AutomationRuns: View {
    @Environment(AppModel.self) private var model
    let automation: Automation

    @ViewBuilder var body: some View {
        let runs = model.automations.runs[automation.id] ?? []
        if !runs.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                SectionHeader("Runs")
                ForEach(runs) { run in
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Space.md) {
                        Text(run.startedAt.map { Formatting.dateAndTime($0) } ?? "")
                            .font(Theme.font(11))
                            .monospacedDigit()
                            .foregroundStyle(Theme.secondaryText)
                            .frame(width: 110, alignment: .leading)
                        outcome(run)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func outcome(_ run: AutomationRunRecord) -> some View {
        switch (run.status, run.reply?.status) {
        case ("success", nil) where run.text != nil:
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                // strut's agent wrote it, not Peel's: its links open nothing in Peel.
                MessageText(text: run.text ?? "", chat: nil, agentLinks: false)
                if let cost = run.cost {
                    Text(cost.formatted(.currency(code: "USD").precision(.fractionLength(2...4)))).muted()
                }
            }
        case ("success", nil) where automation.isSystem:
            Text("Finished").muted()
        case (_, .delivered?):
            MessageText(text: run.reply?.text ?? "", chat: nil, agentLinks: true)
        case (_, .nothing?):
            Text("Nothing to report").muted()
        case ("running", _):
            Text("Running…").muted()
        default:
            Text("Didn't finish: " + (run.reply?.error ?? run.error ?? "no reason given"))
                .font(Theme.font(12))
                .foregroundStyle(Theme.attention)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
