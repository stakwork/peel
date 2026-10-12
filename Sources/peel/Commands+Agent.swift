import AgentKit
import Foundation
import PeelAgent
import PeelCore
import Synchronization

/// `peel agent`: a streamed conversation with a model in the terminal, with
/// one built-in tool (`current_time`) and, given a profile's storage, the
/// Sphinx read tools over it (`SphinxTools`). With `--send`, a connected
/// engine and the send tool too, each send asked about in the terminal
/// (y, a for always, n), the "always" answers kept in the profile's
/// agent store as the app keeps them. The API key comes from the
/// environment only; it is never written anywhere or printed. Nothing a
/// tool reads is printed beyond the one-line summary of its result.
enum AgentCommand {
    /// What `--send` adds: the engine to send through, and the account's rules.
    struct Sending {
        let engine: Engine
        let rules: ApprovalRules

        /// The rules in `profile`'s agent store, as the app opens it.
        init(engine: Engine, profile: Profile) throws {
            self.engine = engine
            rules = ApprovalRules(store: try SQLiteAgentStore.open(for: profile, storage: engine.storage))
        }
    }

    static let keyVariable = "PEEL_AGENT_API_KEY"

    static let systemPrompt = """
        You are Peel's assistant, talking with the user in a terminal. Answer plainly and briefly. \
        Use a tool when it would give a better answer than guessing.
        """

    /// `sending` connects the account for `--send`; it is called once the
    /// arguments and the key have been checked, and disconnected after.
    static func run(
        _ arguments: Arguments, storage: Storage? = nil, sending connect: (() async throws -> Sending)? = nil
    ) async throws {
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

        let sending = try await connect?()
        let input = TerminalLines()
        let sphinx = (sending?.engine.storage ?? storage).map(SphinxTools.init(storage:))
        var tools = [Tool.currentTime] + (sphinx?.tools ?? [])
        var prompt = sphinx == nil ? systemPrompt : systemPrompt + " " + SphinxTools.systemPrompt
        if let sphinx, let sending {
            tools.append(sphinx.send(through: sending.engine))
            prompt += " " + SphinxTools.sendPrompt
        }
        var loop = AgentLoop(provider: provider, tools: ToolRegistry(tools), model: model, systemPrompt: prompt)
        loop.approver = sending.map { ApprovalGate(rules: $0.rules) { await ask($0, input: input) } }
        if let maxSteps { loop.maxSteps = maxSteps }
        do {
            try await converse(with: loop, input: input, describing: "\(providerName), \(model)")
        } catch {
            await sending?.engine.disconnect()
            throw error
        }
        await sending?.engine.disconnect()
    }

    /// Asks about one tool call in the terminal: what it will do, its exact
    /// content (control characters shown, not obeyed), y for once, a for
    /// always (when it costs nothing), n or Ctrl-C for no.
    private static func ask(_ request: ApprovalRequest, input: TerminalLines) async -> ApprovalDecision {
        let intent = request.intent
        print("\n[approval needed] \(visible(intent.action))")
        if let content = intent.content { print("  \"\(visible(content))\"") }
        for line in intent.lines { print("  \(visible(line))") }
        // Only an answer typed after the question counts.
        await input.discardPending()
        let always = intent.mayBeAlwaysAllowed ? ", a = always\(intent.target.map { " for \(visible($0.name))" } ?? "")" : ""
        while true {
            print("Allow? y = once\(always), n = no: ", terminator: "")
            fflush(stdout)
            guard let answer = await input.next() else { return .deny }
            switch answer.trimmingCharacters(in: .whitespaces).lowercased() {
            case "y", "yes": return .allowOnce
            case "a", "always": if !always.isEmpty { return .alwaysAllow }
            case "n", "no", "": return .deny
            default: break
            }
        }
    }

    /// `text` with its control characters written out, so nothing in it can
    /// move the cursor or hide what is shown.
    private static func visible(_ text: String) -> String {
        var shown = ""
        for scalar in text.unicodeScalars {
            if scalar.properties.generalCategory == .control, scalar != "\n" {
                shown += "\\u{\(String(scalar.value, radix: 16))}"
            } else {
                shown.unicodeScalars.append(scalar)
            }
        }
        return shown
    }

    /// Reads a line, runs a turn, prints it as it streams, until end of
    /// input. Ctrl-C stops the reply in progress; at the prompt it quits.
    private static func converse(with loop: AgentLoop, input: TerminalLines, describing label: String) async throws {
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
        while true {
            print("\n> ", terminator: "")
            fflush(stdout)
            guard let line = await input.next() else { break }
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

/// Standard input a line at a time, shared by the prompt and the approval
/// questions. A reader cancelled while it waits (Ctrl-C) gets nil, and the
/// line typed next goes to whoever asks next.
actor TerminalLines {
    private var buffered: [String] = []
    /// The one reader waiting, numbered so a late cancel ends only its own wait.
    private var waiter: (id: Int, continuation: CheckedContinuation<String?, Never>)?
    private var waits = 0
    private var ended = false
    private var reader: Task<Void, Never>?

    /// The next line; nil at the end of input or when cancelled.
    func next() async -> String? {
        if reader == nil {
            reader = Task.detached { [weak self] in
                do {
                    for try await line in FileHandle.standardInput.bytes.lines { await self?.deliver(line) }
                } catch {
                    print("\nstopped reading the terminal: \(PeelError.readable(error))")
                }
                await self?.deliver(nil)
            }
        }
        if !buffered.isEmpty { return buffered.removeFirst() }
        if ended { return nil }
        waits += 1
        let id = waits
        // One reader at a time; one left waiting would never be resumed.
        cancel(waiter?.id ?? 0)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { waiter = (id, $0) }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    private func deliver(_ line: String?) {
        if line == nil { ended = true }
        if let waiting = waiter {
            waiter = nil
            waiting.continuation.resume(returning: line)
        } else if let line {
            buffered.append(line)
        }
    }

    /// Drops lines typed before now, and what the terminal holds unread. A
    /// script's input (not a terminal) is kept: it was written to answer.
    func discardPending() {
        guard isatty(STDIN_FILENO) == 1 else { return }
        buffered.removeAll()
        tcflush(STDIN_FILENO, TCIFLUSH)
    }

    private func cancel(_ id: Int) {
        guard let waiting = waiter, waiting.id == id else { return }
        waiter = nil
        waiting.continuation.resume(returning: nil)
    }
}
