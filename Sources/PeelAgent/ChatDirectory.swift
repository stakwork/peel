import Foundation
import PeelCore

/// The person's chats (ready contacts and joined tribes, as the sidebar
/// lists them), found by the name the model gives, as the official Mac app
/// finds them (`AIAgentManager.resolveContactOrTribe`): the chat id, then
/// the exact name, then the name normalised (case, underscores, spaces),
/// then without spaces, then a part of it, then within a few typos. Two
/// chats equally close are ambiguous, never a guess.
struct ChatDirectory: Sendable {
    enum Match: Equatable {
        case found(Conversation)
        case ambiguous([Conversation])
        case none
    }

    let chats: [Conversation]

    func resolve(_ query: String, tribesOnly: Bool = false) -> Match {
        let chats = tribesOnly ? chats.filter(\.isTribe) : chats
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // No name is this long; it would only make the typo pass slow.
        guard !trimmed.isEmpty, trimmed.count <= 200 else { return .none }
        if let chat = chats.first(where: { $0.chat == trimmed }) { return .found(chat) }

        let normal = Self.normalised(trimmed)
        let squashed = Self.squashed(normal)
        let named = chats.map { (chat: $0, name: Self.normalised($0.name)) }
        let passes: [((chat: Conversation, name: String)) -> Bool] = [
            { $0.chat.alias == trimmed },
            { $0.name == normal },
            { !squashed.isEmpty && Self.squashed($0.name) == squashed },
            { $0.name.contains(normal) || (!squashed.isEmpty && Self.squashed($0.name).contains(squashed)) },
        ]
        for pass in passes {
            let matches = named.filter(pass).map(\.chat)
            if matches.count == 1 { return .found(matches[0]) }
            if matches.count > 1 { return .ambiguous(matches) }
        }

        // Within a few typos, the threshold growing with the name; the
        // closest wins only when clearly closer than the next.
        let threshold = max(1, normal.count / 4)
        let near = named.map { (chat: $0.chat, distance: Self.distance($0.name, normal)) }
            .filter { $0.distance <= threshold }
            .sorted { $0.distance < $1.distance }
        guard let closest = near.first else { return .none }
        if near.count == 1 || closest.distance + 2 <= near[1].distance { return .found(closest.chat) }
        return .ambiguous(near.map(\.chat))
    }

    /// Trimmed, underscores as spaces, runs of spaces as one, lowercased.
    static func normalised(_ name: String) -> String {
        name.replacingOccurrences(of: "_", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .lowercased()
    }

    /// Without spaces: "tomtest2" finds "Tom Test 2".
    static func squashed(_ name: String) -> String {
        name.replacingOccurrences(of: " ", with: "")
    }

    /// Levenshtein edit distance, by character.
    static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                current[j] = a[i - 1] == b[j - 1] ? previous[j - 1] : 1 + min(previous[j - 1], previous[j], current[j - 1])
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }
}
