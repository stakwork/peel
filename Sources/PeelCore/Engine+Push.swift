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

extension Engine {
    /// Registers this install's APNs token with the account's server through
    /// the core (`setPushTokenForApp`), as sphinx-ios-v2's `registerDeviceID`
    /// does, with Peel's app ID and the token's APNs environment so the hub
    /// can route by app. Returns whether it registered.
    ///
    /// Nothing is sent unless `PeelPushFlags.registerWithHub` is on, and it
    /// is off by default (docs/phases/07-iphone.md, "Push: what is built",
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
