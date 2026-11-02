import Foundation
import Testing
@testable import PeelCore
@testable import PeelTestSupport

/// The PIN timeout as the official `pin_timeout` (phase 11, decision 13):
/// the mapping between the two scales, and the sync of the item.
struct PINTimeoutTests {
    static let key = Preferences.pinTimeoutKey
    static let synced = Preferences.syncedKeys(enabling: [Preferences.pinTimeoutKey])

    private func file(_ items: String) throws -> PreferencesFile {
        try PreferencesFile(text: #"{"items":[\#(items)]}"#)
    }

    private func item(_ value: String, at date: Int) -> String {
        #"{"key":"pin_timeout","identifier":"0","date":"\#(date)","value":"\#(value)"}"#
    }

    /// What Peel's setting is once read back (what `Engine.pinTimeoutHours` does).
    private func hours(_ storage: Storage) throws -> Int? {
        try storage.preference(.pinTimeout).map(PINTimeout.peelHours(fromOfficial:))
    }

    // MARK: The mapping

    @Test func everyOfficialValueMapsToTheNearestOption() {
        let expected = [0, 1, 1] + Array(repeating: 4, count: 6) + Array(repeating: 12, count: 10)
            + Array(repeating: 24, count: 6) + [PINTimeout.never]
        #expect(expected.count == 26)
        for official in 0...25 {
            #expect(PINTimeout.peelHours(fromOfficial: official) == expected[official], "\(official)")
        }
    }

    @Test func tiesGoToTheShorterAndEdgesClamp() {
        #expect(PINTimeout.peelHours(fromOfficial: 8) == 4)
        #expect(PINTimeout.peelHours(fromOfficial: 18) == 12)
        #expect(PINTimeout.peelHours(fromOfficial: 2) == 1)
        #expect(PINTimeout.peelHours(fromOfficial: 3) == 4)
        #expect(PINTimeout.peelHours(fromOfficial: 25) == PINTimeout.never)
        #expect(PINTimeout.peelHours(fromOfficial: 99) == PINTimeout.never)
        #expect(PINTimeout.peelHours(fromOfficial: -5) == 0)
        #expect(PINTimeout.peelHours(fromOfficial: Int.max) == PINTimeout.never)
        #expect(PINTimeout.peelHours(fromOfficial: Int.min) == 0)
    }

    @Test func peelWritesHoursAsTheyAreAndNeverAs25() {
        for hours in [0, 1, 4, 12, 24] {
            #expect(PINTimeout.officialHours(fromPeel: hours) == hours)
            #expect(PINTimeout.peelHours(fromOfficial: PINTimeout.officialHours(fromPeel: hours)) == hours)
        }
        #expect(PINTimeout.officialHours(fromPeel: PINTimeout.never) == 25)
        #expect(PINTimeout.officialHours(fromPeel: -7) == 25)
        // More than 24 hours must not become "never" in the file.
        #expect(PINTimeout.officialHours(fromPeel: 48) == 24)
        #expect(PINTimeout.peelHours(fromOfficial: PINTimeout.officialHours(fromPeel: PINTimeout.never)) == PINTimeout.never)
    }

    @Test func theItemReadsClampedAndRefusesGarbage() {
        let read = Preference<Int>.pinTimeout.read
        #expect(read(.string("8")) == 8 && read(.string("0")) == 0 && read(.string("25")) == 25)
        #expect(read(.string("99")) == 25 && read(.string("-5")) == 0)
        for garbage: JSONValue in [
            .string("abc"), .string(""), .string("1.5"), .string("1e3"), .string(" 4"), .string("99999999999999999999999"),
            .string("inf"), .string("nan"), .int(4), .double(4), .bool(true), .null, .array([]), .object([:]),
        ] {
            #expect(read(garbage) == nil, "\(garbage)")
        }
        #expect(Preference<Int>.pinTimeout.takes(0, 24))
        #expect(Preference<Int>.pinTimeout.takes(25, 0))
        #expect(Preference<Int>.pinTimeout.optIn)
    }

    @Test func everyWrittenValueIsAnOfficialFixedPoint() throws {
        for hours in -3...30 {
            let written = try Preference<Int>.pinTimeout.write(PINTimeout.officialHours(fromPeel: hours))
            #expect(Preferences.isOfficialFixedPoint(written), "\(hours)")
        }
        #expect(try Preference<Int>.pinTimeout.write(PINTimeout.officialHours(fromPeel: PINTimeout.never)) == .string("25"))
    }

    // MARK: Sync

    @Test func neverIsUploadedAs25() throws {
        let storage = try TempProfile().storage()
        try storage.setPreference(.pinTimeout, PINTimeout.officialHours(fromPeel: PINTimeout.never), at: Date(timeIntervalSince1970: 1000))
        #expect(try hours(storage) == PINTimeout.never)
        let server = try file(#"{"key":"x_future","identifier":"0","date":"9","value":"keep"}"#)
        let merge = server.merged(with: try storage.preferenceRows(), keys: Self.synced)
        #expect(merge.uploads == [.init(key: Self.key, identifier: "0")])
        let uploaded = merge.file.items.first { $0["key"]?.string == Self.key }
        #expect(uploaded?["value"] == .string("25"))
        #expect(merge.file.items.first { $0["key"]?.string == "x_future" } == server.items[0])
    }

    @Test func aNewerFileItemIsTakenNearest() throws {
        let storage = try TempProfile().storage()
        try storage.setPreference(.pinTimeout, 24, at: Date(timeIntervalSince1970: 1000))
        let server = try file(item("8", at: 2000))
        let merge = server.merged(with: try storage.preferenceRows(), keys: Self.synced)
        #expect(!merge.changed)
        #expect(try storage.applyPreferences(merge.apply) == 1)
        #expect(try hours(storage) == 4)
        // Stored as the file holds it.
        #expect(try storage.preferenceRow(Self.key, "0")?.value == #""8""#)
    }

    @Test func anOlderFileItemDoesNotOverride() throws {
        let storage = try TempProfile().storage()
        try storage.setPreference(.pinTimeout, 12, at: Date(timeIntervalSince1970: 3000))
        let merge = try file(item("0", at: 2000)).merged(with: try storage.preferenceRows(), keys: Self.synced)
        #expect(merge.apply.isEmpty)
        #expect(merge.changed)
        #expect(merge.file.items[0]["value"] == .string("12"))
        #expect(try hours(storage) == 12)
    }

    @Test func aGarbageFileItemIsNotTaken() throws {
        let storage = try TempProfile().storage()
        try storage.setPreference(.pinTimeout, 4, at: Date(timeIntervalSince1970: 1000))
        let merge = try file(item("1.5", at: 2000)).merged(with: try storage.preferenceRows(), keys: Self.synced)
        #expect(try storage.applyPreferences(merge.apply.filter { $0.row.value != $0.expected?.value }) == 0)
        #expect(try hours(storage) == 4)
    }

    @Test func aDeviceWithoutTheOptInLeavesTheItemUntouched() throws {
        let storage = try TempProfile().storage()
        try storage.setPreference(.pinTimeout, 12, at: Date(timeIntervalSince1970: 9000))
        let items = item("8", at: 2000) + #","# + #"{"key":"x_future","identifier":"0","date":"9","value":"anything","note":"kept"}"#
        let server = try file(items)
        for keys in [Preferences.synced, Preferences.syncedKeys(enabling: [Preferences.biometricKey])] {
            let merge = server.merged(with: try storage.preferenceRows(), keys: keys)
            #expect(!merge.changed && merge.apply.isEmpty)
            #expect(merge.file == server)
        }
        #expect(!PreferenceCapabilities().keys.contains(Self.key))
        #expect(PreferenceCapabilities(pinTimeout: true).keys == [Self.key])
    }

    @Test func neverGoesAcrossAsTwentyFiveAndBackToNever() throws {
        let phone = try TempProfile().storage()
        let mac = try TempProfile().storage()
        try phone.setPreference(.pinTimeout, PINTimeout.officialHours(fromPeel: PINTimeout.never), at: Date(timeIntervalSince1970: 1000))
        let up = PreferencesFile().merged(with: try phone.preferenceRows(), keys: Self.synced)
        #expect(up.file.items.first?["value"] == .string("25"))
        let down = up.file.merged(with: try mac.preferenceRows(), keys: Self.synced)
        #expect(try mac.applyPreferences(down.apply) == 1)
        #expect(try hours(mac) == PINTimeout.never)
        #expect(!down.changed)
    }
}
