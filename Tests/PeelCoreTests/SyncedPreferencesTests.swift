import Foundation
import Testing
@testable import PeelCore
@testable import PeelTestSupport

/// `chat_color`, `biometric_enabled` and `ai_agent_config` in the merge
/// (phase 11, decisions 9 to 11), and the rule that the agent's key is
/// never anywhere but the Keychain.
struct SyncedPreferencesTests {
    let profile = TempProfile()

    static let testKey = "sk-test-not-real"
    static let agentKey = Preferences.agentConfigKey
    static let both: Set<String> = [Preferences.biometricKey, Preferences.agentConfigKey]
    /// What this device holds as the connected credential, as `merged` is given it.
    static let mine = JSONValue.string("OpenAI|\(testKey)|Bot")

    private func file(_ items: String) throws -> PreferencesFile {
        try PreferencesFile(text: #"{"items":[\#(items)]}"#)
    }

    private func row(_ key: String, _ value: String, at date: Double, for identifier: String = "0") -> PreferenceRow {
        PreferenceRow(key: key, identifier: identifier, value: value, updatedAt: date)
    }

    private func item(_ key: String, _ value: String, at date: Double, for identifier: String = "0") -> String {
        #"{"key":"\#(key)","identifier":"\#(identifier)","date":"\#(Int(date))","value":"\#(value)"}"#
    }

    private func placeholder(at date: Double) -> PreferenceRow {
        row(Self.agentKey, Storage.secretPlaceholder, at: date)
    }

    // MARK: chat_color

    @Test func aColourIsTakenAsLowerCaseHexWithAHash() throws {
        let server = try file([
            item("chat_color", "#FF00AA", at: 5, for: "Ann-color"), item("chat_color", "00FF00", at: 6, for: "02ab-color"),
        ].joined(separator: ","))
        let merge = server.merged(with: [])
        #expect(merge.apply.map(\.row) == [
            row("chat_color", ##""#ff00aa""##, at: 5, for: "Ann-color"), row("chat_color", ##""#00ff00""##, at: 6, for: "02ab-color"),
        ])
        #expect(!merge.changed)
    }

    /// A colour is import-only: no row of it goes up, whatever its date, in
    /// a file that has the item, one that does not, or none yet.
    @Test func aColourIsNeverUploaded() throws {
        let mine = row("chat_color", ##""#112233""##, at: 9_999, for: "Ann-color")
        let older = try file(item("chat_color", "#ff00aa", at: 5, for: "Ann-color"))
        let merge = older.merged(with: [mine])
        #expect(!merge.changed && merge.file == older)
        // The file's value is the truth, taken over the row.
        #expect(merge.apply.map(\.row.value) == [##""#ff00aa""##])

        let empty = try file("")
        #expect(!empty.merged(with: [mine]).changed && empty.merged(with: [mine]).file == empty)
        #expect(!PreferencesFile().merged(with: [mine], bootstrapping: 0).changed)
        #expect(!PreferencesFile().merged(with: [mine]).changed)
        #expect(Preference<String>.chatColor.uploads == false)
    }

    @Test func aBadColourIsRefusedAndTakesTheFilesDate() throws {
        let server = try file(item("chat_color", "red", at: 50, for: "Ann-color"))
        let kept = row("chat_color", ##""#00ff00""##, at: 10, for: "Ann-color")
        let merge = server.merged(with: [kept])
        #expect(merge.apply.map(\.row) == [row("chat_color", ##""#00ff00""##, at: 50, for: "Ann-color")])
        #expect(server.merged(with: []).apply.isEmpty)
        for bad in ["#12345", "#1234567", "#ggg000", "", "#", "##123456", " 123456"] {
            #expect(Preference<String>.chatColor.read(.string(bad)) == nil, "\(bad)")
        }
        for good in ["#ABCDEF", "abcdef", "#000000", "123456"] {
            #expect(Preference<String>.chatColor.read(.string(good)) == "#" + good.lowercased().replacingOccurrences(of: "#", with: ""))
        }
        #expect(Preference<String>.chatColor.read(.int(123_456)) == nil)
        // What Peel would store never reads as a number to the official apps' retyping.
        #expect(Preferences.isOfficialFixedPoint(try Preference<String>.chatColor.write("123456")))
        #expect(try Preference<String>.chatColor.write("123456") == .string("#123456"))
        #expect(throws: UnwritablePreference.self) { try Preference<String>.chatColor.write("nope") }
    }

    @Test func theLastDuplicateColourWins() throws {
        let server = try file([
            item("chat_color", "#111111", at: 1, for: "Ann-color"), item("chat_color", "#222222", at: 2, for: "Ann-color"),
        ].joined(separator: ","))
        #expect(server.merged(with: []).apply.map(\.row.value) == [##""#222222""##])
    }

    @Test func syncedColoursAreTheColourKeysOnly() throws {
        let storage = try profile.storage()
        try storage.pool.write { db in
            try row("chat_color", ##""#ABCDEF""##, at: 1, for: "Ann-color").upsert(db)
            try row("chat_color", ##""#112233""##, at: 1, for: "chat-02aa-color").upsert(db)
            try row("chat_color", ##""#112233""##, at: 1, for: "participant").upsert(db)
            try row("chat_color", #""nope""#, at: 1, for: "Bad-color").upsert(db)
        }
        #expect(try storage.syncedColours() == ["Ann-color": "#abcdef", "chat-02aa-color": "#112233"])
    }

    // MARK: biometric_enabled

    /// Where Face ID syncs the item is stored, dated and uploaded; on the
    /// Mac it stays in the file byte for byte, never stored or applied.
    @Test func faceIDSyncsOnlyWhereTheDeviceSaysSo() throws {
        let server = try file(item("biometric_enabled", "true", at: 9))
        let mac = server.merged(with: [])
        #expect(mac.apply.isEmpty && !mac.changed)
        #expect(try mac.file.text == server.text)
        let macLocal = server.merged(with: [row("biometric_enabled", #""false""#, at: 99)])
        #expect(macLocal.apply.isEmpty && !macLocal.changed)

        let phone = Preferences.syncedKeys(enabling: [Preferences.biometricKey])
        let applied = server.merged(with: [], keys: phone)
        #expect(applied.apply.map(\.row) == [row("biometric_enabled", #""true""#, at: 9)])
        let uploaded = server.merged(with: [row("biometric_enabled", #""false""#, at: 99)], keys: phone)
        #expect(uploaded.uploads == [.init(key: "biometric_enabled", identifier: "0")])
        #expect(uploaded.file.items[0]["value"] == .string("false") && uploaded.file.items[0]["date"] == .string("99"))
        #expect(Preferences.isOfficialFixedPoint(try Preference<Bool>.biometricEnabled.write(true)))
    }

    // MARK: ai_agent_config

    @Test func theAgentConfigReadsAsTheOfficialAppsReadIt() {
        func read(_ text: String) -> AgentConfig? { AgentConfig(item: text) }
        #expect(read("Anthropic|k1|Ann") == AgentConfig(provider: .anthropic, apiKey: "k1", name: "Ann"))
        #expect(read("OpenAI|k1") == AgentConfig(provider: .openai, apiKey: "k1", name: nil))
        // Everything between the first and the last part is the key.
        #expect(read("openai|a|b|c|Bot") == AgentConfig(provider: .openai, apiKey: "a|b|c", name: "Bot"))
        #expect(read("OPENROUTER|k|") == AgentConfig(provider: .openrouter, apiKey: "k", name: nil))
        #expect(read("Anthropic||Bot") == nil && read("Anthropic|") == nil)
        #expect(read("Gemini|k|Bot") == nil && read("k|Bot") == nil && read("Anthropic") == nil && read("") == nil)
    }

    @Test func theAgentConfigIsWrittenAsOfficial() throws {
        let write = Preference<AgentConfig>.agentConfig.write
        #expect(try write(AgentConfig(provider: .anthropic, apiKey: "k", name: "Ann")) == .string("Anthropic|k|Ann"))
        #expect(try write(AgentConfig(provider: .openai, apiKey: "k")) == .string("OpenAI|k|Sphinx Agent"))
        #expect(try write(AgentConfig(provider: .openrouter, apiKey: "k")) == .string("OpenRouter|k|Sphinx Agent"))
        #expect(try write(AgentConfig(provider: .openai, apiKey: "k", name: "a|b")) == .string("OpenAI|k|a b"))
        #expect(throws: UnwritablePreference.self) { try write(AgentConfig(provider: .openai, apiKey: "")) }
        // The pipe makes every key a fixed point of the official retyping,
        // even one that is all digits or "true".
        for key in ["123456", "true", "1e30", "nan", "inf", "007"] {
            let value = try write(AgentConfig(provider: .anthropic, apiKey: key))
            #expect(Preferences.isOfficialFixedPoint(value), "\(key)")
            #expect(OfficialApp.rewrite(#"{"items":[{"key":"ai_agent_config","identifier":"0","date":"1","value":"\#(value.string ?? "")"}]}"#)
                    == #"{"items":[{"date":"1","identifier":"0","key":"ai_agent_config","value":"\#(value.string ?? "")"}]}"#)
        }
    }

    @Test func aNewerFileKeyIsTakenWhereNoneIsConnected() throws {
        let server = try file(item(Self.agentKey, "OpenAI|\(Self.testKey)|Bot", at: 100))
        let merge = server.merged(with: [], keys: Preferences.syncedKeys(enabling: Self.both))
        #expect(merge.secrets.count == 1 && merge.secrets[0].pair == .init(key: Self.agentKey, identifier: "0"))
        #expect(merge.apply.map(\.row) == [placeholder(at: 100)])
        #expect(merge.differing.isEmpty && !merge.changed)
        // Older than what was last seen (a person disconnected): not given back.
        let seen = server.merged(with: [placeholder(at: 100)], keys: Preferences.syncedKeys(enabling: Self.both))
        #expect(seen.secrets.isEmpty && seen.apply.isEmpty)
        // A newer item is taken again.
        let newer = server.merged(with: [placeholder(at: 50)], keys: Preferences.syncedKeys(enabling: Self.both))
        #expect(newer.secrets.count == 1)
        // Not a config (unknown provider): refused, nothing to take.
        let unknown = try file(item(Self.agentKey, "Gemini|k|Bot", at: 100))
        #expect(unknown.merged(with: [], keys: Preferences.syncedKeys(enabling: Self.both)).secrets.isEmpty)
    }

    /// A different key connected here is never replaced: kept, the file's
    /// date taken, and offered. The same key is nothing to offer.
    @Test func aDifferentConnectedKeyIsKeptAndOffered() throws {
        let keys = Preferences.syncedKeys(enabling: Self.both)
        let server = try file(item(Self.agentKey, "Anthropic|sk-other|Ann", at: 100))
        let merge = server.merged(with: [placeholder(at: 50)], keys: keys, secrets: [Self.agentKey: Self.mine])
        #expect(merge.secrets.isEmpty && !merge.changed)
        #expect(merge.differing == [.init(key: Self.agentKey, identifier: "0")])
        #expect(merge.apply.map(\.row) == [placeholder(at: 100)])
        // No row yet: still offered, nothing stored.
        let fresh = server.merged(with: [], keys: keys, secrets: [Self.agentKey: Self.mine])
        #expect(fresh.differing.count == 1 && fresh.apply.isEmpty && fresh.secrets.isEmpty)
        // The same provider and key (another name) is the same credential.
        let same = try file(item(Self.agentKey, "OpenAI|\(Self.testKey)|Other", at: 100))
            .merged(with: [placeholder(at: 50)], keys: keys, secrets: [Self.agentKey: Self.mine])
        #expect(same.differing.isEmpty && same.secrets.isEmpty)
    }

    /// The placeholder's date orders it; the value uploaded is the
    /// Keychain's, never the row's, and none is made without one.
    @Test func theKeyGoesUpFromTheKeychainNotTheRow() throws {
        let keys = Preferences.syncedKeys(enabling: Self.both)
        let server = try file(item(Self.agentKey, "Anthropic|sk-other|Ann", at: 100))
        let up = server.merged(with: [placeholder(at: 200)], keys: keys, secrets: [Self.agentKey: Self.mine])
        #expect(up.uploads == [.init(key: Self.agentKey, identifier: "0")])
        #expect(up.file.items[0]["value"] == Self.mine && up.file.items[0]["date"] == .string("200"))
        #expect(up.differing.isEmpty && up.apply.isEmpty)
        let uploadedText = try up.file.text
        #expect(!uploadedText.contains("redacted"))
        // Newer here, but nothing connected (disconnected: the file keeps its item).
        let none = server.merged(with: [placeholder(at: 200)], keys: keys)
        #expect(!none.changed && none.secrets.isEmpty && none.file == server)
        // A file that has none gets it, bootstrapping or not.
        for since in [nil, 0.0] {
            let started = PreferencesFile().merged(with: [placeholder(at: 200)], bootstrapping: since, keys: keys, secrets: [Self.agentKey: Self.mine])
            #expect(started.file.items.count == 1 && started.file.items[0]["value"] == Self.mine)
        }
        // A row never dated (0) never goes up; nor does an unsynced device's.
        #expect(!PreferencesFile().merged(with: [placeholder(at: 0)], keys: keys, secrets: [Self.agentKey: Self.mine]).changed)
        #expect(!PreferencesFile().merged(with: [placeholder(at: 200)], secrets: [Self.agentKey: Self.mine]).changed)
    }

    @Test func noKeyIsInAnyRowOrChange() throws {
        let keys = Preferences.syncedKeys(enabling: Self.both)
        let server = try file(item(Self.agentKey, "OpenAI|\(Self.testKey)|Bot", at: 100))
        let merge = server.merged(with: [], keys: keys)
        let storage = try profile.storage()
        #expect(try storage.applyPreferences(merge.apply) == 1)
        for row in try storage.preferenceRows() {
            #expect(!row.value.contains(Self.testKey) && !row.key.contains(Self.testKey))
            #expect(row.isSecret ? row.displayValue == "<redacted>" : true)
        }
        #expect(try storage.preferenceRow(Self.agentKey, "0") == placeholder(at: 100))
        // Stored placeholder is never read as a value, nor can a value be stored.
        #expect(try storage.preference(.agentConfig) == nil)
        #expect(throws: UnwritablePreference.self) {
            try storage.setPreference(.agentConfig, AgentConfig(provider: .openai, apiKey: Self.testKey))
        }
        try storage.setSecretDate(Self.agentKey, at: Date(timeIntervalSince1970: 500))
        #expect(try storage.preferenceRow(Self.agentKey, "0") == placeholder(at: 500))
        #expect(throws: UnwritablePreference.self) { try storage.setSecretDate("tip_amount") }
        // The whole database file: no trace of the key.
        let bytes = try FileManager.default.contentsOfDirectory(at: profile.url, includingPropertiesForKeys: [.isRegularFileKey])
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .map { try Data(contentsOf: $0) }
        #expect(!bytes.isEmpty)
        for data in bytes { #expect(data.range(of: Data(Self.testKey.utf8)) == nil) }
    }

    @Test func nothingThatPrintsHoldsTheKey() throws {
        let config = AgentConfig(provider: .openai, apiKey: Self.testKey, name: "Bot")
        let change = SecretChange(pair: .init(key: Self.agentKey, identifier: "0"), value: Self.mine)
        var dumped = ""
        dump(config, to: &dumped)
        dump(change, to: &dumped)
        let texts = [
            String(describing: config), String(reflecting: config), "\(config)", String(describing: change),
            String(reflecting: change), dumped, UnwritablePreference(key: Self.agentKey).description,
        ]
        for text in texts { #expect(!text.contains(Self.testKey), "\(text)") }
    }
}
