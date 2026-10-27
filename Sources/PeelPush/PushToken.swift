import Foundation

/// Where an APNs token is valid: Debug builds register with Apple's sandbox,
/// Release ones with production. The hub must send to the matching gateway.
public enum PushEnvironment: String, Sendable, Equatable {
    case development
    case production
}

/// What Peel tells the push path about this install: the APNs token as hex,
/// the app it is for and the gateway it works on.
public struct PushRegistration: Equatable, Sendable {
    public let token: String
    public let appID: String
    public let environment: PushEnvironment

    public init(token: String, appID: String, environment: PushEnvironment) {
        self.token = token
        self.appID = appID
        self.environment = environment
    }
}

public enum PushToken {
    /// The device token as lowercase hex, which is how Sphinx hands it to
    /// `setPushToken` (`registerDeviceID`).
    public static func hex(_ token: Data) -> String {
        token.map { String(format: "%02x", $0) }.joined()
    }
}

/// How a registration is put into the one string the core's `setPushToken`
/// takes. The core knows nothing of an app ID or a gateway.
///
/// TODO: when sphinx-rs and the mixer carry an `app_id` and an environment
/// with the token (hub routing for Peel, one registration per app), write the
/// encoding here and nowhere else. Until then the token goes as Sphinx sends
/// it, and the registration's app and environment go nowhere.
public protocol PushRegistrationEncoding: Sendable {
    func coreToken(for registration: PushRegistration) -> String
}

public struct PlainTokenEncoding: PushRegistrationEncoding {
    public init() {}
    public func coreToken(for registration: PushRegistration) -> String { registration.token }
}
