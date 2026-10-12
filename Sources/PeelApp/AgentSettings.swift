import AgentKit
import SwiftUI
import PeelCore

/// Account › Peel agent: its name, the connected provider (Change), the key
/// by its last four (Replace, Remove confirmed in place), the model, and
/// Clear conversation. Each change is an `AgentSession` action.
struct AgentSettingsSection: View {
    static let id = "agent-settings"
    @Environment(AppModel.self) private var model
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
                            Label("Connected", systemImage: "circle.fill")
                                .labelStyle(.titleAndIcon)
                                .font(Theme.font(12))
                                .foregroundStyle(Theme.confirmed)
                                .imageScale(.small)
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
                            InlineConfirm(trigger: "Remove", prompt: "Remove the key? The agent stops until you connect again.",
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
                Fact("Conversation") {
                    Text("Clears the agent chat on this Mac. Your other chats are not touched.")
                        .font(Theme.font(12))
                        .foregroundStyle(Theme.secondaryText)
                } trailing: {
                    InlineConfirm(trigger: "Clear…", prompt: "Clear the agent chat?", confirm: "Clear") {
                        attempt { try agent.clear() }
                    }
                }
            }
            Text(footnote)
                .font(Theme.font(12))
                .foregroundStyle(problem == nil ? Theme.secondaryText : Theme.attention)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
        }
    }

    private var footnote: String {
        if let problem { return problem }
        let provider = agent.connection?.provider.name ?? "the provider you connect"
        return "The key stays in \(model.agentKeyPlace) and is not synced. What the agent reads to answer you is sent to \(provider), not to Sphinx or to us."
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
                FormItem(label: "Name", helper: "What the agent is called in the sidebar and in its chat.",
                         problem: problem) {
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
