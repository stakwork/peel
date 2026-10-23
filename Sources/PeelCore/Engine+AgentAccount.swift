import Foundation
import Sphinxrs

/// The agent's own Sphinx account (docs/agent-on-strut.md, section 4): a
/// second account the twelve words recover, which reveals nothing about this
/// one. Its seed is the core's `agent_seed(seed, n)`, HKDF-SHA256 over this
/// account's seed with the info `agent seed <n>`. Only the derived seed leaves
/// the engine, for the bridge that holds the agent's account (`BundledBridge`,
/// over its admin `/seed`); it is never printed, dumped or reflected.
public struct AgentAccount: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// The agent's seed, 32 bytes hex.
    public let seed: String
    /// The agent's account key (child index 0), the contact this account adds.
    public let pubkey: String
    /// The core's network, which the bridge sets with the seed.
    public let network: String
    /// This account's key: the one sender the bridge answers.
    public let owner: String
    /// This device (`Setting.deviceID`), the one the bridge's requests name.
    public let device: String
    /// The broker as runner takes it, `host:port` (TLS on port 8883 only).
    public let broker: String

    public var description: String { "agent account \(pubkey)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["pubkey": pubkey, "owner": owner], displayStyle: .struct) }
}

extension Engine {
    /// The agent's account: agent 1, as foundation.md numbers them. Refused
    /// without a server, or with one runner would reach otherwise than Peel
    /// does: runner takes TLS from the port (8883), Peel from the address.
    public func agentAccount() throws -> AgentAccount {
        guard let server else { throw Failure.noServer }
        guard server.tls == (server.port == 8883) else {
            throw PeelError("the agent's bridge cannot reach \(server): it uses TLS on port 8883 and only there")
        }
        guard let device = try storage.value(for: .deviceID) else { throw PeelError("this device has no id yet") }
        let agentSeed = try Sphinxrs.agentSeed(seed: seed, n: 1)
        return AgentAccount(
            seed: agentSeed, pubkey: try agentPubkey(of: agentSeed), network: network, owner: accountKey,
            device: device, broker: "\(server.host):\(server.port)"
        )
    }

    /// The agent's account key alone: how every device of this account,
    /// the phone included, knows the agent's DM, with no bridge of its own.
    public func agentPubkey() throws -> String {
        try agentPubkey(of: Sphinxrs.agentSeed(seed: seed, n: 1))
    }

    private func agentPubkey(of agentSeed: String) throws -> String {
        try Sphinxrs.pubkeyFromSeed(seed: agentSeed, idx: 0, time: clock.next(), network: network)
    }
}
