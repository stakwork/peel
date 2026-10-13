import Foundation
import Testing
@testable import PeelCore

/// The profile's contact info and the sats, from `scripts/fund-dev.sh`.
let fundRequest: (contactInfo: String, sats: UInt64)? = {
    let environment = ProcessInfo.processInfo.environment
    guard environment["PEEL_STACK_DIR"] != nil, let info = environment["PEEL_FUND_CONTACT"],
          let sats = environment["PEEL_FUND_SATS"].flatMap(UInt64.init) else { return nil }
    return (info, sats)
}()

/// The test half of `scripts/fund-dev.sh`, the one sanctioned way to give a
/// development profile sats: the bank (`Bank`) adds the profile by its
/// contact info and pays it, a real payment on the local stack. This
/// process never opens the profile; the script keeps it online with
/// `peel listen` so it answers the key exchange, and checks its balance.
@Suite(.enabled(if: fundRequest != nil, "runs only from scripts/fund-dev.sh"), .timeLimit(.minutes(10)))
struct FundDev {
    @Test func pay() async throws {
        let (info, sats) = try #require(fundRequest)
        try #require(sats > 0 && sats < Bank.targetSats / 2)
        // The stack the script named, and only one on this machine.
        let stack = try await Stack.shared.current()
        for address in [stack.broker, stack.tribes, stack.memes] {
            try #require(address.hasPrefix("127.0.0.1:"), "not a loopback stack: \(address)")
        }
        let pubkey = String(info.prefix(while: { $0 != "_" }))
        let bank = try await Bank.shared.account()
        try await bank.engine.addContact(code: info)
        try await eventually("the profile to answer the bank's key exchange", timeout: .seconds(60)) {
            try bank.isReadyContact(pubkey: pubkey)
        }
        let before = try await bank.settledBalance() ?? 0
        try await bank.engine.sendPayment(to: pubkey, amountMsat: sats * 1000, confirmedMsat: sats * 1000)
        try await eventually("the mixer to take \(sats) sats from the bank", timeout: .seconds(60)) {
            try (bank.balance ?? .max) + sats <= before
        }
    }
}
