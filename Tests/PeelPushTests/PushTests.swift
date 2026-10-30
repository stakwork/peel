import Foundation
import Testing
@testable import PeelPush

struct PushTokenTests {
    @Test func tokenIsLowercaseHexWithLeadingZeros() {
        #expect(PushToken.hex(Data([0x00, 0x0a, 0xff, 0x10])) == "000aff10")
        #expect(PushToken.hex(Data()) == "")
        #expect(PushToken.hex(Data(repeating: 0xab, count: 32)) == String(repeating: "ab", count: 32))
    }
}

struct PushKeyTests {
    final class Memory: PushKeyStoring, @unchecked Sendable {
        var value: String?
        var failing = false
        func load() throws -> String? { value }
        func save(_ key: String) throws {
            if failing { throw PushError.keychain(-1) }
            value = key
        }
    }

    @Test func generatedKeyIs32BytesOfHexAndFresh() {
        let a = PushKey.generate(), b = PushKey.generate()
        #expect(PushKey.isValid(a))
        #expect(a != b)
    }

    @Test func keyIsMadeOnceAndKept() {
        let store = Memory()
        let first = PushKey.loadOrCreate(in: store)
        #expect(first != nil && store.value == first)
        #expect(PushKey.loadOrCreate(in: store) == first)
    }

    @Test func aKeptValueThatIsNotAKeyIsReplaced() {
        let store = Memory()
        store.value = "short"
        let key = PushKey.loadOrCreate(in: store)
        #expect(key.map(PushKey.isValid) == true)
    }

    @Test func noKeyWhenItCannotBeKept() {
        let store = Memory()
        store.failing = true
        #expect(PushKey.loadOrCreate(in: store) == nil)
    }

    @Test func validityRejectsUppercaseAndWrongLength() {
        #expect(!PushKey.isValid(String(repeating: "A", count: 64)))
        #expect(!PushKey.isValid(String(repeating: "a", count: 63)))
        #expect(PushKey.isValid(String(repeating: "0", count: 64)))
    }
}

struct PushConfigTests {
    private let infoDictionary: [String: Any] = [
        "PeelAppID": "com.sphinx.peel", "PeelAppGroup": "group.com.sphinx.peel",
        "PeelKeychainGroup": "ABCDE12345.com.sphinx.peel.shared", "PeelPushEnvironment": "development",
    ]

    @Test func readsTheBuildsKeys() {
        #expect(PushConfig(info: infoDictionary) == PushConfig(
            appID: "com.sphinx.peel", appGroup: "group.com.sphinx.peel",
            keychainGroup: "ABCDE12345.com.sphinx.peel.shared", environment: .development))
    }

    @Test func missingOrUnexpandedValuesGiveNone() {
        var broken = infoDictionary
        broken["PeelAppGroup"] = "$(PEEL_APP_GROUP)"
        #expect(PushConfig(info: broken) == nil)
        broken = infoDictionary
        broken["PeelPushEnvironment"] = "staging"
        #expect(PushConfig(info: broken) == nil)
        broken = infoDictionary
        broken.removeValue(forKey: "PeelKeychainGroup")
        #expect(PushConfig(info: broken) == nil)
    }

    @Test func hubRegistrationIsOffByDefault() throws {
        let defaults = try #require(UserDefaults(suiteName: "PushFlagsTests-\(UUID().uuidString)"))
        #expect(PeelPushFlags.registerWithHub(info: [:], defaults: defaults) == false)
        #expect(PeelPushFlags.registerWithHub(info: [PeelPushFlags.registerWithHubKey: true], defaults: defaults))
        defaults.set(false, forKey: PeelPushFlags.registerWithHubKey)
        #expect(!PeelPushFlags.registerWithHub(info: [PeelPushFlags.registerWithHubKey: true], defaults: defaults))
    }

    @Test func coreArgumentsCarryTheAppAndEnvironment() {
        let debug = PushRegistration(token: "abcd", appID: "com.sphinx.peel", environment: .development)
        #expect(debug.coreArguments == PushCoreArguments(pushToken: "abcd", appId: "com.sphinx.peel", pushEnvironment: "development"))
        let release = PushRegistration(token: "abcd", appID: "com.sphinx.peel", environment: .production)
        #expect(release.coreArguments.pushEnvironment == "production")
    }

    @Test func theEnvironmentIsTheBuildsAndNothingElse() throws {
        for word in ["development", "production"] {
            var info = infoDictionary
            info["PeelPushEnvironment"] = word
            #expect(PushConfig(info: info)?.environment.rawValue == word)
        }
    }
}

struct PushContentTests {
    struct Fake: ChildIndexDecrypting {
        var result: Result<UInt64, any Error>
        var expecting: (child: String, key: String)?
        func decrypt(child: String, pushKey: String) throws -> UInt64 {
            if let expecting { #expect(expecting.child == child && expecting.key == pushKey) }
            return try result.get()
        }
    }

    private let key = String(repeating: "ab", count: 32)
    private func payload(_ child: Any?) -> [AnyHashable: Any] {
        var custom: [String: Any] = [:]
        if let child { custom["child"] = child }
        return ["aps": ["alert": "x", "custom_data": custom]]
    }
    private let names = PushNameDirectory(contacts: [3: "Bob"], tribes: [7: "Peelers"])

    @Test func childIsReadFromCustomData() {
        #expect(PushNotificationResolver.encryptedChild(from: payload("xyz")) == "xyz")
        #expect(PushNotificationResolver.encryptedChild(from: payload(nil)) == nil)
        #expect(PushNotificationResolver.encryptedChild(from: payload(5)) == nil)
        #expect(PushNotificationResolver.encryptedChild(from: payload("")) == nil)
        #expect(PushNotificationResolver.encryptedChild(from: ["aps": "no"]) == nil)
        #expect(PushNotificationResolver.encryptedChild(from: [:]) == nil)
    }

    @Test func namesAContactOrATribeByDecryptedIndex() {
        let contact = PushNotificationResolver.resolve(
            userInfo: payload("enc"), pushKey: key,
            decryptor: Fake(result: .success(3), expecting: ("enc", key)), names: names)
        #expect(contact == .text(title: "Peel", body: "You have new messages from Bob"))
        let tribe = PushNotificationResolver.resolve(
            userInfo: payload("enc"), pushKey: key, decryptor: Fake(result: .success(7)), names: names)
        #expect(tribe == .text(title: "Peel", body: "You have new messages in Peelers"))
    }

    @Test func everyFailureFallsBackToTheGenericLine() {
        let ok = Fake(result: .success(3))
        let failing = Fake(result: .failure(PushError.notConfigured))
        #expect(PushNotificationResolver.resolve(userInfo: [:], pushKey: key, decryptor: ok, names: names) == .generic)
        #expect(PushNotificationResolver.resolve(userInfo: payload("enc"), pushKey: nil, decryptor: ok, names: names) == .generic)
        #expect(PushNotificationResolver.resolve(userInfo: payload("enc"), pushKey: "", decryptor: ok, names: names) == .generic)
        #expect(PushNotificationResolver.resolve(userInfo: payload("enc"), pushKey: key, decryptor: failing, names: names) == .generic)
        #expect(PushNotificationResolver.resolve(userInfo: payload("enc"), pushKey: key, decryptor: ok, names: nil) == .generic)
        // An index nobody has a name for.
        #expect(PushNotificationResolver.resolve(
            userInfo: payload("enc"), pushKey: key, decryptor: Fake(result: .success(99)), names: names) == .generic)
        #expect(PushNotificationContent.generic == .text(title: "Peel", body: "You have new messages"))
    }

    @Test func aHiveLinkIsLeftAsTheServerSentIt() {
        for child in ["acme/feature:12", "acme/task:9"] {
            #expect(PushNotificationResolver.resolve(
                userInfo: payload(child), pushKey: key, decryptor: Fake(result: .success(3)), names: names) == .asSent)
        }
        #expect(!PushNotificationResolver.isHiveLink("a/b/c"))
    }

    @Test func namesAreCleanedToOneShortLine() {
        let dirty = PushNameDirectory(contacts: [1: "Bo\nb\u{0007}", 2: "   "])
        #expect(dirty.name(forIndex: 1)?.name == "Bob")
        #expect(dirty.name(forIndex: 2) == nil)
        let long = PushNameDirectory(contacts: [1: String(repeating: "x", count: 500)])
        #expect(long.name(forIndex: 1)?.name.count == 100)
    }

    @Test func directoryRoundTripsAndRefusesOtherJSON() throws {
        let data = try #require(names.encoded())
        #expect(PushNameDirectory(json: data) == names)
        #expect(PushNameDirectory(json: Data("[1,2]".utf8)) == nil)
        #expect(PushNameDirectory(json: Data("{\"contact-x\":\"A\",\"other\":\"B\"}".utf8)) == PushNameDirectory())
    }
}

struct PushKeyReadTests {
    @Test func theExtensionReadsAKeyAndNeverMakesOne() {
        let store = PushKeyTests.Memory()
        #expect(PushKey.existing(in: store) == nil)
        #expect(store.value == nil)
        store.value = "bad"
        #expect(PushKey.existing(in: store) == nil)
        store.value = String(repeating: "0f", count: 32)
        #expect(PushKey.existing(in: store) == store.value)
    }
}
