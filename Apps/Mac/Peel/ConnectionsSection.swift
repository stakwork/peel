import PeelAgent
import PeelCore
import PeelUI
import SwiftUI

/// Account › Connections: the services the agent uses with your own
/// credentials, kept in your strut (`AppModel+Connections`). Each MCP
/// server: where it is, whether it answered and with how many tools (and
/// how many ask first), which agents use it, Test and Remove. Add MCP
/// server registers one; Gmail is next. Below, the Stadeum workspaces
/// paired as peers (`StadeumSection`).
struct ConnectionsSection: View {
    static let id = "connections"
    @Environment(AppModel.self) private var model
    @State private var adding = false

    var body: some View {
        let connections = model.connections
        VStack(alignment: .leading, spacing: 6) {
            SettingsSection("Connections") {
                if adding {
                    AddMCPServerForm { adding = false }
                } else {
                    ForEach(connections.servers) { server in
                        MCPServerRow(server: server)
                    }
                    Fact("Gmail") {
                        Text("Coming soon").muted()
                    } trailing: {
                        EmptyView()
                    }
                    Fact("Add a service") {
                        Text(model.grantsConnections
                             ? "Your assistant uses it with your own key, kept in its memory. A tool the service marks read-only runs as asked; any other asks you first."
                             : "Kept on your home server, whose own settings decide which of its agents use it.")
                            .muted()
                            .fixedSize(horizontal: false, vertical: true)
                    } trailing: {
                        Button("Add MCP server") { adding = true }
                            .buttonStyle(.peel(.outline))
                            .disabled(model.memoryServer == nil)
                    }
                }
            }
            if let problem = connections.problem {
                Text(problem)
                    .font(Theme.font(12))
                    .foregroundStyle(Theme.attention)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
            StadeumSection()
        }
        // Read again whenever strut is (again) reachable.
        .task(id: model.memoryServer?.base) { await model.loadConnections() }
    }
}

/// One MCP server: its place, its state, the agents that use it, Test, Remove.
private struct MCPServerRow: View {
    @Environment(AppModel.self) private var model
    let server: MCPServer
    @State private var removing = false

    var body: some View {
        let connections = model.connections
        Fact(server.name) {
            VStack(alignment: .leading, spacing: 6) {
                Text(server.place).muted()
                status(connections.probes[server.name], testing: connections.testing.contains(server.name))
                if model.grantsConnections {
                    HStack(spacing: Theme.Space.lg) {
                        grantSwitch("Assistant", isOn: connections.grants.assistant.contains(server.name)) {
                            model.setGrant(server.name, assistant: $0)
                        }
                        grantSwitch("Jobs", isOn: connections.grants.jobs.contains(server.name)) {
                            model.setGrant(server.name, jobs: $0)
                        }
                    }
                }
                HStack(spacing: 8) {
                    if !removing {
                        Button("Test") { Task { await model.testMCPServer(server.name) } }
                            .buttonStyle(.peel(.outline))
                            .disabled(connections.testing.contains(server.name))
                    }
                    InlineConfirm(trigger: "Remove", prompt: "Remove \(server.name)?",
                                  explanation: "Your assistant stops using it, and its key is deleted from your memory.",
                                  confirm: "Remove", alignment: .leading, confirming: $removing) {
                        Task { await model.removeMCPServer(server.name) }
                    }
                }
                .padding(.top, 2)
            }
        } trailing: {
            EmptyView()
        }
        .task { if connections.probes[server.name] == nil { await model.testMCPServer(server.name) } }
    }

    /// "Connected · 12 tools, 4 ask first", or why it did not answer.
    @ViewBuilder
    private func status(_ probe: MCPProbe?, testing: Bool) -> some View {
        if testing {
            Text("Checking…").muted()
        } else if let probe, let error = probe.error {
            Text(error)
                .font(Theme.font(12))
                .foregroundStyle(Theme.attention)
                .fixedSize(horizontal: false, vertical: true)
        } else if let probe {
            let asking = probe.tools.filter(\.gated).count
            HStack(spacing: 6) {
                ConnectedLabel()
                    .fixedSize()
                Text("\(probe.tools.count) \(probe.tools.count == 1 ? "tool" : "tools")\(asking > 0 ? ", \(asking) ask\(asking == 1 ? "s" : "") first" : "")")
                    .muted()
            }
            .font(Theme.font(12))
        }
    }

    private func grantSwitch(_ label: String, isOn: Bool, set: @escaping (Bool) -> Void) -> some View {
        HStack(spacing: 6) {
            PeelSwitch(isOn: Binding(get: { isOn }, set: set))
                .accessibilityRepresentation { Toggle(label, isOn: Binding(get: { isOn }, set: set)) }
            Text(label).font(Theme.font(12)).fixedSize()
        }
    }
}

/// Add MCP server: its name (which prefixes its tools), its address, and a
/// key or token if it takes one, which goes into your memory's encrypted
/// store and is never shown again.
private struct AddMCPServerForm: View {
    @Environment(AppModel.self) private var model
    let done: () -> Void
    @State private var name = ""
    @State private var address = ""
    @State private var key = ""
    @State private var problem: String?
    @State private var adding = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            FormLabel("Add an MCP server", detail: "Linear's is https://mcp.linear.app/mcp, with a personal API key from Linear's settings.")
            FormItem(label: "Name", helper: "Letters, digits, - or _. Its tools are named after it.") {
                FormTextField(label: "Name", prompt: "linear", text: $name, focusOnAppear: true)
            }
            FormItem(label: "Address") {
                FormTextField(label: "Address", prompt: "https://mcp.linear.app/mcp", text: $address, monospaced: true)
            }
            FormItem(label: "Key or token", helper: "Kept in your assistant's memory, encrypted. Leave empty if it takes none.") {
                FormTextField(label: "Key or token", text: $key, secure: true)
                    .onSubmit(add)
            }
            FormFooter(problem: problem) {
                Button("Cancel", action: done)
                    .buttonStyle(.peel(.outline))
                Button(adding ? "Adding…" : "Add", action: add)
                    .buttonStyle(.peel(.primary))
                    .keyboardShortcut(.defaultAction)
                    .disabled(url == nil || name.trimmed.isEmpty || adding)
            }
        }
        .padding(settingsRowPadding)
        .onChange(of: [name, address, key]) { problem = nil }
    }

    private var url: URL? {
        URL(string: address.trimmed).flatMap { $0.scheme == "https" || $0.scheme == "http" ? $0 : nil }
    }

    private func add() {
        guard let url, !adding else { return }
        adding = true
        Task {
            problem = await model.addMCPServer(name: name.trimmed, url: url, key: key)
            adding = false
            if problem == nil { done() }
        }
    }
}
