import Foundation
import Testing
@testable import AgentKit

/// The model clients against the real providers: the one proof of the wire
/// shapes the `Fixtures/` streams (written by hand from the docs) only
/// describe. Opt-in, never part of a plain `swift test`; see
/// docs/testing.md, "Live model checks":
///
///     PEEL_AGENT_LIVE=1 PEEL_AGENT_PROVIDER=anthropic PEEL_AGENT_API_KEY=… \
///       swift test --filter LiveProviderTests
///
/// `PEEL_AGENT_MODEL` picks a model (default: the provider's recommended
/// one). The bad-key check needs no key, only `PEEL_AGENT_LIVE=1`.
enum LiveModel {
    static let environment = ProcessInfo.processInfo.environment
    static let enabled = environment["PEEL_AGENT_LIVE"] == "1"

    /// The provider, model and key named by the environment, if live and complete.
    static let credential: AgentCredential? = {
        guard enabled, let name = environment["PEEL_AGENT_PROVIDER"], let provider = AgentProvider(rawValue: name),
              let key = environment["PEEL_AGENT_API_KEY"], !key.isEmpty else { return nil }
        let model = environment["PEEL_AGENT_MODEL"].flatMap { $0.isEmpty ? nil : $0 } ?? provider.recommendedModel
        return AgentCredential(provider: provider, model: model, apiKey: key)
    }()

    static var client: any ModelProvider {
        get throws {
            let credential = try #require(credential)
            return credential.provider.client(apiKey: credential.apiKey)
        }
    }
}

@Suite(.enabled(if: LiveModel.enabled, "live model checks run with PEEL_AGENT_LIVE=1"), .timeLimit(.minutes(2)))
struct LiveProviderTests {
    /// Each provider refuses a made-up key, and the client says so as
    /// `.invalidKey`, without the key in its words.
    @Test(arguments: AgentProvider.allCases)
    func aBadKeyIsInvalidKey(provider: AgentProvider) async throws {
        let tail = String(UUID().uuidString.prefix(8))
        let key = "sk-peel-not-a-real-key-\(tail)"
        let request = ModelRequest(model: provider.recommendedModel, system: "", messages: [.user("Hi")], maxTokens: 16)
        let (_, failure) = await collect(provider.client(apiKey: key).stream(request))
        guard case .invalidKey(let message)? = failure else {
            Issue.record("\(provider.name) answered a made-up key with \(String(describing: failure))")
            return
        }
        // Not the key, nor the part of it a provider may echo masked.
        for part in [tail, String(key.suffix(4)), "sk-peel"] { #expect(message?.contains(part) != true, "\(message ?? "")") }
    }

    /// A streamed reply arrives in pieces, with its usage, and ends as a
    /// finished turn.
    @Test(.enabled(if: LiveModel.credential != nil, "needs PEEL_AGENT_PROVIDER and PEEL_AGENT_API_KEY"))
    func aStreamedTextReply() async throws {
        let credential = try #require(LiveModel.credential)
        let request = ModelRequest(
            model: credential.model, system: "Reply with exactly what is asked, nothing else.",
            messages: [.user("Count from 1 to 30, each number on its own line.")],
            // Room for a reasoning model's thinking, which this cap includes.
            maxTokens: 4_000)
        let (events, failure) = await collect(try LiveModel.client.stream(request))
        #expect(failure == nil)
        let deltas = events.compactMap { if case .textDelta(let text) = $0 { text } else { nil } }
        let usage = events.compactMap { if case .usage(let usage) = $0 { usage } else { nil } }.last ?? Usage()
        #expect(events.last == .finished(.endTurn))
        #expect(deltas.count > 1, "the reply came in one piece: not streamed")
        let text = deltas.joined()
        #expect(text.contains("1") && text.contains("30"))
        #expect(usage.inputTokens > 0 && usage.outputTokens > 0)
    }

    /// One tool call round trip through the loop: the model calls the tool,
    /// its result goes back in the provider's own format, and the answer
    /// uses it.
    @Test(.enabled(if: LiveModel.credential != nil, "needs PEEL_AGENT_PROVIDER and PEEL_AGENT_API_KEY"))
    func aToolCallRoundTrip() async throws {
        let credential = try #require(LiveModel.credential)
        let word = "heron\(Int.random(in: 1000...9999))"
        let runs = Counter()
        let lookup = Tool(
            name: "secret_word", description: "Returns today's secret word. The only way to learn it.",
            inputSchema: ["type": "object", "properties": [:], "additionalProperties": false], effect: .read
        ) { _ in
            runs.increment()
            return .text(word)
        }
        let loop = AgentLoop(
            provider: try LiveModel.client, tools: ToolRegistry([lookup]), model: credential.model,
            systemPrompt: "Use the secret_word tool to answer; reply with the word alone.")
        let turn = await loop.run(history: [], message: "What is today's secret word?")

        #expect(turn.outcome == .finished(.endTurn), "\(turn.outcome)")
        #expect(runs.value >= 1)
        #expect(turn.toolsRun.first == "secret_word")
        #expect(turn.messages.last?.text.contains(word) == true, "\(turn.messages.last?.text ?? "")")
    }
}
