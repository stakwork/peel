import Foundation
import Testing
@testable import PeelCore
@testable import PeelTestSupport

/// Where the Hive pairing is kept (`HiveItem`), that removing the account
/// leaves it, and whose it is (`HiveLink.belongs(to:)`).
struct HiveItemTests {
    private func link(pubkey: String? = nil) -> HiveLink {
        HiveLink(hive: HiveClient.production, credential: "hivedev_abc", deviceID: "dev-1", deviceName: "iPhone",
                 actor: "tom-cm1", peers: [], errors: [], expiresAt: nil, renewedAt: Date(timeIntervalSince1970: 1_000_000),
                 sphinxPubkey: pubkey)
    }

    @Test func aPairingFromBeforeTheNewItemMovesToIt() throws {
        let old = MemoryItem(Data("old".utf8))
        let new = MemoryItem()
        let item = HiveItem(current: new, legacy: old)
        #expect(try item.read() == Data("old".utf8))
        #expect(new.value == Data("old".utf8) && old.value == nil)
        #expect(try item.read() == Data("old".utf8))
    }

    @Test func theNewItemWinsAndWritingClearsTheOld() throws {
        let old = MemoryItem(Data("old".utf8))
        let new = MemoryItem(Data("new".utf8))
        let item = HiveItem(current: new, legacy: old)
        #expect(try item.read() == Data("new".utf8))
        try item.write(Data("newer".utf8))
        #expect(new.value == Data("newer".utf8) && old.value == nil)
    }

    @Test func deletingRemovesBoth() throws {
        let old = MemoryItem(Data("old".utf8))
        let new = MemoryItem(Data("new".utf8))
        try HiveItem(current: new, legacy: old).delete()
        #expect(new.value == nil && old.value == nil)
    }

    @Test func removingTheAccountKeepsThePairing() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "hive-keep-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let kept = MemoryItem(Data("link".utf8))
        try Profile(developmentAt: folder, hive: kept, keepsHive: true).delete()
        #expect(kept.value == Data("link".utf8))
        // A development profile's own file goes with it.
        let removed = MemoryItem(Data("link".utf8))
        try Profile(developmentAt: folder, hive: removed, keepsHive: false).delete()
        #expect(removed.value == nil)
    }

    @Test func aLinkIsKeptUnlessRecordedForAnotherAccount() {
        #expect(link(pubkey: "02aa").belongs(to: "02aa"))
        #expect(!link(pubkey: "02aa").belongs(to: "02bb"))
        #expect(link().belongs(to: "02bb"))
    }

    @Test func aLinkStoredWithoutAPubkeyStillDecodes() throws {
        let item = MemoryItem()
        try link(pubkey: "02aa").write(to: item)
        let stored = try #require(item.value)
        let object = try JSONSerialization.jsonObject(with: stored)
        var json = try #require(object as? [String: Any])
        json["sphinxPubkey"] = nil
        try item.write(try JSONSerialization.data(withJSONObject: json))
        #expect(try HiveLink.read(from: item)?.sphinxPubkey == nil)
        #expect(try HiveLink.read(from: item)?.credential == "hivedev_abc")
    }
}
