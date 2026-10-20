import Foundation

/// The services the agent answers with, on a pasted API key that strut is
/// given (`AutomationsClient.setModel`).
public enum AgentProvider: String, Codable, CaseIterable, Sendable, Hashable {
    case anthropic
    case openAI = "openai"
    case openRouter = "openrouter"

    /// A model the provider offers, as the picker shows it.
    public struct Model: Sendable, Hashable {
        public let id: String
        public let name: String
    }

    public var name: String {
        switch self {
        case .anthropic: "Anthropic"
        case .openAI: "OpenAI"
        case .openRouter: "OpenRouter"
        }
    }

    /// One line under the name in the provider list.
    public var detail: String {
        switch self {
        case .anthropic: "Claude models · API key"
        case .openAI: "GPT models · API key"
        case .openRouter: "Many providers, one account · API key"
        }
    }

    /// Where a person makes a key.
    public var keyPage: URL {
        switch self {
        case .anthropic: URL(string: "https://console.anthropic.com/settings/keys")!
        case .openAI: URL(string: "https://platform.openai.com/api-keys")!
        case .openRouter: URL(string: "https://openrouter.ai/settings/keys")!
        }
    }

    /// The picker's models, the recommended one first.
    public var models: [Model] {
        switch self {
        case .anthropic:
            [Model(id: "claude-sonnet-5-5", name: "Claude Sonnet 5.5"),
             Model(id: "claude-opus-5-5", name: "Claude Opus 5.5"),
             Model(id: "claude-haiku-5-5", name: "Claude Haiku 5.5")]
        case .openAI:
            [Model(id: "gpt-5", name: "GPT-5"), Model(id: "gpt-5-mini", name: "GPT-5 mini")]
        case .openRouter:
            [Model(id: "anthropic/claude-sonnet-5.5", name: "Claude Sonnet 5.5"),
             Model(id: "openai/gpt-5", name: "GPT-5")]
        }
    }

    public var recommendedModel: String { models[0].id }

    /// A model's name as the picker shows it; an id it does not list as itself.
    public func modelName(_ id: String) -> String {
        models.first { $0.id == id }?.name ?? id
    }
}

/// A connected model: the provider, the model and the key. Kept whole in
/// the device's Keychain (`AgentCredentialStore`), never in the agent's
/// store; it prints without the key.
public struct AgentCredential: Codable, Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible,
    CustomReflectable
{
    public var provider: AgentProvider
    public var model: String
    public var apiKey: String

    public init(provider: AgentProvider, model: String, apiKey: String) {
        self.provider = provider
        self.model = model
        self.apiKey = apiKey
    }

    /// The key's last four characters, all a screen shows of it.
    public var keyHint: String { String(apiKey.suffix(4)) }

    public var description: String { "AgentCredential(\(provider.rawValue), \(model), [key])" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["provider": provider, "model": model]) }
}

/// Where the connected model's credential is kept: this device's Keychain
/// in the app.
public protocol AgentCredentialStore: Sendable {
    func read() throws -> AgentCredential?
    func write(_ credential: AgentCredential) throws
    func delete() throws
}
