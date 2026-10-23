import Foundation
import Synchronization
@testable import AgentKit

/// A count several tasks may add to.
final class Counter: Sendable {
    private let count = Mutex(0)
    var value: Int { count.withLock { $0 } }
    func increment() { count.withLock { $0 += 1 } }
}

/// A credential kept in memory; `failing` makes reads throw, as a locked Keychain would.
final class MemoryCredentials: AgentCredentialStore {
    private let kept = Mutex<AgentCredential?>(nil)
    private let fails = Mutex(false)
    var failing: Bool {
        get { fails.withLock { $0 } }
        set { fails.withLock { $0 = newValue } }
    }

    struct Locked: LocalizedError { var errorDescription: String? { "locked" } }

    func read() throws -> AgentCredential? {
        if failing { throw Locked() }
        return kept.withLock { $0 }
    }
    func write(_ credential: AgentCredential) throws { kept.withLock { $0 = credential } }
    func delete() throws { kept.withLock { $0 = nil } }
}

/// The credential the session tests connect with.
let testKey = AgentCredential(provider: .anthropic, model: "claude-sonnet-5-5", apiKey: "sk-ant-test-4f2a")

/// A fresh path for an agent store in the temporary directory; the caller removes it.
func temporaryStorePath() -> String {
    FileManager.default.temporaryDirectory.appendingPathComponent("agent-\(UUID().uuidString).sqlite").path
}
