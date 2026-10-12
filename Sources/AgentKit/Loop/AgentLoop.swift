import Foundation

/// One turn of a conversation with tools: sends the context, streams the
/// reply, runs the tools it asks for in order (reads next to each other side
/// by side), sends their results back, and repeats until the model is done
/// or `maxSteps` model calls have been made. A model call that fails before
/// any of it is shown is made again under `retry`.
///
/// Stop is cancelling the task that awaits `run`. The turn then returns at
/// once with messages that are whole: the reply's text so far (no tool call
/// without its result), and a result for every tool call, "not run" for
/// the ones it did not get to.
///
/// Every turn's messages either end on the model's words or add nothing, so
/// the next turn never opens on tool results whose reasoning was dropped.
public struct AgentLoop: Sendable {
    public var provider: any ModelProvider
    public var tools: ToolRegistry
    public var model: String
    public var systemPrompt: String
    /// The most a single reply may be.
    public var maxTokens = 16_000
    /// The most model calls in one turn.
    public var maxSteps = 10
    /// Estimated tokens of earlier conversation sent with a turn (see `ContextWindow`).
    public var historyBudget = 60_000
    /// The most characters of a tool's result the model is sent.
    public var maxToolResultCharacters = 50_000
    /// Asked before every call of a tool that acts (`Tool.Effect.send`);
    /// with none, such calls are refused.
    public var approver: (any ToolApprover)?
    /// When a failed model call is made again on its own.
    public var retry = RetryPolicy()
    /// The most `.read` tools of one step running at once.
    public var concurrentReads = 4
    /// Waits before a retry; throws when the turn is stopped (tests replace it).
    var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }

    public init(provider: any ModelProvider, tools: ToolRegistry, model: String, systemPrompt: String) {
        self.provider = provider
        self.tools = tools
        self.model = model
        self.systemPrompt = systemPrompt
    }

    /// Runs one turn: `message` after `history`. `onEvent` is awaited for each
    /// event, in order. The result's `messages` are the turn's, to append to
    /// the history: the person's message first, or none at all when no reply
    /// came back (a failure, a refusal, a stop before any text), so that
    /// asking again does not send the question twice.
    public func run(
        history: [ModelMessage], message: String, onEvent: @Sendable (LoopEvent) async -> Void = { _ in }
    ) async -> TurnResult {
        var turn = await steps(history: history, message: message, onEvent: onEvent)
        turn.close()
        return turn
    }

    private func steps(
        history: [ModelMessage], message: String, onEvent: @Sendable (LoopEvent) async -> Void
    ) async -> TurnResult {
        var turn = TurnResult(messages: [.user(message)])
        // Signed reasoning goes back only within its own turn; the window
        // moving on would otherwise invalidate it.
        let earlier = ContextWindow.recent(history.map(\.withoutProviderBlocks), budget: historyBudget)

        let steps = max(maxSteps, 1)
        for step in 1...steps {
            let request = ModelRequest(
                model: model, system: systemPrompt, messages: earlier + turn.messages, tools: tools.definitions,
                maxTokens: maxTokens)
            let (reply, usage, finish, failure) = await modelCall(request, onEvent: onEvent)
            if let failure {
                // Keep the text that arrived; calls without results would
                // make the history unsendable.
                turn.usage += usage
                let partial = ModelMessage(role: .assistant, content: reply.text.isEmpty ? [] : [.text(reply.text)])
                if !partial.content.isEmpty { turn.messages.append(partial) }
                turn.outcome = failure == .cancelled || Task.isCancelled ? .stopped : .failed(failure)
                return turn
            }
            turn.usage += usage
            let calls = reply.toolCalls
            if finish == .refusal {
                // A declined reply's partial output is not an answer: it stays
                // on screen but out of the history, its calls unrun.
                turn.toolsNotRun += calls.map(\.name)
                turn.outcome = .finished(finish)
                break
            }
            if !reply.content.isEmpty { turn.messages.append(reply) }

            if calls.isEmpty {
                turn.outcome = .finished(finish)
                break
            }
            if finish == .maxTokens {
                turn.skip(calls, because: "the reply was cut off")
                turn.outcome = .finished(finish)
                break
            }
            if step == steps {
                turn.skip(calls, because: "the turn reached its limit of \(steps) steps")
                turn.outcome = .stepLimit
                break
            }

            let results = await runTools(calls, turn: &turn, onEvent: onEvent)
            turn.messages.append(ModelMessage(role: .user, content: results))
            if Task.isCancelled {
                turn.outcome = .stopped
                break
            }
        }
        return turn
    }

    /// One model call: the reply, its usage and how it finished, or the
    /// failure that ended it with what arrived before. A retryable failure
    /// before any text was shown is tried again under `retry`, after
    /// telling `onEvent` how long it waits; Stop ends the wait at once.
    private func modelCall(
        _ request: ModelRequest, onEvent: @Sendable (LoopEvent) async -> Void
    ) async -> (ModelMessage, Usage, FinishReason, ModelError?) {
        var spent = Usage()
        var retries = 0
        let began = ContinuousClock.now
        while true {
            var reply = ModelMessage(role: .assistant, content: [])
            var usage = Usage()
            var finish = FinishReason.endTurn
            do {
                for try await event in provider.stream(request) {
                    switch event {
                    case .textDelta(let text):
                        reply.appendText(text)
                        await onEvent(.textDelta(text))
                    case .toolCallCompleted(let call):
                        reply.content.append(.toolUse(call))
                    case .providerBlock(let name, let value):
                        reply.content.append(.provider(name: name, value))
                    case .usage(let latest):
                        usage = latest
                    case .finished(let reason):
                        finish = reason
                    }
                }
                try Task.checkCancellation()
                spent += usage
                return (reply, spent, finish, nil)
            } catch {
                spent += usage
                let error = ModelError(error)
                // Words already shown would be shown twice. Tool calls in
                // the reply were neither shown nor run, so they go with it.
                retries += 1
                guard reply.text.isEmpty, !Task.isCancelled,
                      let delay = retry.delay(after: error, retry: retries, elapsed: began.duration(to: .now),
                                              jitter: .random(in: 0.5...1))
                else { return (reply, spent, finish, error) }
                await onEvent(.retrying(after: delay, error))
                do {
                    try await sleep(delay)
                } catch {
                    return (reply, spent, finish, .cancelled)
                }
                // Going again now.
                await onEvent(.retrying(after: .zero, error))
            }
        }
    }

    /// Runs a step's tool calls in order and returns their results in that
    /// order. Reads next to each other run side by side, `concurrentReads`
    /// at a time, each announced as it starts. Any other call waits for the
    /// reads before it and runs alone, its approval included: nothing else
    /// runs while a card waits, and a read after a send sees what it did. A
    /// call that fails does not stop the others. Stop does: a call not
    /// started is answered "not run".
    private func runTools(
        _ calls: [ToolCall], turn: inout TurnResult, onEvent: @Sendable (LoopEvent) async -> Void
    ) async -> [ContentBlock] {
        // Each call's tool looked up once; nil for one that cannot run.
        let resolved = calls.map { $0.malformedInput == nil ? tools[$0.name] : nil }
        // A call with no tool to run (unknown, malformed) only answers: it
        // goes with the reads rather than splitting them.
        let isRead = resolved.map { ($0?.effect ?? .read) == .read }
        var outputs = [(output: String, failed: Bool)?](repeating: nil, count: calls.count)
        var next = 0
        while next < calls.count, !Task.isCancelled {
            // A run of reads side by side, or one other call alone.
            var end = next + 1
            if isRead[next] { while end < calls.count, isRead[end] { end += 1 } }
            let limit = isRead[next] ? max(concurrentReads, 1) : 1
            await withTaskGroup(of: (Int, String, Bool, Duration).self) { group in
                var running = 0
                while true {
                    while running < limit, next < end, !Task.isCancelled {
                        let index = next
                        let call = calls[index]
                        await onEvent(.toolStarted(id: call.id, name: call.name, input: call.input))
                        group.addTask {
                            let started = ContinuousClock.now
                            let (output, failed) = await perform(call, with: resolved[index])
                            return (index, output, failed, started.duration(to: .now))
                        }
                        running += 1
                        next += 1
                    }
                    guard let (index, output, failed, duration) = await group.next() else { break }
                    running -= 1
                    outputs[index] = (output, failed)
                    await onEvent(.toolFinished(id: calls[index].id, name: calls[index].name,
                                                summary: Self.summary(of: output), duration: duration, failed: failed))
                }
            }
        }

        return calls.indices.map { index in
            let call = calls[index]
            guard let (output, failed) = outputs[index] else {
                turn.toolsNotRun.append(call.name)
                return .toolResult(ToolResult(toolCallID: call.id, content: "Not run: stopped by the user.", isError: true))
            }
            turn.toolsRun.append(call.name)
            return .toolResult(ToolResult(toolCallID: call.id, content: output, isError: failed))
        }
    }

    /// Runs one tool call with its tool (nil when it has none or its
    /// arguments were malformed): what the model is sent, and whether it failed.
    private func perform(_ call: ToolCall, with tool: Tool?) async -> (String, Bool) {
        if call.malformedInput != nil {
            return ("The arguments were not a valid JSON object; call the tool again with valid JSON.", true)
        }
        guard let tool else { return ("There is no tool named \(call.name).", true) }
        do {
            let output: String
            switch try await tool.plan(call.input) {
            case .result(let result):
                output = result.text
            case .action(let intent, let run):
                // Reads run side by side; only a tool declared to act may, one at a time.
                guard tool.effect != .read else { return ("Not run: a read tool may not act.", true) }
                let outcome = await approver?.approve(ApprovalRequest(callID: call.id, tool: call.name, intent: intent))
                if let refusal = ApprovalOutcome.refusal(outcome, of: intent) { return refusal }
                output = try await run().text
            }
            guard output.count > maxToolResultCharacters else { return (output, false) }
            return (String(output.prefix(maxToolResultCharacters)) + "\n[cut: the result was longer]", false)
        } catch is CancellationError {
            return ("Stopped by the user before it finished.", true)
        } catch {
            return (error.localizedDescription, true)
        }
    }

    /// A tool's result in one short line, for a quiet row in the chat: room
    /// for a chat id and a message uuid (a send's link) beside the words.
    static func summary(of output: String) -> String {
        let line = output.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return line.count > 240 ? String(line.prefix(239)) + "…" : line
    }
}

/// What a turn shows as it runs.
public enum LoopEvent: Sendable, Hashable {
    case textDelta(String)
    case toolStarted(id: String, name: String, input: JSONValue)
    case toolFinished(id: String, name: String, summary: String, duration: Duration, failed: Bool)
    /// The model call failed with `error` before showing anything, and is
    /// made again after this wait; `.zero` when it is made again now.
    case retrying(after: Duration, ModelError)
}

/// How a turn ended and what it added to the conversation.
public struct TurnResult: Sendable, Hashable {
    public enum Outcome: Sendable, Hashable {
        case finished(FinishReason)
        case stepLimit
        case stopped
        case failed(ModelError)
    }

    public var outcome: Outcome = .stopped
    /// The turn's messages, to append to the history: the person's message,
    /// then replies and tool results. Every tool call in them has its result.
    public var messages: [ModelMessage]
    public var usage = Usage()
    /// Tools that ran, or started and were stopped, in order.
    public var toolsRun: [String] = []
    /// Tools the model asked for that did not run.
    public var toolsNotRun: [String] = []

    /// What was and was not done, for a turn that did not finish normally.
    public var summary: String? {
        let stop: String
        switch outcome {
        case .finished(.endTurn), .finished(.toolUse): return nil
        case .finished(.maxTokens): stop = "The reply reached its length limit."
        case .finished(.refusal): stop = "The provider declined to answer."
        case .finished(.other(let reason)): stop = "The reply ended (\(reason))."
        case .stepLimit: stop = "Stopped after the most steps a turn may take."
        case .stopped: stop = "Stopped."
        case .failed(let error): stop = error.localizedDescription
        }
        let ran = toolsRun.isEmpty ? "No tools ran." : "Ran \(toolsRun.joined(separator: ", "))."
        let skipped = toolsNotRun.isEmpty ? "" : " Did not run \(toolsNotRun.joined(separator: ", "))."
        return "\(stop) \(ran)\(skipped)"
    }

    /// Ends the turn's messages on the model's words. A turn that stopped on
    /// tool results gets a closing note: its reasoning blocks are not sent
    /// with later turns, and a tool loop left open without them is refused.
    /// A turn with no reply adds nothing.
    mutating func close() {
        if messages.count == 1 {
            messages = []
        } else if messages.last?.role == .user {
            messages.append(ModelMessage(role: .assistant, content: [.text("(The turn ended before an answer.)")]))
        }
    }

    /// Answers `calls` without running them, so the history stays whole.
    mutating func skip(_ calls: [ToolCall], because reason: String) {
        messages.append(
            ModelMessage(
                role: .user,
                content: calls.map { .toolResult(ToolResult(toolCallID: $0.id, content: "Not run: \(reason).", isError: true)) }))
        toolsNotRun += calls.map(\.name)
    }
}

extension ModelMessage {
    /// Adds streamed text to the trailing text block, or starts one.
    mutating func appendText(_ text: String) {
        if case .text(var soFar)? = content.last {
            // Out of the array first, so the append does not copy the reply so far.
            content.removeLast()
            soFar += text
            content.append(.text(soFar))
        } else {
            content.append(.text(text))
        }
    }
}
