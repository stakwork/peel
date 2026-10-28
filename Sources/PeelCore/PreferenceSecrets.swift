import Foundation

// What the official `chat_color`, `biometric_enabled` and `ai_agent_config`
// items need beyond the registry (`docs/phases/11-preferences-sync.md`,
// decisions 9 to 11).

/// A colour as the official apps write it: `#rrggbb`.
enum ChatColour {
    /// `#rrggbb` in lower case for `#rrggbb` or `rrggbb` in any case (the
    /// iOS app reads it without the `#`), nil for anything else.
    static func normalised(_ text: String) -> String? {
        let digits = text.hasPrefix("#") ? text.dropFirst() : Substring(text)
        guard digits.utf8.count == 6, digits.utf8.allSatisfy({
            (0x30...0x39).contains($0) || (0x41...0x46).contains($0) || (0x61...0x66).contains($0)
        }) else { return nil }
        return "#" + digits.lowercased()
    }

    /// The channels, 0 to 255, of a colour `normalised` accepts.
    static func channels(_ text: String) -> (red: Double, green: Double, blue: Double)? {
        guard let hex = normalised(text), let value = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        return (Double((value >> 16) & 0xFF), Double((value >> 8) & 0xFF), Double(value & 0xFF))
    }
}

/// The agent's model and key as the official apps keep them in
/// `ai_agent_config`: `"<Provider>|<apiKey>|<agentName>"`. It holds a live
/// third-party key, so it never prints it, and it lives in memory for the
/// length of one sync (or one connect); it is never stored in a database.
public struct AgentConfig: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// The services the official apps name. Peel's `.openRouter` is
    /// written as "OpenRouter", which they may not know and read as
    /// Anthropic (decision 11); an unknown one read from the file is not applied.
    public enum Provider: String, Sendable, CaseIterable {
        case anthropic, openai, openrouter

        /// As the official apps write it.
        public var officialName: String {
            switch self {
            case .anthropic: "Anthropic"
            case .openai: "OpenAI"
            case .openrouter: "OpenRouter"
            }
        }

        /// The provider a name stands for, in any case.
        init?(official name: String) {
            self.init(rawValue: name.lowercased())
        }
    }

    /// What the official apps call an agent that has no name.
    public static let defaultName = "Sphinx Agent"

    public var provider: Provider
    public var apiKey: String
    /// The agent's name from the file, kept so it goes back unchanged; nil
    /// for none (written as `defaultName`).
    public var name: String?

    public init(provider: Provider, apiKey: String, name: String? = nil) {
        self.provider = provider
        self.apiKey = apiKey
        self.name = name
    }

    /// As the official apps read it: split on "|"; the provider is the
    /// first part; with three or more the name is the last and the key is
    /// everything between, joined with "|"; with two there is no name. A
    /// provider that is not known, or an empty key, is not a config.
    init?(item text: String) {
        let parts = text.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, let provider = Provider(official: parts[0]) else { return nil }
        let key = parts.count >= 3 ? parts[1..<(parts.count - 1)].joined(separator: "|") : parts[1]
        guard !key.isEmpty else { return nil }
        self.provider = provider
        apiKey = key
        name = parts.count >= 3 ? parts[parts.count - 1].nilIfEmpty : nil
    }

    /// The item's value. The key always puts a "|" in it, so the official
    /// apps' string retyping (a bool, an int, a double) never changes it.
    var item: String {
        "\(provider.officialName)|\(apiKey)|\((name ?? Self.defaultName).replacingOccurrences(of: "|", with: " "))"
    }

    public var description: String { "AgentConfig(\(provider.rawValue), [key])" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["provider": provider]) }
}

/// The connected agent credential as the sync sees it, supplied by the app
/// from the Keychain item behind `Profile.agentCredential`, so the engine
/// is tested with one in memory. The key crosses it only for one sync.
public protocol SyncedAgentCredential: Sendable {
    /// What is connected here, nil for none.
    func read() throws -> AgentConfig?
    /// Connects `config` here, replacing what was: the provider's
    /// recommended model, the name kept beside the key. The running agent
    /// is then told, as a manual connect tells it.
    func keep(_ config: AgentConfig) throws
}

/// What this device adds to the account's synced preferences. The default
/// adds nothing: those keys stay pass-through in the file.
public struct PreferenceCapabilities: Sendable {
    /// Face ID is something this device can be offered (iOS): `biometric_enabled` syncs.
    public var biometrics: Bool
    /// Where this device keeps the agent's credential, if it has an agent:
    /// `ai_agent_config` syncs.
    public var agentCredential: (any SyncedAgentCredential)?

    public init(biometrics: Bool = false, agentCredential: (any SyncedAgentCredential)? = nil) {
        self.biometrics = biometrics
        self.agentCredential = agentCredential
    }

    /// The opt-in keys this device syncs.
    var keys: Set<String> {
        var keys: Set<String> = []
        if biometrics { keys.insert(Preferences.biometricKey) }
        if agentCredential != nil { keys.insert(Preferences.agentConfigKey) }
        return keys
    }
}

/// A secret value taken from the file, on its way to the Keychain: carried
/// from `merged` to the engine, never stored, never printed.
struct SecretChange: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    let pair: PreferenceID
    let value: JSONValue

    var description: String { "SecretChange(\(pair.key))" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: ["key": pair.key]) }
}
