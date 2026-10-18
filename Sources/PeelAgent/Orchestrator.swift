import AgentKit
import Foundation
import PeelCore

/// Peel's half of strut's `orchestrator` (docs/agent-on-strut.md, section 1):
/// the workflow strut ships and seeds, which the bridge runs for each of the
/// owner's messages. strut gives it its own tools (`memory/*`, `job/*`) and
/// a generic prompt; Peel adds the rest through the host delta the bundled
/// server reads at boot (`hostConfig`, `STRUT_HOST_CONFIG`): its prompt
/// section, the `sphinx/*` steps that ask this Mac for what only it can do
/// (read the person's chats, send as them), and strut's `automation/*` steps
/// on `peel-automation-run`, each change behind an `approve` card on the
/// Mac. The steps and that workflow are Peel's, published as the bridge
/// starts (`AutomationsClient.installOrchestrator`, `useBridge`).
public enum Orchestrator {
    /// Where the automations the orchestrator makes run: the same `agent`
    /// step with no session and the unattended prompt.
    public static let automationWorkflow = "peel-automation-run"

    /// strut's `automation/*` steps, which act on `automationWorkflow` only.
    static let automationTools = ["list", "preview", "create", "update", "delete", "run-now"].map { "automation/" + $0 }

    /// What the orchestrator is granted beside strut's own: the reads, the
    /// send, the automations. Never `approve`, which only the automation
    /// steps call.
    static let tools: [String] = DeviceStep.reads.map(\.type) + [DeviceStep.send.type] + automationTools

    /// What an automation's run is granted: memory and the reads; no send
    /// (PR 7 adds one for an automation with a send grant), no schedules.
    static let automationRunTools = MemoryTools.Names.strut.all + DeviceStep.reads.map(\.type)

    // MARK: The prompt

    /// Who the agent is; `where` says how the user reaches it.
    static func intro(_ where: String) -> String {
        """
        You are Peel's agent, a helper inside Peel, a Sphinx chat app. \(`where`) Answer plainly and briefly, in \
        Markdown when it helps. Use a tool when it gives a better answer than guessing. When the tools you have \
        cannot do what is asked, say so.
        """
    }

    /// What the model does when the Mac has not answered a request.
    static let waiting = """
        A tool that asks the user's Mac may answer that it is waiting for it (status pending): their Mac has not \
        answered yet. Then say in a line that you are waiting for their Mac, and stop. Its answer comes later as \
        a message marked as from the Mac, and you go on from there.
        """

    /// Peel's section of the orchestrator's prompt, after strut's: today's
    /// agent prompt (`AgentSetup.systemPrompt`) with strut's tool names, the
    /// chats on the Mac, and what to do when it does not answer.
    static let section = [
            intro("""
                The user talks with you in your direct message, from their Mac, their phone or Sphinx's own apps; \
                each message starts with the time and their time zone.
                """),
            AgentMessageLink.instruction, SphinxTools.systemPrompt(.strut), waiting,
            SphinxTools.sendPrompt(tool: DeviceStep.send.type), MemoryTools.systemPrompt(.strut),
            AutomationTools.systemPrompt(list: "automation/list"),
        ].joined(separator: " ")

    /// `peel-automation-run`'s prompt: the same, unattended, with nothing
    /// about sending or scheduling, whose tools a run is not offered.
    static let unattended = [
            intro("Your result reaches the user in your direct message; the run's message says when it runs."),
            AgentMessageLink.instruction, SphinxTools.systemPrompt(.strut),
            "If their Mac does not answer a tool, say what you could not read.", MemoryTools.systemPrompt(.strut),
        ].joined(separator: " ")

    // MARK: The host delta

    /// The JSON strut's bundled server reads at boot (`STRUT_HOST_CONFIG`):
    /// Peel's tools and section on the orchestrator, which runs on the
    /// connected model (`model: null`, strut's `STRUT_DEFAULT_MODEL`), and
    /// the automation steps' workflow and approval step.
    static func hostConfig() throws -> Data {
        let config: AgentKit.JSONValue = [
            "orchestrator": ["tools": .array(tools.map(AgentKit.JSONValue.string)), "system": .string(section), "model": .null],
            "automation": ["workflow": .string(automationWorkflow), "approve": .string(DeviceStep.approve.type)],
        ]
        return Data(config.jsonString.utf8)
    }

    // MARK: peel-automation-run

    /// One automation run in strut: the input strut's `automation/*` steps
    /// write (`name`, `prompt`, `since`, `now`), today's run instruction
    /// (`AutomationRun.instruction`) as its prompt, its reply in the
    /// orchestrator's shape so the bridge reads both alike.
    static var automationRunYAML: String {
        """
        name: \(automationWorkflow)
        # Sealed: a job's meta/run-workflow never runs it to read the chats.
        sealed: true
        input:
          name: { type: string }
          prompt: { type: string }
          since: { type: json, required: false, description: "When the last successful run finished; null on the first" }
          now: { type: string, required: false, description: "When this run fired" }
        steps:
          - id: dir
            type: job/dir
          - id: turn
            type: agent
            config:
              cwd: "{{ dir.path }}"
              system: "{{ params.system }}"
              prompt: \(yamlString(runPrompt))
              toolFilter: [none]
              agentTools: "{{ params.tools }}"
              maxSteps: 30
              schema:
                type: object
                required: [text]
                properties:
                  text: { type: string, description: "What the person should be told, written for them; only \(AutomationRun.nothingToReport) when there is nothing worth telling this time." }
          - id: result
            type: pack
            config:
              text: "{{ turn.object.text }}"
              artifacts: []
              cost: "{{ turn.cost }}"
        params:
          tools: \(AgentKit.JSONValue.array(automationRunTools.map(AgentKit.JSONValue.string)).jsonString)
          system: \(yamlString(unattended))

        """
    }

    /// The run's message, as `AutomationRun.instruction` words it, from the input.
    static let runPrompt = """
        This is a scheduled automation, "{{ input.name }}", running on its own at {{ input.now || 'a time not given' }} (UTC). \
        No one is watching and no one can answer a question or approve an action. The last run finished at \
        {{ input.since || 'no time yet: this is its first run, so "new" means the last 7 days' }}; after a run, "new" means since it. \
        Peel keeps each run's time for you, so keep nothing about the run itself in memory.

        Carry out the task below with the tools you have, then reply with exactly what the person should be told: \
        it is delivered to them as it is, so write it for them, not about the run. If there is nothing worth telling \
        them this time, reply with only \(AutomationRun.nothingToReport). If a step would need something you cannot \
        do here, such as sending a message to someone, say what you would send instead of doing it.

        Task: {{ input.prompt }}
        """

    /// `text` as one YAML scalar: a JSON string is one.
    static func yamlString(_ text: String) -> String {
        AgentKit.JSONValue.string(text).jsonString
    }
}

/// A device request as a strut step (docs/agent-on-strut.md, "Request
/// types"): it posts the request to the bridge on loopback, with the port and
/// token Peel keeps in strut's secret store, and gives the model the Mac's
/// answer. A request's id is its run and a hash of its place in it and its
/// args, so a resumed step asks the same question and gets the stored
/// answer, and a stored answer never stands for other args. When the Mac
/// has not answered in time the step returns `pending` wrapped in
/// `withStop()`: the turn ends, and the answer comes as a later turn.
struct DeviceStep: Sendable {
    let type: String
    let kind: String
    let description: String
    /// The step's zod input, as JavaScript.
    let input: String
    /// How long the bridge waits for the Mac's answer before `pending` (at
    /// most 300 s): a read's 30 s, or a card's.
    var wait = 30
    /// How long the Mac may still act on it (`not_after`): a read's 12 hours.
    var lifetime = 12 * 3600

    static let portSecret = "PEEL_BRIDGE_PORT"
    static let tokenSecret = "PEEL_BRIDGE_TOKEN"

    static let chat = #"z.string().describe("A contact or tribe name, or a chat id.")"#
    static let anyChat = #"z.string().optional().describe("A contact or tribe name, or a chat id; leave out for every chat.")"#

    static let reads = [
        DeviceStep(type: "sphinx/chats", kind: "chats.list",
                   description: "List the user's Sphinx contacts and tribes, with their names and chat ids (public keys), from their Mac.",
                   input: "z.object({})"),
        DeviceStep(type: "sphinx/read", kind: "chats.read",
                   description: """
                       Read the recent messages of one chat, most recent last, as the chat shows them, from the user's Mac. \
                       In a tribe, a thread of two or more messages shows as its newest message, marked [IN THREAD, n replies]; \
                       read it whole with thread (its root uuid). Each line is "[sender] date (uuid=… thread=… reply=… [marker]): text".
                       """,
                   input: """
                       z.object({ chat: \(chat), limit: z.number().int().min(1).max(\(SphinxTools.recentLimit.max)).optional().describe("How many messages, default \(SphinxTools.recentLimit.default)."), thread: z.string().optional().describe("A tribe thread's root uuid, to read that thread's messages.") })
                       """),
        DeviceStep(type: "sphinx/threads", kind: "chats.threads",
                   description: """
                       List the threads in a tribe, most recently active first, each with its root uuid, who started it, its first \
                       message, its reply count and when it was last active, from the user's Mac. Read one with sphinx/read and thread.
                       """,
                   input: """
                       z.object({ chat: z.string().describe("A tribe name or chat id. Threads are only in tribes."), limit: z.number().int().min(1).max(\(SphinxTools.threadLimit.max)).optional().describe("How many threads, default \(SphinxTools.threadLimit.default).") })
                       """),
        DeviceStep(type: "sphinx/unseen", kind: "chats.unseen",
                   description: """
                       Read the messages the user has not seen yet, oldest first, from their Mac. With a chat, that chat's; without \
                       one, every chat with unseen messages, grouped by chat, newest chat first: use this for "what did I miss?". \
                       Same line format as sphinx/read.
                       """,
                   input: "z.object({ chat: \(anyChat) })"),
        DeviceStep(type: "sphinx/search", kind: "chats.search",
                   description: """
                       Search the user's messages on their Mac for words, as Peel's chat search does: every word or "quoted phrase" \
                       must appear (each at least three characters), and from:name narrows to a sender. In one chat, or in every \
                       chat when chat is left out. Results are grouped by chat, newest first.
                       """,
                   input: """
                       z.object({ q: z.string().min(1).describe("Words, \\"phrases\\" and from:name."), chat: \(anyChat), limit: z.number().int().min(1).max(\(SphinxTools.searchLimit.max)).optional().describe("How many results, default \(SphinxTools.searchLimit.default).") })
                       """),
    ]

    /// A send as the user: the Mac shows the exact text (and a tribe's
    /// price) on a card in the DM and sends only on Allow. The card is the
    /// decision, so the cap the Mac checks is its own most unless the
    /// person named one.
    static let send = DeviceStep(
        type: "sphinx/send", kind: "send",
        description: """
            Send a text message as the user to a contact or tribe. The user sees the exact message on a card on their Mac and must \
            allow it before anything is sent; a tribe message costs sats, which the card shows. With thread_uuid it goes into that \
            tribe thread; with reply_to_uuid it replies to that message. Use only uuids you read in a result for that same chat.
            """,
        input: """
            z.object({ chat: \(chat), text: z.string().min(1).max(\(SphinxTools.maxMessage)).describe("The message as it should be sent."), thread_uuid: z.string().optional().describe("A tribe thread's root uuid, or any message in it, to post in that thread."), reply_to_uuid: z.string().optional().describe("The uuid of a message in this chat to reply to."), max_price_sats: z.number().int().min(0).max(1000000).optional().describe("Only when the user named the most a tribe message may cost them, in sats.") })
            """,
        wait: 300, lifetime: 3600)

    /// The card strut's `automation/*` steps ask before acting: their
    /// `{ intent }`, answered `{ approved }`.
    static let approve = DeviceStep(
        type: "sphinx/approve", kind: "approve",
        description: "Ask the user on their Mac to allow an action, on a card showing it. Called by strut's automation steps, never as a tool.",
        input: "z.object({ intent: z.object({ action: z.string(), content: z.string().optional(), details: z.array(z.string()).optional() }) })",
        wait: 300, lifetime: 3600)

    static let all = reads + [send, approve]

    /// The step, as strut loads a custom one: `defineStep` from strut, the
    /// bridge reached on 127.0.0.1 only, its port and token read from the
    /// secret store in code, so a workflow can name neither.
    var source: String {
        let args = kind == "send" ? "{ ...cfg, max_price_sats: cfg.max_price_sats ?? 1000000 }" : "cfg"
        // An approval: the model is never given its result as text.
        let answer = kind == "approve"
            ? """
                if (a.status === "done") return { approved: true };
                    return { approved: false, status: a.status, error: a.error ?? "The user did not allow it." };
                """
            : """
                if (a.status === "done") return typeof a.result?.text === "string" ? a.result.text : JSON.stringify(a.result ?? null);
                    return { status: a.status, error: a.error ?? "Their Mac did not do it." };
                """
        return """
            import { createHash } from "node:crypto";
            import { z, defineStep, withStop } from "strut";

            // Peel's device request \(kind) (docs/agent-on-strut.md, "Request types"), published by Peel.
            // Sealed: the meta surface (a job's meta/* tools) never runs it.
            export default defineStep({
              type: \(Orchestrator.yamlString(type)),
              sealed: true,
              description: \(Orchestrator.yamlString(description)),
              input: \(input),
              output: z.any(),
              async run(cfg, ctx) {
                const token = await ctx.services.secrets.get("\(Self.tokenSecret)");
                const port = Number(await ctx.services.secrets.get("\(Self.portSecret)"));
                if (!token || !Number.isInteger(port) || port < 1 || port > 65535) {
                  throw new Error('secrets "\(Self.tokenSecret)" and "\(Self.portSecret)" are not set: Peel stores them when the agent\\'s bridge starts');
                }
                if (!ctx.runId || !ctx.path) throw new Error("\(type) runs only inside a run, as an agent's tool");
                const args = \(args);
                // The same call asks the same question again (a resumed run gets the stored answer);
                // any other args are another question, so an answer never stands for what it did not see.
                const id = `${ctx.runId}/${createHash("sha256").update(`${ctx.path}\\n\(kind)\\n${JSON.stringify(args)}`).digest("hex").slice(0, 32)}`;
                const res = await ctx.services.http(`http://127.0.0.1:${port}/bridge/device/request`, {
                  method: "POST",
                  headers: { authorization: `Bearer ${token}` },
                  body: { id, kind: "\(kind)", args, wait_secs: \(wait), not_after: Math.floor(Date.now() / 1000) + \(lifetime), run: ctx.runId },
                  timeout: \((wait + 30) * 1000),
                });
                if (!res.ok) {
                  const why = typeof res.body === "string" ? res.body : res.body?.error ?? JSON.stringify(res.body);
                  throw new Error(`The agent's bridge answered ${res.status}: ${why}`);
                }
                const a = res.body ?? {};
                if (a.status === "pending") {
                  return withStop({ status: "pending", note: "The user's Mac has not answered yet. Say you are waiting for their Mac, and stop: its answer comes as a later message." });
                }
                \(answer)
              },
            });

            """
    }
}

extension AutomationsClient {
    /// What the orchestrator's turns need from strut beyond its seed, before
    /// the bridge starts: the `sphinx/*` steps (one version per content, so
    /// the same source is a no-op) and `peel-automation-run`, and no port or
    /// token from a bridge that is gone (`useBridge` sets the new ones), so a
    /// turn the bridge runs at once never posts to an old one.
    public func installOrchestrator() async throws {
        try await forgetBridge()
        for step in DeviceStep.all {
            _ = try await call("POST", "steps", ["name": .string(step.type), "code": .string(step.source),
                                                 "description": .string(step.description)],
                               what: "the \(step.type) step")
        }
        try await publish(Orchestrator.automationWorkflow, yaml: Orchestrator.automationRunYAML,
                          description: "One of Peel's automations, run in strut with nobody watching: memory and the reads on the Mac.")
    }

    /// Where the steps reach `bridge`, now running: its port and token in
    /// strut's encrypted secret store (`DeviceStep`'s secrets, new on each launch).
    public func useBridge(_ bridge: BundledBridge.Server) async throws {
        guard let port = bridge.base.port else { throw PeelError("The agent's bridge has no port.") }
        _ = try await call("PUT", "secrets/\(DeviceStep.portSecret)", ["value": .string(String(port))], what: "the bridge's port")
        _ = try await call("PUT", "secrets/\(DeviceStep.tokenSecret)", ["value": .string(bridge.token)], what: "the bridge's token")
    }

    /// Takes the stopped bridge's port and token out of strut's secret
    /// store, so no step posts to that port (and its token) again.
    public func forgetBridge() async throws {
        try await deleteSecrets([DeviceStep.portSecret, DeviceStep.tokenSecret], what: "the bridge's secrets")
    }
}
