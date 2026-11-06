import Foundation
import PeelPush
import Sphinxrs

/// The one core call that registers a push token. A seam so a test sees the
/// app ID and environment it is given without a server.
protocol PushCoreRegistering: Sendable {
    func register(seed: String, uniqueTime: String, state: Data, pushKey: String, arguments: PushCoreArguments) throws -> RunReturn
}

/// The core's `setPushTokenForApp` (sphinx-rs 0.8.40), which carries an
/// `app_id` and a `push_environment` with the token.
struct CorePushRegistrar: PushCoreRegistering {
    func register(seed: String, uniqueTime: String, state: Data, pushKey: String, arguments: PushCoreArguments) throws -> RunReturn {
        try Sphinxrs.setPushTokenForApp(
            seed: seed, uniqueTime: uniqueTime, state: state, pushToken: arguments.pushToken, pushKey: pushKey,
            appId: arguments.appId, pushEnvironment: arguments.pushEnvironment)
    }
}

/// The core's calls that tell the mixer how to push to this account: whether
/// a device is being used (`setActive`), that everything is read (`readAll`)
/// and that a push token goes (`unregisterPushTokenForApp`). A seam so a
/// test sees what each is given without a server.
protocol PushStateCoreCalling: Sendable {
    func setActive(seed: String, uniqueTime: String, state: Data, active: Bool, ttlSecs: UInt64?) throws -> RunReturn
    func readAll(seed: String, uniqueTime: String, state: Data) throws -> RunReturn
    func unregisterPushToken(seed: String, uniqueTime: String, state: Data, appId: String) throws -> RunReturn
}

/// The core's `setActive`, `readAll` and `unregisterPushTokenForApp`
/// (sphinx-rs 0.8.42).
struct CorePushStateCaller: PushStateCoreCalling {
    func setActive(seed: String, uniqueTime: String, state: Data, active: Bool, ttlSecs: UInt64?) throws -> RunReturn {
        try Sphinxrs.setActive(seed: seed, uniqueTime: uniqueTime, state: state, active: active, ttlSecs: ttlSecs)
    }

    func readAll(seed: String, uniqueTime: String, state: Data) throws -> RunReturn {
        try Sphinxrs.readAll(seed: seed, uniqueTime: uniqueTime, state: state)
    }

    func unregisterPushToken(seed: String, uniqueTime: String, state: Data, appId: String) throws -> RunReturn {
        try Sphinxrs.unregisterPushTokenForApp(seed: seed, uniqueTime: uniqueTime, state: state, appId: appId)
    }
}

extension Engine {
    /// Tells the account's server whether this device is being used, so the
    /// mixer pushes only badge updates to the others while one is active.
    /// Only the Mac sends it (`Platform.sendsActiveLease`); the phone never
    /// does. The lease is the server's default length (no `ttlSecs`), so the
    /// caller renews it while it holds. Sends nothing while not connected.
    public func setDeviceActive(_ active: Bool) async throws {
        try await setActive(active, through: CorePushStateCaller())
    }

    func setActive(_ active: Bool, through caller: any PushStateCoreCalling) async throws {
        guard transport != nil else { return }
        try await run { time, state in
            try caller.setActive(seed: seed, uniqueTime: time, state: state, active: active, ttlSecs: nil)
        }
    }

    /// Takes this install's push token off the account's server for the app
    /// ID it was registered with (`unregisterPushTokenForApp`), for Forget.
    /// Returns whether it was sent: not with a blank app ID, without a
    /// connection, or while `PeelPushFlags.registerWithHub` is off, as
    /// `registerPushToken`.
    @discardableResult
    public func unregisterPush(
        appID: String, registrationAllowed: Bool = PeelPushFlags.registerWithHub()
    ) async throws -> Bool {
        try await unregister(appID: appID, registrationAllowed: registrationAllowed, through: CorePushStateCaller())
    }

    func unregister(appID: String, registrationAllowed: Bool, through caller: any PushStateCoreCalling) async throws -> Bool {
        let appID = appID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard registrationAllowed, transport != nil, !appID.isEmpty else { return false }
        try await run { time, state in
            try caller.unregisterPushToken(seed: seed, uniqueTime: time, state: state, appId: appID)
        }
        return true
    }

    /// Tells the server every chat is read (`readAll`), so the mixer's badge
    /// count restarts from zero. The caller decides when (`ReadAllGate`).
    /// Sends nothing while not connected.
    public func markEverythingRead() async throws {
        try await markAllRead(through: CorePushStateCaller())
    }

    func markAllRead(through caller: any PushStateCoreCalling) async throws {
        guard transport != nil else { return }
        try await run { time, state in
            try caller.readAll(seed: seed, uniqueTime: time, state: state)
        }
    }

    /// Registers this install's APNs token with the account's server through
    /// the core (`setPushTokenForApp`), as sphinx-ios-v2's `registerDeviceID`
    /// does, with Peel's app ID and the token's APNs environment so the hub
    /// can route by app. Returns whether it registered.
    ///
    /// Nothing is sent unless `PeelPushFlags.registerWithHub` is on, and it
    /// is off without its Info.plist key (docs/phases/07-iphone.md, "Push: what is built",
    /// "Turning registration on"). Not connected, or a key that is not a
    /// push key, or an empty token, sends nothing either.
    ///
    /// `registrationAllowed` is a parameter so the flag's refusal is tested
    /// without touching the process's defaults.
    @discardableResult
    public func registerPushToken(
        _ registration: PushRegistration, pushKey: String,
        registrationAllowed: Bool = PeelPushFlags.registerWithHub()
    ) async throws -> Bool {
        try await register(registration, pushKey: pushKey, registrationAllowed: registrationAllowed, through: CorePushRegistrar())
    }

    func register(
        _ registration: PushRegistration, pushKey: String, registrationAllowed: Bool,
        through registrar: any PushCoreRegistering
    ) async throws -> Bool {
        guard registrationAllowed, transport != nil, PushKey.isValid(pushKey), !registration.token.isEmpty else {
            return false
        }
        let arguments = registration.coreArguments
        try await run { time, state in
            try registrar.register(
                seed: seed, uniqueTime: time, state: state, pushKey: pushKey, arguments: arguments)
        }
        return true
    }
}
