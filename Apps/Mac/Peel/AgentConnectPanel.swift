import AgentKit
import SwiftUI
import PeelCore
import PeelUI

/// Connect a model: the provider, its API key (pasted, or typed), the
/// model, then one small test call with the spinner inside Connect. What
/// went wrong says so under the key, in the provider's plain words
/// (`ModelError`). Opens beside the button that opened it.
struct AgentConnectPanel: View {
    @Environment(AppModel.self) private var model
    let agent: AgentSession
    let done: () -> Void

    @State private var provider: AgentProvider
    @State private var modelID: String
    @State private var key = ""
    @State private var checking = false
    /// The test call running, cancelled when the panel closes.
    @State private var check: Task<Void, Never>?
    @State private var problem: String?

    init(agent: AgentSession, done: @escaping () -> Void) {
        self.agent = agent
        self.done = done
        let provider = agent.connection?.provider ?? .anthropic
        _provider = State(initialValue: provider)
        _modelID = State(initialValue: agent.connection?.model ?? provider.recommendedModel)
    }

    var body: some View {
        Panel("Connect a model", close: done) {
            VStack(alignment: .leading, spacing: 16) {
                FormItem(label: "Provider") {
                    PeelDropdown(
                        selection: provider,
                        options: AgentProvider.allCases.map { ($0, "\($0.name) · \($0.detail)") }
                    ) { chosen in
                        guard chosen != provider else { return }
                        provider = chosen
                        modelID = chosen.recommendedModel
                        problem = nil
                    }
                    .disabled(checking)
                }
                VStack(alignment: .leading, spacing: 4) {
                    FormItem(label: "\(provider.name) API key", problem: problem) {
                        HStack(spacing: 8) {
                            FormTextField(label: "\(provider.name) API key", text: $key, problem: problem != nil,
                                          focusOnAppear: true, secure: true)
                                .onSubmit { connect() }
                            Button("Paste") {
                                if let pasted = Clipboard.paste() { key = pasted.trimmed }
                            }
                            .buttonStyle(.peel(.outline))
                        }
                        .disabled(checking)
                    }
                    Button("Get a key from \(provider.name)") {
                        model.web.open(provider.keyPage)
                    }
                    .buttonStyle(.peel(.link, size: .sm))
                }
                FormItem(label: "Model") {
                    PeelDropdown(
                        selection: modelID,
                        options: provider.models.map { model in
                            (model.id, model.id == provider.recommendedModel ? "\(model.name) (recommended)" : model.name)
                        }
                    ) { modelID = $0 }
                    .disabled(checking)
                }
            }
            .padding(.top, 10)
            .onDisappear { check?.cancel() }
        } footer: {
            FormFooter(problem: nil) {
                Button("Cancel", action: done)
                    .buttonStyle(.peel(.outline))
                // On while it checks, keeping its fill under the spinner;
                // `connect` ignores a second click.
                Button { connect() } label: { Text("Connect").buttonProgress(checking) }
                    .buttonStyle(.peel(.primary))
                    .keyboardShortcut(.defaultAction)
                    .disabled(key.trimmed.isEmpty)
            }
        }
    }

    private func connect() {
        let key = key.trimmed
        guard !key.isEmpty, !checking else { return }
        checking = true
        problem = nil
        check = Task {
            defer { checking = false }
            do {
                try await agent.connect(AgentCredential(provider: provider, model: modelID, apiKey: key))
                done()
            } catch is CancellationError {
                // Closed while it checked: nothing was kept.
            } catch {
                problem = (error as? ModelError)?.localizedDescription ?? PeelError.problem(error, couldNot: "keep the key")
            }
        }
    }
}
