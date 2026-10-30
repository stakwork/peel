import Foundation
import PeelPush
import Sphinxrs
import Testing
@testable import PeelCore
@testable import PeelTestSupport

/// The registration is the one call that can take the official app's
/// notifications away, so what keeps it from running is tested (the flag, a
/// key that is not a push key), and so is what it carries: Peel's app ID and
/// the environment the build signed the token for.
struct PushRegistrationTests {
    let profile = TempProfile()

    /// Records what the core would be given, then stops the call (a
    /// `RunReturn` is not made by hand), which the engine passes on.
    final class Recorder: PushCoreRegistering, @unchecked Sendable {
        struct Stopped: Error {}
        private let lock = NSLock()
        private var seen: [(PushCoreArguments, String)] = []
        var calls: [(arguments: PushCoreArguments, key: String)] { lock.withLock { seen.map { ($0.0, $0.1) } } }

        func register(seed: String, uniqueTime: String, state: Data, pushKey: String, arguments: PushCoreArguments) throws -> RunReturn {
            lock.withLock { seen.append((arguments, pushKey)) }
            throw Stopped()
        }
    }

    private func attempt(
        _ registration: PushRegistration, allowed: Bool, key: String = PushKey.generate()
    ) async throws -> Recorder {
        let storage = try registeredStorage(profile)
        let recorder = Recorder()
        try await withTestEngine(storage, on: Transport(publishing: { _, _ in })) { engine in
            do {
                _ = try await engine.register(registration, pushKey: key, registrationAllowed: allowed, through: recorder)
            } catch is Recorder.Stopped {}
        }
        return recorder
    }

    @Test(arguments: [(PushEnvironment.development, "development"), (.production, "production")])
    func carriesPeelsAppIDAndTheTokensEnvironment(environment: PushEnvironment, word: String) async throws {
        let key = PushKey.generate()
        let recorder = try await attempt(
            PushRegistration(token: "abcd", appID: "com.sphinx.peel", environment: environment), allowed: true, key: key)
        let call = try #require(recorder.calls.first)
        #expect(recorder.calls.count == 1)
        #expect(call.arguments == PushCoreArguments(pushToken: "abcd", appId: "com.sphinx.peel", pushEnvironment: word))
        #expect(call.key == key)
    }

    @Test func nothingIsCalledWhileTheFlagIsOff() async throws {
        let recorder = try await attempt(
            PushRegistration(token: "abcd", appID: "com.sphinx.peel", environment: .development), allowed: false)
        #expect(recorder.calls.isEmpty)
    }

    @Test func nothingIsCalledWithAKeyThatIsNotAPushKey() async throws {
        let recorder = try await attempt(
            PushRegistration(token: "abcd", appID: "com.sphinx.peel", environment: .development), allowed: true, key: "nope")
        #expect(recorder.calls.isEmpty)
    }

    @Test func nothingIsCalledWithoutAToken() async throws {
        let recorder = try await attempt(
            PushRegistration(token: "", appID: "com.sphinx.peel", environment: .development), allowed: true)
        #expect(recorder.calls.isEmpty)
    }

    @Test func thePublicEntryPointSendsNothingWhileTheFlagIsOff() async throws {
        let storage = try registeredStorage(profile)
        try await withTestEngine(storage, on: Transport(publishing: { _, _ in })) { engine in
            let registered = try await engine.registerPushToken(
                PushRegistration(token: "abcd", appID: "com.sphinx.peel", environment: .development),
                pushKey: PushKey.generate(), registrationAllowed: false)
            #expect(registered == false)
        }
    }
}
