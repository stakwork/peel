import Foundation

/// When a call began: the earliest moment anyone is known to have joined its
/// room, so every participant's timer reads the same. Only ever moves earlier,
/// so it holds when the first to join has since left.
public enum CallStart {
    /// The earlier of what is kept and the joins just seen (nils ignored).
    public static func earliest(_ kept: Date?, _ joins: [Date?]) -> Date? {
        (joins.compactMap { $0 } + [kept].compactMap { $0 }).min()
    }
}
