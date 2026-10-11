import Foundation
import GRDB
import Testing
@testable import PeelCore

private let person = keyG
private let publicTribe = key2G
private let privateTribe = key3G
/// Not a host: a registry read fails before any request is made.
private let unreadableHost = "no host"

private func date(_ text: String) -> Date { try! Date(text, strategy: .iso8601) }

/// What the database makes of a body's `metadata` (`message.senderTZ`, v14).
private func storedTZ(_ body: String) throws -> String? {
    let queue = try DatabaseQueue()
    try Storage.migrator.migrate(queue)
    return try queue.write { db in
        try db.execute(sql: "INSERT INTO message (uuid, type, chat, fromMe, body) VALUES ('a', 0, '02aa', 0, ?)", arguments: [body])
        return try String.fetchOne(db, sql: "SELECT senderTZ FROM message")
    }
}

/// A body carrying `tz` as the official apps send it.
private func body(tz: String) -> String { #"{"content":"hi","metadata":"{\"tz\":\"\#(tz)\"}"}"# }

/// The offsets on the wire, both ways.
struct TimeZoneOffsetTests {
    @Test(arguments: [
        ("Europe/London", "2026-07-01T12:00:00Z", "GMT+1"),
        ("Europe/London", "2026-01-01T12:00:00Z", "GMT+0"),
        ("Asia/Kolkata", "2026-07-01T12:00:00Z", "GMT+5:30"),
        ("America/New_York", "2026-01-01T12:00:00Z", "GMT-5"),
        ("America/St_Johns", "2026-01-01T12:00:00Z", "GMT-3:30"),
        ("Asia/Kathmandu", "2026-01-01T12:00:00Z", "GMT+5:45"),
        ("UTC", "2026-01-01T12:00:00Z", "GMT+0"),
    ])
    func formatsAsTheOfficialAppsDoWithSummerTime(zone: String, at: String, expected: String) throws {
        #expect(TimeZoneOffset.format(try #require(TimeZone(identifier: zone)), at: date(at)) == expected)
    }

    @Test(arguments: [
        ("GMT+1", 3600), ("GMT-5", -18_000), ("GMT+5:30", 19_800), ("GMT+05:30", 19_800), ("GMT-3:30", -12_600),
        ("GMT+0", 0), ("GMT", 0), ("UTC", 0), ("UTC+2", 7200), ("GMT+14", 50_400), ("GMT-12", -43_200),
    ])
    func readsFixedOffsets(text: String, seconds: Int) throws {
        #expect(try #require(TimeZoneOffset.zone(text)).secondsFromGMT() == seconds)
    }

    @Test func readsKnownZoneNames() throws {
        let london = try #require(TimeZoneOffset.zone("Europe/London"))
        #expect(london.identifier == "Europe/London")
        #expect(london.secondsFromGMT(for: date("2026-07-01T12:00:00Z")) == 3600)
    }

    @Test func storesTheTZFromAMessagesMetadataString() throws {
        #expect(try storedTZ(#"{"content":"hi","metadata":"{\"tz\":\"GMT+1\"}"}"#) == "GMT+1")
        #expect(try storedTZ(#"{"metadata":"{\"tz\":\"Europe/London\",\"x\":1}"}"#) == "Europe/London")
    }

    /// A malformed `metadata` is ignored and never costs the message its other fields.
    @Test(arguments: [
        #"{"content":"hi"} metadata"#,
        #"{"content":"hi","metadata":{"tz":"GMT+1"}}"#,
        #"{"content":"hi","metadata":"not json"}"#,
        #"{"content":"hi","metadata":"[\"GMT+1\"]"}"#,
        #"{"content":"hi","metadata":"{\"tz\":1}"}"#,
        #"{"content":"hi","metadata":"{\"tz\":\"\"}"}"#,
        #"{"content":"hi","metadata":5}"#,
        #"{"content":"hi","metadata":null}"#,
        #"{"content":"hi","metadata":"{\"tz\":\"\#(String(repeating: "x", count: 65))\"}"}"#,
    ])
    func ignoresMalformedMetadata(body: String) throws {
        #expect(try storedTZ(body) == nil)
        if body.hasSuffix("}") { #expect(BodyFields.decode(body)?.content == "hi") }
    }

    @Test func setsAndRemovesTheMetadataString() throws {
        let body = #"{"content":"a/b"}"#
        let shared = try TimeZoneOffset.setting("GMT+5:30", in: body)
        #expect(try storedTZ(shared) == "GMT+5:30")
        #expect(try JSONDecoder().decode([String: String].self, from: Data(shared.utf8))["metadata"] == #"{"tz":"GMT+5:30"}"#)
        #expect(BodyFields.decode(shared)?.content == "a/b")
        let removed = try TimeZoneOffset.setting(nil, in: shared)
        #expect(!removed.contains("metadata"))
        #expect(BodyFields.decode(removed)?.content == "a/b")
        // Untouched when there is nothing to add or take out.
        #expect(try TimeZoneOffset.setting(nil, in: body) == body)
    }
}

/// The per-chat switch, what `deliver` sends, and someone else's local time.
struct TimeZoneSharingTests {
    let profile = TempProfile()

    /// An engine with a person, a public and a private tribe in the core's state.
    private func engine() throws -> (Engine, Storage) {
        let storage = try profile.storage()
        // Neither registry can be reached: nothing below may need it. Both
        // are listed on the account's own tribes host.
        try storage.set(unreadableHost, for: .tribeHost)
        try storage.save([
            Tribe(pubkey: publicTribe, host: unreadableHost),
            Tribe(pubkey: privateTribe, host: unreadableHost, isPrivate: true),
        ])
        let state = coreContact(person, contactKey: key3G)
            .merging(coreContact(publicTribe, contactKey: nil)) { $1 }
            .merging(coreContact(privateTribe, contactKey: nil)) { $1 }
        _ = try storage.apply(Storage.Commit(state: state, contacts: [(person, true)]))
        return (try testEngine(storage), storage)
    }

    /// The offset in what `deliver` would hand the core for a text to `chat`.
    /// `offsetShared` is synchronous: deciding never waits on the network.
    private func sent(to chat: String, _ engine: Engine, body: String = #"{"content":"hi"}"#) async throws -> String? {
        let body = try TimeZoneOffset.setting(try await engine.offsetShared(in: chat, type: MessageType.text), in: body)
        #expect(BodyFields.decode(body)?.content == "hi")
        return try storedTZ(body)
    }

    /// The private tribe's registry record, as `refreshTribes` would read it.
    private func record(isPrivate: Bool) throws -> TribeInfo {
        try JSONDecoder().decode(TribeInfo.self, from: Data(#"{"pubkey":"\#(privateTribe)","name":"T","private":\#(isPrivate)}"#.utf8))
    }

    /// On by default, as in the official apps: a chat with no row shares in
    /// a direct message and in a tribe stored as private, by the stored
    /// record alone; a public tribe never.
    @Test func onByDefaultWithNoRow() async throws {
        let (engine, storage) = try engine()
        try await engine.setTimeZone("Asia/Kolkata")
        for chat in [person, publicTribe, privateTribe] {
            #expect(try await engine.timeZoneSharing(in: chat))
            #expect(try storage.chatTimeZone(chat) == nil)
        }
        #expect(try await sent(to: person, engine) == "GMT+5:30")
        #expect(try await engine.offsetShared(in: person) == "GMT+5:30")
        #expect(try await sent(to: publicTribe, engine) == nil)
        #expect(try await engine.offsetShared(in: publicTribe) == nil)
        // The stored record decides; its registry is never asked first.
        #expect(try await engine.offsetShared(in: privateTribe) == "GMT+5:30")
        #expect(try await sent(to: privateTribe, engine) == "GMT+5:30")
    }

    /// After a send to a private tribe its record is queued for the
    /// background refresh only once the last one read is older than
    /// `tribeRecheck`.
    @Test func aStalePrivateRecordIsRecheckedInTheBackground() async throws {
        let (engine, _) = try engine()
        let start = ContinuousClock.now
        await engine.saveRecords([try record(isPrivate: true)], asked: start)
        #expect(await !engine.recheckIfStale(privateTribe, now: start + .seconds(60)))
        #expect(await engine.recheckIfStale(privateTribe, now: start + Engine.tribeRecheck + .seconds(1)))
    }

    /// A record read since that says public stops the offset with the next message.
    @Test func aTribeMadePublicStopsGettingItOnceRead() async throws {
        let (engine, _) = try engine()
        await engine.saveRecords([try record(isPrivate: false)], asked: .now)
        #expect(await engine.knownTribe(privateTribe)?.isPrivate == false)
        #expect(try await sent(to: privateTribe, engine) == nil)
    }

    /// Only the account's own tribes host may call a tribe private (audit
    /// C, finding 4): the same record from any other host leaves the tribe
    /// public, and the time zone unsent.
    @Test func onlyTheOwnTribesHostMakesATribePrivate() async throws {
        let (engine, storage) = try engine()
        try await engine.setTimeZone("Asia/Kolkata")
        await engine.saveRecords([try record(isPrivate: true)], asked: .now)
        #expect(try await sent(to: privateTribe, engine) == "GMT+5:30")
        try storage.set("tribes.example.com", for: .tribeHost)
        await engine.saveRecords([try record(isPrivate: true)], asked: .now)
        #expect(await engine.knownTribe(privateTribe)?.isPrivate == false)
        #expect(try await sent(to: privateTribe, engine) == nil)
    }

    /// Turning it off writes the row the preferences file would hold, and
    /// stops the offset, a retry's included; turning it on again sends.
    @Test func turningItOffWritesARowAndStopsIt() async throws {
        let (engine, storage) = try engine()
        try await engine.setTimeZone("Asia/Kolkata")
        let before = Int64(Date.now.timeIntervalSince1970)
        try await engine.setTimeZoneSharing(false, in: person)
        try await engine.setTimeZoneSharing(false, in: privateTribe)
        for chat in [person, privateTribe] {
            let row = try #require(try storage.chatTimeZone(chat))
            #expect(!row.enabled && row.identifier == nil)
            #expect(row.updatedAt >= before && row.updatedAt <= Int64(Date.now.timeIntervalSince1970))
            #expect(try await !engine.timeZoneSharing(in: chat))
            #expect(try await engine.sharedOffset(in: chat, type: MessageType.text) == nil)
            #expect(try await engine.offsetShared(in: chat) == nil)
        }
        // A retry of a message sent while it was on follows the switch as it is now.
        #expect(try await sent(to: person, engine, body: body(tz: "GMT+5:30")) == nil)
        try await engine.setTimeZoneSharing(true, in: person)
        try await engine.setTimeZoneSharing(true, in: privateTribe)
        for chat in [person, privateTribe] {
            #expect(try storage.chatTimeZone(chat)?.enabled == true)
        }
        #expect(try await sent(to: person, engine) == "GMT+5:30")
        #expect(try await engine.offsetShared(in: privateTribe) == "GMT+5:30")
    }

    /// No switch in a public tribe, and a row that says on (from a tribe
    /// made public since, or another device) never makes Peel send; nor to
    /// a key the core does not hold as a person.
    @Test func neverInAPublicTribe() async throws {
        let (engine, storage) = try engine()
        let stranger = strangerKey
        #expect(try await sent(to: stranger, engine) == nil)
        await #expect(throws: Engine.Failure.publicTribeTimeZone) { try await engine.setTimeZoneSharing(true, in: publicTribe) }
        await #expect(throws: Engine.Failure.notAChat) { try await engine.setTimeZoneSharing(true, in: stranger) }
        try await storage.pool.write { db in
            for chat in [publicTribe, stranger] {
                try ChatTimeZone(chat: chat, enabled: true, identifier: nil, updatedAt: 1).insert(db)
            }
        }
        #expect(try await engine.timeZoneSharing(in: publicTribe))
        #expect(try await sent(to: publicTribe, engine) == nil)
        #expect(try await engine.offsetShared(in: publicTribe) == nil)
        #expect(try await sent(to: stranger, engine) == nil)
        // Turning it off always works.
        try await engine.setTimeZoneSharing(false, in: publicTribe)
        #expect(try await !engine.timeZoneSharing(in: publicTribe))
    }

    @Test func onlyTextAttachmentsAndPaymentsCarryIt() async throws {
        let (engine, _) = try engine()
        for type in [MessageType.text, MessageType.attachment, MessageType.directPayment] {
            #expect(try await engine.sharedOffset(in: person, type: type) != nil)
        }
        for type in [MessageType.boost, MessageType.delete, MessageType.groupJoin, MessageType.invoice] {
            #expect(try await engine.sharedOffset(in: person, type: type) == nil)
        }
    }

    /// A zone set for one chat on another device wins over the account's.
    @Test func aChatsOwnZoneWins() async throws {
        let (engine, storage) = try engine()
        try await engine.setTimeZone("Europe/London")
        try await storage.pool.write { db in
            try ChatTimeZone(chat: person, enabled: true, identifier: "Asia/Bangkok", updatedAt: 1).insert(db)
        }
        #expect(try await engine.sharedOffset(in: person, type: MessageType.text) == "GMT+7")
        try await engine.setTimeZoneSharing(false, in: person)
        #expect(try storage.chatTimeZone(person)?.identifier == "Asia/Bangkok")
        await #expect(throws: Engine.Failure.unknownTimeZone("BST")) { try await engine.setTimeZone("BST") }
    }

    @Test func theirLocalTimeIsTheNewestReadableOffsetWithin90Days() async throws {
        let (engine, storage) = try engine()
        try await engine.setTimeZone("UTC")
        let now = date("2026-10-08T12:00:00Z")
        let day: Int64 = 24 * 3600 * 1000
        func message(_ n: Int, chat: String, alias: String? = nil, tz: String, daysAgo: Int64) -> Message {
            .fixture(
                uuid: uuid(n), chat: chat, sender: alias.map { sender(chat, alias: $0) }, body: body(tz: tz),
                timestamp: now.millisecondsSince1970 - daysAgo * day
            )
        }
        _ = try storage.apply(Storage.Commit(messages: [
            message(1, chat: person, tz: "GMT-5", daysAgo: 100),
            message(2, chat: person, tz: "GMT+1", daysAgo: 10),
            message(3, chat: person, tz: "EST", daysAgo: 1),
            message(4, chat: privateTribe, alias: "ann", tz: "GMT+5:30", daysAgo: 2),
            message(5, chat: privateTribe, alias: "bob", tz: "GMT-8", daysAgo: 95),
        ].map { ($0, false, nil) }))

        let theirs = try #require(try await engine.localTime(of: person, at: now))
        #expect(theirs.sent == "GMT+1")
        #expect(theirs.difference == 3600)
        #expect(theirs.seen == Date(millisecondsSince1970: now.millisecondsSince1970 - 10 * day))
        #expect(try await engine.localTime(of: privateTribe, member: "ann", at: now)?.difference == 19_800)
        #expect(try await engine.localTime(of: privateTribe, member: "bob", at: now) == nil)
        // A tribe has no local time of its own, only its members.
        await #expect(throws: Engine.Failure.memberNeeded) { try await engine.localTime(of: privateTribe, at: now) }
    }

    /// A run header's fallback: per sender, the newest offset at or before
    /// a moment and within 90 days of it, for a whole page in one query.
    @Test func senderZonesAtAMoment() throws {
        let (_, storage) = try engine()
        let now = date("2026-10-08T12:00:00Z").millisecondsSince1970
        let day: Int64 = 24 * 3600 * 1000
        func message(_ n: Int, chat: String, alias: String? = nil, tz: String, at: Int64) -> Message {
            .fixture(uuid: uuid(n), chat: chat, sender: alias.map { sender(chat, alias: $0) }, body: body(tz: tz), timestamp: at)
        }
        _ = try storage.apply(Storage.Commit(messages: [
            message(1, chat: privateTribe, alias: "ann", tz: "GMT+5:30", at: now - 5 * day),
            message(2, chat: privateTribe, alias: "ann", tz: "GMT+1", at: now + day),
            message(3, chat: privateTribe, alias: "bob", tz: "GMT-8", at: now - 95 * day),
            message(4, chat: person, tz: "GMT-5", at: now - day),
            // Unreadable, so the one before it counts.
            message(5, chat: person, tz: "EST", at: now - day / 2),
        ].map { ($0, false, nil) }))
        let tribe = try storage.senderTimeZones(
            in: privateTribe, inTribe: true, wanted: [("ann", now), ("bob", now), ("cat", now), ("ann", now + 2 * day)]
        )
        #expect(tribe.mapValues { $0.secondsFromGMT() } == [0: 19_800, 3: 3600])
        let direct = try storage.senderTimeZones(in: person, inTribe: false, wanted: [(nil, now), (nil, now - 2 * day)])
        #expect(direct.mapValues { $0.secondsFromGMT() } == [0: -18_000])
        #expect(try storage.senderTimeZones(in: person, inTribe: false, wanted: []).isEmpty)
    }

    /// The column follows the stored body, so a delete clears it.
    @Test func storedWithTheMessageAndClearedByADelete() throws {
        let storage = try profile.storage()
        let row = Message.fixture(uuid: uuid(1), chat: person, body: body(tz: "GMT+1"))
        _ = try storage.apply(Storage.Commit(messages: [(row, false, nil)]))
        #expect(try storage.message(uuid: uuid(1), in: person)?.senderTimeZone?.secondsFromGMT() == 3600)
        let delete = Message.fixture(
            uuid: uuid(2), type: MessageType.delete, chat: person, body: #"{"replyUuid":"\#(uuid(1))"}"#,
            content: "", replyUUID: uuid(1)
        )
        _ = try storage.apply(Storage.Commit(messages: [(delete, false, nil)]))
        let deleted = try #require(try storage.message(uuid: uuid(1), in: person))
        #expect(deleted.deleted)
        #expect(deleted.senderTZ == nil)
    }
}
