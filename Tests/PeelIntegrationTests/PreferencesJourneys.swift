import Foundation
import Testing
@testable import PeelCore
@testable import PeelTestSupport
import GRDB

extension Journeys {
    /// Preferences following one account between its devices, through the
    /// encrypted file on the memes stub (phase 11).
    @Suite struct Preferences {
        /// The file as the stub holds it, decrypted with the account's key.
        static func file(of person: Person) async throws -> PreferencesFile {
            let sealed = try String(contentsOf: try await Stack.shared.preferencesFile(of: try person.pubkey), encoding: .utf8)
            let plain = try MediaCrypto.decrypt(try #require(Data(base64Encoded: sealed)), key: try await person.engine.preferencesKey())
            return try PreferencesFile(text: String(decoding: plain, as: UTF8.self))
        }

        /// Writes the file as an official app would: the whole text, encrypted with the account's key.
        static func write(_ text: String, for person: Person) async throws {
            let sealed = try MediaCrypto.encrypt(Data(text.utf8), key: try await person.engine.preferencesKey())
            try Data(sealed.base64EncodedString().utf8).write(to: try await Stack.shared.preferencesFile(of: try person.pubkey))
        }

        /// A change on one device shows on the other: the boost amount, the
        /// confirmation threshold and a chat's time zone switch. The stub
        /// holds only ciphertext.
        @Test func aChangeOnOneDeviceShowsOnTheOther() async throws {
            let alice = try await Person.create("alice")
            let bob = try await Person.create("bob")
            try await Bank.shared.give(100, to: alice)
            try await alice.engine.addContact(code: try bob.contactInfo)
            try await eventually("Alice and Bob to be contacts") {
                try alice.isReadyContact(bob) && bob.isReadyContact(alice)
            }
            let second = try await Person.restore("alice", mnemonic: alice.mnemonic)
            try await eventually("the restore to finish", timeout: .seconds(60)) { await !second.engine.isSyncingHistory }

            try await alice.engine.setBoostAmount(msat: 21_000)
            try await alice.engine.setPaymentConfirmation(msat: 50_000)
            try await alice.engine.setTimeZoneSharing(false, in: try bob.pubkey)
            let sent = try await alice.engine.syncPreferences()
            #expect(sent.uploaded)
            let stored = try Data(contentsOf: try await Stack.shared.preferencesFile(of: try alice.pubkey))
            #expect(stored.range(of: Data("tip_amount".utf8)) == nil, "the stub holds the file in the clear")

            _ = try await second.engine.syncPreferences()
            #expect(try await second.engine.boostAmountMsat() == 21_000)
            #expect(try await second.engine.paymentConfirmationMsat() == 50_000)
            #expect(try await !second.engine.timeZoneSharing(in: try bob.pubkey))

            await second.close()
            await bob.close()
            await alice.close()
        }

        /// Two devices change the same setting offline: once both have
        /// synced, both hold the later change, whichever synced first.
        @Test func conflictingOfflineEditsResolveToTheLater() async throws {
            let one = try await Person.create("alice")
            let two = try await Person.restore("alice", mnemonic: one.mnemonic)
            try await eventually("the restore to finish", timeout: .seconds(60)) { await !two.engine.isSyncingHistory }
            _ = try await one.engine.syncPreferences()
            // Restored, it starts no file of its own: there is none yet.
            await #expect(throws: Engine.Failure.preferencesMissing) { try await two.engine.syncPreferences() }
            let now = Date.now
            try one.storage.setPreference(.boostAmountMsat, 300_000, at: now.addingTimeInterval(10))
            try two.storage.setPreference(.boostAmountMsat, 400_000, at: now.addingTimeInterval(20))
            try two.storage.setPreference(.timeZone, "Asia/Tokyo", at: now.addingTimeInterval(10))
            try one.storage.setPreference(.timeZone, "Europe/Paris", at: now.addingTimeInterval(20))

            #expect(try await one.engine.syncPreferences().uploaded)
            #expect(try await two.engine.syncPreferences().uploaded)
            _ = try await one.engine.syncPreferences()
            for device in [one, two] {
                #expect(try await device.engine.boostAmountMsat() == 400_000)
                #expect(try await device.engine.chosenTimeZone() == "Europe/Paris")
            }
            await two.close()
            await one.close()
        }

        /// A file written by an official app, with keys Peel does not know (an
        /// API key among them), comes back with every one of them untouched
        /// after Peel adds its own; Peel stores none of them.
        @Test func unknownKeysSurviveARoundTrip() async throws {
            let alice = try await Person.create("alice")
            let others = #"""
                {"key":"feed_status","identifier":"f1","date":"7","value":{"chat_pubkey":"02aa","feed_url":"https://x","feed_id":"f1","subscribed":"true","sats_per_minute":"5","player_speed":"1.5","item_id":"i"}},
                {"key":"feed_item_status","identifier":"f1-i","date":"7","value":{"duration":"60","current_time":"5"}},
                {"key":"ai_agent_config","identifier":"0","date":"8","value":"openai|sk-test-not-real|Bot"},
                {"key":"chat_color","identifier":"Ann-color","date":"9","value":"#ff00aa"},
                {"key":"pin_timeout","identifier":"0","date":"9","value":"0"},
                {"key":"biometric_enabled","identifier":"0","date":"9","value":"true"},
                {"key":"tip_amount","identifier":"0","date":"100","value":"500"}
                """#
            try await Self.write(#"{"items":[\#(others)]}"#, for: alice)
            let pulled = try await alice.engine.syncPreferences()
            #expect(!pulled.uploaded)
            #expect(try await alice.engine.boostAmountMsat() == 500_000)

            try await alice.engine.setPaymentConfirmation(msat: 7_000)
            #expect(try await alice.engine.syncPreferences().uploaded)
            let before = try PreferencesFile(text: #"{"items":[\#(others)]}"#)
            let after = try await Self.file(of: alice)
            #expect(Array(after.items.prefix(before.items.count)) == before.items)
            #expect(after.items.dropFirst(before.items.count).map { $0["key"]?.string } == ["peel.payment_confirmation_msat"])
            #expect(try alice.storage.preferenceRows().allSatisfy { PeelCore.Preferences.registry[$0.key] != nil })
            // The colour is taken (import-only); Face ID, the agent's key and
            // `pin_timeout` are not this device's to store: they stay in the file.
            #expect(try alice.storage.preferenceRow("chat_color", "Ann-color")?.value == ##""#ff00aa""##)
            let unstored: Set = ["biometric_enabled", "ai_agent_config", "pin_timeout"]
            #expect(try alice.storage.preferenceRows().allSatisfy { !unstored.contains($0.key) })
            #expect(try await alice.engine.biometricWish() == nil)
            await alice.close()
        }

        private static let everyKey = #"""
            {"items":[
            {"key":"pin_timeout","identifier":"0","date":"9","value":"0"},
            {"key":"biometric_enabled","identifier":"0","date":"9","value":"true"},
            {"key":"chat_color","identifier":"Ann-color","date":"9","value":"#FF00AA"},
            {"key":"ai_agent_config","identifier":"0","date":"8","value":"openai|sk-test-not-real|Bot"},
            {"key":"tip_amount","identifier":"0","date":"100","value":"500"}]}
            """#
        private static let testKey = "sk-test-not-real"

        /// No row of the account's database, and no byte of its files, holds the key.
        static func assertNoTrace(of key: String, in person: Person) throws {
            for row in try person.storage.preferenceRows() { #expect(!row.value.contains(key)) }
            let files = FileManager.default.enumerator(at: person.profile.directory, includingPropertiesForKeys: [.isRegularFileKey])
            while let url = files?.nextObject() as? URL {
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                #expect(try Data(contentsOf: url).range(of: Data(key.utf8)) == nil, "\(url.lastPathComponent)")
            }
        }

        static func value(_ key: String, of person: Person) async throws -> JSONValue? {
            try await file(of: person).items.first { $0["key"]?.string == key }?["value"]
        }

        /// A phone with an agent credential to keep: a file with every
        /// official key. The colour is taken as `#rrggbb`; Face ID's wish is
        /// stored but nothing is enrolled; the agent's key goes to the
        /// credential and nowhere else; `pin_timeout` is untouched. Then a key
        /// connected here goes up, from the credential, and the rest of the file is as it was.
        @Test func everyOfficialKeyOnADeviceThatSyncsThem() async throws {
            let alice = try await Person.create("alice")
            let credential = FakeAgentCredential()
            await alice.engine.configurePreferences(PreferenceCapabilities(biometrics: true, agentCredential: credential))
            try await Self.write(Self.everyKey, for: alice)
            let pulled = try await alice.engine.syncPreferences()
            #expect(!pulled.uploaded && pulled.applied >= 4)
            #expect(try await alice.engine.syncedColours() == ["Ann-color": "#ff00aa"])
            #expect(try await alice.engine.biometricWish() == true)
            #expect(credential.current == AgentConfig(provider: .openai, apiKey: Self.testKey, name: "Bot") && credential.keeps == 1)
            #expect(await !alice.engine.agentCredentialAdoptable)
            #expect(try alice.storage.preferenceRows().allSatisfy { $0.key != "pin_timeout" })
            #expect(try alice.storage.preferenceRow("ai_agent_config", "0")?.value == "\"redacted-secret\"")
            try Self.assertNoTrace(of: Self.testKey, in: alice)
            // The same file again changes nothing (no second keep, no upload).
            #expect(try await alice.engine.syncPreferences().uploaded == false && credential.keeps == 1)

            // A dry run says which, never what.
            credential.connect(AgentConfig(provider: .anthropic, apiKey: "sk-test-other"))
            try await alice.engine.agentCredentialConnected()
            let preview = try await alice.engine.previewPreferences()
            #expect(preview.uploaded.map(\.key) == ["ai_agent_config"])
            #expect(!String(describing: preview).contains("sk-test"))

            #expect(try await alice.engine.syncPreferences().uploaded)
            let after = try await Self.file(of: alice)
            func value(_ key: String) -> JSONValue? { after.items.first { $0["key"]?.string == key }?["value"] }
            #expect(value("ai_agent_config") == .string("Anthropic|sk-test-other|Sphinx Agent"))
            #expect(value("pin_timeout") == .string("0") && value("biometric_enabled") == .string("true"))
            #expect(value("chat_color") == .string("#FF00AA"), "an imported colour goes back as it came")
            #expect(value("tip_amount") == .string("500"))
            await alice.close()
        }

        /// A colour is never uploaded, even one dated far in the future in the
        /// database, and an upload of something else leaves the file's colour as it is.
        @Test func aColourNeverGoesUp() async throws {
            let alice = try await Person.create("alice")
            try await Self.write(Self.everyKey, for: alice)
            _ = try await alice.engine.syncPreferences()
            try await alice.storage.pool.write { db in
                try PreferenceRow(key: "chat_color", identifier: "Bob-color", value: ##""#000000""##, updatedAt: 9_999_999_999).upsert(db)
                try PreferenceRow(key: "chat_color", identifier: "Ann-color", value: ##""#000000""##, updatedAt: 9_999_999_999).upsert(db)
            }
            try await alice.engine.setBoostAmount(msat: 21_000)
            #expect(try await alice.engine.syncPreferences().uploaded)
            let after = try await Self.file(of: alice)
            let colours = after.items.filter { $0["key"]?.string == "chat_color" }
            #expect(colours.count == 1 && colours[0]["value"] == .string("#FF00AA"))
            await alice.close()
        }

        /// Face ID's choice goes up only from a device that syncs it, when the
        /// person makes it; the other, as the Mac app, neither writes nor applies it.
        @Test func faceIDIsWrittenOnlyFromAPhone() async throws {
            let phone = try await Person.create("alice")
            await phone.engine.configurePreferences(PreferenceCapabilities(biometrics: true))
            let mac = try await Person.restore("alice", mnemonic: phone.mnemonic)
            try await eventually("the restore to finish", timeout: .seconds(60)) { await !mac.engine.isSyncingHistory }

            try await mac.engine.setBiometricEnabled(true)
            #expect(try mac.storage.preferenceRows().allSatisfy { $0.key != "biometric_enabled" })
            #expect(try await phone.engine.biometricWish() == nil)

            try await phone.engine.setBiometricEnabled(true)
            #expect(try await phone.engine.syncPreferences().uploaded)
            let first = try await Self.value("biometric_enabled", of: phone)
            #expect(first == .string("true"))
            try await phone.engine.setBiometricEnabled(false)
            #expect(try await phone.engine.syncPreferences().uploaded)
            let second = try await Self.value("biometric_enabled", of: phone)
            #expect(second == .string("false"))

            // The Mac syncs and applies none of it.
            _ = try await mac.engine.syncPreferences()
            #expect(try mac.storage.preferenceRows().allSatisfy { $0.key != "biometric_enabled" })
            #expect(try await mac.engine.biometricWish() == nil)
            await mac.close()
            await phone.close()
        }

        /// A different key connected here is not replaced by the file's: it is
        /// offered, and taken only when asked for.
        @Test func aDifferentKeyIsOfferedNotTaken() async throws {
            let alice = try await Person.create("alice")
            let credential = FakeAgentCredential(AgentConfig(provider: .anthropic, apiKey: "sk-test-local", name: nil))
            await alice.engine.configurePreferences(PreferenceCapabilities(agentCredential: credential))
            try await Self.write(Self.everyKey, for: alice)
            let pulled = try await alice.engine.syncPreferences()
            #expect(!pulled.uploaded)
            #expect(credential.current?.apiKey == "sk-test-local" && credential.keeps == 0)
            #expect(await alice.engine.agentCredentialAdoptable)
            // Nothing is stored for it yet; a connect here is dated now and beats the file's item.
            #expect(try alice.storage.preferenceRow("ai_agent_config", "0") == nil)
            try Self.assertNoTrace(of: Self.testKey, in: alice)

            #expect(try await alice.engine.adoptSyncedAgentCredential())
            #expect(try alice.storage.preferenceRow("ai_agent_config", "0")?.updatedAt == 8)
            #expect(credential.current == AgentConfig(provider: .openai, apiKey: Self.testKey, name: "Bot") && credential.keeps == 1)
            #expect(await !alice.engine.agentCredentialAdoptable)
            #expect(try await !alice.engine.syncPreferences().uploaded)
            try Self.assertNoTrace(of: Self.testKey, in: alice)
            await alice.close()
        }

        /// Disconnecting here never deletes the file's item nor uploads an
        /// empty key, and the same item is not given back on the next sync.
        @Test func disconnectingKeepsTheFilesItem() async throws {
            let alice = try await Person.create("alice")
            let credential = FakeAgentCredential()
            await alice.engine.configurePreferences(PreferenceCapabilities(agentCredential: credential))
            try await Self.write(Self.everyKey, for: alice)
            _ = try await alice.engine.syncPreferences()
            credential.connect(nil)
            try await alice.engine.agentCredentialConnected()
            #expect(try await !alice.engine.syncPreferences().uploaded)
            #expect(credential.current == nil && credential.keeps == 1)
            let kept = try await Self.value("ai_agent_config", of: alice)
            #expect(kept == .string("openai|sk-test-not-real|Bot"))
            // A Keychain that cannot be read leaves the agent's key out of the sync.
            credential.failReads(true)
            #expect(try await !alice.engine.syncPreferences().uploaded)
            await alice.close()
        }

        /// The twelve words on a new device bring the settings back as soon
        /// as it is online, with no sync asked for.
        @Test func restoreBringsSettingsBack() async throws {
            let alice = try await Person.create("alice")
            try await alice.engine.setBoostAmount(msat: 42_000)
            try await alice.engine.setTimeZone("Asia/Kolkata")
            _ = try await alice.engine.syncPreferences()

            let restored = try await Person.restore("alice", mnemonic: alice.mnemonic)
            try await eventually("the settings to come back") {
                let boost = try await restored.engine.boostAmountMsat()
                let zone = try await restored.engine.chosenTimeZone()
                return boost == 42_000 && zone == "Asia/Kolkata"
            }
            await restored.close()
            await alice.close()
        }

        /// The memes server's "not found" (a 404, which it also says for a
        /// storage error) after this device has seen the file changes
        /// nothing and uploads nothing; a device that never saw one starts
        /// it with only what was chosen on it since.
        @Test func notFoundAfterTheFileWasSeenWritesNothing() async throws {
            let alice = try await Person.create("alice")
            try await alice.engine.setBoostAmount(msat: 21_000)
            #expect(try await alice.engine.syncPreferences().uploaded)
            let path = try await Stack.shared.preferencesFile(of: try alice.pubkey)
            try FileManager.default.removeItem(at: path)
            try await alice.engine.setBoostAmount(msat: 42_000)
            await #expect(throws: Engine.Failure.preferencesMissing) { try await alice.engine.syncPreferences() }
            #expect(!FileManager.default.fileExists(atPath: path.path))
            await #expect(throws: Engine.Failure.preferencesMissing) { try await alice.engine.previewPreferences() }
            await alice.close()
        }

        /// An account from before sync (no `device.may_start_preferences`,
        /// no restore row: made here, perhaps restored on a phone since)
        /// never starts the file on a "not found": nothing goes up.
        @Test func anAccountFromBeforeSyncNeverStartsTheFile() async throws {
            let alice = try await Person.create("alice")
            try await alice.storage.pool.write { try $0.execute(sql: "DELETE FROM preference WHERE key = 'device.may_start_preferences'") }
            try await alice.engine.setBoostAmount(msat: 21_000)
            let path = try await Stack.shared.preferencesFile(of: try alice.pubkey)
            await #expect(throws: Engine.Failure.preferencesMissing) { try await alice.engine.syncPreferences() }
            #expect(!FileManager.default.fileExists(atPath: path.path))
            await alice.close()
        }

        /// A dry run names what a sync would apply and upload, and changes nothing.
        @Test func aDryRunChangesNothing() async throws {
            let alice = try await Person.create("alice")
            _ = try await alice.engine.syncPreferences()  // the one on connect, done
            try await Self.write(#"{"items":[{"key":"tip_amount","identifier":"0","date":"100","value":"500"}]}"#, for: alice)
            try alice.storage.setPreference(.timeZone, "Asia/Tokyo")
            let path = try await Stack.shared.preferencesFile(of: try alice.pubkey)
            let before = try Data(contentsOf: path)
            let preview = try await alice.engine.previewPreferences()
            #expect(preview.found)
            #expect(preview.applied.map(\.key) == ["tip_amount"])
            #expect(preview.uploaded.map(\.key) == ["peel.time_zone"])
            #expect(try Data(contentsOf: path) == before)
            #expect(try await alice.engine.boostAmountMsat() == Engine.defaultBoostAmountMsat)
            await alice.close()
        }

        /// A file an official app could not read is left exactly as it is.
        @Test func anUnreadableFileIsLeftAlone() async throws {
            let alice = try await Person.create("alice")
            try await Self.write(#"{"items":[{"key":"tip_amount","identifier":"0","date":"1","value":null}]}"#, for: alice)
            let path = try await Stack.shared.preferencesFile(of: try alice.pubkey)
            let before = try Data(contentsOf: path)
            try await alice.engine.setBoostAmount(msat: 9_000)
            await #expect(throws: Engine.Failure.unreadablePreferences) { try await alice.engine.syncPreferences() }
            #expect(try Data(contentsOf: path) == before)
            await alice.close()
        }
    }
}
