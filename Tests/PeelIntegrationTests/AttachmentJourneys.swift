import Foundation
import Testing
@testable import PeelCore

extension Journeys {
    @Suite struct Attachments {
        /// Alice sends Bob a PDF: it goes up to the memes stub encrypted
        /// (the stub never holds the words in it), and Bob downloads and
        /// decrypts exactly the bytes she sent.
        @Test func uploadDownloadAndDecrypt() async throws {
            let alice = try await Person.create("alice")
            let bob = try await Person.create("bob")
            try await Bank.shared.give(100, to: alice)
            try await alice.engine.addContact(code: try bob.contactInfo)
            try await eventually("Alice and Bob to be contacts") {
                try alice.isReadyContact(bob) && bob.isReadyContact(alice)
            }

            let secret = "the key is under the third stone \(UUID().uuidString)"
            let original = Data("%PDF-1.4\n% \(secret)\n%%EOF\n".utf8)
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("PeelIntegration-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let file = folder.appendingPathComponent("field-notes.pdf")
            try original.write(to: file)

            let id = try await alice.engine.sendAttachment(file, text: "notes", to: try bob.pubkey)
            try await eventually("the upload and the message to be done") {
                let row = try alice.storage.message(id: id)
                return row?.uploadState == .done && row?.delivery == .delivered
            }
            let uploads = try await Stack.shared.memesUploads()
            #expect(!uploads.isEmpty)
            #expect(uploads.allSatisfy { $0.range(of: Data(secret.utf8)) == nil }, "the memes server holds the plain file")

            let received = try await eventually("Bob to receive the attachment") {
                try bob.messages(in: alice.pubkey).first { $0.type == MessageType.attachment }
            }
            #expect(received.content == "notes")
            #expect(received.attachmentKind == .pdf)
            let downloaded = try await bob.engine.downloadAttachment(messageID: try #require(received.id))
            #expect(try Data(contentsOf: downloaded.file) == original)
            #expect(downloaded.kind == .pdf)
            #expect(downloaded.size == original.count)
            #expect(!downloaded.cached)
            let again = try await bob.engine.downloadAttachment(messageID: try #require(received.id))
            #expect(again.cached)

            await alice.close()
            await bob.close()
        }

        /// The payments review's journey 4: Bob sells a picture in a direct
        /// message, Alice buys it, his key comes back and the picture
        /// decrypts. A second one's purchase Bob stores but does not answer
        /// before his engine closes (bug hunt N3); reopened, he answers it.
        @Test func aPaidPictureIsBoughtAndAnsweredEvenAfterASellerStops() async throws {
            let alice = try await Person.create("alice")
            let bob = try await Person.create("bob")
            try await Bank.shared.give(1_000, to: alice)
            try await alice.engine.addContact(code: try bob.contactInfo)
            try await eventually("Alice and Bob to be contacts") {
                try alice.isReadyContact(bob) && bob.isReadyContact(alice)
            }
            let (aliceKey, bobKey) = (try alice.pubkey, try bob.pubkey)

            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("PeelIntegration-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            /// Bob sells a picture for 20 sats; Alice's copy of it, locked.
            func sell(_ name: String) async throws -> (sold: Int64, received: Message, original: Data) {
                let original = try #require(Data(base64Encoded: onePixelPNG))
                let file = folder.appendingPathComponent("\(name).png")
                try original.write(to: file)
                let sold = try await bob.engine.sendAttachment(file, text: name, to: aliceKey, priceSats: 20)
                let received = try await eventually("Alice to receive \(name)") {
                    try alice.messages(in: bobKey).first { $0.type == MessageType.attachment && $0.content == name }
                }
                #expect(try alice.storage.purchaseState(of: received) == .locked)
                return (sold, received, original)
            }
            /// Alice's copy unlocked by the key, and the picture it decrypts to.
            func opened(_ received: Message, timeout: Duration = .seconds(20)) async throws -> Data {
                try await eventually("the key for \(received.content ?? "") to arrive", timeout: timeout) {
                    try alice.storage.purchaseState(of: received) == .unlocked
                }
                let downloaded = try await alice.engine.downloadAttachment(messageID: try #require(received.id))
                return try Data(contentsOf: downloaded.file)
            }

            let first = try await sell("first")
            try await alice.engine.buyAttachment(messageID: try #require(first.received.id), confirmedMsat: 20_000)
            #expect(try await opened(first.received) == first.original)

            // The second: Bob's copy has no key while the purchase lands, so
            // it is stored and not answered, as if Peel stopped in between.
            let second = try await sell("second")
            let body = try #require(try bob.storage.message(id: second.sold)?.body)
            try await bob.storage.pool.write { db in
                try db.execute(sql: "UPDATE message SET body = ? WHERE id = ?", arguments: [
                    #"{"mediaToken":"\#(AttachmentFields.decode(body)?.mediaToken ?? "")"}"#, second.sold,
                ])
            }
            try await alice.engine.buyAttachment(messageID: try #require(second.received.id), confirmedMsat: 20_000)
            try await eventually("Bob to store the purchase") {
                try bob.messages(in: aliceKey).filter { $0.type == MessageType.purchase && !$0.fromMe }.count == 2
            }
            await bob.engine.close()
            try await bob.storage.pool.write { db in
                try db.execute(sql: "UPDATE message SET body = ? WHERE id = ?", arguments: [body, second.sold])
            }
            #expect(try alice.storage.purchaseState(of: second.received) == .processing)

            // Reopened: a new engine on the same profile answers it, once.
            let reopened = Person(
                name: bob.name, profile: bob.profile,
                engine: try Engine(mnemonic: bob.mnemonic, storage: bob.storage), mnemonic: bob.mnemonic
            )
            try await reopened.engine.connect()
            #expect(try await opened(second.received, timeout: .seconds(40)) == second.original)
            #expect(try reopened.messages(in: aliceKey).filter { $0.type == MessageType.purchaseAccept }.count == 2)

            await alice.close()
            await reopened.close()
        }
    }
}

/// A one-pixel PNG.
private let onePixelPNG = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
