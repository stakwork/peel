import Foundation
@testable import PeelCore

/// Medians of repeated runs, merged into one JSON file of results.
enum Bench {
    static func measure(_ name: String, runs: Int = 15, _ body: () throws -> Void) rethrows {
        try body() // warm-up
        var times: [Duration] = []
        for _ in 0..<runs { times.append(try ContinuousClock().measure(body)) }
        record(name, times)
    }

    static func measureAsync(_ name: String, runs: Int = 15, _ body: () async throws -> Void) async throws {
        try await body()
        var times: [Duration] = []
        for _ in 0..<runs { times.append(try await ContinuousClock().measure(body)) }
        record(name, times)
    }

    private static func record(_ name: String, _ times: [Duration]) {
        let median = times.sorted()[times.count / 2]
        let ms = Double(median.components.seconds) * 1e3 + Double(median.components.attoseconds) / 1e15
        print(String(format: "BENCH %-40@ %10.3f ms", name as NSString, ms))
        let url = URL(fileURLWithPath: ProcessInfo.processInfo.environment["PEEL_BENCH_OUT"] ?? ".build/bench/latest.json")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var results = (try? JSONDecoder().decode([String: Double].self, from: Data(contentsOf: url))) ?? [:]
        results[name] = (ms * 1000).rounded() / 1000
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(results).write(to: url)
    }
}

/// A profile directory removed with the object.
final class BenchProfile {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("PeelBench-\(UUID().uuidString)", isDirectory: true)

    func storage() throws -> Storage { try Storage(directory: url) }

    deinit { try? FileManager.default.removeItem(at: url) }
}

/// A synthetic account: 10 tribes and 40 contacts, 100k messages. The first
/// tribe holds 40k, the others 4k each, each contact 600. Tribe messages
/// carry sender JSON; some are replies, thread messages, boosts, giphys,
/// links and images, so every join in the reads has rows to find.
enum Seed {
    static func key(_ n: Int) -> String { "02" + String(format: "%064x", n + 1) }
    static func uuid(_ n: Int) -> String { String(format: "%064x", n) }

    static let tribes = (0..<10).map { key(1_000 + $0) }
    static let people = (0..<40).map { key(2_000 + $0) }

    static func text(_ n: Int) -> String {
        switch n % 10 {
        case 0: "lorem ipsum **bold** and _soft_ https://example.com/page/\(n) dolor"
        case 1: "> quoted line\n\nreply with `code` and @alice"
        case 2: "- one\n- two\n- three \(n)"
        case 3: "giphy::" + Data(#"{"url":"https://media.giphy.com/media/x/giphy.gif","text":"hi","aspect_ratio":1.5}"#.utf8).base64EncodedString()
        default: "lorem ipsum dolor sit amet \(n), consectetur adipiscing elit"
        }
    }

    static func message(_ n: Int, chat: String, tribe: Bool) -> Message {
        let fromMe = n % 7 == 0
        let alias = fromMe ? "Me" : "Person \(n % 25)"
        let senderJSON = tribe
            ? #"{"pubkey":"\#(key(3_000 + n % 25))","alias":"\#(alias)","photo_url":"https://example.com/p/\#(n % 25).png","role":0}"#
            : nil
        var type = MessageType.text
        var body: String?
        var reply: String?
        var thread: String?
        if n % 50 == 49 { type = MessageType.boost; reply = uuid(n - 1) }
        if n % 13 == 0, n > 20 { reply = uuid(n - 10) }
        if tribe, n % 40 >= 30, n % 40 < 35 { thread = uuid(n - n % 40 + 29) }
        if n % 17 == 0 {
            type = MessageType.attachment
            body = #"{"content":"","mediaType":"image/png","mediaKey":"k","mediaToken":"t"}"#
        }
        return Message(
            id: nil, uuid: uuid(n), serverIndex: Int64(n), type: type, chat: chat, fromMe: fromMe,
            sender: senderJSON, body: body, content: type == MessageType.boost ? "" : text(n),
            msat: type == MessageType.boost ? 1_000 : nil, timestamp: 1_700_000_000_000 + Int64(n) * 60_000,
            tag: fromMe ? "tag\(n)" : nil, paymentHash: nil, status: fromMe ? "COMPLETE" : nil, replyUUID: reply,
            threadUUID: thread, amountMsat: nil
        )
    }

    static func chats() -> Storage.Commit {
        var commit = Storage.Commit(contacts: people.map { ($0, true) })
        commit.tribes = tribes.enumerated().map { index, pubkey in
            var tribe = Tribe(pubkey: pubkey, pricePerMessageMsat: 0)
            tribe.name = "Tribe \(index)"
            return tribe
        }
        return commit
    }

    /// Built once per process (it takes a while) and reused.
    nonisolated(unsafe) private static var shared: (BenchProfile, Storage)?

    static func large() throws -> Storage {
        if let shared { return shared.1 }
        let profile = BenchProfile()
        let storage = try profile.storage()
        _ = try storage.apply(chats())
        var n = 0
        func fill(_ chat: String, count: Int, tribe: Bool) throws {
            for start in stride(from: 0, to: count, by: 1_000) {
                let page = (start..<min(count, start + 1_000)).map {
                    (message(n + $0, chat: chat, tribe: tribe), tribe, String?.none)
                }
                _ = try storage.apply(Storage.Commit(messages: page))
            }
            n += count
        }
        try fill(tribes[0], count: 40_000, tribe: true)
        for tribe in tribes.dropFirst() { try fill(tribe, count: 4_000, tribe: true) }
        for person in people { try fill(person, count: 600, tribe: false) }
        // Read markers part-way, so unread counts have ranges to walk.
        var reads = Storage.Commit()
        for chat in tribes + people { reads.reads[chat] = Int64(n / 2) }
        _ = try storage.apply(reads)
        shared = (profile, storage)
        return storage
    }
}
