import Foundation
@testable import PeelCore

/// The agent's credential for the preferences sync, held in memory: what
/// the app backs with the Keychain (`SyncedAgentCredential`). Never touches
/// a file, so a test can prove the key reached no database.
final class FakeAgentCredential: SyncedAgentCredential, @unchecked Sendable {
    private let lock = NSLock()
    private var config: AgentConfig?
    private var unreadable = false
    /// How many times a key from the file was kept.
    private(set) var keeps = 0

    init(_ config: AgentConfig? = nil) {
        self.config = config
    }

    var current: AgentConfig? {
        lock.withLock { config }
    }

    /// What connecting a model by hand does: replaces what is kept.
    func connect(_ config: AgentConfig?) {
        lock.withLock { self.config = config }
    }

    func failReads(_ fails: Bool) {
        lock.withLock { unreadable = fails }
    }

    func read() throws -> AgentConfig? {
        try lock.withLock {
            if unreadable { throw PeelError("the Keychain is locked") }
            return config
        }
    }

    func keep(_ config: AgentConfig) throws {
        lock.withLock {
            self.config = config
            keeps += 1
        }
    }
}
