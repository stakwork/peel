import Foundation

/// The PIN kept on this device between unlocks, so an app the system ended in
/// the background opens again without it while the PIN timeout has not run
/// out (the iPhone; the Mac asks at every launch).
///
/// In the data-protection Keychain, `WhenUnlockedThisDeviceOnly` and never
/// synchronised (`KeychainItem`): it never leaves this device, and it cannot
/// be read while the phone is locked. With the PIN it keeps when Peel was last
/// in use and the timeout that applied then: the timeout lives in the
/// account's database, which only the PIN opens. Past it the PIN is removed
/// and has to be typed. "When Peel opens" keeps nothing.
public struct RememberedPIN: Sendable {
    let item: any SecretItem

    init(item: any SecretItem) {
        self.item = item
    }

    struct Kept: Codable, Equatable {
        var pin: String
        /// When Peel was last in use.
        var activeAt: Date
        /// `PINTimeout`: hours, or `never`.
        var timeoutHours: Int
    }

    /// Keeps `pin` with when Peel was last in use and the timeout now; with a
    /// timeout of 0 ("When Peel opens"), removes what was kept instead.
    public func keep(_ pin: String, activeAt: Date, timeoutHours: Int) {
        guard timeoutHours != 0 else { return forget() }
        write(Kept(pin: pin, activeAt: activeAt, timeoutHours: timeoutHours))
    }

    /// Peel was in use until `activeAt`: the timeout counts from then. Nothing
    /// is kept by it when no PIN is.
    public func touch(activeAt: Date) {
        guard var kept = read() else { return }
        kept.activeAt = activeAt
        write(kept)
    }

    /// The timeout changed: kept with the PIN, so the next launch reads it
    /// before the account opens. 0 removes the PIN.
    public func timeoutChanged(to hours: Int) {
        guard hours != 0 else { return forget() }
        guard var kept = read(), kept.timeoutHours != hours else { return }
        kept.timeoutHours = hours
        write(kept)
    }

    /// The PIN changed: the new one replaces a kept one.
    public func pinChanged(to pin: String) {
        guard var kept = read() else { return }
        kept.pin = pin
        write(kept)
    }

    /// The kept PIN while its timeout has not run out at `now`; one that has
    /// is removed. Nil while the phone is locked (the item cannot be read).
    public func pin(at now: Date = Date()) -> String? {
        guard let kept = read() else { return nil }
        guard Self.isValid(kept, at: now) else {
            forget()
            return nil
        }
        return kept.pin
    }

    public func forget() {
        try? item.delete()
    }

    static func isValid(_ kept: Kept, at now: Date) -> Bool {
        switch kept.timeoutHours {
        case PINTimeout.never: true
        case ...0: false
        // A clock set back counts as no time passed.
        default: now.timeIntervalSince(kept.activeAt) <= Double(kept.timeoutHours) * 3600
        }
    }

    private func read() -> Kept? {
        guard let data = try? item.read() else { return nil }
        return try? JSONDecoder().decode(Kept.self, from: data)
    }

    private func write(_ kept: Kept) {
        guard let data = try? JSONEncoder().encode(kept) else { return }
        try? item.write(data)
    }
}
