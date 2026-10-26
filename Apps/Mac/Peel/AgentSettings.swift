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

/// Account › Brain: where Peel Home is, this Mac or a home server
/// (docs/always-on.md), with its move out and back; a link waiting for a
/// yes, and a move's progress and result, above it.
struct BrainSection: View {
    @Environment(AppModel.self) private var model
    @State private var problem: String?
    /// Peel Home's step waiting on the person: the box's link to open, or
    /// "Use this Mac's copy" to confirm.
    @State private var homeAsk: HomeAsk?

    private enum HomeAsk { case link, copy }

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
            Fact("Peel Home") {
                VStack(alignment: .leading, spacing: 2) {
                    Text("This Mac")
                    Text(model.homeMoveBlocker ?? "Your assistant runs here. Move it to a home server to keep it answering while this Mac sleeps.")
                        .muted()
                        .fixedSize(horizontal: false, vertical: true)
                }
            } trailing: {
                Button("Move to a home server…") { homeAsk = .link }
                    .buttonStyle(.peel(.outline))
                    .disabled(model.homeMoveBlocker != nil || homeAsk != nil)
            }
        case .moved(let home)?:
            movedRows(home)
        case nil:
            Fact("Peel Home") {
                Text("Peel couldn't read where Peel Home is, so it starts nothing for now.").muted()
            } trailing: {
                Button("Use this Mac") { attempt(couldNot: "use this Mac") { try model.useThisMac() } }
                    .buttonStyle(.peel(.outline))
            }
        }
    }

    /// Peel Home moved: where, since when, and the way back; until the
    /// agent has answered from there, Ping again beside it.
    @ViewBuilder private func movedRows(_ home: MovedHome) -> some View {
        let busy = model.homeMove?.isRunning == true || homeAsk != nil
        Fact("Peel Home") {
            VStack(alignment: .leading, spacing: 2) {
                Text("Your home server")
                Text(home.host)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.secondaryText)
                    .textSelection(.enabled)
                Text(home.answered ? "Moved \(Formatting.date(home.date)). Your assistant answers from there, even while this Mac sleeps."
                     : "Sent \(Formatting.date(home.date)), but your assistant hasn't answered from there yet. This Mac keeps its own stopped, so two never run at once.")
                    .foregroundStyle(home.answered ? Theme.secondaryText : Theme.attention)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } trailing: {
            HStack(spacing: 8) {
                if !home.answered {
                    Button("Ping again") { model.pingHomeAgain() }
                        .buttonStyle(.peel(.outline))
                }
                Button("Move back to this Mac…") { homeAsk = .link }
                    .buttonStyle(.peel(.outline))
            }
            .disabled(busy)
        }
        Fact("This Mac's copy") {
            Text(home.strutCopy == nil ? "This Mac's own, as it was when Peel Home was sent, for a home server that is gone."
                 : "Kept from \(Formatting.date(home.date)), for a home server that is gone.").muted()
        } trailing: {
            Button("Use this Mac's copy…") { homeAsk = .copy }
                .buttonStyle(.peel(.outline))
                .disabled(busy)
        }
    }

    /// A Peel Home move under way or how it ended; the box's link waiting
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
                away ? .attention : .neutral, back ? "Move Peel Home back to this Mac from \(link.host)?" : "Move Peel Home to your home server at \(link.host)?",
                detail: model.homeMoveBlocker ?? (away
                    ? "\(link.host) isn't on your home network. Peel Home carries your assistant's own account and keys: "
                        + "only move it to a computer you run."
                    : back
                    ? "Your assistant, its memory and its automations come back and run on this Mac. It's offline for about a minute."
                    : "Your assistant, its memory and its automations move there and keep answering while this Mac sleeps. "
                        + "It's offline for about a minute. Your Sphinx words stay on this Mac.")
            ) {
                HStack(spacing: 8) {
                    Button(back ? "Move back" : "Move") {
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
            switch ask {
            case .link:
                Callout(.neutral, "Open your home server's link", detail: model.brain?.moved == nil
                        ? "Set up Peel Home on your home server, then open the link its page shows on this Mac."
                        : "On your home server's page, choose Send Peel Home back, then open the link it shows on this Mac.") {
                    Button("Cancel") { homeAsk = nil }
                        .buttonStyle(.peel(.outline))
                        .padding(.top, 6)
                }
                .padding(.top, Theme.Space.md)
            case .copy:
                let day = model.brain?.moved.map { Formatting.date($0.date) } ?? ""
                Callout(.neutral, "Use this Mac's copy from \(day)?",
                        detail: "Peel Home goes back to how it was on this Mac on \(day). What happened on your home server since is lost. "
                            + "Only do this if your home server is gone: two copies must never run at once.") {
                    HStack(spacing: 8) {
                        Button("Use this Mac's copy") {
                            homeAsk = nil
                            attempt(couldNot: "use this Mac's copy") { try model.useThisMacCopy() }
                        }
                        .buttonStyle(.peel(.primary))
                        Button("Cancel") { homeAsk = nil }
                            .buttonStyle(.peel(.outline))
                    }
                    .padding(.top, 6)
                }
                .padding(.top, Theme.Space.md)
            }
        }
    }


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
            Callout(.neutral, detail: "Peel Home is on your home server, and your assistant answered from there.",
                    icon: .symbol("checkmark.circle", Theme.confirmed), dismiss: dismiss)
        case .ended(.movedBack(let answered)):
            Callout(.neutral, detail: answered ? "Peel Home is back on this Mac, and your assistant answered."
                        : "Peel Home is back on this Mac. Your assistant hasn't answered yet; it may still be starting.",
                    icon: .symbol("checkmark.circle", Theme.confirmed), dismiss: dismiss)
        case .ended(.unchanged(let why)), .ended(.unanswered(_, let why)), .ended(.stillAway(let why)):
            Callout(.attention, detail: why, dismiss: dismiss)
        }
    }

    static func words(_ direction: HomeMoveState.Direction, _ step: PeelHomeMove.Step) -> String {
        switch (direction, step) {
        case (_, .checking): "Checking your home server…"
        case (.out, .sending): "Stopping your assistant here and sending Peel Home to your home server…"
        case (.back, .sending): "Bringing Peel Home back to this Mac…"
        case (.out, .waiting): "Waiting for your assistant to answer from your home server…"
        case (.back, .waiting): "Starting your assistant here and waiting for it to answer…"
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

