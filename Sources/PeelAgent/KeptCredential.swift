import AgentKit
import Foundation
import PeelCore

/// The credential as JSON in one `SecretItem`: the Keychain in the app, a
/// development profile's owner-only file (`Profile.agentCredential`), read
/// by the app and by `peel eval memory --profile`.
public struct KeptCredential: AgentCredentialStore {
    let item: any SecretItem

    public init(item: any SecretItem) {
        self.item = item
    }

    public func read() throws -> AgentCredential? {
        try item.read().map { try JSONDecoder().decode(AgentCredential.self, from: $0) }
    }

    public func write(_ credential: AgentCredential) throws {
        try item.write(JSONEncoder().encode(credential))
    }

    public func delete() throws {
        try item.delete()
    }
}
