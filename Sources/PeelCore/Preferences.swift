import Foundation
import GRDB

/// One user setting: its item in the official apps' preferences file
/// (`docs/phases/11-preferences-sync.md`), where it is kept, and how its
/// value reads and writes. The registry is the static members below;
/// `Storage.preference` and `Storage.setPreference` are the only way a
/// setting is read or written.
public struct Preference<Value: Sendable>: Sendable {
    /// The item's key in the file: an official key with the official
    /// encoding, a Peel-only key under `peel.`, or a device-only key under `device.`.
    public let key: String
    public let scope: PreferenceScope
    /// The value as the official apps read it; nil if it is not one.
    let read: @Sendable (JSONValue) -> Value?
    /// The value as the file holds it; throws for one it cannot hold.
    let write: @Sendable (Value) throws -> JSONValue
    /// The apply policy: whether a value from the file is taken here, given
    /// the one this device holds (nil for none). Any, unless the setting
    /// guards money: then only one that asks for no less here.
    var takes: @Sendable (_ incoming: Value, _ current: Value?) -> Bool = { _, _ in true }
    /// Whether a value chosen here goes up to the file. False for an
    /// import-only setting (`chat_color`): the file's value is taken, and
    /// no row of it is ever uploaded, of any date, so a writer added later
    /// cannot leak it (decision 9 of phase 11).
    var uploads = true
    /// Whether a device syncs it only when it says so
    /// (`PreferenceCapabilities`): a key another platform owns stays a
    /// pass-through in the file here (decisions 10 and 11).
    var optIn = false
    /// Whether a value from the file is stored in its canonical form (what
    /// `write` gives for what `read` took), not as the file has it.
    var canonical = false
    /// For a secret: whether two values are the same one, so a sync never
    /// asks whether to replace what is already here.
    var same: (@Sendable (Value, Value) -> Bool)?

    var entry: (String, Preferences.Entry) {
        (key, Preferences.Entry(
            scope: scope,
            takes: { [read, takes] incoming, current in
                guard let value = read(incoming) else { return false }
                return takes(value, current.flatMap(read))
            },
            uploads: uploads, optIn: optIn,
            normalised: { [read, write, canonical] value in
                guard canonical, let parsed = read(value), let written = try? write(parsed) else { return value }
                return written
            },
            sameSecret: { [read, same] first, second in
                guard let same, let one = read(first), let other = read(second) else { return false }
                return same(one, other)
            }
        ))
    }
}

public enum PreferenceScope: Sendable {
    /// Follows the account between its devices (the preferences file).
    case account
    /// Stays on this device; its key starts with `device.`.
    case device
    /// Follows the account like `.account`, but its value is a secret: it
    /// is never stored in the database, only handed to the Keychain
    /// (`SyncedAgentCredential`); the `preference` row under its key holds
    /// a fixed placeholder and the item's date, nothing else.
    case secret
}

/// A setting that has no value of this type, or one the file cannot hold.
struct UnwritablePreference: Error, CustomStringConvertible {
    let key: String
    var description: String { "the preference \(key) cannot hold that value" }
}

// MARK: - The registry

extension Preference where Value == UInt64 {
    /// What a one-tap boost tips, in msat: the official `tip_amount`, kept
    /// in whole sats (`DataSyncModels.swift:270-278`).
    public static var boostAmountMsat: Self {
        Self(key: "tip_amount", scope: .account, read: { value in
            guard let sats = value.wholeNumber, sats > 0, sats <= UInt64.max / 1000 else { return nil }
            return sats * 1000
        }, write: { msat in
            guard msat > 0, msat % 1000 == 0 else { throw UnwritablePreference(key: "tip_amount") }
            return .string(String(msat / 1000))
        })
    }

    /// Payments and boosts over this many msat are confirmed first; Peel
    /// only. Taken from the file only when it is stricter than this
    /// device's (decision 7): a device never asks for less because another did.
    public static var paymentConfirmationMsat: Self {
        Self(key: "peel.payment_confirmation_msat", scope: .account, read: { $0.wholeNumber },
             write: { .string(String($0)) },
             takes: { incoming, current in incoming <= (current ?? Engine.defaultPaymentConfirmationMsat) })
    }

    /// The boost amount last confirmed on this device, in msat: a one-tap
    /// boost over the threshold sends only this one unasked (decision 3).
    public static var boostConfirmedMsat: Self {
        Self(key: "device.boost_confirmed_msat", scope: .device, read: { $0.wholeNumber },
             write: { .string(String($0)) })
    }

    /// When the preferences layer came to this device (v24), in seconds: a
    /// device starting the file anew uploads only what was chosen since.
    public static var preferencesSince: Self {
        Self(key: "device.preferences_since", scope: .device, read: { $0.wholeNumber },
             write: { .string(String($0)) })
    }
}

extension Preference where Value == String {
    /// A colour another device gave a person or a chat: the official
    /// `chat_color`, its identifier the colour key (`<pubkey>-color`,
    /// `chat-<pubkey>-color`, `<alias>-color`). Import-only: the official
    /// apps write each colour once from their own random pick, and Peel has
    /// no picker, so it takes the file's and never uploads one. Read as
    /// `#rrggbb` or `rrggbb`, any case, and stored as lower case `#rrggbb`
    /// (never bare hex, which the official apps' string retyping can turn
    /// into a number); anything else is refused.
    public static var chatColor: Self {
        Self(key: Preferences.chatColorKey, scope: .account, read: { $0.string.flatMap(ChatColour.normalised) },
             write: { hex in
                 guard let normal = ChatColour.normalised(hex) else { throw UnwritablePreference(key: Preferences.chatColorKey) }
                 return .string(normal)
             }, uploads: false, canonical: true)
    }

    /// The zone this account's offset comes from, an IANA name or a fixed
    /// `GMT±H`; "" means each device's own. Peel only: the official apps
    /// set a zone per chat or use the device's.
    public static var timeZone: Self {
        Self(key: "peel.time_zone", scope: .account, read: \.string, write: { .string($0) })
    }

    /// The memes server this device has seen the account's preferences
    /// file on (one decrypted here, or an upload done). From then on that
    /// server's "not found", which it also says for a storage error, is not
    /// believed: Peel never starts the file anew over a real one. A new
    /// memes server is a new start.
    public static var preferencesFileSeen: Self {
        Self(key: "device.preferences_file_seen", scope: .device, read: \.string, write: { .string($0) })
    }
}

extension Preference where Value == Bool {
    /// Whether this device may start the account's preferences file on a
    /// "not found": written only when an account is signed up or created
    /// by a build that has sync (`Account.open`), never by a restore or the
    /// migration, so no existing database starts a file (decision 8).
    public static var mayStartPreferences: Self {
        Self(key: "device.may_start_preferences", scope: .device, read: \.flag, write: { .string($0 ? "true" : "false") })
    }
}

extension Preference where Value == Bool {
    /// Whether the person turned Face ID on: the official `biometric_enabled`
    /// (iOS writes it and applies it; the Mac app ignores it). Synced only
    /// by a device that has Face ID to offer (`PreferenceCapabilities`); a
    /// value from the file is the person's wish and never enrols anything
    /// (decision 10).
    public static var biometricEnabled: Self {
        Self(key: Preferences.biometricKey, scope: .account, read: \.flag, write: { .string($0 ? "true" : "false") },
             optIn: true)
    }
}

extension Preference where Value == AgentConfig {
    /// The agent's model and key: the official `ai_agent_config`,
    /// `"<Provider>|<apiKey>|<agentName>"`. A secret: the key lives only in
    /// the Keychain (`SyncedAgentCredential`), the row under this key holds
    /// the item's date and a placeholder. Synced only by a device with an
    /// agent (decision 11).
    public static var agentConfig: Self {
        Self(key: Preferences.agentConfigKey, scope: .secret, read: { $0.string.flatMap(AgentConfig.init(item:)) },
             write: { config in
                 guard !config.apiKey.isEmpty else { throw UnwritablePreference(key: Preferences.agentConfigKey) }
                 return .string(config.item)
             }, optIn: true, same: { $0.provider == $1.provider && $0.apiKey == $1.apiKey })
    }
}

extension Preference where Value == TimeZoneSharing {
    /// Whether this account's offset goes with what it sends in one chat,
    /// and a zone for that chat: the official `timezone` item, identifier
    /// the chat's pubkey (`DataSyncModels.swift:435-510`).
    public static var timeZoneSharing: Self {
        Self(key: "timezone", scope: .account, read: TimeZoneSharing.init(item:), write: \.item)
    }
}

extension Preference where Value == Int {
    /// Hours without use before the app asks for the PIN again; 0 means
    /// only at launch. This device only: the PIN is this device's, and the
    /// official `pin_timeout` has another scale (decision 4 of phase 11).
    public static var pinTimeoutHours: Self {
        Self(key: "device.pin_timeout_hours", scope: .device, read: { $0.wholeNumber.flatMap { Int(exactly: $0) } },
             write: { .string(String(max(0, $0))) })
    }
}

extension Preference where Value == Bool {
    /// Whether notifications show what a message says. This device only:
    /// it is about who can see this screen.
    public static var notificationText: Self {
        Self(key: "device.notification_text", scope: .device, read: \.flag, write: { .string($0 ? "true" : "false") })
    }
}

extension Preference where Value == NotificationPolicy.Style {
    /// What a notification does: banner, sound, both or neither. This
    /// device only: it is about this Mac's screen and speakers.
    public static var notificationStyle: Self {
        Self(key: "device.notification_style", scope: .device,
             read: { $0.string.flatMap(NotificationPolicy.Style.init(rawValue:)) }, write: { .string($0.rawValue) })
    }
}

extension Preference where Value == String {
    /// The name of the sound a notification plays; "" is the default.
    public static var notificationSound: Self {
        Self(key: "device.notification_sound", scope: .device, read: \.string, write: { .string($0) })
    }
}

/// Every registered key and whether it follows the account: what sync may
/// read from the file and write to it, and nothing else.
public enum Preferences {
    /// The identifier of an account-wide item (a per-chat one has the chat's pubkey).
    public static let accountWide = "0"
    /// Peel-only keys: the official apps keep and ignore them.
    static let peelPrefix = "peel."
    static let devicePrefix = "device."
    /// The official keys Peel now reads (`pin_timeout` is not among them).
    static let chatColorKey = "chat_color"
    static let biometricKey = "biometric_enabled"
    static let agentConfigKey = "ai_agent_config"

    /// A registered key: where it goes, and its apply policy
    /// (`Preference.takes`, false for a value that is not one of its) over
    /// the stored value.
    struct Entry: Sendable {
        let scope: PreferenceScope
        let takes: @Sendable (_ incoming: JSONValue, _ current: JSONValue?) -> Bool
        /// False for an import-only key: `merged` never uploads or
        /// bootstraps a row of it.
        var uploads = true
        /// Synced only where the engine enables it (`PreferenceCapabilities`).
        var optIn = false
        /// A value from the file as it is stored; as it came unless the key stores one form.
        var normalised: @Sendable (JSONValue) -> JSONValue = { $0 }
        /// For a secret: whether two values are the same one.
        var sameSecret: @Sendable (JSONValue, JSONValue) -> Bool = { _, _ in false }

        var followsAccount: Bool { scope != .device }
    }

    /// Every preference in the registry, by key: add a new one here.
    static let registry: [String: Entry] = Dictionary(uniqueKeysWithValues: [
        Preference<UInt64>.boostAmountMsat.entry,
        Preference<UInt64>.paymentConfirmationMsat.entry,
        Preference<UInt64>.boostConfirmedMsat.entry,
        Preference<UInt64>.preferencesSince.entry,
        Preference<String>.timeZone.entry,
        Preference<String>.chatColor.entry,
        Preference<Bool>.biometricEnabled.entry,
        Preference<AgentConfig>.agentConfig.entry,
        Preference<TimeZoneSharing>.timeZoneSharing.entry,
        Preference<Int>.pinTimeoutHours.entry,
        Preference<Bool>.notificationText.entry,
        Preference<NotificationPolicy.Style>.notificationStyle.entry,
        Preference<String>.notificationSound.entry,
        Preference<String>.preferencesFileSeen.entry,
        Preference<Bool>.mayStartPreferences.entry,
    ])

    /// The keys that follow the account on every device, plus the opt-in
    /// ones `optIns` names: what sync may read from the file and write to it.
    /// An opt-in key not named stays a pass-through in the file, byte for byte.
    static func syncedKeys(enabling optIns: Set<String>) -> Set<String> {
        Set(registry.filter { $0.value.followsAccount && (!$0.value.optIn || optIns.contains($0.key)) }.keys)
    }

    /// Keys that follow the account on every device.
    static let synced = syncedKeys(enabling: [])

    /// What the official apps write back for a string they read, or nil
    /// where reading it crashes them: "true"/"false" in any case become a
    /// bool, a string `Int` reads becomes that int, and one `Double` reads
    /// without a "." becomes `Int(double)`, which traps outside Int's range
    /// (`DataSyncModels.swift:155-180`, written back at `:34-96`).
    static func officialRewrite(_ text: String) -> String? {
        switch text.lowercased() {
        case "true": return "true"
        case "false": return "false"
        default: break
        }
        if let number = Int(text) { return String(number) }
        if let number = Double(text), !text.contains(".") {
            guard number.isFinite, number >= -0x1p63, number < 0x1p63 else { return nil }
            return String(Int(number))
        }
        return text
    }

    /// Whether the official apps read `value` and write it back unchanged:
    /// a string their rules leave alone, or exactly the `timezone` object
    /// with "true" or "false". Peel writes nothing else to the file.
    static func isOfficialFixedPoint(_ value: JSONValue) -> Bool {
        switch value {
        case .string(let text):
            return officialRewrite(text) == text
        case .object(let fields):
            guard fields.count == 2, case .string(let enabled)? = fields["timezone_enabled"],
                  case .string? = fields["timezone_identifier"] else { return false }
            return enabled == "true" || enabled == "false"
        default:
            return false
        }
    }
}

/// A chat's time zone item: share the offset there, and a zone for that
/// chat only (set on another device; Peel never writes one of its own).
public struct TimeZoneSharing: Sendable, Equatable {
    public var enabled: Bool
    /// Nil means the account's zone ("" in the file).
    public var identifier: String?

    public init(enabled: Bool, identifier: String?) {
        self.enabled = enabled
        self.identifier = identifier
    }

    /// As the official apps read it: `timezone_enabled` (or the legacy
    /// `timezoneEnabled`) a string, "true" in any case meaning on; the
    /// identifier "" or missing meaning none (`DataSyncModels.swift:461-486`).
    init?(item value: JSONValue) {
        guard case .object(let fields) = value else { return nil }
        for (enabledKey, identifierKey) in [("timezone_enabled", "timezone_identifier"), ("timezoneEnabled", "timezoneIdentifier")] {
            guard case .string(let enabled)? = fields[enabledKey] else { continue }
            self.enabled = enabled.lowercased() == "true"
            identifier = fields[identifierKey]?.string?.nilIfEmpty
            return
        }
        return nil
    }

    var item: JSONValue {
        .object(["timezone_enabled": .string(enabled ? "true" : "false"), "timezone_identifier": .string(identifier ?? "")])
    }
}

// MARK: - JSON values

/// A JSON value kept as it was read, so an item Peel does not change goes
/// back into the file as it came.
public enum JSONValue: Sendable, Equatable, Codable {
    case string(String)
    case int(Int64)
    case double(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    init?(text: String) {
        guard let value = JSON.decode(JSONValue.self, from: text) else { return nil }
        self = value
    }

    /// Compact, keys sorted: the same value always gives the same text.
    var text: String {
        get throws {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return String(decoding: try encoder.encode(self), as: UTF8.self)
        }
    }

    public var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    /// A whole number of zero or more, written as the official apps write
    /// ints (a string) or as a JSON number they also read.
    var wholeNumber: UInt64? {
        switch self {
        case .string(let text): return Int(text).flatMap { UInt64(exactly: $0) }
        case .int(let value): return UInt64(exactly: value)
        default: return nil
        }
    }

    /// A bool as the official apps read one: "true"/"false" in any case, or a JSON bool.
    var flag: Bool? {
        switch self {
        case .bool(let value): return value
        case .string(let text): return ["true": true, "false": false][text.lowercased()]
        default: return nil
        }
    }
}

// MARK: - Storage

/// One preference as stored: the file's item for this key and identifier.
public struct PreferenceRow: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "preference"
    public internal(set) var key: String
    public internal(set) var identifier: String
    /// The item's value as JSON text.
    public internal(set) var value: String
    /// The item's date in seconds; 0 for a value never chosen on a device
    /// that syncs (one kept from before sync).
    public internal(set) var updatedAt: Double

    /// Whether it follows the account to its other devices.
    public var followsAccount: Bool { Preferences.registry[key]?.followsAccount ?? false }

    /// The value as `prefs` prints it: a secret's is never shown.
    public var displayValue: String { isSecret ? "<redacted>" : value }

    /// Whether its value is a secret kept elsewhere: the row holds only a placeholder.
    public var isSecret: Bool { Preferences.registry[key]?.scope == .secret }
}

extension Storage {
    /// The value set for `preference` (for a chat, by its pubkey); nil when
    /// none is, or what is stored is not one.
    public func preference<Value>(_ preference: Preference<Value>, for identifier: String = Preferences.accountWide) throws -> Value? {
        // A secret's row holds a placeholder, never a value.
        guard preference.scope != .secret else { return nil }
        return try preferenceRow(preference.key, identifier).flatMap { JSONValue(text: $0.value) }.flatMap(preference.read)
    }

    func preferenceRow(_ key: String, _ identifier: String) throws -> PreferenceRow? {
        try pool.read { db in try PreferenceRow.fetchOne(db, key: ["key": key, "identifier": identifier]) }
    }

    /// Every stored preference, by key and identifier.
    public func preferenceRows() throws -> [PreferenceRow] {
        try pool.read { db in try PreferenceRow.order(Column("key"), Column("identifier")).fetchAll(db) }
    }

    /// Sets `preference` to `value`, dated `now` but always after the
    /// version it replaces, so a change beats what it was made on even when
    /// that came from a device whose clock runs ahead. An account value
    /// must be one the official apps write back unchanged. Returns false
    /// when the value was already this and chosen (a value from before
    /// sync, date 0, chosen again gets its date).
    @discardableResult
    func setPreference<Value>(
        _ preference: Preference<Value>, _ value: Value, for identifier: String = Preferences.accountWide,
        at now: Date = .now
    ) throws -> Bool {
        // A secret's value goes to the Keychain, never through here.
        guard preference.scope != .secret else { throw UnwritablePreference(key: preference.key) }
        let item = try preference.write(value)
        guard preference.scope == .device || Preferences.isOfficialFixedPoint(item) else {
            throw UnwritablePreference(key: preference.key)
        }
        let text = try item.text
        return try pool.write { db in
            let old = try PreferenceRow.fetchOne(db, key: ["key": preference.key, "identifier": identifier])
            if let old, old.value == text, old.updatedAt > 0 { return false }
            let date = (max(now.timeIntervalSince1970, (old?.updatedAt ?? 0) + 1)).rounded(.down)
            try PreferenceRow(key: preference.key, identifier: identifier, value: text, updatedAt: date).upsert(db)
            return true
        }
    }
}

extension Storage {
    /// What a secret's row holds in place of its value.
    static let secretPlaceholder = "\"redacted-secret\""

    /// Dates a secret's item `date` (or now, but after the version it
    /// replaces) under a placeholder: the date is all `merged` needs to
    /// order it against the file, and no key material is kept.
    func setSecretDate(_ key: String, for identifier: String = Preferences.accountWide, at date: Date = .now) throws {
        guard Preferences.registry[key]?.scope == .secret else { throw UnwritablePreference(key: key) }
        try pool.write { db in
            let old = try PreferenceRow.fetchOne(db, key: ["key": key, "identifier": identifier])
            let seconds = (max(date.timeIntervalSince1970, (old?.updatedAt ?? 0) + 1)).rounded(.down)
            try PreferenceRow(key: key, identifier: identifier, value: Self.secretPlaceholder, updatedAt: seconds).upsert(db)
        }
    }

    /// Records that a secret item from the file dated `date` is held here.
    func takeSecretDate(_ key: String, for identifier: String = Preferences.accountWide, date: Double) throws {
        guard Preferences.registry[key]?.scope == .secret else { throw UnwritablePreference(key: key) }
        try pool.write { db in
            try PreferenceRow(key: key, identifier: identifier, value: Self.secretPlaceholder, updatedAt: date).upsert(db)
        }
    }

    /// Every colour another device gave, by colour key (`<pubkey>-color`,
    /// `chat-<pubkey>-color`, `<alias>-color`), as `#rrggbb`. Keys that are
    /// not colour keys are left out.
    func syncedColours() throws -> [String: String] {
        var colours: [String: String] = [:]
        for row in try preferenceRows() where row.key == Preferences.chatColorKey && row.identifier.hasSuffix("-color") {
            guard let hex = JSONValue(text: row.value)?.string.flatMap(ChatColour.normalised) else { continue }
            colours[row.identifier] = hex
        }
        return colours
    }
}
