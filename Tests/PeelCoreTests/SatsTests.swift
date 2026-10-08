import Foundation
import Testing
@testable import PeelCore

struct SatsTests {
    /// As the official apps show them: the rest of a sat dropped.
    @Test func amountsShowAsWholeSatsTruncated() {
        #expect(Sats.format(msat: 0) == "0 sats")
        #expect(Sats.format(msat: -5_000) == "0 sats")
        #expect(Sats.format(msat: 1) == "0 sats")
        #expect(Sats.format(msat: 499) == "0 sats")
        #expect(Sats.format(msat: 500) == "0 sats")
        #expect(Sats.format(msat: 999) == "0 sats")
        #expect(Sats.format(msat: 1_000) == "1 sat")
        #expect(Sats.format(msat: 1_499) == "1 sat")
        #expect(Sats.format(msat: 1_500) == "1 sat")
        #expect(Sats.format(msat: 1_999) == "1 sat")
        #expect(Sats.format(msat: 2_000) == "2 sats")
        #expect(Sats.format(msat: 21_000) == "21 sats")
        #expect(Sats.format(msat: UInt64.max) == "\((UInt64.max / 1000).formatted()) sats")
        // Grouped as the locale groups.
        #expect(Sats.format(msat: 1_210_000) == "\(1_210.formatted()) sats")
        #expect(Sats.number(msat: 1_210_999) == 1_210.formatted())
        #expect(Sats.number(msat: Int64(-1)) == "0")
    }

    /// Sent amounts carry a true minus, received a plus; nothing for zero.
    @Test func signedAmountsUseATrueMinus() {
        #expect(Sats.signed(msat: 500_000, incoming: true) == "+500")
        #expect(Sats.signed(msat: 21_000, incoming: false) == "\u{2212}21")
        #expect(Sats.signed(msat: 2_000_000, incoming: false) == "\u{2212}\(2_000.formatted())")
        #expect(Sats.signed(msat: 999, incoming: false) == "0")
        #expect(Sats.signed(msat: 0, incoming: true) == "0")
    }

    @Test func aShortfallIsNeverHidden() {
        #expect(Sats.format(msat: 1_600, of: 2_000) == "1 of 2 sats")
        #expect(Sats.format(msat: 2_100, of: 2_400) == "\(2_100.formatted()) of \(2_400.formatted()) msat")
        #expect(Sats.format(msat: 2_000, of: 2_000) == "2 of 2 sats")
    }

    @Test func typedAmountsAreExactInTheSmallerUnit() throws {
        #expect(try Sats.parse("", unit: 1000, of: "price") == 0)
        #expect(try Sats.parse("3", unit: 1000, of: "price") == 3000)
        #expect(try Sats.parse("1.5", unit: 1000, of: "price") == 1500)
        #expect(try Sats.parse("0.5", unit: 3_600_000, of: "time") == 1_800_000)
        #expect(throws: PeelError.self) { try Sats.parse("0.0001", unit: 1000, of: "price") }
        #expect(throws: PeelError.self) { try Sats.parse("-1", unit: 1000, of: "price") }
        #expect(throws: PeelError.self) { try Sats.parse("1.2.3", unit: 1000, of: "price") }
        #expect(throws: PeelError.self) { try Sats.parse("1e3", unit: 1000, of: "price") }
        #expect(throws: PeelError.self) { try Sats.parse("99999999999999999", unit: 1000, of: "price") }
    }
}
