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

/// What the engine hands the core for the mixer's state: the Mac's active
/// lease (default length), the one `readAll`, and the token's removal, which
/// needs the app ID it was registered with and the same flag as registering.
struct PushStateCallTests {
    let profile = TempProfile()

    /// Records each call, then stops it (a `RunReturn` is not made by hand).
    final class Recorder: PushStateCoreCalling, @unchecked Sendable {
        struct Stopped: Error {}
        private let lock = NSLock()
        private var seen: [String] = []
        var calls: [String] { lock.withLock { seen } }

        func setActive(seed: String, uniqueTime: String, state: Data, active: Bool, ttlSecs: UInt64?) throws -> RunReturn {
            lock.withLock { seen.append("setActive \(active) ttl=\(ttlSecs.map(String.init) ?? "nil")") }
            throw Stopped()
        }

        func readAll(seed: String, uniqueTime: String, state: Data) throws -> RunReturn {
            lock.withLock { seen.append("readAll") }
            throw Stopped()
        }

        func unregisterPushToken(seed: String, uniqueTime: String, state: Data, appId: String) throws -> RunReturn {
            lock.withLock { seen.append("unregister \(appId)") }
            throw Stopped()
        }
    }

    /// Runs `body` on an engine with a transport (or none), absorbing the recorder's stop.
    private func attempt(connected: Bool = true, _ body: (Engine, Recorder) async throws -> Void) async throws -> [String] {
        let storage = try registeredStorage(profile)
        let recorder = Recorder()
        if connected {
            try await withTestEngine(storage, on: Transport(publishing: { _, _ in })) { engine in
                do { try await body(engine, recorder) } catch is Recorder.Stopped {}
            }
        } else {
            let engine = try testEngine(storage)
            do { try await body(engine, recorder) } catch is Recorder.Stopped {}
            await engine.disconnect()
        }
        return recorder.calls
    }

    @Test(arguments: [true, false])
    func theLeaseIsTheDefaultLength(active: Bool) async throws {
        let calls = try await attempt { engine, recorder in try await engine.setActive(active, through: recorder) }
        #expect(calls == ["setActive \(active) ttl=nil"])
    }

    @Test func theLeaseSendsNothingOffline() async throws {
        let calls = try await attempt(connected: false) { engine, recorder in try await engine.setActive(true, through: recorder) }
        #expect(calls.isEmpty)
    }

    @Test func readAllIsSentOnceConnectedOnly() async throws {
        let online = try await attempt { engine, recorder in try await engine.markAllRead(through: recorder) }
        #expect(online == ["readAll"])
        let offline = try await attempt(connected: false) { engine, recorder in try await engine.markAllRead(through: recorder) }
        #expect(offline.isEmpty)
    }

    @Test func unregisteringCarriesTheAppID() async throws {
        let calls = try await attempt { engine, recorder in
            _ = try await engine.unregister(appID: "com.sphinx.peel", registrationAllowed: true, through: recorder)
        }
        #expect(calls == ["unregister com.sphinx.peel"])
    }

    @Test(arguments: ["", "  \n"])
    func unregisteringWithABlankAppIDSendsNothing(blank: String) async throws {
        let calls = try await attempt { engine, recorder in
            let sent = try await engine.unregister(appID: blank, registrationAllowed: true, through: recorder)
            #expect(sent == false)
        }
        #expect(calls.isEmpty)
    }

    @Test func unregisteringWhileTheFlagIsOffSendsNothing() async throws {
        let calls = try await attempt { engine, recorder in
            let sent = try await engine.unregister(appID: "com.sphinx.peel", registrationAllowed: false, through: recorder)
            #expect(sent == false)
        }
        #expect(calls.isEmpty)
    }

    @Test func unregisteringOfflineSendsNothing() async throws {
        let calls = try await attempt(connected: false) { engine, recorder in
            let sent = try await engine.unregister(appID: "com.sphinx.peel", registrationAllowed: true, through: recorder)
            #expect(sent == false)
        }
        #expect(calls.isEmpty)
    }

    @Test func thePublicUnregisterSendsNothingWhileTheFlagIsOff() async throws {
        let storage = try registeredStorage(profile)
        try await withTestEngine(storage, on: Transport(publishing: { _, _ in })) { engine in
            let sent = try await engine.unregisterPush(appID: "com.sphinx.peel", registrationAllowed: false)
            #expect(sent == false)
        }
    }
}

struct ReadAllGateTests {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    @Test func theFirstAskIsAllowedOnceAndNotAgainThisSession() {
        var gate = ReadAllGate()
        let first = gate.claim(now: t0)
        #expect(first)
        let second = gate.claim(now: t0.addingTimeInterval(3 * 3600))
        #expect(!second, "once per session, however long after")
    }

    @Test func aRecentRunFromAnotherSessionHoldsItOffForThirtyMinutes() {
        let gate = ReadAllGate(last: t0)
        #expect(!gate.allows(now: t0.addingTimeInterval(ReadAllGate.interval - 1)))
        #expect(gate.allows(now: t0.addingTimeInterval(ReadAllGate.interval)))
    }

    @Test func aTimeInTheFutureDoesNotHoldItOff() {
        #expect(ReadAllGate(last: t0.addingTimeInterval(3600)).allows(now: t0))
    }

    @Test func claimingKeepsTheTimeInTheDefaults() throws {
        let defaults = try #require(UserDefaults(suiteName: "ReadAllGateTests-\(UUID())"))
        var gate = ReadAllGate(defaults: defaults)
        let first = gate.claim(now: t0, defaults: defaults)
        #expect(first)
        #expect(defaults.object(forKey: ReadAllGate.key) as? Date == t0)
        #expect(!ReadAllGate(defaults: defaults).allows(now: t0.addingTimeInterval(60)), "a new session reads it")
        let second = gate.claim(now: t0.addingTimeInterval(60), defaults: defaults)
        #expect(!second)
    }

    @Test func aRefusedClaimWritesNothing() throws {
        let defaults = try #require(UserDefaults(suiteName: "ReadAllGateTests-\(UUID())"))
        var gate = ReadAllGate(last: t0)
        let claimed = gate.claim(now: t0.addingTimeInterval(60), defaults: defaults)
        #expect(!claimed)
        #expect(defaults.object(forKey: ReadAllGate.key) == nil)
    }
}
