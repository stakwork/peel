import AgentKit
import Foundation
import PeelCore

/// The agent's credential for the preferences sync (`ai_agent_config`,
/// `docs/phases/11-preferences-sync.md` decision 11): the Keychain item
/// behind `Profile.agentCredential`, read and written whole as the agent's
/// own `KeptCredential` does, so a key that came from the file is the one
/// the agent answers with. The key passes through here for one sync only.
struct AgentCredentialSync: SyncedAgentCredential {
    let item: any SecretItem
    /// Called after a key from the file was kept, so the running agent
    /// reads it and hands it to strut as a manual connect does.
    let kept: @Sendable () -> Void

    func read() throws -> AgentConfig? {
        guard let data = try item.read() else { return nil }
        let credential = try JSONDecoder().decode(AgentCredential.self, from: data)
        guard !credential.apiKey.isEmpty else { return nil }
        return AgentConfig(provider: Self.provider(credential.provider), apiKey: credential.apiKey, name: credential.agentName)
    }

    func keep(_ config: AgentConfig) throws {
        let provider = Self.provider(config.provider)
        try item.write(JSONEncoder().encode(AgentCredential(
            provider: provider, model: provider.recommendedModel, apiKey: config.apiKey, agentName: config.name
        )))
        kept()
    }

    static func provider(_ provider: AgentProvider) -> AgentConfig.Provider {
        switch provider {
        case .anthropic: .anthropic
        case .openAI: .openai
        case .openRouter: .openrouter
        }
    }

    static func provider(_ provider: AgentConfig.Provider) -> AgentProvider {
        switch provider {
        case .anthropic: .anthropic
        case .openai: .openAI
        case .openrouter: .openRouter
        }
    }
}
