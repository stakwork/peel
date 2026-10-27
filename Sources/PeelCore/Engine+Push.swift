import Foundation
import PeelPush
import Sphinxrs

extension Engine {
    /// Registers this install's APNs token with the account's server through
    /// the core's `setPushToken`, as sphinx-ios-v2's `registerDeviceID` does.
    /// Returns whether it registered.
    ///
    /// Nothing is sent unless `PeelPushFlags.registerWithHub` is on, and it
    /// is off by default: the server keeps one push token per account, so
    /// registering from Peel on a real account takes the official Sphinx
    /// app's notifications away. Turn it on only against a stack of your own
    /// or once the hub routes by `app_id` for Peel (docs/phases/07-iphone.md,
    /// "Push: what is built"). Not connected or a key that is not a push key
    /// sends nothing either.
    ///
    /// `registrationAllowed` is a parameter so the flag's refusal is tested
    /// without touching the process's defaults.
    @discardableResult
    public func registerPushToken(
        _ registration: PushRegistration, pushKey: String,
        encoding: any PushRegistrationEncoding = PlainTokenEncoding(),
        registrationAllowed: Bool = PeelPushFlags.registerWithHub()
    ) async throws -> Bool {
        guard registrationAllowed, transport != nil, PushKey.isValid(pushKey), !registration.token.isEmpty else {
            return false
        }
        let token = encoding.coreToken(for: registration)
        try await run { time, state in
            try Sphinxrs.setPushToken(seed: seed, uniqueTime: time, state: state, pushToken: token, pushKey: pushKey)
        }
        return true
    }
}
