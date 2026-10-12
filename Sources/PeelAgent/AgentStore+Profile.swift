import AgentKit
import Foundation
import PeelCore

extension SQLiteAgentStore {
    /// The account's agent store (`agent.sqlite` beside its database),
    /// stamped with its device id: the one way the app and the CLI open it,
    /// so both read the same conversation and "always" rules.
    public static func open(for profile: Profile, storage: Storage) throws -> SQLiteAgentStore {
        let device = (try? storage.value(for: .deviceID)) ?? "peel"
        return try SQLiteAgentStore(path: profile.agentDatabase.path, device: device)
    }
}
