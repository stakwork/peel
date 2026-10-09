import Foundation
@testable import PeelCore

/// Where the journeys' sats come from. Made once per run: two accounts pay
/// each other their whole balance, less the payment's 1-sat ping
/// (`Engine.pingMsat`), through Peel's own checks while the mixer
/// runs `TESTING_ONLY_ADD_TO_SENDER` (senders are never debited, so the
/// balances grow), then the mixer restarts with real accounting, which every
/// journey runs under. Peel's checks are not loosened; the one thing set by
/// hand is the bank's first balance: a new account with no sats gets no
/// balance from the server, and Peel adds a contact only once it knows one.
actor Bank {
    static let shared = Bank()
    static let targetSats: UInt64 = 2_000_000

    private var funded: Person?

    func account() async throws -> Person {
        if let funded { return funded }
        try await Stack.shared.setMixer(.fund)
        let bank = try await Person.create("bank")
        let mint = try await Person.create("mint")
        // The key exchange's 5 sats and its ping; under TESTING_ONLY_ADD_TO_SENDER
        // they are never debited, and the server's next balance replaces this.
        try bank.storage.set(String(Engine.keyExchangeMsat + Engine.pingMsat(toTribe: false)), for: .balanceMsat)
        try await bank.engine.addContact(code: try mint.contactInfo)
        try await eventually("the bank and the mint to be contacts") {
            try bank.isReadyContact(mint) && mint.isReadyContact(bank)
        }
        var rounds = 0
        while try (bank.balance ?? 0) < Self.targetSats {
            rounds += 1
            guard rounds <= 60 else { throw StackError("funding stalled at \(try bank.balance ?? 0) sats") }
            for (from, to) in [(mint, bank), (bank, mint)] {
                let amount = try await eventually("\(from.name)'s balance") { try from.balance.flatMap { $0 > 1 ? $0 - 1 : nil } }
                let before = try to.balance ?? 0
                try await from.engine.sendPayment(to: try to.pubkey, amountMsat: amount * 1000, confirmedMsat: amount * 1000)
                try await eventually("\(to.name) to receive \(amount) sats") { try (to.balance ?? 0) >= before + amount }
            }
        }
        await mint.close()
        try await Stack.shared.setMixer(.real)
        funded = bank
        return bank
    }

    /// Gives `person` `sats` from the bank, adding them as a contact first.
    func give(_ sats: UInt64, to person: Person) async throws {
        let bank = try await account()
        if try !bank.isReadyContact(person) {
            try await bank.engine.addContact(code: try person.contactInfo)
            try await eventually("\(person.name) and the bank to be contacts") {
                try bank.isReadyContact(person) && person.isReadyContact(bank)
            }
        }
        let before = try await person.settledBalance() ?? 0
        try await bank.engine.sendPayment(to: try person.pubkey, amountMsat: sats * 1000, confirmedMsat: sats * 1000)
        try await eventually("\(person.name) to receive \(sats) sats from the bank") {
            try (person.balance ?? 0) >= before + sats
        }
    }
}
