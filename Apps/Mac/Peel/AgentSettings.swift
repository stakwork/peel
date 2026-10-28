import AgentKit
import SwiftUI
import PeelAgent
import PeelCore
import PeelUI

/// Account › Peel agent: its name, the connected provider (Change), the key
/// by its last four (Replace, Remove confirmed in place), the model, its
/// own account (Set up) and Clear for the earlier chat on this Mac. Each change is an `AgentSession` action.
struct AgentSettingsSection: View {
    @Environment(AppModel.self) private var model
    let agent: AgentSession

    @State private var problem: String?
    @State private var removingKey = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SettingsSection {
                AgentNameRow(agent: agent)
                Fact("Provider") {
                    VStack(alignment: .leading, spacing: 4) {
                        if let connection = agent.connection {
                            HStack(spacing: 8) {
                                Text(connection.provider.name)
                                // Connected only once strut has it.
                                if model.modelHandOver == .handing {
                                    Text("Connecting…").muted()
                                } else if strutHasModel {
                                    ConnectedLabel()
                                        .font(Theme.font(12))
                                }
                            }
                        } else {
                            Text("No model connected")
                                .foregroundStyle(Theme.secondaryText)
                        }
                        if let handOverProblem {
                            Text(handOverProblem)
                                .font(Theme.font(12))
                                .foregroundStyle(Theme.attention)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                } trailing: {
                    HStack(spacing: 8) {
                        if handOverProblem != nil {
                            Button("Try again") { model.modelChanged() }
                                .buttonStyle(.peel(.outline))
                        }
                        AgentConnectButton(source: .account, title: agent.connection == nil ? "Connect" : "Change")
                    }
                }
                if let connection = agent.connection {
                    Fact("API key") {
                        Text("•••• \(connection.keyHint)")
                            .monospacedDigit()
                            .accessibilityLabel("Key ending \(connection.keyHint)")
                    } trailing: {
                        HStack(spacing: 8) {
                            // Replace steps aside while Remove asks.
                            if !removingKey {
                                AgentConnectButton(source: .accountKey, title: "Replace")
                            }
                            // The DM and its bridge stay: it answers again once a model is connected.
                            InlineConfirm(trigger: "Remove", prompt: "Remove the key?",
                                          explanation: model.agentChat == nil ? nil
                                              : "Your assistant stays in Direct messages but can't answer until you connect a model.",
                                          confirm: "Remove", alignment: .trailing, confirming: $removingKey) {
                                attempt { try agent.removeKey() }
                            }
                        }
                    }
                    Fact("Model") {
                        PeelDropdown(
                            selection: connection.model,
                            options: models(connection)
                        ) { chosen in attempt { try agent.setModel(chosen) } }
                        .fixedSize()
                    }
                }
                // Each "Always allow" given on a card, until revoked; a workspace's is under Connections.
                ForEach(Array(agent.approvalRules.filter { $0.tool != DeviceActions.peerTool }.enumerated()), id: \.element.id) { index, rule in
                    Fact(index == 0 ? "Always allowed" : "") {
                        Text(AgentToolTitle.of(rule.tool) + (rule.target.map { " to \($0.name)" } ?? ""))
                    } trailing: {
                        Button("Revoke") { attempt { try agent.revoke(rule) } }
                            .buttonStyle(.peel(.outline))
                    }
                }
                // Each send grant an automation's card made, until revoked.
                let cards = model.macAgent.deviceCards
                ForEach(Array(cards.grants.enumerated()), id: \.element.id) { index, grant in
                    Fact(index == 0 ? "May post as you" : "") {
                        Text("\(grant.name ?? "An automation"), to \(grant.summary)")
                    } trailing: {
                        Button("Revoke") { attempt { try cards.revoke(grant) } }
                            .buttonStyle(.peel(.outline))
                    }
                }
                AgentAccountRow()
                // Only while there is any: gone once cleared.
                if !agent.turns.isEmpty {
                    Fact(AgentListRow.oldChatsTitle) {
                        // Not EmptyView: it drops the value's full-width frame and the row centres.
                        Spacer(minLength: 0)
                    } trailing: {
                        InlineConfirm(trigger: "Clear…", prompt: "Clear the old assistant chats on this Mac?", confirm: "Clear") {
                            attempt { try agent.clear() }
                        }
                    }
                }
            }
            if let problem {
                Text(problem)
                    .font(Theme.font(12))
                    .foregroundStyle(Theme.attention)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        }
    }

    /// Connected: strut took the key, or there is no strut of Peel's own to
    /// hand it to (Peel Home moved: the box has the key it took along). Not while Peel's strut is
    /// starting or stopped: the Own account row says how that is going.
    private var strutHasModel: Bool {
        model.modelHandOver == .handed || !(model.hasOwnStrut && model.brain == .thisMac)
    }

    /// Why strut does not have what was connected or removed, if it does not.
    private var handOverProblem: String? {
        if case .failed(let problem)? = model.modelHandOver { problem } else { nil }
    }

    /// The provider's models, with the one in use even if the list has no longer got it.
    private func models(_ connection: AgentSession.Connection) -> [(value: String, label: String)] {
        let listed = connection.provider.models.map { (value: $0.id, label: $0.name) }
        return listed.contains { $0.value == connection.model }
            ? listed : listed + [(value: connection.model, label: connection.model)]
    }

    private func attempt(_ change: () throws -> Void) {
        do {
            try change()
            problem = nil
        } catch {
            problem = PeelError.problem(error, couldNot: "change the agent")
        }
    }
}

/// The agent's own account (`AppModel.agentSetUp`): where it stands, and
/// Set up or Try again.
private struct AgentAccountRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let setUp = model.agentSetUp
        Fact("Own account") {
            Text(setUp.line)
                .font(Theme.font(12))
                .foregroundStyle(setUp.problem ? Theme.attention : Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        } trailing: {
            if let action = setUp.action {
                Button(action) { model.setUpAgent() }
                    .buttonStyle(.peel(.outline))
            }
        }
    }
}

/// In the agent chat's composer place until its DM is the chat: "Give your
/// assistant its own account", what it costs and Set up; then how it is going.
struct AgentSetUpPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let setUp = model.agentSetUp
        let offer = setUp == .offer
        Callout(setUp.problem ? .attention : .neutral, offer ? "Give your assistant its own account" : nil,
                detail: setUp.line, icon: setUp.busy ? .progress : nil) {
            if let action = setUp.action {
                Button(action) { model.setUpAgent() }
                    .buttonStyle(.peel(offer ? .primary : .outline))
                    .padding(.top, offer ? 6 : 0)
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
    }
}

/// In the agent DM's composer place while no model is connected: it can't
/// answer, so nothing is sent; Connect opens the Connect panel beside it.
struct AgentModelPrompt: View {
    var body: some View {
        Callout(.neutral, "Connect a model", detail: "Your assistant can't answer until you connect one.") {
            AgentConnectButton(source: .dm, title: "Connect", variant: .primary)
                .padding(.top, 6)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
    }
}

/// The agent's name, edited in place as the account's own name is.
private struct AgentNameRow: View {
    let agent: AgentSession
    @State private var editing = false
    @State private var draft = ""
    @State private var problem: String?

    var body: some View {
        if editing {
            VStack(alignment: .leading, spacing: 14) {
                FormItem(label: "Name", problem: problem) {
                    FormTextField(label: "Name", text: $draft, focusOnAppear: true)
                        .onSubmit(save)
                }
                .padding([.horizontal, .top], settingsRowPadding)
                FormFooter(problem: nil) {
                    Button("Cancel") { editing = false }
                        .buttonStyle(.peel(.outline))
                    Button("Save", action: save)
                        .buttonStyle(.peel(.primary))
                        .keyboardShortcut(.defaultAction)
                        .disabled(draft.trimmed.isEmpty || draft.trimmed == agent.name)
                }
                .padding([.horizontal, .bottom], settingsRowPadding)
            }
        } else {
            Fact("Name") {
                Text(agent.name)
            } trailing: {
                Button("Edit") {
                    draft = agent.name
                    problem = nil
                    editing = true
                }
                .buttonStyle(.peel(.outline))
            }
        }
    }

    private func save() {
        guard !draft.trimmed.isEmpty else { return }
        do {
            try agent.rename(draft)
            editing = false
        } catch {
            problem = PeelError.readable(error)
        }
    }
}

/// Account › Always on: where Peel Home is, this Mac or a home server
/// (docs/always-on.md), with its move out and back; a link waiting for a
/// yes, and a move's progress and result, above it.
struct BrainSection: View {
    @Environment(AppModel.self) private var model
    @State private var problem: String?
    /// What waits on the person: the steps on the box that end in its link
    /// (Set up…, Turn off…), or Restore to confirm.
    @State private var homeAsk: HomeAsk?

    private enum HomeAsk { case steps, restore }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            homeCallouts
            SettingsSection {
                rows
            }
            if let problem {
                Text(problem)
                    .font(Theme.font(12))
                    .foregroundStyle(Theme.attention)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        }
    }

    @ViewBuilder private var rows: some View {
        switch model.brain {
        case .thisMac?:
            Fact("Always on") {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Off")
                    Text(model.homeMoveBlocker
                         ?? "Your assistant only answers while this Mac is awake. Run it on a home server to keep it answering around the clock.")
                        .muted()
                        .fixedSize(horizontal: false, vertical: true)
                }
            } trailing: {
                Button("Set up…") { homeAsk = .steps }
                    .buttonStyle(.peel(.outline))
                    .disabled(model.homeMoveBlocker != nil || homeAsk != nil)
            }
        case .moved(let home)?:
            movedRows(home)
        case nil:
            Fact("Always on") {
                Text("Peel couldn't tell where your assistant runs, so it starts nothing for now.").muted()
            } trailing: {
                Button("Use this Mac") { attempt(couldNot: "use this Mac") { try model.useThisMac() } }
                    .buttonStyle(.peel(.outline))
            }
        }
    }

    /// Peel Home moved: where, since when, and Turn off, the way back; until
    /// the agent has answered from there, Ping again beside it. Under it,
    /// Restore: the lossy way back, for a box that is gone.
    @ViewBuilder private func movedRows(_ home: MovedHome) -> some View {
        let busy = model.homeMove?.isRunning == true || homeAsk != nil
        Fact("Always on") {
            VStack(alignment: .leading, spacing: 2) {
                Text(home.answered ? "On, from your home server" : "Sent to your home server")
                Text(home.host)
                    .font(Theme.code(12))
                    .foregroundStyle(Theme.secondaryText)
                    .textSelection(.enabled)
                Text(home.answered ? "Answering since \(Formatting.date(home.date)), even while this Mac sleeps."
                     : "Sent \(Formatting.date(home.date)), but your assistant hasn't answered from there yet. This Mac keeps its own stopped, so two never run at once.")
                    .foregroundStyle(home.answered ? Theme.secondaryText : Theme.attention)
                    .fixedSize(horizontal: false, vertical: true)
                // This Mac's strut for dictation, kept in step with the box (`HomeSyncer`).
                if home.answered, let syncer = model.macAgent.homeSyncer {
                    Text(Self.homeSync(syncer.status, lastSync: syncer.lastSync))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryText)
                }
            }
        } trailing: {
            HStack(spacing: 8) {
                if !home.answered {
                    Button("Ping again") { model.pingHomeAgain() }
                        .buttonStyle(.peel(.outline))
                }
                Button("Turn off…") { homeAsk = .steps }
                    .buttonStyle(.peel(.outline))
            }
            .disabled(busy)
        }
        Fact("Server gone?") {
            Text(home.strutCopy == nil ? "Restore your assistant on this Mac as it was when it was sent. Anything since then is lost."
                 : "Restore your assistant on this Mac as it was on \(Formatting.date(home.date)). Anything since then is lost.").muted()
        } trailing: {
            Button("Restore…") { homeAsk = .restore }
                .buttonStyle(.peel(.outline))
                .disabled(busy)
        }
    }

    /// When this Mac's strut for dictation last synced with the box, or that
    /// its last try didn't reach it; or that it can't, with no peer record or
    /// one whose token ran out (a year after the move: moving back and out
    /// again makes a new one).
    private static func homeSync(_ status: HomeSyncer.Status, lastSync: Date?) -> String {
        switch status {
        case .noPeer: "Your home server gave this Mac no way to sync with it, so dictation uses what it knew at the move."
        case .expired(let date):
            "This Mac's sync with your home server ran out \(Formatting.date(date)). Turn off Always on and set it up again to renew it."
        case .notYet: "Not synced with this Mac yet."
        case .synced(let date): "Last synced with this Mac \(Formatting.dateAndTime(date))."
        case .failed(let at):
            "Couldn't reach your home server when this Mac last tried, \(Formatting.dateAndTime(at)). Dictation keeps "
                + (lastSync.map { "what it last synced, \(Formatting.dateAndTime($0))." } ?? "what it knew at the move.")
        }
    }

    /// A move under way or how it ended; the box's link waiting
    /// for a yes; or the person's next step, asked in place.
    @ViewBuilder private var homeCallouts: some View {
        if let move = model.homeMove {
            HomeMoveCallout(move: move, dismiss: { model.homeMove = nil }, cancel: model.cancelHomeMove)
                .padding(.top, Theme.Space.md)
        }
        if let link = model.homeLink {
            let back = model.brain?.moved != nil
            let away = !back && !link.isHomeNetwork
            Callout(
                away ? .attention : .neutral,
                back ? "Turn off Always on and bring your assistant back from \(link.host)?" : "Move your assistant to your home server at \(link.host)?",
                detail: model.homeMoveBlocker ?? (away
                    ? "\(link.host) isn't on your home network. Your assistant carries its own account and keys: "
                        + "only move it to a computer you run."
                    : back
                    ? "Your assistant, its memory and its automations come back and run on this Mac. It's offline for about a minute."
                    : "Its memory and automations go with it, and it keeps answering while this Mac sleeps. "
                        + "It's offline for about a minute. Your Sphinx words stay on this Mac.")
            ) {
                HStack(spacing: 8) {
                    Button(back ? "Turn off" : "Move") {
                        homeAsk = nil
                        model.moveHome()
                    }
                    .buttonStyle(.peel(.primary))
                    .disabled(model.homeMoveBlocker != nil)
                    Button("Cancel") { model.homeLink = nil }
                        .buttonStyle(.peel(.outline))
                }
                .padding(.top, 6)
            }
            .padding(.top, Theme.Space.md)
        } else if let ask = homeAsk {
            Group {
                switch ask {
                case .steps:
                    stepsCallout
                case .restore:
                    let day = model.brain?.moved.map { Formatting.date($0.date) } ?? ""
                    Callout(.neutral, "Restore your assistant on this Mac?",
                            detail: "This Mac goes back to how it was on \(day), when your assistant moved. What happened on your home server since then is lost. "
                                + "Only do this if your home server is gone: two copies must never run at once.") {
                        HStack(spacing: 8) {
                            Button("Restore") {
                                homeAsk = nil
                                attempt(couldNot: "restore your assistant") { try model.useThisMacCopy() }
                            }
                            .buttonStyle(.peel(.primary))
                            Button("Cancel") { homeAsk = nil }
                                .buttonStyle(.peel(.outline))
                        }
                        .padding(.top, 6)
                    }
                }
            }
            .padding(.top, Theme.Space.md)
        }
    }

    /// Set up… or Turn off…: the steps on the box that end in the link this
    /// Mac opens. The box serves no page while Peel Home runs there, so the
    /// way back is its setup command.
    private var stepsCallout: some View {
        let home = model.brain?.moved
        let steps: [HomeSteps.Step] = if let home {
            [
                .init(words: "On your home server, in the folder you started it from, run:",
                      command: "docker compose exec setup sh /setup.sh send-back \(home.host)"),
                .init(words: "Open the link it prints, on this Mac."),
            ]
        } else {
            [
                .init(words: "On that computer, copy Peel's [home folder](\(Self.homeGuide)) over and, inside it, run:",
                      command: "docker compose up -d"),
                .init(words: "On this Mac, open its setup page at http://<its address>:8090."),
                .init(words: "Click the link on that page. Peel asks before anything moves."),
            ]
        }
        return Callout(.neutral, home == nil ? "Run your assistant on a home server" : "Turn off Always on",
                       detail: home == nil
                           ? "Any computer on your home network that stays on and runs Docker: a Raspberry Pi, a NAS, a spare Mac or PC."
                           : "Your assistant comes back to this Mac with everything it did on your home server.") {
            VStack(alignment: .leading, spacing: 8) {
                HomeSteps(steps: steps)
                Button("Cancel") { homeAsk = nil }
                    .buttonStyle(.peel(.outline))
            }
            .padding(.top, 6)
        }
    }

    /// How to set up the box, until there's a download of its own.
    private static let homeGuide = "https://github.com/stakwork/peel/blob/main/home/README.md"

    private func attempt(couldNot action: String, _ change: () throws -> Void) {
        do {
            try change()
            problem = nil
        } catch {
            problem = PeelError.problem(error, couldNot: action)
        }
    }
}

/// A Peel Home move under way, or how it ended: amber when it didn't move,
/// never red, since nothing was lost.
private struct HomeMoveCallout: View {
    let move: HomeMoveState
    let dismiss: () -> Void
    let cancel: () -> Void

    var body: some View {
        switch move {
        case .running(let direction, let step):
            Callout(detail: Self.words(direction, step), icon: .progress) {
                Button("Cancel", action: cancel)
                    .buttonStyle(.peel(.outline))
            }
        case .ended(.movedOut):
            Callout(.neutral, detail: "Always on. Your assistant answered from your home server.",
                    icon: .symbol("checkmark.circle", Theme.confirmed), dismiss: dismiss)
        case .ended(.movedBack(let answered)):
            Callout(.neutral, detail: answered ? "Your assistant is back on this Mac, and it answered."
                        : "Your assistant is back on this Mac. It hasn't answered yet; it may still be starting.",
                    icon: .symbol("checkmark.circle", Theme.confirmed), dismiss: dismiss)
        case .ended(.unchanged(let why)), .ended(.unanswered(_, let why)), .ended(.stillAway(let why)):
            Callout(.attention, detail: why, dismiss: dismiss)
        }
    }

    static func words(_ direction: HomeMoveState.Direction, _ step: PeelHomeMove.Step) -> String {
        switch (direction, step) {
        case (_, .checking): "Checking your home server…"
        case (.out, .sending): "Stopping your assistant here and moving it to your home server…"
        case (.back, .sending): "Bringing your assistant back to this Mac…"
        case (.out, .waiting): "Waiting for your assistant to answer from your home server…"
        case (.back, .waiting): "Starting your assistant here and waiting for it to answer…"
        }
    }
}

/// Numbered steps done on the home server, each with the command to run
/// and a Copy beside it. A step's words may hold a `[text](https://…)` link,
/// shown with its host as in messages.
private struct HomeSteps: View {
    struct Step {
        let words: String
        var command: String? = nil
    }

    let steps: [Step]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(index + 1).")
                        .monospacedDigit()
                        .muted()
                    VStack(alignment: .leading, spacing: 6) {
                        Text(LinkText.attributed(step.words, myAliases: [], size: 12))
                            .muted()
                        if let command = step.command {
                            HStack(spacing: 8) {
                                Text(command)
                                    .font(Theme.code(12))
                                    .textSelection(.enabled)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 5)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Theme.codeFill, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                                CopyButton("Copy", text: command)
                            }
                        }
                    }
                }
            }
        }
    }
}

/// "Connected" with a green dot: a model.
struct ConnectedLabel: View {
    var body: some View {
        Label("Connected", systemImage: "circle.fill")
            .labelStyle(.titleAndIcon)
            .foregroundStyle(Theme.confirmed)
            .imageScale(.small)
    }
}

