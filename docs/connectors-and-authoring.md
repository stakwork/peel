# Connectors and workflow authoring

Last updated 2026-10-22. **A design for Tom and Evan to agree; nothing
here is built.** Phase 1 ([agent-on-strut.md](agent-on-strut.md)) made
the agent a Sphinx contact whose loop is strut's `orchestrator`. This doc
covers the next two things Tom wants: connectors (Gmail, Linear, his Mac
calendar, Claude Code and Codex, Jamie and Hive), and an agent that builds
and schedules its own strut workflows. One design serves Peel's agent and
Hive's Jamie.

Read on 2026-10-22 from strut `origin/main` (4150016, #266), Peel `main`
(d92c0b85, whose `Vendor/strut.lock` pins strut c180e8f, #220) and Hive
`master` (1f87b3c6e). It replaces the connector parts of
[jobs-architecture.md](jobs-architecture.md) (P5, P6, J1) and the
authoring row (D) of [automations-and-jobs.md](automations-and-jobs.md).

## In one paragraph

Every connector lives in the user's own strut, as tools. A connector is
either a family of strut steps (`slack/*`, and new `gmail/*`) or an MCP
server registered with strut once (Linear), and its token is a named
secret in strut's encrypted store. Grants decide which agent gets it: the
orchestrator, jobs, or workflows the builder writes. A tool that acts
stops for your approval through strut's proposals, which Peel shows as a
card in the agent's DM. Local things (Calendar, Reminders) stay device
requests to your Mac, shown on the same Connections screen. For
authoring, the orchestrator starts strut's `builder` job; the builder
writes the workflow, proposes to publish it and proposes a schedule; you
approve each on a card; the workflow runs on its schedule and its result
lands in the DM. Hive's Jamie gets the same connectors by moving its MCP
servers from Hive's database into the org's strut. A team's connectors
stay on the team's strut: your agent reaches a Hive workspace as a strut
peer and asks its orchestrator, Jamie, on your own session there.

## How it feels

**Adding a Hive workspace and asking it to review a PR.**

1. In Account › Connections, "Add a Hive workspace". Peel shows a short
   code and opens Hive's pair page in your browser, already signed in.
2. Hive asks "Connect this Mac to stakwork?"; you approve. Peel saves the
   workspace as a peer of your strut and lists it: "stakwork (Hive):
   Jamie, 14 shared workflows".
3. In the DM: "ask stakwork to review peel#342". Your agent sees this
   belongs to stakwork and asks first: a card, "Send this request to
   stakwork? Review stakwork/peel#342". Allow once, or Always for
   stakwork.
4. Jamie, on stakwork's strut, starts a review job with the team's
   GitHub access. Your agent says "stakwork is reviewing it".
5. When the job ends, its result arrives in the DM, from stakwork:
   "Two issues: …", with links that open through your strut.

**Adding Gmail and asking about an email.**

1. In Connections, Gmail › Sign in with Google. You pick your account and
   allow read and draft. Gmail shows Connected, on for the Assistant.
2. In the DM: "did Evan reply about the strut pin?" The agent searches
   Gmail and answers with the thread's gist and a link.
3. "Reply that Thursday works." The agent drafts it and a card shows the
   reply in full: To, Subject, the text. Send, Deny. Send sends it once.

## Tom's direction (2026-10-22)

1. Every connector lives in strut, as tools.
2. Credentials live on the user's own strut (their brain), never on our
   servers.
3. The orchestrator uses connectors as tools, through MCP where strut has
   no steps.
4. The same architecture serves Hive's Jamie and Peel's agent.
5. Peel's agent creates and manages its own strut workflows ("research
   YouTube every Monday and send me the top 5"), not only prompts on a
   schedule, the way Jamie and the builder do in Hive.

## What the code says (and where the brief was off)

| Claim | What the code says |
|---|---|
| strut has slack, github, gdrive, sheets and x steps | Yes, plus `git/*` (token by `tokenSecret`). Two to six steps each, under `src/steps/lib/<family>/` |
| Tokens are named secrets; no OAuth | Yes: no sign-in flow and no token refresh anywhere. But `gdrive/*` takes a raw Google access token (`GOOGLE_ACCESS_TOKEN`) or a service account, and `sheets/*` signs a service-account JWT itself |
| No Gmail, Linear or Calendar | Yes. strut's orchestrator comments expect a host to add `calendar/*` (`orchestrator.yaml:137`) |
| MCP is per launch only | Yes: `POST /workflows/:name/run { mcp }`, Streamable HTTP only, at most 10 servers (`src/mcp-servers.ts`). Also kept on the run record so a resumed run reconnects, and inherited by `job/start`, `job/continue` and `meta/run-workflow` |
| No approval for MCP tools | Yes. The `approve:` gate only wraps registry steps (`agent.ts:696-728`) |
| Hive's `OrgMcpServer` rows serve the Vercel Jamie only | Yes (`externalMcpTools.ts:143`, from `runCanvasAgent`, skipped on read-only runs). Jamie on strut sends `{prompt, session, context}`, no `mcp` (`services/strut-orchestrator.ts:101-128`) |
| The builder publishes ungated | Yes: `approve: []` by default (`builder.yaml:183-189`). But a publish may only overwrite workflows stamped `publisher: ai`, may not declare `sealed` or `peer`, and is refused if anything it reaches is sealed (`authoring.ts:745-773`) |
| No `meta/set-automation` | Yes. The builder *chat* has `set_automation` with no approval (`src/ai/tools.ts:804`), but the builder job does not |
| Proposals exist (#222) | Yes: `src/proposals.ts`, `GET /proposals`, `POST /proposals/:id/decide`, `run.end { proposals }` |
| Peel grants `sphinx/*` and `automation/*`, no builder list | Yes, by name: the five chat reads, `sphinx/send` and `automation/list` to `run-now`; not `sphinx/post` or `sphinx/approve` (`Orchestrator.swift:20-26`, `hostConfig()` at :138-145). No `builder` key |
| `sphinx/read` isn't sealed against authored workflows | **No.** Every Peel device step is `defineStep({ sealed: true })` (`Orchestrator.swift:395`), so a builder publish that grants `sphinx/*` is refused. The real hole is secrets: below |
| Peel's strut has the builder | **Not yet.** The builder (#239) and proposals (#222) landed after Peel's pin (c180e8f). Moving the pin seeds `builder` with `approve: []` and `peer: true`, and the orchestrator can already start it (`job/start { workflow: builder }`) |

**The real hole: any strut code can read any secret by name.** There is no
allowlist (`capabilities.ts:44-109`); `secretsEnv` on `agent` and `exec`
injects any named secret; the store even falls back to the boot
environment (`capabilities.ts:79-88`, wired at :414). So a builder-authored
step, or an authored workflow's `exec` step with `secretsEnv:
[PEEL_BRIDGE_TOKEN]`, can call the bridge on loopback and ask your Mac for
`chats.*` reads. The bridge checks only the token, the request id and the
kind, not which run asks (`runner/src/bridge/device.rs:69-75`), and the
Mac answers reads without a card (`DeviceActions.swift:78`). It can also read the model key and every
connector token. Sealing `sphinx/*` does not stop that. Section 7 closes
it.

## 1. The connector model

### Three kinds, one list

| Kind | What it is | Its credential | Examples |
|---|---|---|---|
| **Step family** | Steps in strut under `<service>/*`; each becomes a tool `<service>_<verb>` | A named secret in strut's store (`SLACK_BOT_TOKEN`) | slack, github, x, gdrive, sheets; new: gmail |
| **MCP server** | A remote server registered with strut once; its tools become `mcp/<server>/<tool>` | A named secret, referenced by the registration | Linear, Hive's `/mcp`, Notion later |
| **Device request** | A sealed `sphinx/*` or `calendar/*` step that asks your Mac over the DM | None in strut: your Mac holds the keys and EventKit | Your chats, sends as you, Calendar, Reminders |

Step families stay the default for services we use a lot and want to
shape (Gmail). MCP covers the long tail without strut code. Device
requests are only for what lives on your devices.

### What exists and what's new

| Piece | Exists | New |
|---|---|---|
| Secret store | `PUT/DELETE /secrets/:name`, `GET /secrets` (names only); per-person `/actors/:actor/secrets` (person's value first, then the deployment's) | Nothing |
| Steps as tools | `agentTools` globs; the host delta (`STRUT_HOST_CONFIG`: `job`, `orchestrator`, `builder`, each `{tools, approve, system, model}`, `peer: false` only on the builder; and `automation: {workflow, approve, grants}`) (`src/server.ts:35-91`) | `builder.reach` (section 7) |
| Approval | `approve:` on an agent records a proposal instead of running the step; `decide` runs it in code with the run's own secrets and MCP servers | MCP tools can be named in `approve:` |
| MCP | Per launch, HTTP, masked headers, inherited by child runs | **A registry**: `GET/PUT/DELETE /mcp-servers/:name { url, tokenSecret?, headerSecrets?, toolFilter? }`, values by secret name; grants name `mcp/<server>/*` |
| Discovery | `GET /steps` returns `{core, workspace}` of `{type, source, description}` | Each step's `secrets` (names it reads) and `effect` (`read`/`write`), for the Connections screen and default approvals |
| Secret scoping | None | Code the AI published reads only the secrets its approved reach names (section 7) |
| Health | `GET /health` only; an unreachable MCP server is skipped with a log line | `POST /mcp-servers/:name/test` (a `tools/list` probe); a step family is "connected" when its secrets are set |

That is three strut additions (registry, step metadata, secret scoping)
and one extension (MCP tools in grants and `approve:`). Everything else is
reuse.

### Adding one

- **A step family:** a folder of steps in strut, upstream, declaring the
  secret names it reads and its effect. Steps that act are listed in the
  host's `approve:`.
- **An MCP server:** `PUT /mcp-servers/linear { url:
  "https://mcp.linear.app/mcp", tokenSecret: "LINEAR_API_KEY" }` and
  `PUT /secrets/LINEAR_API_KEY`. No code. Peel's Connections screen does
  both from "Add".
- **A device request:** a new kind in Peel (`reminders.list`), a sealed
  step Peel publishes for it, the EventKit handler on the Mac.

### Where credentials live

Always in strut's encrypted store on the brain (your Mac now, a home
server in Phase 2), under `STRUT_SECRET_KEY`, which Peel already keeps per
account (`Profile.strutKey`). Peel's Mac app writes them on loopback and
never keeps a copy. They never travel in a Sphinx message
([agent-architecture.md](agent-architecture.md)). In Hive, a person's own
token is an actor secret and an org's is a deployment secret on the org's
strut (section 5).

### Grants: who gets which connector

| Agent | Where its grants come from | Peel's toggle |
|---|---|---|
| The orchestrator (the DM) | `orchestrator.tools` in the host delta | "Assistant" |
| Jobs (`job`) | `job.tools` in the host delta | "Jobs" |
| Workflows the builder writes | The workflow's own `agentTools` and steps, checked at publish against `builder.reach` (new, section 7) | "Workflows" |
| The builder itself | `builder.tools` (`meta/*`, `app/*` and graph and job reads); no connectors | None |

A toggle rewrites `host-config.json`, which strut reads at boot, so a
change restarts Peel's strut (a second or two). Grants a launcher passes
in `params` may narrow, never widen (`closure.ts:135-154`).

### Approval for tools that act

One gate: strut's proposals.

- **Steps:** the host lists acting steps in `approve:` (`gmail/send`,
  `slack/post-message`). strut's new `effect` lets Peel fill that list
  from the toggles rather than by hand.
- **MCP tools:** the same list, by name (`mcp/linear/create_issue`). By
  default every tool of a registered server is gated except those the
  server marks `readOnlyHint`; the Connections screen can ungate one.
- **Sends as you and device writes** keep Peel's own card and send grants
  (Phase 1). They are already sealed and approved on the Mac.

A proposal reaches you as a card in the DM (section 7, "The card").
"Always allow" takes the tool out of that agent's `approve:` list in the
delta, so it runs without a card next time; never for a send, anything
that spends, or a publish.

## 2. Peel's Connections screen

On the Mac, a new section in Account, under Agent. One list: strut's
connectors and this Mac's.

```
Connections
  Gmail        tom@…         Connected       Assistant ● Jobs ● Workflows ○
  Notion       MCP           Connected       Assistant ● Jobs ● Workflows ●
  Slack        —             Needs a token   [Paste token]
  GitHub       tomsmith8     Connected       Assistant ○ Jobs ● Workflows ○
  Claude Code  this Mac      Signed in       Jobs ●
  Linear       MCP           Error: 401      [Replace token]
  ─ Hive workspaces ─
  stakwork     Jamie · 14 shared workflows   Paired   Asks first ●  [Remove]
  [+ Add a Hive workspace]
  ─ On this Mac ─
  Calendar     EventKit      Allowed         Assistant ● Jobs ●  (never workflows)
  Reminders    EventKit      Not allowed     [Allow access]
  Your chats   Sphinx        Built in        Assistant ● Jobs ●  (never workflows)
  [+ Add an MCP server]
```

- **The list** is built from `GET /steps` grouped by family (with the new
  `secrets` and `effect`), `GET /mcp-servers`, and `GET /secrets` for which
  names are set. Families with no secret (memory, job, meta) are not
  connectors and don't show.
- **Add a token:** a secure field, `PUT /secrets/:name`, then the status
  check. The value is never shown again (Replace, Remove), as the model
  key is today.
- **Sign in:** Gmail only, for now (section 3).
- **Add an MCP server:** URL and token. Peel registers it, probes it, and
  shows its tools with each one's gate (Asks first / Runs).
- **Toggles** per agent, as in section 1. Local connections have no
  Workflows toggle: device steps are sealed from authored workflows.
- **Hive workspaces** are peers, not connectors (section 6): paired, not
  given a token; one switch, whether a request to it asks first.
- **Status:** Connected, Needs a token, Error (the last failure's words,
  from the probe or the last run), Off. No polling: checked when the
  screen opens and after each change.

**On the iPhone,** You › Agent (`YouRoute.agent`, an empty slot today)
shows the same list read only in Phase 1, from a snapshot the Mac sends
over the DM when it changes (names and status, never values). Toggles
from the phone come with Phase 2's phone-as-device. Tokens are entered
on the Mac only, since they never travel over Sphinx.

## 3. Gmail and Linear

### Linear: the official MCP server, with a pasted key

Linear runs a hosted MCP server at `https://mcp.linear.app/mcp`
(Streamable HTTP; `/mcp/readonly` for reads only). It takes OAuth 2.1
with dynamic client registration, or a personal API key as
`Authorization: Bearer`.

| Option | For | Against |
|---|---|---|
| **MCP, pasted API key** | No strut code; Linear maintains the tools; works on strut's existing HTTP transport | Tools are Linear's shape, not ours |
| MCP, OAuth 2.1 | No key to copy | strut has no OAuth client; needs a redirect into Peel |
| New `linear/*` steps | Our tool shapes | Code to write and keep up with Linear's API |

**Recommended:** MCP with a pasted personal key, registered in strut.
Writes (create or update an issue, comment) are gated by default.

### Gmail: new strut steps, Google sign-in from Peel

Gmail's useful scopes are Google's **restricted** ones (`gmail.readonly`,
`gmail.modify`, `gmail.compose`); `gmail.send` alone is sensitive. A
public app asking for a restricted scope needs Google's verification, and
a yearly security assessment if the mail passes through a third-party
server. An app in "Testing" status gets refresh tokens that expire after
7 days. An unverified app in production shows Google's "unverified app"
screen before consent and is capped at 100 new users. Google's
restricted-scope page exempts apps "used by only a few users, all of whom
are known personally to you".

| Option | For | Against |
|---|---|---|
| **`gmail/*` steps, Google OAuth from Peel** | Narrow scopes; tokens on your strut; same helper fixes gdrive's expiring token | Verification before a public release |
| A Gmail MCP server | No strut code | No first-party one; third-party hosts route your mail through their servers, against direction 2 |
| IMAP with an app password | No Google review | Whole mailbox, needs 2-step verification, Workspace admins can turn it off |
| Mail.app by device request | Local | Mac awake, AppleScript, slow |

**Recommended:** `gmail/*` steps in strut (`search`, `read`,
`draft`, `send`, `label`), with `send` and `label` gated. Peel signs in as
a native app (PKCE in `ASWebAuthenticationSession`, no client secret) and
writes the refresh token and client id to strut's secrets; strut gains one
Google token helper that swaps a refresh token for an access token, used by
`gmail/*`, `gdrive/*` and later `calendar` on the web. For Tom now: our
own OAuth client in production status, unverified, under the personal-use
exemption (no 7-day expiry; the unverified screen at each consent). Start
verification before anyone else uses it. Scopes: `gmail.readonly` and `gmail.compose`
(drafts and send) to begin; `gmail.modify` only if labels are wanted.

Since mail goes from Google to your own strut and nowhere else, Peel's
assessment burden should be the light one. Hive's is not: its strut runs
on Stakwork's swarms (section 5).

## 4. The rest of Tom's list

| Connector | How | Notes |
|---|---|---|
| Mac Calendar | `calendar.*` device requests (designed in agent-on-strut.md, PR 8, dropped from Phase 1) | Reads answered; writes on the card |
| Mac Reminders | New `reminders.*` device requests, the same EventKit permission path | `list`, `create`, `complete`; writes on the card |
| Claude Code, Codex | strut's `acp/prompt` step (pinned `claude-agent-acp` and `codex-acp` presets, `acp/prompt.ts:35-37`): a local coding agent with its own login on the Mac. On strut main, not at Peel's pin: it arrives with P1 | No strut secret: the CLI's own sign-in. Grant to jobs only. Whether it runs inside Peel's sandboxed strut is open question 6 |
| Jamie, Hive | A strut peer: the org's strut, called with `strut/run-workflow` (section 6) | The team's connectors and credentials stay on the team's strut. Hive's `/mcp` as an MCP server is a fallback for Hive's own org tools |

## 5. Hive alignment

Hive's strut is the org's: one per default workspace swarm, mounted at
`/lab` in stakgraph's MCP server (`strut-target.ts:63-86`), with people
told apart by `x-strut-actor` (`strut-target.ts:41-44`). The same model
fits:

| Today in Hive | Move to |
|---|---|
| `OrgMcpServer` rows, headers encrypted in Hive's database, used by the Vercel Jamie | strut's MCP registry on the org's strut; header values as deployment secrets |
| No per-person connector tokens (only a GitHub token pushed as an actor secret on job turns) | A person's tokens as actor secrets; one registration (`tokenSecret: LINEAR_API_KEY`) resolves to each person's own key |
| Jamie on strut gets no `mcp` | The orchestrator's grants name `mcp/*` (org servers) in Hive's delta |
| `StrutProposalCard` for graph-write proposals | The same card for connector and publish proposals: nothing new |

The steps:

1. **Write both.** Hive's MCP settings save to `PUT {lab}/mcp-servers`
   and `{lab}/secrets` as well as `OrgMcpServer`.
2. **Jamie on strut uses them.** Hive's strut delta (stakgraph's
   `createStrut` options) grants `mcp/*` to the orchestrator and jobs and
   lists write tools in `approve:`.
3. **Vercel Jamie retires,** then `OrgMcpServer` and its routes go. Until
   then it keeps reading its own rows, since it needs header values and
   strut never returns them.

**Direction 2 in Hive.** The org's strut runs on Stakwork's swarms, so
"never on our servers" there means "in the org's strut, never in Hive's
database". That is a weaker promise than Peel's, and Gmail there needs
Google's full assessment. Open question 3.

## 6. Peers: a Hive workspace (Jamie)

A team's connectors and credentials stay on the team's strut. Your agent
does not copy them; it calls that strut as a **peer** and asks its
orchestrator, Jamie, which uses them there. This is strut's own plan,
`plans/chained-orchestrators.md` (ruled with Evan, 2026-10-22), with Peel
as "the desktop app". Most of strut's half is built.

### What strut already has

| Piece | State |
|---|---|
| Peers on file: `PUT/GET/DELETE /peers/:id { baseUrl, token, label, description, repos }`, in an encrypted `peers.json`; the token is readable by nothing, steps get a capability that names a peer (`src/peers.ts`) | Built |
| `strut/list-peers` and `strut/run-workflow { peer, workflow, input, wait, room }`, both granted to the orchestrator (`orchestrator.yaml`) | Built |
| Caller-pulled: the caller launches, then reads the peer's event stream and reattaches with `?skip=N`, so a strut behind NAT (your Mac) can call a cloud one | Built |
| `peer: true` (any peer may launch) and `peer: person` (only a person's credential); `orchestrator.yaml` is `peer: person` | Built (strut#274) |
| Person tokens: `POST /peers/tokens { actor, days }` on a standalone strut; a `lab:peer` JWT with a `sub` under stakgraph (stakgraph#1811). The actor is the credential's subject, never a header | Built (strut#274) |
| The person's session: a person-launched turn may open `<actor>/…`, so `<person>/<org>` is one conversation with Jamie on the web and from your Mac | Built (strut#274) |
| Rooms: `callback: { room: true }` delivers `run.end` and `job.update` to a WebSocket room per person on the peer, buffered while you are away (`src/rooms.ts`) | Built (strut#276) |
| Peer files read through your own strut: `GET /peers/:id/jobs/:job/files/…` | Built |
| MCP never crosses: `strut/run-workflow` forwards no `mcp`; a host's MCP tools ride its own launches only | Built, by design |
| Hive's pairing (device code, person-scoped `lab:peer` tokens, Jamie's session id `<person>/<org>`) | Not built (Hive) |

**Not `peer: true` for Jamie.** strut ruled `peer: person` for the
orchestrator: through `job/start` a turn starts a job whose agent has
bash, and Hive's nightly cron gives a peer token to every other swarm of
the org, so `peer: true` would give any spoke a shell on central. A
person can already start the same job through Jamie, so the orchestrator
is open to people, not to struts. "Ask Jamie" is already shared on
strut main; Hive's swarms get it when stakgraph moves its strut pin.

### The flow

1. **Pair.** Strut's ruled shape is the OAuth device flow: in Peel,
   "Add a Hive workspace" asks Hive for a code and opens Hive's pair page;
   you approve the orgs; Peel polls Hive and gets one peer record per org
   (`{ id: <org slug>, baseUrl: <central>/lab, token: lab:peer with sub =
   you, label, description, repos }`) and writes each with `PUT /peers/:id`
   on your strut. Hive also gives Peel a device credential, and Peel
   renews the week-long peer tokens daily through it. Tom's "Connect from
   Peel" link is the fallback with no device flow: Hive (or a standalone
   strut's `POST /peers/tokens`) shows a link holding the address and a
   person token, and Peel's "Add" takes it pasted.
2. **List.** Peel shows each workspace with the workflows it opens to a
   person (`peer: true` or `person`). Peel never holds the peer's token,
   and strut's read-through serves only files today, so this needs one
   more read-through, `GET /peers/:id/workflows`, filtered to those (S6).
   The orchestrator sees one line per peer from `strut/list-peers`
   (label, description, repos).
3. **Ask.** Peel's orchestrator section (strut's
   `personalOrchestratorSystem(person)`) says when a request belongs to an
   org: run that org's orchestrator with `strut/run-workflow { peer,
   workflow: orchestrator, input: { prompt, session: <person>/<org> },
   room: true }` and relay its reply word for word.
4. **The card.** Peel's delta lists `strut/run-workflow` in
   `orchestrator.approve`. It is a registry step, so each call becomes a
   proposal (checked: `approve:` gates any granted registry step,
   `agent.ts:703-745`). The proposal reaches the Mac as an `approve`
   request (R1) and shows "Send this request to stakwork?" with the
   prompt. Two things the check found:
   - **"Always for this workspace" is not a strut feature.** `approve:`
     gates a step type, not its arguments. Peel keeps it as an
     `ApprovalRules` rule keyed by `(strut/run-workflow, peer)` on the
     Mac, which answers the `approve` request without showing the card.
     No strut change.
   - **An accepted call's answer comes back on the next turn.** `decide`
     runs the step in code; its result reaches the agent as a
     `[proposal-result]` line before the session's next prompt. So after
     `decide` the bridge starts a turn, as it does for a late device
     result, and the agent relays Jamie's reply.
5. **Results.** Jamie's reply comes back in the turn. Jobs Jamie starts
   finish later: they post to your room on the org's strut. Strut's plan
   has the desktop app join the room; in Peel that is the **bridge**,
   which runs beside strut on the brain (and on the home server in Phase
   2). It joins each peer's room and turns each `run.end` into a DM
   message from that workspace and a wake turn, the way automation
   results land today. Deliverables are tagged `{ peer, job }` and open
   through your strut's read-through.

### Identity

Your strut never says who you are; the credential does. On Hive's strut
the actor is the pairing token's `sub`: Hive's id for you, the actor Hive
already uses for your Jamie turns, delegations and actor secrets. So a
request from your Mac bills to you, reads your actor secrets there, and
opens your session `<person>/<org>`. A plain peer key with
`x-strut-actor: tom` cannot launch the orchestrator (403) or join your
room. What Hive uses for the `sub` (its actor name today) is a question
for Evan.

## 7. Peel's agent authoring workflows

### The flow

"Research YouTube every Monday and send me the top 5."

1. **The orchestrator decides the shape.** A prompt on a schedule with
   only memory and your chats is an automation on `peel-automation-run`
   (built, PR 7). Anything that needs its own steps, connectors or a
   fixed procedure is a workflow: it calls `job/start { workflow:
   builder, title, prompt }` and tells you it has started.
2. **The builder writes it.** In its own job: drafts the YAML, writes a
   step if needed (`meta/create-step`), test-runs it (`meta/run-step`,
   `meta/run-workflow`), checks claims.
3. **It proposes to publish.** `meta/publish-workflow` is in
   `builder.approve`, so the call becomes a proposal with a rationale.
   Today strut parses a proposal's input against the step's schema when
   it is made, but the publish gate (sealed, and `builder.reach` once it
   exists) runs only when it is applied. It should also run when the
   proposal is made, so
   a workflow you could never publish is refused before you see a card
   (question for Evan 3).
4. **It proposes the schedule.** The new `meta/set-automation` (gated)
   records `{workflow, trigger, input}`, applied after the publish it
   depends on.
5. **The job ends.** `run.end { text, proposals }` goes to the bridge, the
   job's callback.
6. **You approve on a card.** The bridge sends each proposal to your Mac
   as an `approve` device request; the Mac shows the card; your answer
   goes back; the bridge calls `POST /proposals/:id/decide`. strut applies
   it in code.
7. **It runs.** Each Monday strut fires the workflow; its `run.end` goes
   to the bridge (the automation's callback) and the result lands in the
   DM, as automation results do today. "Send me" means the DM: an authored
   workflow cannot reach `sphinx/*`, so it cannot post as you.

### The card

```
New workflow: youtube-weekly-top-5          from "Research YouTube…"
  Searches YouTube (web_search), ranks by views, writes a summary
  Uses: web search · YouTube Data API (YOUTUBE_API_KEY)
  Runs: every Monday at 9:00 (next: Mon 26 Oct)
  [View YAML]                     Publish and schedule · Publish only · Deny
```

What it uses comes from the workflow's closure, in plain words; secrets by
name. Publish and schedule accepts both proposals in order. There is no
Always allow for publishing.

### What Peel needs

| Need | Change |
|---|---|
| The builder seeded and gated | Move the strut pin past #239; Peel's delta sets `builder: { approve: [meta/publish-workflow, meta/create-step, meta/edit-step, meta/set-automation], peer: false }`. **This ships with the pin move,** since the pin otherwise gives the orchestrator an ungated builder |
| The orchestrator may start it | Nothing: `job/start` is already granted |
| `meta/set-automation` | New strut step: create, update, pause or delete an automation on a workflow published `ai`; never on seeded or host workflows. Under `meta/*`, so sealed from the meta surface but granted to the builder |
| Results reach the DM | Its automations get the bridge as callback: Peel's `pointRunEnds` (today: your automations on `peel-automation-run`, `Orchestrator.swift:510-515`) widens to every automation on an `ai` workflow |
| Proposals as cards | The bridge relays `run.end.proposals` as `approve` requests and calls `decide` (runner, Evan's); Peel's card learns the proposal shape |
| `sphinx/*` sealed | Already: Peel's device steps are `sealed: true` |
| Secrets scoped | New in strut: `builder.reach { tools, builtins, secrets }` in the host delta. A publish whose closure names a step, built-in (`bash`, `exec`) or `secretsEnv` outside it is refused; at run time, steps published `ai` read only `reach.secrets`. Peel's default: connectors toggled for Workflows, `web_search`, `web_fetch`, no `bash`, no `exec`, and the secrets of those connectors. `PEEL_BRIDGE_*` and model keys are never in it |

`reach` is the `secretsEnv` allowlist and the per-connector Workflows
toggle in one list. The cheaper version is `STRUT_SEALED` globs (a deny
list); for code an agent writes, an allow list is the right default.

### Seeing and managing them

On the Mac, Automations (built) gets a third group, **Workflows the
assistant made**, below Yours and System:

- Each row: name, schedule in words, last run and its result, next run.
- Row menu: Pause / Resume (`PATCH …/automations/:id { enabled }`), Run
  now (`…/fire`), Delete (`DELETE /workflows/:name`, which strut refuses
  while a run is live and which removes its automations).
- Detail: what it uses (as on the card), the YAML read only, runs, and
  "Change it…", which opens the DM with "Change youtube-weekly-top-5: …"
  so the builder makes a new version behind a new card.
- In the DM: "what workflows do I have?" (`meta/list-workflows` is
  already the builder's; the orchestrator gets `automation/list` widened
  to read every automation, read only).

On the iPhone, the same list read only in Phase 1, from the Mac's
snapshot; pause and delete in Phase 2.

## 8. PR plan

Risk tiers are AGENTS.md's ("How a change ships"). strut and runner PRs
follow their own review; the tier is what Peel's table would give. **E**
marks a PR that needs Evan's agreement first.

| # | Repo | What | Done when | Risk | Waits on |
|---|---|---|---|---|---|
| 0 | peel | This doc | Tom and Evan agree | low | — |
| S1 E | strut | Secret scoping: `builder.reach { tools, builtins, secrets }` in the host delta; the publish gate checks it; steps published `ai` read only `reach.secrets` (store and `secretsEnv`) | Tests: an authored workflow naming `secretsEnv: [X]`, `exec` or a tool outside reach is refused; an `ai` step reading an unlisted secret fails; seeded steps unaffected; Hive unaffected without a `reach` | high (secrets) | — |
| S2 E | strut | `meta/set-automation`, `ai` workflows only, with an optional callback default from the host | Tests: refuses a seeded workflow; in `approve:` it becomes a proposal and applies after its publish | medium | — |
| S3 E | strut | MCP registry: `/mcp-servers` routes, values by secret name (actor first), `mcp/<server>/<tool>` in `agentTools` and `approve:`, `readOnlyHint` default gating, `…/test` probe | Tests: a registered server's tools reach an agent granted `mcp/linear/*` and not one without; a gated tool makes a proposal that `decide` runs; per-launch `mcp` unchanged | high (secrets, untrusted input) | — |
| S4 | strut | `secrets` and `effect` on `StepDef`, in `GET /steps`; set on the existing connector steps | `GET /steps` lists them; old steps without them still load | low | — |
| S5 E | strut | Google token helper (refresh token to access token, cached) and `gmail/*` steps; `gdrive/*` uses the helper | Tests against recorded Google replies; a live check on Tom's account | high (secrets, mail) | S4 |
| R1 E | sphinx (runner) | The bridge relays `run.end.proposals` as `approve` device requests and calls `decide` with the answer, once | On the local stack: a builder job's publish proposal shows as a card; Allow publishes once; a repeat does nothing | high (untrusted input) | — |
| P1 | peel | Move the strut pin to current main with the builder gated (`builder.approve`, `peer: false`) in the delta | The orchestrator starts a builder job; its publish stays a pending proposal; nothing publishes unapproved | medium | — |
| P2 | peel | The card for proposals: the closure in plain words, schedule, Publish and schedule / Publish only / Deny; `pointRunEnds` covers `ai` workflows | Journey: "every Monday, top 5 YouTube videos" ends with one card; approve; Run now lands the result in the DM | high (approvals) | P1, R1, S1, S2 |
| P3 | peel | Connections screen on the Mac: list, paste token, add MCP server, per-agent toggles writing the delta and restarting strut, status | Click check: add Linear with a key, see Connected, ask the DM for "my open Linear issues"; toggle Jobs off and a job no longer gets it | high (secrets) | S3, S4 |
| P4 | peel | Google sign-in (PKCE) writing the refresh token to strut | Sign in on Tom's account; "anything from Evan today?" reads Gmail; a send shows a card | high (secrets) | P3, S5 |
| P5 | peel | "Workflows the assistant made" in Automations: pause, run now, delete, detail | Click check on a workflow from P2 | medium | P2 |
| P6 | peel | Calendar and Reminders by device request (PR 8 revived, plus `reminders.*`) | "What's on Thursday?" answers; "remind me to call Sam at 5" shows a card and creates one reminder | high (a new permission, writes) | — |
| P7 | peel | iPhone: You › Agent shows connections and assistant-made workflows read only, from the Mac's snapshot | From the phone, the list matches the Mac's | medium | P3, P5 |
| H1 | hive | MCP settings write to the org's strut too (registry and secrets) | A server added in Hive appears in `GET {lab}/mcp-servers` | high (secrets) | S3 |
| H2 E | hive + stakgraph | Jamie on strut gets `mcp/*` in the orchestrator and job deltas, writes in `approve:`; proposals on `StrutProposalCard` | Jamie on strut lists Linear issues through the org's server; a write asks first | medium | H1 |
| H3 | hive | Remove `OrgMcpServer` once the Vercel Jamie retires | Builds; no reader left | medium | H2, Vercel Jamie retired |
| S6 E | strut | `GET /peers/:id/workflows`: the peer's workflows open to a person, read through with the peer's token | Two struts: the list shows `peer: true` and `person` workflows and nothing else; the token never leaves | low | — |
| R2 E | sphinx (runner) | The bridge joins each peer's room with that peer's token, delivers `run.end` to the DM as a message from the workspace and starts a wake turn; starts a turn after a `decide` that ran a step | On a two-strut stack: a job started on the peer lands in the DM once; the bridge down through it still delivers on reconnect | high (untrusted input) | R1 |
| P8 | peel | Peers: "Add a Hive workspace" (the device flow, or a pasted link), saved with `PUT /peers/:id`, token renewal; the workspace and its shared workflows in Connections; `strut/run-workflow` in `orchestrator.approve` with the "Send this request to …?" card and Always for this workspace as a Mac rule; `personalOrchestratorSystem` in Peel's section; results in the DM | Two struts (one standing in for Hive): "ask stakwork to review peel#342" shows the card once, Always skips it next time, the review job's result arrives in the DM from stakwork | high (credentials, approvals) | P1, R1, R2, S6; H4 for real Hive |
| H4 E | hive | Pairing for Peel: the device code and pair page, a device credential, person-scoped `lab:peer` minting (`sub` = the person), "my strut peers" renewal, a "Connect from Peel" link as the fallback; Jamie's session id `<person>/<org>`; stakgraph's strut pin past strut#274 so Jamie's orchestrator is shared `peer: person` | From Peel, pairing adds the org; a turn from the Mac and one from Hive's web share one session; a revoked device stops renewing | high (credentials) | — |

```
first   S1  S2  S3  S4  S6  R1  P1  P6  H4     (P1 safe alone: proposals just wait)
then    S5  P2  P3  H1  R2
then    P4  P5  H2  P8
then    P7  H3
```

### Questions for Evan

Paste as they are:

1. OK to scope secrets for AI-published code with a host `builder.reach { tools, builtins, secrets }` allow list, checked at publish and at read?
2. OK to add `meta/set-automation` (ai-published workflows only, gated through `approve:`) rather than widening `automation/*`?
3. Can a publish proposal run the publish gate when it is made, not only on `decide`, and can a pending `meta/set-automation` depend on a pending publish of the same workflow, applied in order?
4. OK to add a persistent MCP registry (`/mcp-servers`, values by secret name with actor first) and let `agentTools`/`approve:` name `mcp/<server>/<tool>`?
5. Gate MCP tools by default unless the server marks them `readOnlyHint`?
6. OK to add `secrets` and `effect` to `StepDef` and `GET /steps`?
7. Should strut own a Google refresh-token helper, with `gmail/*` steps upstream?
8. OK for runner to relay `run.end.proposals` as `approve` device requests and call `decide` itself?
9. Can strut reload `STRUT_HOST_CONFIG` without a restart, or is a restart per toggle fine?
10. For Hive: does stakgraph's `createStrut` take a host delta, so Jamie's orchestrator can be granted `mcp/*`?
11. Should runner also refuse a device request from a run it did not launch or call back for (today it checks only the token, id and kind)?
12. strut ruled `peer: person`, not `peer: true`, for the orchestrator: is that the "Ask Jamie" Hive shares, and when does stakgraph's strut pin reach strut#274 and #276?
13. For peer calls from Peel, the actor is the pairing token's `sub`: which id does Hive put there (its actor name, as in `x-strut-actor`), so it matches Jamie's delegations, actor secrets and `<person>/<org>` session?
14. OK to add `GET /peers/:id/workflows` (a peer's person-open workflows, read through), so Peel can list what a Hive workspace shares?

## 9. Open questions

1. **Two approvals or one card?** Publish and schedule are two proposals.
   *Recommended:* one card that accepts both in order, with "Publish
   only" beside it.
2. **Builder on a peer.** strut's builder can build on another strut.
   *Recommended:* `peer: false` in Peel; revisit when Tom has a home
   server and a Hive swarm to build on.
3. **Hive's promise on credentials.** The org's strut is on our swarms.
   *Recommended:* say "in your org's strut, never in Hive's database",
   and keep Gmail out of Hive until Google's assessment is done.
4. **Who may see an authored workflow's YAML?** *Recommended:* the card
   and detail show it read only; edits only go through the builder, so
   every version passes the gate and a card.
5. **Bash in authored workflows.** Hive's jobs have bash. *Recommended:*
   none in Peel's `reach` to start; a workflow that needs a shell is a job,
   not a schedule.
6. **Claude Code and Codex inside the sandbox.** `acp/prompt` spawns
   `npx` and the agent's CLI, which Peel's sandboxed strut may not allow.
   *Recommended:* try it in a signed Release build before promising it;
   if it fails, Debug builds only until the home server.
7. **MCP OAuth.** Linear and others offer OAuth 2.1 with dynamic
   registration. *Recommended:* pasted keys first; add OAuth in strut
   (Peel opens the browser, strut holds the tokens) when a server we need
   has no keys.
8. **A connector the orchestrator should not hold at all.** Some tokens
   (GitHub with write) are better for jobs only. *Recommended:* the
   Assistant toggle defaults off for anything with writes, on for reads.
