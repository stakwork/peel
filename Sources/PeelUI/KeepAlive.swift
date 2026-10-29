/// A few things kept alive while they are out of sight, most recently used
/// first: a workspace app's web view, which would lose the page's state if
/// it were made again each time the person came back to it. At most `limit`
/// are kept; the one shown longest ago goes first, and anything that goes
/// (this way, `evict` or `evictAll`) is handed to `teardown`.
///
/// Each value belongs to an owner (the app): asking for another key of the
/// same owner, which is a new page of it, drops the old one.
@MainActor
public final class KeepAlive<Key: Hashable, Value> {
    private struct Entry {
        let key: Key
        let owner: String
        let value: Value
    }

    private let limit: Int
    private let teardown: (Value) -> Void
    /// Most recently used last.
    private var entries: [Entry] = []

    public init(limit: Int, teardown: @escaping (Value) -> Void) {
        self.limit = limit
        self.teardown = teardown
    }

    /// The value kept for `key`, now the most recent; else the one `make`
    /// builds, kept in its place, with the owner's other keys and the oldest
    /// beyond the limit torn down.
    public func value(for key: Key, owner: String, make: () -> Value) -> Value {
        if let index = entries.firstIndex(where: { $0.key == key }) {
            let entry = entries.remove(at: index)
            entries.append(entry)
            return entry.value
        }
        drop { $0.owner == owner }
        let entry = Entry(key: key, owner: owner, value: make())
        entries.append(entry)
        while entries.count > limit { teardown(entries.removeFirst().value) }
        return entry.value
    }

    /// Tears down every kept key that `isGone` names.
    public func evict(where isGone: (Key) -> Bool) {
        drop { isGone($0.key) }
    }

    /// Tears down everything kept for owners `isGone` names.
    public func evict(owners isGone: (String) -> Bool) {
        drop { isGone($0.owner) }
    }

    public func evictAll() {
        drop { _ in true }
    }

    private func drop(_ isGone: (Entry) -> Bool) {
        let gone = entries.filter(isGone)
        entries.removeAll(where: isGone)
        gone.forEach { teardown($0.value) }
    }

    public var count: Int { entries.count }
}
