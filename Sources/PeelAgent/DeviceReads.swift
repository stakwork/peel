import AgentKit
import Foundation
import PeelCore

/// The device requests the Mac answers in Phase 1 for strut's agent, the
/// chat reads (docs/agent-on-strut.md, "Request types"), each through a
/// Sphinx read tool (`SphinxTools`), whose `ChatData` strut's model reads.
/// Any other kind is refused, said plainly.
public struct DeviceReads: Sendable {
    let tools: SphinxTools

    public init(storage: Storage) {
        tools = SphinxTools(storage: storage)
    }

    /// The handler `Engine.answerDeviceRequests` takes, for reads only.
    public var handler: DeviceRequestHandler {
        { request in await answer(request.kind, request.args) }
    }

    func answer(_ kind: String, _ args: PeelCore.JSONValue) async -> DeviceAnswer {
        guard case .object = args, let input = try? AgentKit.JSONValue(encoding: args) else {
            return .failed("args must be a JSON object")
        }
        guard let (tool, toolInput) = call(kind, input) else {
            return .failed("unsupported: this Mac does not answer '\(kind)' requests")
        }
        do {
            // A read tool never asks: its plan is its result.
            guard case .result(let output) = try await tool.plan(toolInput) else {
                return .failed("unsupported: '\(kind)' is not a read")
            }
            return .done(output.text)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// The tool for `kind` and its input, from the request's `args`: the
    /// tools' own fields, but a chat is always `chat`, a thread `thread`
    /// and a search's words `q`. `since` is not read yet: the tools
    /// take none.
    func call(_ kind: String, _ args: AgentKit.JSONValue) -> (Tool, AgentKit.JSONValue)? {
        func input(_ fields: [String: AgentKit.JSONValue?]) -> AgentKit.JSONValue {
            .object(fields.compactMapValues { $0 })
        }
        switch kind {
        case "chats.list":
            return (tools.contactsAndTribes, .object([:]))
        case "chats.read":
            if let thread = args["thread"] {
                return (tools.threads, input(["tribe": args["chat"], "thread_uuid": thread]))
            }
            return (tools.recentMessages, input(["chat": args["chat"], "limit": args["limit"]]))
        case "chats.threads":
            return (tools.threads, input(["tribe": args["chat"], "limit": args["limit"]]))
        case "chats.unseen":
            return (tools.unseenMessages, input(["chat": args["chat"]]))
        case "chats.search":
            return (tools.search, input(["query": args["q"], "chat": args["chat"], "limit": args["limit"]]))
        default:
            return nil
        }
    }
}
