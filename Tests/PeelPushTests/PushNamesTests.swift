import Foundation
import Testing
@testable import PeelPush

/// A cipher that depends on the key and refuses anything not sealed under it,
/// so the writer and reader are tested without the platform's crypto.
struct FakeSealer: PushSealing {
    struct Refused: Error {}
    func seal(_ text: String, key: String) throws -> String { "sealed[\(key)]" + text }
    func open(_ sealed: String, key: String) throws -> String {
        let prefix = "sealed[\(key)]"
        guard sealed.hasPrefix(prefix) else { throw Refused() }
        return String(sealed.dropFirst(prefix.count))
    }
}

final class MemoryNameStore: PushNameStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    private var count = 0
    func read() -> String? { lock.withLock { value } }
    func write(_ sealed: String?) { lock.withLock { value = sealed; count += 1 } }
    var writes: Int { lock.withLock { count } }
}

struct PushNameDirectoryWriterTests {
    private let key = String(repeating: "ab", count: 32)
    private let other = String(repeating: "cd", count: 32)
    private let entries = [
        PushNameEntry(kind: .contact, index: 3, name: "Bob"),
        PushNameEntry(kind: .tribe, index: 3, name: "Peelers"),
        PushNameEntry(kind: .tribe, index: 7, name: "Builders"),
    ]

    @Test func whatIsWrittenIsWhatTheExtensionReads() {
        let store = MemoryNameStore()
        #expect(PushNameDirectoryWriter.write(entries, pushKey: key, sealer: FakeSealer(), store: store))
        let read = PushNameDirectory.read(from: store, pushKey: key, sealer: FakeSealer())
        #expect(read == PushNameDirectory(contacts: [3: "Bob"], tribes: [3: "Peelers", 7: "Builders"]))
    }

    @Test func aContactAndATribeWithOneIndexDoNotCollide() {
        let directory = PushNameDirectory(entries: entries)
        #expect(directory.contacts[3] == "Bob")
        #expect(directory.tribes[3] == "Peelers")
    }

    @Test func theStoredFormatIsSphinxsJSONObject() throws {
        let json = try #require(PushNameDirectory(entries: entries).encoded())
        let map = try #require(try JSONSerialization.jsonObject(with: json) as? [String: String])
        #expect(map == ["contact-3": "Bob", "tribe-3": "Peelers", "tribe-7": "Builders"])
        #expect(PushNameDirectory.defaultsKey == "childIndexesStorageKey")
    }

    @Test func namesAreCleanedAndEmptyOnesDropped() {
        let directory = PushNameDirectory(entries: [
            PushNameEntry(kind: .contact, index: 1, name: "Bo\nb\u{0007}"),
            PushNameEntry(kind: .contact, index: 2, name: "  "),
            PushNameEntry(kind: .tribe, index: 3, name: String(repeating: "x", count: 500)),
        ])
        #expect(directory.contacts == [1: "Bob"])
        #expect(directory.tribes[3]?.count == 100)
    }

    @Test func missingKeyBadBlobAndWrongKeyGiveNoNames() {
        let store = MemoryNameStore()
        #expect(PushNameDirectory.read(from: store, pushKey: key, sealer: FakeSealer()) == nil)  // nothing kept
        PushNameDirectoryWriter.write(entries, pushKey: key, sealer: FakeSealer(), store: store)
        #expect(PushNameDirectory.read(from: store, pushKey: nil, sealer: FakeSealer()) == nil)
        #expect(PushNameDirectory.read(from: store, pushKey: "short", sealer: FakeSealer()) == nil)
        #expect(PushNameDirectory.read(from: store, pushKey: other, sealer: FakeSealer()) == nil)
        store.write("corrupt")
        #expect(PushNameDirectory.read(from: store, pushKey: key, sealer: FakeSealer()) == nil)
        // Opens, but is not a names map.
        store.write("sealed[\(key)][1,2]")
        #expect(PushNameDirectory.read(from: store, pushKey: key, sealer: FakeSealer()) == nil)
    }

    @Test func aKeyThatIsNotAPushKeyWritesNothing() {
        let store = MemoryNameStore()
        #expect(!PushNameDirectoryWriter.write(entries, pushKey: "nope", sealer: FakeSealer(), store: store))
        #expect(store.writes == 0)
    }

    @Test func clearingForgetsEverything() {
        let store = MemoryNameStore()
        PushNameDirectoryWriter.write(entries, pushKey: key, sealer: FakeSealer(), store: store)
        PushNameDirectoryWriter.clear(store: store)
        #expect(store.read() == nil)
        #expect(PushNameDirectory.read(from: store, pushKey: key, sealer: FakeSealer()) == nil)
    }

    @Test func theSameNamesAreNotWrittenAgain() {
        let store = MemoryNameStore()
        PushNameDirectoryWriter.write(entries, pushKey: key, sealer: FakeSealer(), store: store)
        PushNameDirectoryWriter.write(entries.reversed(), pushKey: key, sealer: FakeSealer(), store: store)
        #expect(store.writes == 1)
        PushNameDirectoryWriter.write(Array(entries.dropLast()), pushKey: key, sealer: FakeSealer(), store: store)
        #expect(store.writes == 2)
    }

    @Test func theExtensionNamesAPushFromTheWrittenMap() {
        struct Decrypt: ChildIndexDecrypting {
            func decrypt(child: String, pushKey: String) throws -> UInt64 { 7 }
        }
        let store = MemoryNameStore()
        PushNameDirectoryWriter.write(entries, pushKey: key, sealer: FakeSealer(), store: store)
        let names = PushNameDirectory.read(from: store, pushKey: key, sealer: FakeSealer())
        let content = PushNotificationResolver.resolve(
            userInfo: ["aps": ["custom_data": ["child": "enc"]]], pushKey: key, decryptor: Decrypt(), names: names)
        #expect(content == .text(title: "Peel", body: "You have new messages in Builders"))
        // With the map cleared, the generic line.
        PushNameDirectoryWriter.clear(store: store)
        let after = PushNotificationResolver.resolve(
            userInfo: ["aps": ["custom_data": ["child": "enc"]]], pushKey: key, decryptor: Decrypt(),
            names: PushNameDirectory.read(from: store, pushKey: key, sealer: FakeSealer()))
        #expect(after == .generic)
    }
}

#if canImport(CommonCrypto) && canImport(CryptoKit)
struct RNCryptorSealerTests {
    private func hex(_ text: String) -> Data {
        var data = Data()
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            data.append(UInt8(text[index..<next], radix: 16)!)
            index = next
        }
        return data
    }

    /// The independent RNCryptor v3 vector PeelCore's MediaTests uses
    /// (PBKDF2-SHA1 ×10,000, AES-256-CBC, HMAC-SHA256): Sphinx's scheme.
    @Test func opensAnRNCryptorVector() throws {
        let sealed = hex(
            "03010001020304050607010203040506070802030405060708090a0b0c0d0e0f1011824c3d7d729a392faace1f72e6161d"
            + "8886a54b5deb5704ff5f40982db64f6964c4bbbfed851edd0f1c3bab4595d1c8c254a55b7a933d3a9a033624edcc31096b"
        ).base64EncodedString()
        #expect(try RNCryptorSealer().open(sealed, key: String(repeating: "3a", count: 32)) == "peel attachment vector")
    }

    @Test func roundTripsAndRefusesAnotherKeyOrDamage() throws {
        let key = String(repeating: "ab", count: 32)
        let sealed = try RNCryptorSealer().seal("{\"contact-1\":\"Bob\"}", key: key)
        #expect(try RNCryptorSealer().open(sealed, key: key) == "{\"contact-1\":\"Bob\"}")
        #expect(throws: RNCryptorSealer.Failure.self) { try RNCryptorSealer().open(sealed, key: String(repeating: "cd", count: 32)) }
        #expect(throws: RNCryptorSealer.Failure.self) { try RNCryptorSealer().open("not base64!", key: key) }
        #expect(throws: RNCryptorSealer.Failure.self) { try RNCryptorSealer().open(Data([3, 1, 0]).base64EncodedString(), key: key) }
    }

    @Test func theWriterAndReaderWorkWithTheRealCipher() {
        let key = String(repeating: "ab", count: 32)
        let store = MemoryNameStore()
        PushNameDirectoryWriter.write(
            [PushNameEntry(kind: .contact, index: 5, name: "Ann")], pushKey: key, sealer: RNCryptorSealer(), store: store)
        #expect(PushNameDirectory.read(from: store, pushKey: key, sealer: RNCryptorSealer())
                == PushNameDirectory(contacts: [5: "Ann"]))
    }
}
#endif
