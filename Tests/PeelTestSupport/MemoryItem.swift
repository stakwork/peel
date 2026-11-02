import Foundation
@testable import PeelCore

/// A `SecretItem` held in memory: what the Keychain backs in the app.
final class MemoryItem: SecretItem, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?

    init(_ data: Data? = nil) { self.data = data }

    var value: Data? { lock.withLock { data } }

    func read() throws -> Data? { lock.withLock { data } }
    func write(_ data: Data) throws { lock.withLock { self.data = data } }
    func delete() throws { lock.withLock { data = nil } }
}
