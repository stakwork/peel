import Foundation
import PeelCore

/// Where the agent lives: Peel Home, its strut and bridge, on this Mac, or
/// moved to a home server (`PeelHomeMove`), where this Mac's strut and
/// bridge are never started while it is kept.
public enum Brain: Sendable, Equatable {
    case thisMac
    case moved(MovedHome)

    /// Where Peel Home went, nil while it is on this Mac.
    public var moved: MovedHome? {
        if case .moved(let home) = self { home } else { nil }
    }

    /// The account's choice, kept in `item` (`Profile.brain`): nothing kept
    /// is this Mac, and so is a home server kept the old way, by address and
    /// key (before Peel Home moved whole), which Peel no longer uses:
    /// `oldHomeServer` says so, for the app to clear and say once. Throws
    /// when it cannot be read, so a Keychain that fails is never taken for "this Mac".
    public static func read(_ item: any SecretItem) throws -> (brain: Brain, oldHomeServer: Bool) {
        guard let data = try item.read() else { return (.thisMac, false) }
        guard let kept = try? JSONDecoder().decode(Kept.self, from: data) else {
            throw PeelError("Peel couldn't tell where your assistant runs. Choose Use this Mac in Account › Always on.")
        }
        // Moved, and nothing else: a record mixing both is not one Peel wrote.
        switch (kept.moved, kept.url) {
        case (let moved?, nil): return (.moved(moved), false)
        case (nil, _?): return (.thisMac, true)
        default: throw PeelError("Peel couldn't tell where your assistant runs. Choose Use this Mac in Account › Always on.")
        }
    }

    /// Keeps it in `item`: where Peel Home moved, or nothing for this Mac.
    public func keep(in item: any SecretItem) throws {
        switch self {
        case .thisMac: try item.delete()
        case .moved(let home):
            try item.write(JSONEncoder().encode(Kept(moved: home)))
        }
    }

    private struct Kept: Codable {
        /// The old home server's address (its key beside it is never read).
        var url: String?
        var moved: MovedHome?
    }
}

/// Peel Home on a home server (`PeelHomeMove`): where it went and when,
/// whether the agent has answered from there, and this Mac's copy of its
/// folders, kept under the names they were set aside as.
public struct MovedHome: Codable, Sendable, Equatable {
    /// The box's address, from the link (`HomeLink.host`).
    public var host: String
    public var date: Date
    /// The agent answered from the box. Until it has, the move may or may
    /// not have arrived: this Mac's strut and bridge stay stopped all the same.
    public var answered: Bool
    /// This Mac's copy of strut's and the bridge's folders, by their names
    /// beside the originals (`Strut.moved-<date>`); nil until they are set aside.
    public var strutCopy: String?
    public var bridgeCopy: String?

    public init(host: String, date: Date, answered: Bool = false, strutCopy: String? = nil, bridgeCopy: String? = nil) {
        self.host = host
        self.date = date
        self.answered = answered
        self.strutCopy = strutCopy
        self.bridgeCopy = bridgeCopy
    }
}
