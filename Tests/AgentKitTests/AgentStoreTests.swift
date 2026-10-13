import Foundation
import GRDB
import Testing
@testable import AgentKit

/// A store on device `device` whose wall clock stands still at `ms`.
private func store(_ device: String = "a", at ms: Int64 = 1_000) throws -> SQLiteAgentStore {
    try SQLiteAgentStore.inMemory(device: device, now: { ms })
}

/// The built tables, whole but for `record.id` (insert order), for comparing two stores.
private func tables(_ store: SQLiteAgentStore) throws -> [[Row]] {
    try store.db.read { db in
        try [
            "SELECT ref_id, type, name, body, props, created_by, source, created_ms, updated_ms, deleted_ms FROM record",
            "SELECT * FROM link",
            "SELECT * FROM field_clock",
        ].map { try Row.fetchAll(db, sql: $0 + " ORDER BY 1, 2") }
    }
}

private func event(
    _ op: Event.Op, _ refId: String, _ fields: [String: JSONValue] = [:], wall: Int64, counter: Int = 0,
    device: String = "a", id: String? = nil
) -> Event {
    Event(eventId: id ?? UUID().uuidString.lowercased(), op: op, refId: refId, fields: fields,
          ts: HLC(wallMs: wall, counter: counter, device: device))
}

/// A small history from two devices: adds, updates, links, an unlink and a forget.
private func history() -> [Event] {
    [
        event(.add, "r1", ["type": "Person", "name": "Ann", "created_by": "user", "props": ["role": "dev"]], wall: 1),
        event(.add, "r2", ["type": "Project", "name": "Peel", "body": "A Sphinx client", "created_by": "agent"], wall: 2),
        event(.update, "r1", ["name": "Ann Lee", "props": ["city": "Leeds"]], wall: 3, device: "b"),
        event(.update, "r1", ["name": "Ann L", "props": ["role": "lead"]], wall: 3, device: "a"),
        event(.link, "l1", ["type": "works_on", "from": "r1", "to": "r2", "created_by": "agent"], wall: 4),
        event(.add, "r3", ["type": "Memory", "name": "Likes tea", "created_by": "agent"], wall: 5, device: "b"),
        event(.link, "l2", ["type": "about", "from": "r3", "to": "r1", "created_by": "agent"], wall: 6),
        event(.unlink, "l2", wall: 7, device: "b"),
        event(.forget, "r3", ["reason": "wrong"], wall: 8),
        event(.update, "r2", ["props": ["status": "active"]], wall: 9, device: "b"),
    ]
}

struct EventFormatTests {
    @Test func encodingIsStableSnakeCase() throws {
        let e = Event(eventId: "e1", op: .add, refId: "r1", fields: ["name": "Ann", "type": "Person"],
                      ts: HLC(wallMs: 5, counter: 2, device: "mac"))
        let json = String(decoding: try e.encoded(), as: UTF8.self)
        #expect(json == #"{"device":"mac","event_id":"e1","fields":{"name":"Ann","type":"Person"},"op":"add","ref_id":"r1","ts":{"counter":2,"device":"mac","wall_ms":5},"v":1}"#)
        #expect(try Event.decode(Data(json.utf8)) == e)
    }

    @Test func jsonValueRoundTrips() throws {
        let value: JSONValue = ["a": [1, 2.5, "x", true, .null], "b": ["c": false]]
        let data = try JSONEncoder().encode(value)
        #expect(try JSONDecoder().decode(JSONValue.self, from: data) == value)
    }

    @Test func newerVersionIsRefused() throws {
        var e = event(.add, "r1", ["type": "T", "name": "n", "created_by": "u"], wall: 1)
        e.v = Event.version + 1
        #expect(throws: AgentStoreError.unsupportedVersion(Event.version + 1)) { try store().write(e) }
    }
}

struct HLCTests {
    @Test func tickIsMonotonicWhenTheWallClockStalls() {
        var clock = HLC(wallMs: 0, device: "a")
        let first = clock.tick(now: 10)
        let second = clock.tick(now: 10)
        let third = clock.tick(now: 9)
        #expect(first < second && second < third)
        #expect(third == HLC(wallMs: 10, counter: 2, device: "a"))
    }

    @Test func receiveOrdersTheNextTickAfterTheRemote() {
        var clock = HLC(wallMs: 10, device: "a")
        let remote = HLC(wallMs: 50, counter: 3, device: "b")
        clock.receive(remote, now: 20)
        #expect(clock.tick(now: 20) > remote)
    }

    @Test func orderIsWallThenCounterThenDevice() {
        #expect(HLC(wallMs: 1, counter: 9, device: "z") < HLC(wallMs: 2, counter: 0, device: "a"))
        #expect(HLC(wallMs: 1, counter: 1, device: "z") < HLC(wallMs: 1, counter: 2, device: "a"))
        #expect(HLC(wallMs: 1, counter: 1, device: "a") < HLC(wallMs: 1, counter: 1, device: "b"))
    }
}

struct ApplyTests {
    @Test func orderDoesNotMatter() throws {
        let events = history()
        let forward = try store()
        for e in events { try forward.write(e) }
        let backward = try store()
        for e in events.reversed() { try backward.write(e) }
        let shuffled = try store()
        var generator = SystemRandomNumberGenerator()
        for e in events.shuffled(using: &generator) { try shuffled.write(e) }

        #expect(try tables(forward) == tables(backward))
        #expect(try tables(forward) == tables(shuffled))
    }

    @Test func reapplyingAnEventIsANoOp() throws {
        let s = try store()
        let events = history()
        for e in events { #expect(try s.write(e)) }
        let before = try tables(s)
        for e in events { #expect(try s.write(e) == false) }
        #expect(try tables(s) == before)
        #expect(try s.events().count == events.count)
    }

    @Test func lastWriteWinsPerField() throws {
        let s = try store()
        for e in history() { try s.write(e) }
        let ann = try #require(try s.read("r1"))
        // Same wall and counter at 3: device "b" is higher, so its name wins.
        #expect(ann.name == "Ann Lee")
        // Each props key on its own: role from "a" at 3, city from "b" at 3.
        #expect(ann.props == ["role": "lead", "city": "Leeds"])
        #expect(ann.createdMs == 1 && ann.updatedMs == 3)

        // An older update arriving late changes nothing.
        try s.write(event(.update, "r1", ["name": "Old"], wall: 2, device: "c"))
        #expect(try s.read("r1")?.name == "Ann Lee")
    }

    @Test func updateBeforeAddWaitsForTheAdd() throws {
        let s = try store()
        try s.write(event(.update, "r9", ["name": "Later"], wall: 5))
        #expect(try s.read("r9") == nil)
        try s.write(event(.add, "r9", ["type": "Concept", "name": "Early", "created_by": "agent"], wall: 1))
        let record = try #require(try s.read("r9"))
        #expect(record.name == "Later" && record.type == "Concept" && record.createdMs == 1)
    }

    @Test func nullRemovesAPropsKey() throws {
        let s = try store()
        let id = try s.add(type: "Task", name: "Ship", props: ["due": "friday", "owner": "tom"], createdBy: "user")
        try s.update(id, props: ["due": .null])
        #expect(try s.read(id)?.props == ["owner": "tom"])
    }

    @Test func forgetAndRestore() throws {
        let s = try store()
        for e in history() { try s.write(e) }
        #expect(try s.read("r3") == nil)
        #expect(try s.read("r3", includeDeleted: true)?.deletedMs == 8)
        try s.restore("r3")
        #expect(try s.read("r3")?.name == "Likes tea")
    }

    @Test func unlinkHidesTheLink() throws {
        let s = try store()
        for e in history() { try s.write(e) }
        try s.restore("r3")
        // l2 (r3 about r1) was unlinked; only l1 remains from r1.
        #expect(try s.walk("r1").map(\.link.refId) == ["l1"])
        #expect(try Set(s.walk("r1", edgeTypes: nil, direction: .both, depth: 1, limit: 10, includeDeleted: true).map(\.link.refId)) == ["l1", "l2"])
    }

    @Test func unlinkBetweenLiveRecords() throws {
        let s = try store()
        let a = try s.add(type: "T", name: "a", createdBy: "u")
        let b = try s.add(type: "T", name: "b", createdBy: "u")
        let link = try s.link(a, "rel", b, createdBy: "u")
        #expect(try s.walk(a).map(\.record.refId) == [b])
        try s.unlink(link)
        #expect(try s.walk(a).isEmpty)
        #expect(try s.ontology().filter { $0.kind == .link }.isEmpty)
    }

    @Test func fieldsOfTheWrongTypeAreIgnored() throws {
        let s = try store()
        let id = try s.add(type: "T", name: "kept", body: "body", createdBy: "u")
        try s.write(event(.update, id, ["name": 5, "type": .null, "body": true, "deleted_ms": "soon", "color": "red"],
                          wall: 9_999))
        let record = try #require(try s.read(id))
        #expect(record.name == "kept" && record.type == "T" && record.body == "body" && record.deletedMs == nil)
    }

    @Test func deviceMustMatchTheStamp() throws {
        var e = event(.add, "r1", ["type": "T", "name": "n", "created_by": "u"], wall: 1)
        e.device = "other"
        #expect(throws: AgentStoreError.malformedEvent) { try store().write(e) }
    }

    @Test func unlinkBeforeLinkStaysUnlinked() throws {
        let s = try store()
        try s.write(event(.add, "x", ["type": "T", "name": "x", "created_by": "u"], wall: 1))
        try s.write(event(.add, "y", ["type": "T", "name": "y", "created_by": "u"], wall: 1))
        try s.write(event(.unlink, "l", wall: 5))
        try s.write(event(.link, "l", ["type": "rel", "from": "x", "to": "y", "created_by": "u"], wall: 2))
        #expect(try s.walk("x").isEmpty)
    }

    @Test func rebuildEqualsIncrementalState() throws {
        let s = try store()
        for e in history() { try s.write(e) }
        let incremental = try tables(s)
        let hits = try s.search("sphinx")
        try s.rebuild()
        #expect(try tables(s) == incremental)
        #expect(try s.search("sphinx") == hits)
    }

    @Test func writerStampsAndClockSurvivesReopen() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentkit-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let first = try SQLiteAgentStore(path: path, device: "a")
        let id = try first.add(type: "Memory", name: "one", createdBy: "agent")
        let last = try #require(try first.events().last?.ts)
        // A wall clock behind the log still stamps after it.
        let reopened = try SQLiteAgentStore(db: DatabaseQueue(path: path), device: "a", now: { 0 })
        #expect(reopened.stamp() > last)
        #expect(try reopened.read(id)?.name == "one")
    }
}

struct ReadTests {
    @Test func searchMatchesNameAndBodyByPrefix() throws {
        let s = try store()
        let peel = try s.add(type: "Project", name: "Peel", body: "A native Sphinx chat client", createdBy: "user")
        let tea = try s.add(type: "Memory", name: "Likes tea", body: "Green, no sugar", createdBy: "agent")
        try s.add(type: "Memory", name: "Coffee", body: "Never before noon", createdBy: "agent")

        #expect(try s.search("peel").map(\.refId) == [peel])
        #expect(try s.search("sphi").map(\.refId) == [peel])
        #expect(try s.search("tea green").map(\.refId) == [tea])
        #expect(try s.search("Memory", type: "Memory").isEmpty)
        #expect(try s.search("tea", type: "Project").isEmpty)
        #expect(try s.search("\"").isEmpty)
        #expect(try s.search("   ").isEmpty)
        #expect(try s.search("sphinx").first?.snippet?.contains("Sphinx") == true)

        try s.forget(tea)
        #expect(try s.search("tea").isEmpty)
        #expect(try s.search("tea", type: nil, limit: 5, includeDeleted: true).map(\.refId) == [tea])

        try s.update(peel, name: "Rind")
        #expect(try s.search("peel").isEmpty)
        #expect(try s.search("rind").map(\.refId) == [peel])
    }

    /// a → b → c → d, and e → a.
    private func chain() throws -> (SQLiteAgentStore, [String]) {
        let s = try store()
        let ids = try ["a", "b", "c", "d", "e"].map { try s.add(type: "Concept", name: $0, createdBy: "agent") }
        try s.link(ids[0], "next", ids[1], createdBy: "agent")
        try s.link(ids[1], "next", ids[2], createdBy: "agent")
        try s.link(ids[2], "next", ids[3], createdBy: "agent")
        try s.link(ids[4], "parent", ids[0], createdBy: "agent")
        return (s, ids)
    }

    @Test func walkRespectsDepthDirectionTypesAndLimit() throws {
        let (s, ids) = try chain()
        let names = { (steps: [WalkStep]) in steps.map(\.record.name) }

        #expect(try names(s.walk(ids[0], direction: .outgoing, depth: 1)) == ["b"])
        #expect(try names(s.walk(ids[0], direction: .outgoing, depth: 2)) == ["b", "c"])
        // Deeper than maxWalkDepth is clamped.
        #expect(try names(s.walk(ids[0], direction: .outgoing, depth: 10)) == ["b", "c"])
        #expect(try names(s.walk(ids[0], direction: .incoming)) == ["e"])
        #expect(try Set(names(s.walk(ids[0]))) == ["b", "e"])
        #expect(try names(s.walk(ids[0], edgeTypes: ["parent"])) == ["e"])
        #expect(try s.walk(ids[0], direction: .outgoing, depth: 2).map(\.depth) == [1, 2])
        #expect(try s.walk(ids[1], depth: 2, limit: 1).count == 1)
        #expect(try s.walk(ids[1], limit: 0).isEmpty)
        #expect(try s.walk(ids[0], edgeTypes: []).isEmpty)
    }

    @Test func walkSkipsForgottenRecords() throws {
        let (s, ids) = try chain()
        try s.forget(ids[1])
        #expect(try s.walk(ids[0], direction: .outgoing, depth: 2).isEmpty)
    }

    @Test func ontologyCountsLiveTypes() throws {
        let (s, ids) = try chain()
        try s.add(type: "Memory", name: "m", createdBy: "agent")
        try s.forget(ids[4])
        #expect(try s.ontology() == [
            TypeCount(kind: .record, type: "Concept", count: 4),
            TypeCount(kind: .record, type: "Memory", count: 1),
            TypeCount(kind: .link, type: "next", count: 3),
            TypeCount(kind: .link, type: "parent", count: 1),
        ])
    }
}
