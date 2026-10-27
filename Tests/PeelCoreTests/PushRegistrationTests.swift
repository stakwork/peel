import Foundation
import PeelPush
import Testing
@testable import PeelCore
@testable import PeelTestSupport

/// `setPushToken` is the one call that can take the official app's
/// notifications away (the server keeps one token per account), so what
/// keeps it from running is tested: the flag, and a key that is not a push key.
struct PushRegistrationTests {
    let profile = TempProfile()
    private let registration = PushRegistration(token: "abcd", appID: "com.sphinx.peel", environment: .development)

    private func registers(allowed: Bool, key: String) async throws -> (registered: Bool, published: Int) {
        let storage = try registeredStorage(profile)
        let published = Counter()
        var registered = false
        try await withTestEngine(storage, on: Transport(publishing: { _, _ in published.bump() })) { engine in
            registered = try await engine.registerPushToken(registration, pushKey: key, registrationAllowed: allowed)
        }
        return (registered, published.value)
    }

    @Test func nothingIsSentWhileTheFlagIsOff() async throws {
        let result = try await registers(allowed: false, key: PushKey.generate())
        #expect(result.registered == false)
        #expect(result.published == 0)
    }

    @Test func nothingIsSentWithAKeyThatIsNotAPushKey() async throws {
        let result = try await registers(allowed: true, key: "nope")
        #expect(result.registered == false)
        #expect(result.published == 0)
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func bump() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
