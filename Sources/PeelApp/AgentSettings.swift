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
/// last checked. A pairing link's server waits above it for a yes. Nothing
/// is moved between the two: each keeps its own memory.
struct BrainSection: View {
    @Environment(AppModel.self) private var model
    @State private var editing = false
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let pairing = model.pairing {
                Callout(
                    .neutral, "Use the home server at \(pairing.base.host ?? pairing.description)?",
                    detail: "From a pairing link. The agent will use that server's memory; what it remembered on this Mac stays here."
                ) {
                    HStack(spacing: 8) {
                        Button("Use home server") { attempt { try model.setBrain(.homeServer(pairing)) } }
                            .buttonStyle(.peel(.primary))
                        Button("Cancel") { model.pairing = nil }
                            .buttonStyle(.peel(.outline))
                    }
                    .padding(.top, 6)
                }
                .padding(.top, Theme.Space.md)
            }
            SettingsSection("Brain") {
                if editing {
                    HomeServerForm { editing = false }
                } else {
                    rows
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

    @ViewBuilder private var rows: some View {
        switch model.brain {
        case .thisMac?:
            Fact("Brain") {
                VStack(alignment: .leading, spacing: 2) {
                    Text("This Mac")
                    Text("The agent's memory and automations run in Peel on this Mac.").muted()
                }
            } trailing: {
                Button("Use a home server…") { editing = true }
                    .buttonStyle(.peel(.outline))
            }
        case .homeServer(let server)?:
            Fact("Brain") {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Home server")
                    Text(server.description)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Theme.secondaryText)
                        .textSelection(.enabled)
                }
            } trailing: {
                HStack(spacing: 8) {
                    Button("Change") { editing = true }
                        .buttonStyle(.peel(.outline))
                    InlineConfirm(trigger: "Use this Mac", prompt: "The home server keeps its memory.",
                                  confirm: "Use this Mac", confirmKind: .primary) {
                        attempt { try model.setBrain(.thisMac) }
                    }
                }
            }
            Fact("Status") {
                BrainStatusText(status: model.brainStatus)
            } trailing: {
                Button("Check") { model.checkBrain() }
                    .buttonStyle(.peel(.outline))
                    .disabled(model.brainStatus == nil)
            }
        case nil:
            Fact("Brain") {
                Text("Peel could not read this setting, so the agent has no memory.").muted()
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
            problem = PeelError.problem(error, couldNot: "change the brain")
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
            line("Brain offline", why + " Memory waits for it; this Mac's is not used in its place.")
        case .badKey:
            line("Key not accepted", "The home server answered but did not take this key. Copy it again from its setup.")
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

/// The home server's address and key, typed or pasted.
private struct HomeServerForm: View {
    @Environment(AppModel.self) private var model
    let done: () -> Void
    @State private var address = ""
    @State private var key = ""
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            FormItem(label: "Address", helper: "https, or http to a Tailscale address") {
                FormTextField(label: "Address", prompt: "https://brain.your-tailnet.ts.net", text: $address,
                              monospaced: true, focusOnAppear: true)
            }
            FormItem(label: "Key", helper: "STRUT_API_KEY, as the home server's setup printed it") {
                FormTextField(label: "Key", text: $key, secure: true)
                    .onSubmit(save)
            }
            Text("The agent will use the home server's memory. What it remembered on this Mac stays here. "
                + AutomationsView.homeServerNote)
                .muted()
                .fixedSize(horizontal: false, vertical: true)
            FormFooter(problem: problem) {
                Button("Cancel", action: done)
                    .buttonStyle(.peel(.outline))
                Button("Use home server", action: save)
                    .buttonStyle(.peel(.primary))
                    .keyboardShortcut(.defaultAction)
                    .disabled(address.trimmed.isEmpty || key.trimmed.isEmpty)
            }
        }
        .padding(settingsRowPadding)
        .onAppear { address = model.brain?.homeServer?.description ?? "" }
    }

    private func save() {
        guard let url = URL(string: address.trimmed), let server = MemoryServer(base: url, key: key.trimmed, home: true) else {
            problem = "Use an https address, or http to a Tailscale address, and the key as it was printed."
            return
        }
        do {
            try model.setBrain(.homeServer(server))
            done()
        } catch {
            problem = PeelError.problem(error, couldNot: "keep the home server")
        }
    }
}
