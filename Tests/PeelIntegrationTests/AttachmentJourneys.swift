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
    }
}
