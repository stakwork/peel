import Foundation
import GRDB
import Testing
@testable import PeelCore

/// One account on the local stack, made with the real core through `Account`
/// and `Engine`, in a temporary directory of its own.
struct Person: Sendable {
    let name: String
    let profile: Profile
    let engine: Engine
    let mnemonic: String

    var storage: Storage { engine.storage }

    /// A temporary directory for one account; removed by `close()`.
    static func directory(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("PeelIntegration-\(name)-\(UUID().uuidString.prefix(8))", isDirectory: true)
    }

    /// A new account with no invite, connected and registered. `throughTap`
    /// connects it through the wire tap, which records what it sends and receives.
    static func create(_ name: String, throughTap: Bool = false) async throws -> Person {
        let stack = try await Stack.shared.current()
        let profile = Profile(developmentAt: directory(name))
        let created = try await Account.create(
            profile, alias: name, pin: "", server: try address(throughTap ? stack.tap : stack.broker),
            tribeHost: stack.tribes, memesHost: stack.memes
        )
        try await created.engine.connect()
        return Person(name: name, profile: profile, engine: created.engine, mnemonic: created.mnemonic)
    }

    /// The same account from its twelve words, in a new directory: a second device.
    static func restore(_ name: String, mnemonic: String) async throws -> Person {
        let stack = try await Stack.shared.current()
        let profile = Profile(developmentAt: directory("\(name)-restored"))
        let engine = try await Account.restore(
            profile, mnemonic: mnemonic, pin: "", server: try address(stack.broker),
            tribeHost: stack.tribes, memesHost: stack.memes
        )
        try await engine.connect()
        return Person(name: name, profile: profile, engine: engine, mnemonic: mnemonic)
    }

    /// A new account from someone's invite, as the onboarding signs up;
    /// `throughTap` as for `create`.
    static func signup(_ name: String, invite link: String, throughTap: Bool = false) async throws -> Person {
        let stack = try await Stack.shared.current()
        let profile = Profile(developmentAt: directory(name))
        let created = try await Account.signup(
            profile, invite: try Engine.parseInvite(link), alias: name, pin: "",
            server: try address(throughTap ? stack.tap : stack.broker),
            tribeHost: stack.tribes, memesHost: stack.memes
        )
        return Person(name: name, profile: profile, engine: created.engine, mnemonic: created.mnemonic)
    }

    /// Alice on the wire tap, kept connected as the app keeps her, and Bob
    /// off it, as contacts.
    static func contactsOnTap() async throws -> (alice: Person, bob: Person) {
        let alice = try await Person.create("alice", throughTap: true)
        let bob = try await Person.create("bob")
        try await Bank.shared.give(1_000, to: alice)
        try await alice.engine.addContact(code: try bob.contactInfo)
        try await eventually("Alice and Bob to be contacts") {
            try alice.isReadyContact(bob) && bob.isReadyContact(alice)
        }
        await alice.engine.start()
        return (alice, bob)
    }

    /// Takes the wire tap down and waits until this account, on it, sees
    /// its connection go.
    func loseTheTap() async throws {
        try await Stack.shared.tap(.down)
        try await eventually("\(name.capitalized) to see the connection go") { await engine.connection != .connected }
    }

    /// This account in a new engine on the same profile, as after a
    /// relaunch: nothing in memory. Not connected yet.
    func relaunched() throws -> Person {
        Person(name: name, profile: profile, engine: try Engine(mnemonic: mnemonic, storage: storage), mnemonic: mnemonic)
    }

    static func address(_ text: String) throws -> ServerAddress {
        guard let address = ServerAddress(text) else { throw StackError("unreadable address \(text)") }
        return address
    }

    func close() async {
        await engine.close()
        try? FileManager.default.removeItem(at: profile.directory)
    }

    // MARK: - Who

    var contactInfo: String {
        get throws {
            guard let info = try storage.value(for: .contactInfo) else { throw StackError("\(name) is not registered") }
            return info
        }
    }

    var pubkey: String {
        get throws { String(try contactInfo.prefix(while: { $0 != "_" })) }
    }

    /// The balance the server last reported, in sats; nil until it has.
    var balance: UInt64? {
        get throws { try storage.balanceMsat().map { $0 / 1000 } }
    }

    // MARK: - Reads

    /// Every stored message of a chat, oldest first.
    func messages(in chat: String) throws -> [Message] {
        try storage.pool.read { db in
            try Message.fetchAll(db, sql: "SELECT * FROM message WHERE chat = ? ORDER BY id", arguments: [chat])
        }
    }

    func isReadyContact(_ other: Person) throws -> Bool {
        try isReadyContact(pubkey: try other.pubkey)
    }

    func isReadyContact(pubkey: String) throws -> Bool {
        try engine.storage.pool.read { db in
            try Bool.fetchOne(db, sql: "SELECT ready FROM contact WHERE pubkey = ?", arguments: [pubkey]) ?? false
        }
    }

    // MARK: - Waiting

    /// Waits until the balance is `sats` and returns it; on timeout returns
    /// whatever it is then, for the caller to assert on.
    @discardableResult
    func balance(settlingAt sats: UInt64, timeout: Duration = .seconds(15)) async throws -> UInt64? {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if try balance == sats { return sats }
            try await Task.sleep(for: .milliseconds(200))
        }
        return try balance
    }

    /// Waits for the balance to stop moving (no change for `quiet`) and returns it.
    func settledBalance(quiet: Duration = .seconds(2), timeout: Duration = .seconds(20)) async throws -> UInt64? {
        let deadline = ContinuousClock.now + timeout
        var last = try balance
        var since = ContinuousClock.now
        while ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(200))
            let now = try balance
            if now != last {
                last = now
                since = .now
            } else if ContinuousClock.now - since >= quiet {
                return now
            }
        }
        return last
    }
}

/// Polls `check` every `interval` until it returns a value, or fails with `what`.
@discardableResult
func eventually<T>(
    _ what: String, timeout: Duration = .seconds(20), every interval: Duration = .milliseconds(200),
    isolation: isolated (any Actor)? = #isolation,
    _ check: () async throws -> T?
) async throws -> T {
    let deadline = ContinuousClock.now + timeout
    while true {
        if let value = try await check() { return value }
        guard ContinuousClock.now < deadline else { throw StackError("timed out waiting for \(what)") }
        try await Task.sleep(for: interval)
    }
}

/// Polls a condition until it holds, or fails with `what`.
func eventually(
    _ what: String, timeout: Duration = .seconds(20), every interval: Duration = .milliseconds(200),
    isolation: isolated (any Actor)? = #isolation,
    _ check: () async throws -> Bool
) async throws {
    try await eventually(what, timeout: timeout, every: interval) { try await check() ? () : nil }
}
