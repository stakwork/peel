import AgentKit
import Foundation
import PeelCore
import PeelDiagnostics

/// The device requests the Mac answers in Phase 1 for strut's agent, the
/// chat reads (docs/agent-on-strut.md, "Request types"), each through a
/// Sphinx read tool (`SphinxTools`), whose `ChatData` strut's model reads,
/// and `diagnostics.latest`, Peel's own last crash or run record, redacted
/// as the "Show record" sheet shows it (docs/diagnostics.md). Any other
/// kind is refused, said plainly.
public struct DeviceReads: Sendable {
    let tools: SphinxTools
    /// The user's own name, removed from a diagnostics record.
    let myAlias: @Sendable () async -> String?

    public init(storage: Storage, myAlias: @escaping @Sendable () async -> String?) {
        tools = SphinxTools(storage: storage)
        self.myAlias = myAlias
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
        case "diagnostics.latest":
            return (diagnostics, .object([:]))
        default:
            return nil
        }
    }

    /// How the last run ended, then the newest crash record (redacted with
    /// this account's names, which must be read: without them nothing is
    /// sent, and cut to fit a device answer), or the event ring alone when
    /// there is none: never the raw report. The record may be older than the
    /// last run; its date says so. Framed as `ChatData`, whose budget also
    /// caps it.
    var diagnostics: Tool {
        Tool(
            name: "peel_diagnostics",
            description: "Peel's own last crash or run record on this Mac, redacted.",
            inputSchema: ["type": "object", "properties": [:], "additionalProperties": false],
            effect: .read
        ) { _ in
            let names = DiagnosticsNames(chats: try await tools.chats(), myAlias: await myAlias())
            let report: RedactedRecord?
            do {
                report = try await Diagnostics.latestRedactedReport(allow: names.allow, knownNames: names.knownNames)
            } catch {
                // Its words could name a file; the model is told only that it failed.
                throw ToolFailure(errorDescription: "Could not read Peel's record on this Mac.")
            }
            // Framed as data: an exception's words or strut's stderr can echo what others wrote.
            var data = ChatData(report.map { _ in
                "Last run: \(Diagnostics.previousRun().kind.rawValue). Peel's newest crash record on this Mac (its date says when), "
                    + "redacted, with only the crashed thread's top frames and the last events:"
            } ?? "No crash report on this Mac.")
            let text = report.map { $0.compact().rendered() } ?? Diagnostics.snapshot().rendered()
            text.split(separator: "\n", omittingEmptySubsequences: false).forEach { data.add(String($0)) }
            return .text(data.text)
        }
    }
}
