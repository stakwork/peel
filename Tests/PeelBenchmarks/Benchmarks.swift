import Foundation
import Testing
@testable import PeelCore

// Timings for the hot paths a large account exercises; how to run and
// compare them is in AGENTS.md ("PeelBenchmarks").

let benchEnabled = ProcessInfo.processInfo.environment["PEEL_BENCH"] == "1"

@Suite(.serialized, .enabled(if: benchEnabled, "benchmarks run with PEEL_BENCH=1"))
struct Benchmarks {
    // MARK: Message markup

    @Test func markupLeadingBlankLines() {
        let text = String(repeating: "\n", count: 32_000) + "a"
        Bench.measure("markup.blocks.leadingBlank32k", runs: 3) { _ = MessageMarkup.blocks(text) }
    }

    @Test func markupBlankQuoteLines() {
        let text = String(repeating: ">\n", count: 16_000) + "> a"
        Bench.measure("markup.blocks.blankQuote16k", runs: 3) { _ = MessageMarkup.blocks(text) }
    }

    @Test func markupMixed() {
        let texts = (0..<1_000).map(Seed.text)
        Bench.measure("markup.blocks+inlines.mixed1k") {
            for text in texts {
                for block in MessageMarkup.blocks(text) {
                    if case .paragraph(let line) = block { _ = MessageMarkup.inlines(line) }
                }
            }
        }
    }

    // MARK: Per-message fields (what ChatRow.rows reads for every row)

    @Test func rowFields() {
        let messages = (0..<10_000).map { Seed.message($0, chat: Seed.tribes[0], tribe: true) }
        Bench.measure("message.rowFields.10k") {
            for message in messages {
                _ = message.senderDetails
                _ = message.isBlank
                _ = message.countsAsUnread(after: 0)
                _ = message.shownText
                _ = message.giphy
                _ = message.attachmentPriceMsat
                _ = MessageLink.card(in: message.shownText)
            }
        }
    }

    @Test func senderInfo() {
        let messages = (0..<10_000).map { Seed.message($0, chat: Seed.tribes[0], tribe: true) }
        Bench.measure("message.senderInfo.10k") {
            for message in messages { _ = message.senderInfo }
        }
    }

    @Test func preview() {
        let messages = (0..<10_000).map { Seed.message($0, chat: Seed.tribes[0], tribe: true) }
        Bench.measure("message.preview.10k") {
            for message in messages { _ = message.preview }
        }
    }

    // MARK: Writes

    @Test func historyPage() throws {
        let profile = BenchProfile()
        let storage = try profile.storage()
        _ = try storage.apply(Seed.chats())
        // Built ahead, so only the commit is timed; each lands on the pages before it.
        var pages = (0..<16).map { page in
            (page * 100..<page * 100 + 100).map { (Seed.message($0, chat: Seed.tribes[1], tribe: true), true, String?.none) }
        }
        try Bench.measure("storage.apply.historyPage100") {
            _ = try storage.apply(Storage.Commit(messages: pages.removeFirst()))
        }
    }

    // MARK: Reads on a large account (each re-runs on every write)

    @Test func largeAccountReads() async throws {
        let storage = try Seed.large()
        let big = Seed.tribes[0], dmChat = Seed.people[0]

        try await Bench.measureAsync("read.timeline.tribe40k") { _ = try await first(storage.timeline(in: big)) }
        try await Bench.measureAsync("read.timeline.dm") { _ = try await first(storage.timeline(in: dmChat)) }
        try await Bench.measureAsync("read.timeline.tribe.jump9k", runs: 5) {
            _ = try await first(storage.timeline(in: big, limit: 9_000))
        }
        try await Bench.measureAsync("read.conversations") { _ = try await first(storage.conversations()) }
        try await Bench.measureAsync("read.readStates") { _ = try await first(storage.readStates()) }
        try await Bench.measureAsync("read.threads") { _ = try await first(storage.threads()) }

        // Rows into `Message` alone, without the timeline's joins.
        try Bench.measure("read.messageRows.9k", runs: 5) {
            _ = try storage.pool.read { db in
                try Message.fetchAll(db, sql: "SELECT * FROM message WHERE chat = ? LIMIT 9000", arguments: [big])
            }
        }

        let oldest = try #require(try storage.message(uuid: Seed.uuid(0), in: big))
        try Bench.measure("read.timelineLimit.oldest") { _ = try storage.timelineLimit(reaching: oldest) }
        try await Bench.measureAsync("read.search.allChats") {
            _ = try await storage.searchMessages(MessageQuery("lorem"), in: nil, limit: 200)
        }
        try Bench.measure("read.waitingMsat") { _ = try storage.waitingMsat() }
        try Bench.measure("read.paymentItems200", runs: 5) {
            _ = try storage.pool.read { db in try Storage.paymentItems(limit: 200, db) }
        }
        try await Bench.measureAsync("read.recentCallMessages") { _ = try await first(storage.recentCallMessages()) }

        // What one write to `message` costs the always-on observations, a tribe open.
        try await Bench.measureAsync("perWrite.alwaysOnObservations", runs: 5) {
            _ = try await first(storage.conversations())
            _ = try await first(storage.readStates())
            _ = try await first(storage.threads())
            _ = try await first(storage.waitingUpdates())
            _ = try await first(storage.recentCallMessages())
            _ = try await first(storage.timeline(in: big))
            _ = try await first(storage.pinnedMessage(in: big))
        }
        try Bench.measure("write.rescanMentions", runs: 3) { try storage.rescanMentions(sent: "Me", echoed: [:]) }
        try Bench.measure("read.echoedOwnAliases", runs: 5) { _ = try storage.echoedOwnAliases() }
        try Bench.measure("read.tribeSenders.tribe40k", runs: 5) { _ = try storage.tribeSenders(big) }
    }

    /// A jump to an old message (a search match, a notification, a quote):
    /// everything after it, as the timeline grows today, or a window from
    /// just before it. Each re-runs on every write while the chat is open.
    @Test func timelineJump() async throws {
        let storage = try Seed.large()
        let big = Seed.tribes[0]
        for (label, n) in [("9k", 31_000), ("oldest", 0)] {
            let target = try #require(try storage.message(uuid: Seed.uuid(n), in: big))
            let limit = try storage.timelineLimit(reaching: target)
            do {
                try await Bench.measureAsync("jump.\(label).everythingAfter", runs: 5) {
                    _ = try await first(storage.timeline(in: big, limit: limit))
                }
            } catch {
                print("BENCH jump.\(label).everythingAfter failed: \(error)")
            }
            let start = try #require(try storage.timelineStart(reaching: target))
            try await Bench.measureAsync("jump.\(label).window250") {
                _ = try await first(storage.timeline(in: big, from: start, limit: 250))
            }
            // The window is the same rows as that stretch of the whole timeline.
            let window = try #require(try await first(storage.timeline(in: big, from: start, limit: 250)))
            #expect(window.messages.contains { $0.uuid == target.uuid })
            if let whole = try? await first(storage.timeline(in: big, limit: limit)) {
                let stretch = whole.messages.drop { ($0.timestamp!, $0.id!) < (start.timestamp, start.id) }.prefix(250)
                #expect(window.messages == Array(stretch))
                #expect(window.threads == whole.threads.filter { uuid, _ in
                    window.messages.contains { $0.threadUUID == uuid }
                })
            }
        }
    }

    @Test func conversationsAfterTrailingJoins() async throws {
        let profile = BenchProfile()
        let storage = try profile.storage()
        _ = try storage.apply(Seed.chats())
        // A busy tribe whose newest 5k rows are joins: none can be its preview.
        for start in stride(from: 0, to: 6_000, by: 1_000) {
            let page = (start..<start + 1_000).map { n in
                var message = Seed.message(n, chat: Seed.tribes[0], tribe: true)
                if n >= 1_000 { message.type = MessageType.groupJoin }
                return (message, true, String?.none)
            }
            _ = try storage.apply(Storage.Commit(messages: page))
        }
        try await Bench.measureAsync("read.conversations.trailingJoins5k") { _ = try await first(storage.conversations()) }
    }

    // MARK: Core state

    @Test func stateEncode() {
        var state: [String: Data] = [:]
        for n in 0..<1_000 {
            state["c/\(Seed.key(n))"] = Data([0]) + Data(repeating: 7, count: 82)
        }
        Bench.measure("state.encode.1kContacts.x100") {
            for _ in 0..<100 { _ = StateCodec.encode(state) }
        }
    }
}

func first<S: AsyncSequence>(_ sequence: S) async throws -> S.Element? {
    var iterator = sequence.makeAsyncIterator()
    return try await iterator.next()
}
