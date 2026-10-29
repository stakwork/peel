import Foundation
import Testing
@testable import PeelCore
@testable import PeelTestSupport

/// The official apps' reader and writer, ported from
/// `sphinx-mac-v2/.../Managers/Data Sync Manager/DataSyncModels.swift`
/// (`SettingValue.init(from:)` at 134-199, `toOriginalFormatJSON` at
/// 34-96): what an official app uploads after reading a file. Nil where it
/// would refuse the file or crash.
enum OfficialApp {
    static func rewrite(_ text: String, now: Date = Date(timeIntervalSince1970: 1)) -> String? {
        guard case .object(let top)? = JSONValue(text: text), case .array(let list)? = top["items"] else { return nil }
        var items: [JSONValue] = []
        for entry in list {
            guard case .object(let item) = entry, let key = item["key"]?.string, let identifier = item["identifier"]?.string,
                  let date = item["date"]?.string, let value = item["value"], let written = rewrite(value) else { return nil }
            let seconds = TimeInterval(date) ?? now.timeIntervalSince1970
            items.append(.object([
                "key": .string(key), "identifier": .string(identifier),
                "date": .string(String(format: "%.0f", seconds)), "value": written,
            ]))
        }
        return try? JSONValue.object(["items": .array(items)]).text
    }

    private static func rewrite(_ value: JSONValue) -> JSONValue? {
        switch value {
        case .object(let fields):
            func string(_ name: String) -> String? { fields[name]?.string }
            if let chat = string("chat_pubkey"), let url = string("feed_url"), let feed = string("feed_id"),
               let subscribed = string("subscribed"), let sats = string("sats_per_minute"),
               let speed = string("player_speed"), let item = string("item_id") {
                return .object([
                    "chat_pubkey": .string(chat), "feed_url": .string(url), "feed_id": .string(feed),
                    "subscribed": .string(subscribed.lowercased() == "true" ? "true" : "false"),
                    "sats_per_minute": .string(String(Int(sats) ?? 0)), "player_speed": .string(String(Double(speed) ?? 1)),
                    "item_id": .string(item),
                ])
            }
            if let duration = string("duration"), let time = string("current_time") {
                return .object(["duration": .string(String(Int(duration) ?? 0)), "current_time": .string(String(Int(time) ?? 0))])
            }
            for (enabledKey, identifierKey) in [("timezone_enabled", "timezone_identifier"), ("timezoneEnabled", "timezoneIdentifier")] {
                if let enabled = string(enabledKey) {
                    return .object([
                        "timezone_enabled": .string(enabled.lowercased() == "true" ? "true" : "false"),
                        "timezone_identifier": .string(string(identifierKey) ?? ""),
                    ])
                }
            }
            return nil
        case .string(let text):
            return Preferences.officialRewrite(text).map(JSONValue.string)
        case .int(let number):
            return .string(String(number))
        case .bool(let flag):
            return .string(flag ? "true" : "false")
        default:
            return nil
        }
    }
}

struct PreferencesFileTests {
    let profile = TempProfile()

    private func file(_ items: String, extra: String = "") throws -> PreferencesFile {
        try PreferencesFile(text: #"{"items":[\#(items)]\#(extra)}"#)
    }

    private func row(_ key: String, _ value: String, at date: Double, for identifier: String = "0") -> PreferenceRow {
        PreferenceRow(key: key, identifier: identifier, value: value, updatedAt: date)
    }

    private func value(_ merge: PreferencesFile.Merge, _ key: String, _ identifier: String = "0") -> [String: JSONValue]? {
        merge.file.items.first { $0["key"]?.string == key && $0["identifier"]?.string == identifier }
    }

    // MARK: The rules

    /// Stored strictly newer replaces the item; a tie or older takes the
    /// file's, as the official apps let the file win unless strictly newer.
    @Test func theNewerDateWinsAndATieGoesToTheFile() throws {
        let server = try file(#"{"key":"tip_amount","identifier":"0","date":"100","value":"500"}"#)
        let newer = server.merged(with: [row("tip_amount", #""250""#, at: 101)])
        #expect(newer.changed && newer.apply.isEmpty)
        #expect(value(newer, "tip_amount")?["value"] == .string("250"))
        #expect(value(newer, "tip_amount")?["date"] == .string("101"))
        for date: Double in [100, 99, 0] {
            let older = server.merged(with: [row("tip_amount", #""250""#, at: date)])
            #expect(!older.changed)
            #expect(older.apply.map(\.row) == [row("tip_amount", #""500""#, at: 100)])
        }
        // The same value and date: nothing to do either way.
        let same = server.merged(with: [row("tip_amount", #""500""#, at: 100)])
        #expect(!same.changed && same.apply.isEmpty)
    }

    /// An item only in the file is applied; one only here goes up if it was
    /// chosen on a device. From before sync (date 0), an official key stays
    /// here (never pushed over what an official app holds) and a Peel key
    /// goes up dated 0, so any real choice beats it.
    @Test func whatOnlyOneSideHas() throws {
        let server = try file(#"{"key":"timezone","identifier":"02aa","date":"5","value":{"timezone_enabled":"false","timezone_identifier":""}}"#)
        let merge = server.merged(with: [
            row("tip_amount", #""42""#, at: 0),
            row("peel.payment_confirmation_msat", #""0""#, at: 0),
            row("peel.time_zone", #""Asia/Kolkata""#, at: 1_760_000_000),
        ])
        #expect(merge.apply.map(\.row) == [row("timezone", #"{"timezone_enabled":"false","timezone_identifier":""}"#, at: 5, for: "02aa")])
        #expect(merge.changed)
        #expect(value(merge, "tip_amount") == nil)
        #expect(value(merge, "peel.payment_confirmation_msat")?["date"] == .string("0"))
        #expect(value(merge, "peel.time_zone")?["value"] == .string("Asia/Kolkata"))
    }

    /// Every item Peel does not own goes back as it came: other apps' keys,
    /// an API key among them, extra fields on items and beside them. With
    /// one key twice, the last copy is the file's value (the official apps
    /// apply items in order); a newer one here replaces every copy.
    /// Nothing changed means nothing to upload.
    @Test func everythingElseIsUntouched() throws {
        let others = #"""
            {"key":"feed_status","identifier":"f1","date":"7","value":{"chat_pubkey":"02aa","feed_url":"https://x","feed_id":"f1","subscribed":"true","sats_per_minute":"5","player_speed":"1.5","item_id":"i"}},
            {"key":"ai_agent_config","identifier":"0","date":"8","value":"openai|sk-test|Bot"},
            {"key":"chat_color","identifier":"Ann-color","date":"9","value":"#ff00aa"},
            {"key":"private_photo","identifier":"0","date":"9","value":"false"},
            {"key":"pin_timeout","identifier":"0","date":"9","value":"0"},
            {"key":"x_future","identifier":"0","date":"9","value":"anything","note":"kept"},
            {"key":"tip_amount","identifier":"0","date":"100","value":"500"},
            {"key":"tip_amount","identifier":"0","date":"1","value":"7"}
            """#
        let server = try file(others, extra: #","version":"2""#)
        // `chat_color` is Peel's (import-only), so this device already holds the file's value.
        let untouched = server.merged(with: [
            row("tip_amount", #""7""#, at: 1), row("chat_color", ##""#ff00aa""##, at: 9, for: "Ann-color"),
        ])
        #expect(!untouched.changed && untouched.apply.isEmpty)
        let merge = server.merged(with: [row("tip_amount", #""250""#, at: 50)])
        #expect(merge.changed && merge.uploads == [.init(key: "tip_amount", identifier: "0")])
        #expect(merge.file.others == ["version": .string("2")])
        #expect(merge.file.items.count == server.items.count)
        for (index, item) in server.items.enumerated() where index < 6 {
            #expect(merge.file.items[index] == item)
        }
        #expect(merge.file.items[6]["value"] == .string("250") && merge.file.items[7]["value"] == .string("250"))
        // Peel stores only the keys it syncs (the API key never reaches the
        // database; `pin_timeout` is not Peel's, decision 4), and takes the
        // last copy. With no Face ID or agent here, theirs stay pass-through.
        let pulled = server.merged(with: [])
        #expect(pulled.apply.map(\.row) == [
            row("chat_color", ##""#ff00aa""##, at: 9, for: "Ann-color"), row("tip_amount", #""7""#, at: 1),
        ])
        #expect(pulled.secrets.isEmpty && pulled.differing.isEmpty)
    }

    /// A device that has never seen the file starts one only with what was
    /// chosen on it since the preferences layer came (`bootstrapping`):
    /// never a value from before, whatever its key.
    @Test func bootstrappingUploadsOnlyWhatWasChosenSince() {
        let rows = [
            row("tip_amount", #""42""#, at: 0),
            row("peel.payment_confirmation_msat", #""0""#, at: 0),
            row("timezone", #"{"timezone_enabled":"false","timezone_identifier":""}"#, at: 1_759_000_000, for: "02aa"),
            row("peel.time_zone", #""Asia/Kolkata""#, at: 1_760_000_100),
        ]
        let fresh = PreferencesFile().merged(with: rows, bootstrapping: 1_760_000_000)
        #expect(fresh.uploads == [.init(key: "peel.time_zone", identifier: "0")])
        #expect(fresh.file.items.count == 1)
        // With a file there, the dated time zone row goes up and the Peel key from before too.
        let found = PreferencesFile().merged(with: rows)
        #expect(Set(found.uploads.map(\.key)) == ["peel.payment_confirmation_msat", "timezone", "peel.time_zone"])
    }

    /// The threshold from the file is taken only when stricter than this
    /// device's. A looser one is refused, but its date is taken (the value
    /// kept), so a change made here later is dated after it and goes up.
    @Test func aLooserThresholdFromTheFileIsNotTaken() throws {
        let server = try file(#"{"key":"peel.payment_confirmation_msat","identifier":"0","date":"200","value":"1000000"}"#)
        let mine = row("peel.payment_confirmation_msat", #""100000""#, at: 100)
        let refused = server.merged(with: [mine])
        #expect(refused.apply == [.init(row: row("peel.payment_confirmation_msat", #""100000""#, at: 200), expected: mine)])
        #expect(!refused.changed)
        #expect(server.merged(with: []).apply.isEmpty)
        // Once dated, the same file changes nothing more.
        #expect(server.merged(with: [refused.apply[0].row]).apply.isEmpty)
        let stricter = try file(#"{"key":"peel.payment_confirmation_msat","identifier":"0","date":"200","value":"0"}"#)
        #expect(stricter.merged(with: [row("peel.payment_confirmation_msat", #""100000""#, at: 100)]).apply.count == 1)
    }

    /// A value the key cannot hold is left in the file and not applied, as
    /// the official apps ignore it; this device's keys never travel.
    @Test func unreadableValuesAndDeviceKeysStayPut() throws {
        let server = try file(#"""
            {"key":"tip_amount","identifier":"0","date":"100","value":"lots"},
            {"key":"device.notification_text","identifier":"0","date":"100","value":"true"}
            """#)
        let merge = server.merged(with: [row("device.notification_text", #""false""#, at: 200)])
        #expect(merge.apply.isEmpty && !merge.changed)
    }

    /// A file an official app could not read is not read here either, so
    /// Peel never uploads over it.
    @Test func filesTheOfficialAppsCannotReadAreRefused() {
        let bad = [
            #"{"items":[{"key":"tip_amount","identifier":"0","date":100,"value":"5"}]}"#,
            #"{"items":[{"key":"tip_amount","identifier":"0","date":"100","value":null}]}"#,
            #"{"items":[{"key":"tip_amount","identifier":"0","date":"100","value":["5"]}]}"#,
            #"{"items":[{"key":"tip_amount","identifier":"0","date":"100","value":2.5}]}"#,
            #"{"items":[{"key":"x","identifier":"0","date":"1","value":{"other":"shape"}}]}"#,
            #"{"items":[{"key":"tip_amount","identifier":"0","date":"100"}]}"#,
            #"{"items":["tip_amount"]}"#,
            #"{"stuff":[]}"#,
            "not json",
        ]
        for text in bad {
            #expect(throws: Engine.Failure.unreadablePreferences) { try PreferencesFile(text: text) }
            #expect(OfficialApp.rewrite(text) == nil, "\(text)")
        }
    }

    // MARK: Compatibility

    /// What Peel uploads, an official app reads and writes back unchanged:
    /// so a sync of theirs after one of Peel's changes nothing Peel wrote.
    @Test func whatPeelWritesTheOfficialAppsKeepAsIs() throws {
        let storage = try profile.storage()
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        try storage.setPreference(.boostAmountMsat, 21_000, at: now)
        try storage.setPreference(.paymentConfirmationMsat, 0, at: now)
        try storage.setPreference(.timeZone, "", at: now)
        try storage.setPreference(.timeZoneSharing, TimeZoneSharing(enabled: false, identifier: nil), for: "02aa", at: now)
        try storage.setPreference(.timeZoneSharing, TimeZoneSharing(enabled: true, identifier: "Asia/Bangkok"), for: "02bb", at: now)
        let merge = PreferencesFile().merged(with: try storage.preferenceRows())
        #expect(merge.file.items.count == 5)
        let written = try merge.file.text
        #expect(OfficialApp.rewrite(written) == written)
        // And Peel reads its own file back to the same values.
        let again = try PreferencesFile(text: written).merged(with: try storage.preferenceRows())
        #expect(!again.changed && again.apply.isEmpty)
    }

    /// An item dated in a way that does not read counts as the oldest: a
    /// choice made here replaces it (with a readable date), and with none
    /// here it is taken, once.
    @Test func anUnreadableDateIsTheOldest() throws {
        for date in ["soon", "", "nan", "inf", "-inf"] {
            let server = try file(#"{"key":"tip_amount","identifier":"0","date":"\#(date)","value":"500"}"#)
            let mine = server.merged(with: [row("tip_amount", #""250""#, at: 999)])
            #expect(mine.changed && mine.apply.isEmpty, "\(date)")
            #expect(value(mine, "tip_amount")?["date"] == .string("999"))
            let taken = server.merged(with: [])
            #expect(taken.apply.map(\.row) == [row("tip_amount", #""500""#, at: 0)], "\(date)")
            let again = server.merged(with: [row("tip_amount", #""500""#, at: 0)])
            #expect(again.apply.isEmpty && !again.changed)
        }
    }

    // MARK: Applying

    /// What a sync applies is written only over the row it was merged
    /// against: a change made here while the sync was out is never lost,
    /// even one dated before the file's (another device's clock ahead), and
    /// a row added here since is not overwritten either.
    @Test func applyingIsCompareAndSet() throws {
        let storage = try profile.storage()
        try storage.setPreference(.boostAmountMsat, 21_000, at: Date(timeIntervalSince1970: 1_000))
        let read = try storage.preferenceRows()
        let server = try file(#"{"key":"tip_amount","identifier":"0","date":"5000","value":"500"},{"key":"peel.time_zone","identifier":"0","date":"3","value":"UTC"}"#)
        let merge = server.merged(with: read)
        #expect(merge.apply.count == 2)
        // Changed here during the sync, dated before the file's 5000.
        try storage.setPreference(.boostAmountMsat, 42_000, at: Date(timeIntervalSince1970: 1_500))
        try storage.setPreference(.timeZone, "Asia/Tokyo", at: Date(timeIntervalSince1970: 2))
        #expect(try storage.applyPreferences(merge.apply) == 0)
        #expect(try storage.preference(.boostAmountMsat) == 42_000)
        #expect(try storage.preference(.timeZone) == "Asia/Tokyo")
        // Merged again, it applies.
        let again = server.merged(with: try storage.preferenceRows())
        #expect(try storage.applyPreferences(again.apply) == 2)
        #expect(try storage.preference(.boostAmountMsat) == 500_000)
        #expect(try storage.preference(.timeZone) == "UTC")
    }

    /// After a refused file value took its date here, a change made here
    /// is dated after the file's even when the file's clock ran ahead, so
    /// the next sync uploads it.
    @Test func aChangeAfterARefusedValueBeatsTheFile() throws {
        let storage = try profile.storage()
        let ahead = Date.now.timeIntervalSince1970 + 3600
        let server = try file(#"{"key":"peel.payment_confirmation_msat","identifier":"0","date":"\#(Int(ahead))","value":"1000000"}"#)
        try storage.setPreference(.paymentConfirmationMsat, 100_000)
        #expect(try storage.applyPreferences(server.merged(with: try storage.preferenceRows()).apply) == 0)
        #expect(try storage.preference(.paymentConfirmationMsat) == 100_000)
        try storage.setPreference(.paymentConfirmationMsat, 50_000)
        let next = server.merged(with: try storage.preferenceRows())
        #expect(next.uploads.map(\.key) == ["peel.payment_confirmation_msat"])
    }

    /// Only an account signed up or created by a build with sync may start
    /// the file on a "not found", and only until a file was seen on that
    /// server. A database from before sync (no marker, no restore row: an
    /// account made here, perhaps restored on a phone since) never does.
    @Test func onlyAnAccountMadeWithSyncMayStartTheFile() throws {
        let queue = try profile.queue()
        try Storage.migrator.migrate(queue, upTo: "v22")
        try queue.close()
        let storage = try profile.storage()
        #expect(try storage.value(for: .needsRestore) == nil)
        #expect(try !storage.preferenceRows().contains { $0.key == "device.may_start_preferences" })
        #expect(try !storage.mayStartPreferencesFile(on: "memes.example"))
        try storage.setPreference(.mayStartPreferences, true)
        #expect(try storage.mayStartPreferencesFile(on: "memes.example"))
        try storage.setPreference(.preferencesFileSeen, "memes.example")
        #expect(try !storage.mayStartPreferencesFile(on: "memes.example"))
        #expect(try storage.mayStartPreferencesFile(on: "other.example"))
        try storage.set("1", for: .needsRestore)
        #expect(try !storage.mayStartPreferencesFile(on: "other.example"))
    }

    /// A refused value's date is taken at most a day ahead of this clock.
    @Test func aRefusedValuesDateIsClamped() throws {
        let server = try file(#"{"key":"peel.payment_confirmation_msat","identifier":"0","date":"99999999999","value":"1000000"}"#)
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let merge = server.merged(with: [row("peel.payment_confirmation_msat", #""100000""#, at: 100)], now: now)
        #expect(merge.apply.map(\.row.updatedAt) == [1_760_086_400])
    }
}
