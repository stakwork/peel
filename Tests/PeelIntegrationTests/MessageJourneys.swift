import Foundation
import Testing
@testable import PeelCore

extension Journeys {
    @Suite struct DirectMessages {
        /// Alice and Bob talk both ways through the wire tap. Each sees the
        /// other's words; the bytes on the wire never hold them, in any of
        /// the forms a careless client might send them.
        @Test func bothWaysAndNeverInTheClear() async throws {
            let alice = try await Person.create("alice", throughTap: true)
            let bob = try await Person.create("bob", throughTap: true)
            try await Bank.shared.give(100, to: alice)
            try await alice.engine.addContact(code: try bob.contactInfo)
            try await eventually("Alice and Bob to be contacts") {
                try alice.isReadyContact(bob) && bob.isReadyContact(alice)
            }
            let before = try await Stack.shared.wire().count

            let toBob = "the heron leaves at dawn \(UUID().uuidString)"
            let toAlice = "then we meet by the weir \(UUID().uuidString)"
            try await alice.engine.sendText(toBob, to: try bob.pubkey)
            let received = try await eventually("Bob to receive Alice's message") {
                try bob.messages(in: alice.pubkey).first { $0.content == toBob }
            }
            #expect(!received.fromMe)
            #expect(received.type == MessageType.text)
            try await bob.engine.sendText(toAlice, to: try alice.pubkey, replyTo: received.uuid)
            let reply = try await eventually("Alice to receive Bob's reply") {
                try alice.messages(in: bob.pubkey).first { $0.content == toAlice }
            }
            #expect(reply.replyUUID == received.uuid)
            try await eventually("Alice's message to be delivered") {
                try alice.messages(in: bob.pubkey).first { $0.content == toBob }?.delivery == .delivered
            }

            let wire = try await Stack.shared.wire()
            // The tap saw this conversation: the clients' traffic grew, and
            // their keys (in the MQTT topics) went by.
            #expect(wire.count > before)
            #expect(wire.range(of: Data(try alice.pubkey.utf8)) != nil)
            for text in [toBob, toAlice] {
                for form in Self.forms(of: text) {
                    #expect(wire.range(of: form) == nil, "plain text on the wire: \(text)")
                }
            }

            await alice.close()
            await bob.close()
        }

        /// The words as bytes, and in the encodings a payload might carry them in.
        static func forms(of text: String) -> [Data] {
            let utf8 = Data(text.utf8)
            let base64 = utf8.base64EncodedString()
            let hex = utf8.map { String(format: "%02x", $0) }.joined()
            // A distinctive run from the middle catches partial or chunked copies.
            let middle = Data(text.utf8.dropFirst(4).prefix(16))
            return [utf8, Data(base64.utf8), Data(hex.utf8), middle]
        }
    }
}
