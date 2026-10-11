import AgentKit
import Foundation
import PeelAgent
import PeelCore
import Synchronization

/// `peel agent`: a streamed conversation with a model in the terminal, with
/// one built-in tool (`current_time`) and, given a profile's storage, the
/// Sphinx read tools over it (`SphinxTools`). The API key comes from the
/// environment only; it is never written anywhere or printed. Nothing a
/// tool reads is printed beyond the one-line summary of its result.
enum AgentCommand {
    static let keyVariable = "PEEL_AGENT_API_KEY"

    static let systemPrompt = """
        You are Peel's assistant, talking with the user in a terminal. Answer plainly and briefly. \
        Use a tool when it would give a better answer than guessing.
        """

    static func run(_ arguments: Arguments, storage: Storage? = nil) async throws {
        var arguments = arguments
        let providerName = arguments.option("--provider") ?? "anthropic"
        let modelOption = arguments.option("--model")
        let baseURL = try arguments.option("--base-url").map { text in
            guard let url = URL(string: text) else { throw PeelError("cannot read base URL \(text)") }
            return url
        }
        let maxSteps = try arguments.option("--max-steps").map { text in
            guard let steps = Int(text), steps > 0 else { throw PeelError("--max-steps is a whole number above 0, not \(text)") }
            return steps
        }
        guard arguments.isEmpty else { throw PeelError("agent: unexpected \(arguments.rest().joined(separator: " "))") }
        guard let key = ProcessInfo.processInfo.environment[keyVariable], !key.isEmpty else {
            throw PeelError("set \(keyVariable) to the provider's API key")
        }

        let provider: any ModelProvider
        let model: String?
        switch providerName {
        case "anthropic":
            provider = AnthropicProvider(apiKey: key, baseURL: baseURL ?? AnthropicProvider.defaultBaseURL)
            model = modelOption ?? AnthropicProvider.defaultModel
        case "openai":
            provider = OpenAICompatibleProvider(apiKey: key, baseURL: baseURL ?? OpenAICompatibleProvider.openAI)
            model = modelOption
        case "openrouter":
            provider = OpenAICompatibleProvider.openRouter(apiKey: key, baseURL: baseURL ?? OpenAICompatibleProvider.openRouter)
            model = modelOption
        default:
            throw PeelError("--provider is anthropic, openai or openrouter, not \(providerName)")
        }
        guard let model else { throw PeelError("--provider \(providerName) needs --model <id>") }

        let sphinx = storage.map(SphinxTools.init(storage:))
        var loop = AgentLoop(
            provider: provider, tools: ToolRegistry([.currentTime] + (sphinx?.tools ?? [])), model: model,
            systemPrompt: sphinx == nil ? systemPrompt : systemPrompt + " " + SphinxTools.systemPrompt)
        if let maxSteps { loop.maxSteps = maxSteps }
        try await converse(with: loop, describing: "\(providerName), \(model)")
    }

    /// Reads a line, runs a turn, prints it as it streams, until end of
    /// input. Ctrl-C stops the reply in progress; at the prompt it quits.
    private static func converse(with loop: AgentLoop, describing label: String) async throws {
        // Busy from before a turn's task exists until it is over, so a
        // Ctrl-C at its very start stops it rather than quitting. A second
        // Ctrl-C in one turn quits, in case something ignores the first.
        let state = Mutex<(busy: Bool, stopping: Bool, task: Task<TurnResult, Never>?)>((false, false, nil))
        signal(SIGINT, SIG_IGN)
        let interrupts = DispatchSource.makeSignalSource(signal: SIGINT, queue: DispatchQueue(label: "peel.agent.sigint"))
        interrupts.setEventHandler {
            // Signals that arrive together are delivered once, with a count.
            for _ in 0..<max(Int(interrupts.data), 1) {
                let task = state.withLock { state -> Task<TurnResult, Never>?? in
                    guard state.busy, !state.stopping else { return .none }
                    state.stopping = true
                    return .some(state.task)
                }
                guard let task else { exit(130) }
                task?.cancel()
            }
        }
        interrupts.resume()
        defer { interrupts.cancel() }

        print("agent: \(label). Ctrl-C stops a reply (twice quits), Ctrl-D quits, /clear starts over.")
        var history: [ModelMessage] = []
        var lines = FileHandle.standardInput.bytes.lines.makeAsyncIterator()
        while true {
            print("\n> ", terminator: "")
            fflush(stdout)
            guard let line = try await lines.next() else { break }
            let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { continue }
            if text == "/clear" {
                history = []
                print("(conversation cleared)")
                continue
            }

            let earlier = history
            state.withLock { $0 = (busy: true, stopping: false, task: nil) }
            let task = Task { await loop.run(history: earlier, message: text, onEvent: show) }
            if state.withLock({ state in state.task = task; return state.stopping }) { task.cancel() }
            let turn = await task.value
            state.withLock { $0 = (busy: false, stopping: false, task: nil) }
            history += turn.messages
            print()
            if let summary = turn.summary { print("[\(summary)]") }
            print("[tokens: \(turn.usage.inputTokens) in, \(turn.usage.outputTokens) out]")
        }
        print()
    }

    @Sendable private static func show(_ event: LoopEvent) async {
        switch event {
        case .textDelta(let text):
            print(text, terminator: "")
            fflush(stdout)
        case .toolStarted(_, let name, let input):
            print("\n[\(name) \(input.jsonString)]")
        case .toolFinished(_, let name, let summary, let duration, let failed):
            let seconds = duration / .seconds(1)
            print("[\(name) \(failed ? "failed" : "done") in \(String(format: "%.2f", seconds)) s: \(summary)]")
        }
    }
}
