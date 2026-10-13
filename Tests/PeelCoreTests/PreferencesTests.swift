import Foundation
import Testing
@testable import PeelCore
@testable import PeelTestSupport

/// The preferences layer (`Preferences.swift`): the registry, the official
/// apps' encodings, and how a value is stored and dated.
struct PreferencesTests {
    let profile = TempProfile()

    // MARK: The registry

    /// Official keys by their official names, Peel's under `peel.`, and
    /// what stays on this device under `device.`, never synced.
    @Test func keysAreNamespacedByWhereTheyGo() {
        let official: Set = ["tip_amount", "timezone"]
        for (key, entry) in Preferences.registry {
            if entry.scope == .account {
                #expect(official.contains(key) || key.hasPrefix(Preferences.peelPrefix), "\(key)")
            } else {
                #expect(key.hasPrefix(Preferences.devicePrefix), "\(key)")
            }
        }
        #expect(Preferences.synced == official.union(["peel.payment_confirmation_msat", "peel.time_zone"]))
    }

    /// What the official apps write back for a string they read
    /// (`DataSyncModels.swift:155-180`), and the strings that crash them.
    @Test func theOfficialRewriteOfAString() {
        let cases: [(String, String?)] = [
            ("250", "250"), ("007", "7"), ("+5", "5"), ("-0", "0"), ("TRUE", "true"), ("False", "false"),
            ("true", "true"), ("1e3", "1000"), ("0x10", "16"), ("1.5", "1.5"), ("", ""), ("Europe/London", "Europe/London"),
            ("GMT+5:30", "GMT+5:30"), ("{\"a\":1}", "{\"a\":1}"),
            ("inf", nil), ("-infinity", nil), ("nan", nil), ("1e30", nil), ("9223372036854775808", nil),
        ]
        for (text, rewritten) in cases {
            #expect(Preferences.officialRewrite(text) == rewritten, "\(text)")
        }
    }

    /// Every value the account's preferences write comes back unchanged
    /// through the official reader and writer.
    @Test func everySyncedEncodingIsAFixedPoint() throws {
        for msat: UInt64 in [1000, 100_000, 21_000_000, 1_000_000_000_000] {
            #expect(Preferences.isOfficialFixedPoint(try Preference.boostAmountMsat.write(msat)))
        }
        for msat: UInt64 in [0, 1, 100_000, UInt64(Int64.max)] {
            #expect(Preferences.isOfficialFixedPoint(try Preference.paymentConfirmationMsat.write(msat)))
        }
        for zone in [""] + TimeZone.knownTimeZoneIdentifiers + ["GMT+1", "GMT-3:30"] {
            #expect(Preferences.isOfficialFixedPoint(try Preference.timeZone.write(zone)), "\(zone)")
        }
        for sharing in [true, false].flatMap({ on in [nil, "Asia/Bangkok"].map { TimeZoneSharing(enabled: on, identifier: $0) } }) {
            #expect(Preferences.isOfficialFixedPoint(try Preference.timeZoneSharing.write(sharing)))
        }
        // The fixed-point check refuses what the official apps would change or choke on.
        for value: JSONValue in [.string("007"), .string("nan"), .int(5), .bool(true), .null, .array([]),
                                 .object(["timezone_enabled": .string("TRUE"), "timezone_identifier": .string("")]),
                                 .object(["timezone_enabled": .string("true")])] {
            #expect(!Preferences.isOfficialFixedPoint(value), "\(value)")
        }
    }

    /// Reading is as lenient as the official apps: sats as a string or a
    /// JSON number, a time zone item in the legacy camelCase too.
    /// The threshold is taken from the file only when it asks for no less
    /// confirmation here (decision 7); the others take any value.
    @Test func applyPolicies() throws {
        let threshold = try #require(Preferences.registry["peel.payment_confirmation_msat"])
        #expect(threshold.takes(.string("50000"), .string("100000")))
        #expect(threshold.takes(.string("100000"), .string("100000")))
        #expect(!threshold.takes(.string("200000"), .string("100000")))
        // Unset here means the default, 100 sats.
        #expect(threshold.takes(.string("0"), nil) && !threshold.takes(.string("100001"), nil))
        #expect(!threshold.takes(.string("lots"), nil))
        let tip = try #require(Preferences.registry["tip_amount"])
        #expect(tip.takes(.string("5000"), .string("100")))
    }

    @Test func valuesReadAsTheOfficialAppsReadThem() throws {
        let tip = Preference<UInt64>.boostAmountMsat
        #expect(tip.read(.string("250")) == 250_000)
        #expect(tip.read(.int(250)) == 250_000)
        for bad: JSONValue in [.string("0"), .string("-5"), .string("abc"), .string("2.5"), .bool(true), .null] {
            #expect(tip.read(bad) == nil, "\(bad)")
        }
        #expect(throws: UnwritablePreference.self) { try tip.write(1500) }
        let sharing = Preference<TimeZoneSharing>.timeZoneSharing
        let legacy = JSONValue(text: #"{"timezoneEnabled":"TRUE","timezoneIdentifier":"Asia/Bangkok"}"#)
        #expect(legacy.flatMap(sharing.read) == TimeZoneSharing(enabled: true, identifier: "Asia/Bangkok"))
        let current = JSONValue(text: #"{"timezone_enabled":"false","timezone_identifier":""}"#)
        #expect(current.flatMap(sharing.read) == TimeZoneSharing(enabled: false, identifier: nil))
        #expect(sharing.read(.object(["timezone_identifier": .string("UTC")])) == nil)
        #expect(Preference<Bool>.notificationText.read(.string("FALSE")) == false)
    }

    // MARK: Storing

    /// A change is dated now, but always after the version it replaces, and
    /// in whole seconds; setting the same value again changes nothing.
    @Test func aChangeIsDatedAfterWhatItReplaces() throws {
        let storage = try profile.storage()
        let now = Date(timeIntervalSince1970: 1_760_000_000.7)
        #expect(try storage.setPreference(.boostAmountMsat, 21_000, at: now))
        #expect(try storage.preferenceRow("tip_amount", "0")?.updatedAt == 1_760_000_000)
        #expect(try !storage.setPreference(.boostAmountMsat, 21_000, at: now.addingTimeInterval(60)))
        #expect(try storage.preferenceRow("tip_amount", "0")?.updatedAt == 1_760_000_000)
        // Another device's clock ran ahead: the change still beats it.
        try storage.pool.write { db in
            try PreferenceRow(key: "tip_amount", identifier: "0", value: #""500""#, updatedAt: 1_760_009_999.5).upsert(db)
        }
        try storage.setPreference(.boostAmountMsat, 42_000, at: now)
        #expect(try storage.preferenceRow("tip_amount", "0")?.updatedAt == 1_760_010_000)
        #expect(try storage.preference(.boostAmountMsat) == 42_000)
        // A value from before sync (date 0) chosen again is dated, so it goes up.
        try storage.pool.write { db in
            try PreferenceRow(key: "tip_amount", identifier: "0", value: #""42""#, updatedAt: 0).upsert(db)
        }
        #expect(try storage.setPreference(.boostAmountMsat, 42_000, at: now))
        #expect(try storage.preferenceRow("tip_amount", "0")?.updatedAt == 1_760_000_000)
    }

    /// Nothing the official apps would rewrite or crash on is stored for the account.
    @Test func anUnwritableValueIsRefused() throws {
        let storage = try profile.storage()
        #expect(throws: UnwritablePreference.self) { try storage.setPreference(.paymentConfirmationMsat, UInt64.max) }
        #expect(throws: UnwritablePreference.self) { try storage.setPreference(.timeZone, "nan") }
        #expect(try storage.preferenceRows().allSatisfy { $0.key.hasPrefix(Preferences.devicePrefix) })
        #expect(try storage.preference(.paymentConfirmationMsat) == nil)
    }

    /// Per chat by the chat's pubkey, account-wide by "0"; a stored value
    /// that is not one reads as unset.
    @Test func identifiersKeepValuesApart() throws {
        let storage = try profile.storage()
        let off = TimeZoneSharing(enabled: false, identifier: nil)
        try storage.setPreference(.timeZoneSharing, off, for: "02aa")
        #expect(try storage.chatTimeZone("02aa") == off)
        #expect(try storage.chatTimeZone("02bb") == nil)
        try storage.pool.write { db in
            try PreferenceRow(key: "timezone", identifier: "02bb", value: #""on""#, updatedAt: 1).upsert(db)
        }
        #expect(try storage.chatTimeZone("02bb") == nil)
    }
}
