import Foundation

/// Amounts as people see and type them. Money is kept, charged and sent in
/// msat; this is display and input only.
public enum Sats {
    /// "1 sat", "21 sats", "1,210 sats": whole sats, never decimals, the rest
    /// of a sat dropped as the official apps drop it (1,999 msat is "1 sat",
    /// anything under a sat "0 sats"); below zero reads "0 sats".
    public static func format(msat: some BinaryInteger) -> String {
        let sats = whole(msat)
        return "\(sats.formatted()) \(sats == 1 ? "sat" : "sats")"
    }

    /// "1,210": the number alone, as `format`, for chips and lists that
    /// write "sats" apart.
    public static func number(msat: some BinaryInteger) -> String {
        whole(msat).formatted()
    }

    /// "1 of 2 sats": part of an amount, as for an underpaid invoice. Where
    /// dropping the rest of a sat would hide a shortfall ("2 of 2 sats" for
    /// 2,100 of 2,400 msat), both in msat instead.
    public static func format(msat part: some BinaryInteger, of total: some BinaryInteger) -> String {
        let (part, total) = (UInt64(clamping: part), UInt64(clamping: total))
        if part != total && whole(part) == whole(total) { return "\(part.formatted()) of \(total.formatted()) msat" }
        return "\(number(msat: part)) of \(format(msat: total))"
    }

    private static func whole(_ msat: some BinaryInteger) -> UInt64 { UInt64(clamping: msat) / 1000 }

    /// A whole number of sats above zero ("1,000" too), as msat; nil for
    /// anything else, or too many to count in msat.
    public static func msat(_ text: String) -> UInt64? {
        let digits = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "")
        guard let sats = UInt64(digits), sats > 0 else { return nil }
        let (msat, overflow) = sats.multipliedReportingOverflow(by: 1000)
        return overflow ? nil : msat
    }

    /// An amount someone typed, in a unit bigger than the one sent: sats for
    /// msat (1000), hours for milliseconds (3,600,000). Decimals are fine as
    /// long as the result is a whole number of the smaller unit ("1.5" sats
    /// is 1500 msat); blank is zero. Capped at what the tribes server can hold.
    public static func parse(_ text: String, unit: UInt64, of what: String) throws -> UInt64 {
        let text = text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return 0 }
        guard text.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }), text.filter({ $0 == "." }).count <= 1,
              let value = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")) else {
            throw PeelError("the \(what) must be a number")
        }
        let scaled = value * Decimal(unit)
        guard scaled <= Decimal(Int64.max) else { throw PeelError("the \(what) is too large") }
        var whole = Decimal()
        var copy = scaled
        NSDecimalRound(&whole, &copy, 0, .plain)
        guard whole == scaled else { throw PeelError("the \(what) is finer than the network can carry") }
        return UInt64(truncating: whole as NSDecimalNumber)
    }
}
