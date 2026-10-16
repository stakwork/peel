#if os(macOS)
import AgentKit
import Foundation
import PeelUI
import Synchronization

/// Offscreen only: an agent chat with a scripted model, for the driver's
/// `agent` steps (`OffscreenDriver`). Its conversation is kept in memory
/// (never the profile's `agent.sqlite`), its key is a placeholder no
/// provider would take, and its model is `Model`, which answers from a
/// script on this Mac: nothing is ever sent to a provider.
@MainActor enum OffscreenAgent {
    /// How the next answers stream: so many words, one every `delay`, then
    /// `end` before the answer ends.
    struct Pace: Sendable {
        var words: Int
        var delay: Duration
        var end: Duration = .zero
    }

    nonisolated static let pace = Mutex(Pace(words: 40, delay: .zero))

    /// A new agent session on the script, in place of the account's.
    static func session() throws -> AgentSession {
        AgentSession(
            store: try SQLiteAgentStore.inMemory(device: "offscreen"), credentials: Credentials(),
            tools: ToolRegistry([.currentTime]), systemPrompt: "Offscreen script."
        ) { _ in Model() }
    }

    /// Only the placeholder, in memory.
    private final class Credentials: AgentCredentialStore {
        private let credential = Mutex<AgentCredential?>(
            AgentCredential(provider: .anthropic, model: "claude-sonnet-4-5", apiKey: "offscreen-script")
        )

        func read() throws -> AgentCredential? { credential.withLock { $0 } }
        func write(_ credential: AgentCredential) throws { self.credential.withLock { $0 = credential } }
        func delete() throws { credential.withLock { $0 = nil } }
    }

    /// Answers a message that mentions "tool" with a call to `current_time`
    /// first; anything else, and a tool's result, with prose, a word at a
    /// time at the pace set.
    struct Model: ModelProvider {
        func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
            let pace = OffscreenAgent.pace.withLock { $0 }
            let last = request.messages.last
            let afterTool = last?.content.contains { if case .toolResult = $0 { true } else { false } } ?? false
            let callsTool = !afterTool && last?.text.contains("tool") == true
            let turn = request.messages.count
            return AsyncThrowingStream { continuation in
                let task = Task {
                    do {
                        if callsTool {
                            continuation.yield(.toolCallCompleted(ToolCall(id: "call-\(turn)", name: "current_time", input: .object([:]))))
                            continuation.yield(.finished(.toolUse))
                        } else {
                            for word in OffscreenAgent.words(pace.words, from: turn) {
                                if pace.delay > .zero { try await Task.sleep(for: pace.delay) }
                                continuation.yield(.textDelta(word))
                            }
                            if pace.end > .zero { try await Task.sleep(for: pace.end) }
                            continuation.yield(.finished(.endTurn))
                        }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
    }

    nonisolated private static let vocabulary = """
        the chat you asked about moved on since this morning and most of it is about the trip next week \
        Kate wants to leave early on Friday while Sam would rather wait for the weekend so the tickets are \
        cheaper and nobody has booked anything yet there were also two links to places to stay and a long \
        thread about who brings the tent
        """.split(separator: " ").map(String.init)

    /// `count` words of prose, each with the space before it, a paragraph
    /// every 45; `seed` varies where it starts.
    nonisolated static func words(_ count: Int, from seed: Int) -> [String] {
        (0..<count).map { index in
            let word = vocabulary[(seed * 7 + index) % vocabulary.count]
            if index == 0 { return word.prefix(1).uppercased() + word.dropFirst() }
            return (index % 45 == 0 ? ".\n\n" : index % 12 == 0 ? ". " : " ") + word
        } + ["."]
    }
}
#endif
