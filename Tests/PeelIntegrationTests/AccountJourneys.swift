import Foundation
import Testing
@testable import PeelCore

extension Journeys {
    @Suite struct Accounts {
        /// A new account registers with the server; its twelve words bring
        /// the same account back on a second device.
        @Test func signUpThenRestoreFromTwelveWords() async throws {
            let alice = try await Person.create("alice")
            #expect(Engine.words(in: alice.mnemonic).count == 12)
            #expect(await alice.engine.isRegistered)
            let info = try alice.contactInfo
            #expect(info.split(separator: "_").count == 3)

            let second = try await Person.restore("alice", mnemonic: alice.mnemonic)
            #expect(await second.engine.isRegistered)
            #expect(try second.contactInfo == info)
            try await eventually("the restore to finish") { await !second.engine.isSyncingHistory }
            #expect(try second.storage.value(for: .needsRestore) != "1")

            await second.close()
            await alice.close()
        }

        /// Words that are not a mnemonic are refused before anything is written.
        @Test func restoreRefusesWrongWords() async throws {
            let stack = try await Stack.shared.current()
            let profile = Profile(developmentAt: Person.directory("wrong-words"))
            await #expect(throws: (any Error).self) {
                _ = try await Account.restore(
                    profile, mnemonic: Array(repeating: "abandon", count: 12).joined(separator: " "),
                    pin: "", server: try Person.address(stack.broker)
                )
            }
            #expect(!profile.hasAccount)
            try? FileManager.default.removeItem(at: profile.directory)
        }
    }
}
