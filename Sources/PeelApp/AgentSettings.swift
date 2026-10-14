import AgentKit
import SwiftUI
import PeelAgent
import PeelCore
import PeelUI

/// Account › Peel agent: its name, the connected provider (Change), the key
/// by its last four (Replace, Remove confirmed in place), the model and
/// Clear conversation. Each change is an `AgentSession` action.
struct AgentSettingsSection: View {
    static let id = "agent-settings"
    let agent: AgentSession

    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SettingsSection("Peel agent") {
                AgentNameRow(agent: agent)
                Fact("Provider") {
                    if let connection = agent.connection {
                        HStack(spacing: 8) {
                            Text(connection.provider.name)
                            ConnectedLabel()
                                .font(Theme.font(12))
                        }
                    } else {
                        Text("No model connected")
                            .foregroundStyle(Theme.secondaryText)
                    }
                } trailing: {
                    AgentConnectButton(source: .account, title: agent.connection == nil ? "Connect" : "Change")
                }
                if let connection = agent.connection {
                    Fact("API key") {
                        Text("•••• \(connection.keyHint)")
                            .monospacedDigit()
                            .accessibilityLabel("Key ending \(connection.keyHint)")
                    } trailing: {
                        HStack(spacing: 8) {
                            AgentConnectButton(source: .accountKey, title: "Replace")
                            InlineConfirm(trigger: "Remove", prompt: "Remove the key? The agent will stop.",
                                          confirm: "Remove") {
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
                // Each "Always allow" given on a card, until revoked.
                ForEach(Array(agent.approvalRules.enumerated()), id: \.element.id) { index, rule in
                    Fact(index == 0 ? "Always allowed" : "") {
                        Text(AgentToolTitle.of(rule.tool) + (rule.target.map { " to \($0.name)" } ?? ""))
                    } trailing: {
                        Button("Revoke") { attempt { try agent.revoke(rule) } }
                            .buttonStyle(.peel(.outline))
                    }
                }
                Fact("Conversation") {
                    // Not EmptyView: it drops the value's full-width frame and the row centres.
                    Spacer(minLength: 0)
                } trailing: {
                    InlineConfirm(trigger: "Clear…", prompt: "Clear the agent chat?", confirm: "Clear") {
                        attempt { try agent.clear() }
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

/// Account › Brain (`docs/peel-brain.md`): This Mac, Peel's own strut, or
/// the account's home server by address and key, with what it said when
/// last checked. A pairing link's server, or the switch back to this Mac,
/// waits above it for a yes; the memory goes along (`AppModel.setBrain`),
/// and the copy's progress and result show above it as well.
struct BrainSection: View {
    @Environment(AppModel.self) private var model
    @State private var editing = false
    @State private var leaving = false
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let move = model.memoryMove {
                MemoryMoveCallout(move: move) { model.memoryMove = nil }
                    .padding(.top, Theme.Space.md)
            }
            if let pairing = model.pairing {
                Callout(
                    .neutral, "Connect to your home server at \(pairing.host)?",
                    detail: "Peel will keep what it remembers there, so it works while this Mac sleeps."
                ) {
                    HStack(spacing: 8) {
                        Button("Connect") { attempt { try model.setBrain(.homeServer(pairing)) } }
                            .buttonStyle(.peel(.primary))
                            .disabled(moving)
                        Button("Cancel") { model.pairing = nil }
                            .buttonStyle(.peel(.outline))
                    }
                    .padding(.top, 6)
                }
                .padding(.top, Theme.Space.md)
                .onAppear(perform: model.checkLocalMemory)
            }
            if leaving, model.brain?.homeServer != nil {
                Callout(.neutral, "Switch back to this Mac?",
                        detail: "Peel brings what your home server remembers here and saves this Mac's older copy as a backup.") {
                    HStack(spacing: 8) {
                        Button("Use this Mac") {
                            attempt { try model.setBrain(.thisMac) }
                            leaving = false
                        }
                        .buttonStyle(.peel(.primary))
                        Button("Cancel") { leaving = false }
                            .buttonStyle(.peel(.outline))
                    }
                    .padding(.top, 6)
                }
                .padding(.top, Theme.Space.md)
            }
            SettingsSection("Brain") {
                if editing {
                    HomeServerForm(current: model.brain?.homeServer) { editing = false }
                        .onAppear(perform: model.checkLocalMemory)
                } else {
                    rows
                }
            }
            .onChange(of: model.brainFormOpened) { editing = true }
            .onChange(of: model.brainLeaveOpened) { leaving = true }
            if let problem {
                Text(problem)
                    .font(Theme.font(12))
                    .foregroundStyle(Theme.attention)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        }
    }

    private var moving: Bool { model.memoryMove?.isRunning == true }

    @ViewBuilder private var rows: some View {
        switch model.brain {
        case .thisMac?:
            Fact("Using") {
                VStack(alignment: .leading, spacing: 2) {
                    Text("This Mac")
                    Text("Peel remembers things and runs automations here, on this Mac.").muted()
                }
            } trailing: {
                Button("Connect a home server…") { editing = true }
                    .buttonStyle(.peel(.outline))
                    .disabled(moving)
            }
        case .homeServer(let server)?:
            Fact("Using") {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Your home server")
                    Text(server.description)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Theme.secondaryText)
                        .textSelection(.enabled)
                }
            } trailing: {
                HStack(spacing: 8) {
                    Button("Change") { editing = true }
                        .buttonStyle(.peel(.outline))
                    Button("Use this Mac") { leaving = true }
                        .buttonStyle(.peel(.outline))
                }
                .disabled(moving || leaving)
            }
            Fact("Status") {
                BrainStatusText(status: model.brainStatus)
            } trailing: {
                Button("Check") { model.checkBrain() }
                    .buttonStyle(.peel(.outline))
                    .disabled(model.brainStatus == nil)
            }
        case nil:
            Fact("Memory") {
                Text("Peel couldn't read where its memory is kept, so it has none for now.").muted()
            } trailing: {
                Button("Use this Mac") { attempt { try model.setBrain(.thisMac) } }
                    .buttonStyle(.peel(.outline))
            }
        }
    }

    private func attempt(_ change: () throws -> Void) {
        do {
            try change()
            problem = nil
        } catch {
            problem = PeelError.problem(error, couldNot: "switch where Peel keeps its memory")
        }
    }
}

/// A memory move under way, or how it ended: the count that arrived, or
/// why nothing did (amber, never red: nothing was lost).
private struct MemoryMoveCallout: View {
    let move: MemoryMoveState
    let dismiss: () -> Void

    var body: some View {
        switch move {
        case .running(let direction, let step):
            Callout(detail: Self.words(direction, step), icon: .progress)
        case .done(let direction, let facts, let keptBackup):
            let count = Formatting.count(facts, "memory", "memories")
            let words = switch (direction, keptBackup) {
            case (.toHomeServer, false): "Copied \(count) to your home server."
            case (.toHomeServer, true): "Copied \(count) to your home server. Its older copy is saved as a backup there."
            case (.toThisMac, false): "Copied \(count) to this Mac."
            case (.toThisMac, true): "Copied \(count) to this Mac — this Mac's older copy is saved as a backup."
            }
            Callout(.neutral, detail: words, icon: .symbol("checkmark.circle", Theme.confirmed), dismiss: dismiss)
        case .failed(let why):
            Callout(.attention, detail: why, dismiss: dismiss)
        }
    }

    static func words(_ direction: MemoryMoveState.Direction, _ step: MemoryMove.Step?) -> String {
        switch (direction, step) {
        case (_, nil): "Starting Peel's memory on this Mac…"
        case (.toHomeServer, .reading?): "Reading what Peel remembers on this Mac…"
        case (.toHomeServer, .sending?): "Copying it to your home server…"
        case (.toThisMac, .reading?): "Reading what your home server remembers…"
        case (.toThisMac, .sending?): "Copying it to this Mac…"
        }
    }
}

/// A home server's state in words: amber when it cannot be used, never red.
private struct BrainStatusText: View {
    let status: BrainStatus?

    var body: some View {
        switch status {
        case nil:
            Text("Checking…").foregroundStyle(Theme.secondaryText)
        case .connected:
            ConnectedLabel()
        case .offline(let why):
            line("Can't reach your home server", why + " Peel waits for it and doesn't use this Mac's memory meanwhile.")
        case .badKey:
            line("Key not accepted", "Your home server answered but didn't accept the key. Copy it again from your home server's setup.")
        }
    }

    private func line(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).foregroundStyle(Theme.attention)
            Text(detail)
                .muted()
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// "Connected" with a green dot: a model, a home server.
private struct ConnectedLabel: View {
    var body: some View {
        Label("Connected", systemImage: "circle.fill")
            .labelStyle(.titleAndIcon)
            .foregroundStyle(Theme.confirmed)
            .imageScale(.small)
    }
}

/// Connects a home server: the link its setup shows, pasted, or its
/// address and key typed in under "Enter address and key instead" (open,
/// with the address in, when changing the one in use). The link and the key
/// are dots; only the address shows.
private struct HomeServerForm: View {
    @Environment(AppModel.self) private var model
    let done: () -> Void
    @State private var link = ""
    @State private var typing: Bool
    @State private var address: String
    @State private var key = ""
    @State private var problem: String?

    /// `current`: the home server in use, whose address starts typed in.
    init(current: MemoryServer?, done: @escaping () -> Void) {
        self.done = done
        _typing = State(initialValue: current != nil)
        _address = State(initialValue: current?.description ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            FormLabel("Connect a home server",
                      detail: "Keep what Peel remembers on an always-on computer, so it works while this Mac sleeps.")
            FormItem(label: "Link", helper: linkHelper, problem: linkProblem) {
                FormTextField(label: "Link", prompt: "Paste the link from your home server", text: $link,
                              problem: linkProblem != nil, focusOnAppear: !typing, secure: true)
                    .onSubmit(save)
            }
            DisclosureButton(open: $typing) { Text("Enter address and key instead") }
            if typing {
                FormItem(label: "Address", helper: "Your home server's address on Tailscale") {
                    FormTextField(label: "Address", prompt: "https://peel-brain.your-tailnet.ts.net", text: $address,
                                  monospaced: true, focusOnAppear: true)
                }
                FormItem(label: "Key", helper: "The key your home server showed when you set it up") {
                    FormTextField(label: "Key", text: $key, secure: true)
                        .onSubmit(save)
                }
            }
            Text(AutomationsView.homeServerNote)
                .muted()
                .fixedSize(horizontal: false, vertical: true)
            FormFooter(problem: problem ?? typedProblem) {
                Button("Cancel", action: done)
                    .buttonStyle(.peel(.outline))
                Button("Connect", action: save)
                    .buttonStyle(.peel(.primary))
                    .keyboardShortcut(.defaultAction)
                    .disabled(server == nil)
            }
        }
        .padding(settingsRowPadding)
        .onChange(of: [link, address, key]) { problem = nil }
    }

    /// The link without the spaces and line breaks a terminal's wrapping
    /// adds when it is copied; a link has none of its own.
    private var pasted: String { link.filter { !$0.isWhitespace } }

    /// The pasted link's server, nil until it is one.
    private var linked: MemoryServer? {
        URL(string: pasted).flatMap(Brain.pairing)
    }

    /// The address and key typed in, nil until both are usable.
    private var typed: MemoryServer? {
        guard typing, let url = URL(string: address.trimmed) else { return nil }
        return MemoryServer(base: url, key: key.trimmed, home: true)
    }

    /// What Connect connects: the link's once one is pasted, else the
    /// address and key typed.
    private var server: MemoryServer? { pasted.isEmpty ? typed : linked }

    private var linkHelper: String {
        linked.map { "Connects to \($0.host)" } ?? "Your home server shows it when you set it up."
    }

    private var linkProblem: String? {
        pasted.isEmpty || linked != nil ? nil : "That isn't a home server link. Copy it again from your home server."
    }

    /// Only once both are in, so the address is not called wrong while it is typed.
    private var typedProblem: String? {
        guard typing, !address.trimmed.isEmpty, !key.trimmed.isEmpty, typed == nil else { return nil }
        return "That address or key won't work. Copy both from your home server's setup; the address starts with https://."
    }

    private func save() {
        guard let server else { return }
        do {
            try model.setBrain(.homeServer(server))
            done()
        } catch {
            problem = PeelError.problem(error, couldNot: "connect to the home server")
        }
    }
}
