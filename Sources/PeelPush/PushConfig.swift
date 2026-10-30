import Foundation

/// The ids push needs, from Info.plist keys that the build fills in from
/// `Apps/Config/Peel.xcconfig` (`PEEL_BUNDLE_ID`, `PEEL_APP_GROUP`,
/// `PEEL_KEYCHAIN_GROUP`, `PEEL_APS_ENVIRONMENT`). The app and its
/// notification extension read the same keys, so a build under another team
/// and bundle ID needs no code change.
public struct PushConfig: Equatable, Sendable {
    public static let appIDKey = "PeelAppID"
    public static let appGroupKey = "PeelAppGroup"
    public static let keychainGroupKey = "PeelKeychainGroup"
    public static let environmentKey = "PeelPushEnvironment"

    /// The app's bundle ID, which the hub will route by.
    public let appID: String
    /// The app group the app and the extension share (UserDefaults suite).
    public let appGroup: String
    /// The full Keychain access group, team prefix included.
    public let keychainGroup: String
    public let environment: PushEnvironment

    public init(appID: String, appGroup: String, keychainGroup: String, environment: PushEnvironment) {
        self.appID = appID
        self.appGroup = appGroup
        self.keychainGroup = keychainGroup
        self.environment = environment
    }

    /// Nil when a key is missing, empty, or still an unexpanded `$(…)`.
    public init?(info: [String: Any]) {
        func value(_ key: String) -> String? {
            guard let text = (info[key] as? String)?.trimmingCharacters(in: .whitespaces),
                  !text.isEmpty, !text.contains("$(") else { return nil }
            return text
        }
        guard let appID = value(Self.appIDKey), let group = value(Self.appGroupKey),
              let keychain = value(Self.keychainGroupKey),
              let environment = value(Self.environmentKey).flatMap(PushEnvironment.init(rawValue:))
        else { return nil }
        self.init(appID: appID, appGroup: group, keychainGroup: keychain, environment: environment)
    }

    /// This process's own configuration.
    public static var current: PushConfig? {
        PushConfig(info: Bundle.main.infoDictionary ?? [:])
    }
}

/// Switches for push. Off means off: nothing here is on by default.
public enum PeelPushFlags {
    /// Info.plist key and UserDefaults key for `registerWithHub`.
    public static let registerWithHubKey = "PeelPushRegisterWithHub"

    /// Whether Peel may register a push token with the core for an account.
    ///
    /// **Keep this off until the hub can route by `app_id` for Peel.** The
    /// server keeps one push token per account, so registering from Peel on
    /// a real account overwrites the official Sphinx app's token, and that
    /// app stops getting notifications. A UserDefaults value wins over
    /// Info.plist, so a development profile on the local stack can turn it
    /// on without a build.
    public static func registerWithHub(
        info: [String: Any] = Bundle.main.infoDictionary ?? [:],
        defaults: UserDefaults = .standard
    ) -> Bool {
        if defaults.object(forKey: registerWithHubKey) != nil { return defaults.bool(forKey: registerWithHubKey) }
        if let flag = info[registerWithHubKey] as? Bool { return flag }
        return false
    }
}
