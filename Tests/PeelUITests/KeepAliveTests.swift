import Testing
@testable import PeelUI

/// What a workspace app's kept web view does: stay while shown again, go
/// when its page is another or it is the least recent.
@MainActor
struct KeepAliveTests {
    final class Item { }

    private func cache(limit: Int = 3, torn: @escaping (Item) -> Void = { _ in }) -> KeepAlive<String, Item> {
        KeepAlive(limit: limit, teardown: torn)
    }

    @Test func theSameKeyIsTheSameValueAndMadeOnce() {
        let kept = cache()
        var made = 0
        let a = kept.value(for: "a#0", owner: "a") { made += 1; return Item() }
        let b = kept.value(for: "a#0", owner: "a") { made += 1; return Item() }
        #expect(a === b)
        #expect(made == 1)
    }

    @Test func anotherKeyOfTheSameOwnerTearsTheOldDown() {
        var torn: [Item] = []
        let kept = cache { torn.append($0) }
        let old = kept.value(for: "a#0", owner: "a") { Item() }
        let new = kept.value(for: "a#1", owner: "a") { Item() }
        #expect(torn.count == 1 && torn[0] === old)
        #expect(new !== old)
        #expect(kept.count == 1)
    }

    @Test func theLeastRecentGoesOverTheLimit() {
        var torn: [Item] = []
        let kept = cache(limit: 2) { torn.append($0) }
        let a = kept.value(for: "a", owner: "a") { Item() }
        _ = kept.value(for: "b", owner: "b") { Item() }
        _ = kept.value(for: "a", owner: "a") { Item() }   // a is the most recent now
        _ = kept.value(for: "c", owner: "c") { Item() }   // b goes
        #expect(torn.count == 1)
        let again = kept.value(for: "a", owner: "a") { Item() }
        #expect(again === a)
    }

    @Test func evictingByKeyOwnerOrAllTearsDown() {
        var torn = 0
        let kept = cache { _ in torn += 1 }
        _ = kept.value(for: "a#s1", owner: "a") { Item() }
        _ = kept.value(for: "b#s2", owner: "b") { Item() }
        _ = kept.value(for: "c#s2", owner: "c") { Item() }
        kept.evict(where: { $0.hasSuffix("s1") })
        #expect(torn == 1 && kept.count == 2)
        kept.evict(owners: { $0 == "b" })
        #expect(torn == 2 && kept.count == 1)
        kept.evictAll()
        #expect(torn == 3 && kept.count == 0)
    }
}
