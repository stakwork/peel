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
    /// the core's push registration (`registerDeviceID`).
    public static func hex(_ token: Data) -> String {
        token.map { String(format: "%02x", $0) }.joined()
    }
}

/// What the core's push registration is given beside the token: the app it
/// is for and the APNs gateway the token works on, which the mixer routes by.
/// A registration whose environment is not the token's own is undeliverable
/// and the mixer deletes it, so `pushEnvironment` is the one value the build
/// also signs into `aps-environment` (`PEEL_APS_ENVIRONMENT`, read back as
/// `PeelPushEnvironment`; `PushConfig`) and is never decided in code.
public struct PushCoreArguments: Equatable, Sendable {
    public let pushToken: String
    public let appId: String?
    public let pushEnvironment: String?

    public init(pushToken: String, appId: String?, pushEnvironment: String?) {
        self.pushToken = pushToken
        self.appId = appId
        self.pushEnvironment = pushEnvironment
    }
}

extension PushRegistration {
    /// The arguments for the core's app-aware registration.
    public var coreArguments: PushCoreArguments {
        PushCoreArguments(pushToken: token, appId: appID, pushEnvironment: environment.rawValue)
    }
}
