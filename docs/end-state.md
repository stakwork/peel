# Peel's end state

Last updated 2026-10-16. **The picture everything else builds toward**, from
the decisions in [foundation.md](foundation.md). It shows the parts, the path
a message takes, and which phase brings each part. A drawn version is the
"Peel end-state map" artifact (https://claude.ai/artifact/SU2wNEXhw94WB6C5788bCX);
this page is the record.

## In one paragraph

Your assistant lives on a brain you own and is a Sphinx contact. You message
it from your Mac or iPhone as you would a person, so it gets Sphinx's
encryption, offline queues and push for free. On the brain, a small bridge
holds the agent's own Sphinx account and hands each message to strut, which
runs the agent, its memory (Ladybug) and its routines. strut never holds your
keys: anything that needs your account (reading your chats, sending as you,
Calendar) is done by your Mac when strut asks. The brain is your Mac by
default and can move to a home server.

## The map

```mermaid
flowchart LR
  subgraph Devices["Your devices"]
    Mac["Peel on Mac<br/>Sphinx client"]:::built
    Phone["Peel on iPhone<br/>Sphinx client"]:::built
    Chan["Device channel<br/>your Mac reads and sends for the brain"]:::p1
  end
  subgraph Sphinx["Sphinx v2 servers"]
    Broker["Broker + mixer<br/>onion-encrypted, queued"]:::built
    Hub["Push hub"]:::built
    Memes["Memes server<br/>files, encrypted backups"]:::built
  end
  subgraph Brain["The brain: this Mac (P1), home server (P2)"]
    Bridge["Sphinx bridge<br/>from sphinx/runner<br/>agent's own account"]:::p1
    Loop["Agent loop<br/>a strut workflow"]:::p1
    Strut["strut<br/>automations, jobs"]:::built
    Lady["Ladybug<br/>memory + workspace"]:::built
    Snap["Snapshots<br/>handover, then backups"]:::p2
    Budget["Model budgets"]:::p2
    Local["Local model + PII filter"]:::p3
    LN["Lightning node (optional)"]:::p3
  end
  subgraph Net["Internet"]
    AI["Hosted AI<br/>your key"]:::built
    Copy2["Second backup copy"]:::open
  end
  subgraph Keys["Key zone"]
    Signer["Remote signer<br/>signs and decrypts only"]:::p3
  end
  Mac -- "1" --> Broker
  Phone -- "1" --> Broker
  Broker -- "2" --> Bridge
  Bridge -- "3" --> Loop
  Loop -- "4" --> Lady
  Loop -- "4" --> AI
  Bridge -- "5" --> Broker
  Hub -- "6" --> Phone
  Chan <--> Broker
  Snap --> Memes
  Snap -.-> Copy2
  Signer <-.-> Brain
  Phone -.->|"optional VPN (P2)"| Strut
  classDef built fill:#ffffff,stroke:#8b919c,color:#171a20
  classDef p1 fill:#e9f0fb,stroke:#2a62c4,color:#171a20
  classDef p2 fill:#e6f4f1,stroke:#0e8571,color:#171a20
  classDef p3 fill:#f1ebfa,stroke:#7748c0,color:#171a20,stroke-dasharray:5 4
  classDef open fill:#ffffff,stroke:#9a7b2e,color:#171a20,stroke-dasharray:5 4
```

Grey is built today, blue is Phase 1, green Phase 2, violet Phase 3, and
dashed amber is open.

## A message to the agent

1. You write to the agent from your Mac or iPhone, as to any contact.
2. The broker queues it, onion-encrypted, until the brain is online. The
   bridge opens it with the agent's own account.
3. The bridge starts a run of the agent loop in strut.
4. The loop recalls memory from Ladybug and asks a model.
5. The reply goes back through the bridge and the broker, encrypted.
6. The push hub wakes your phone.

If the brain is asleep or moving, the message waits in the queue. Nothing new
is needed for auth, push or encryption.

When a run needs your account, strut sends a request to your Mac as a hidden
control message in the agent's DM. The Mac does it with your keys and sends
back the result. With no device awake, the run shows "waiting for your Mac".

## Phases

| Phase | What it brings | Where the brain is |
|---|---|---|
| Built today | Peel on Mac and iPhone on Sphinx v2; strut bundled in Peel on Ladybug (memory, automations, jobs); the agent loop in Swift on one Mac; `sphinx/runner`, a headless account that receives but doesn't reply | The Mac, inside Peel |
| 1. The agent is a contact | The bridge from `sphinx/runner`, bundled in Peel.app; the agent's own Sphinx account; the loop moves into strut; one conversation, the agent DM, on Mac and iPhone; the device channel, answered by the Mac | Your Mac |
| 2. Always on, can't lose it | In this order: a home server as one Docker bundle, with the whole-brain snapshot and handover from Mac to home server and back; the iPhone answers device requests too (the first device to accept does it); then sealed backups of memory and the whole brain, restored from your words; model budgets, real auth on strut, an optional Tailscale VPN | Your Mac, or a home server |
| 3. Keys off the brain | A remote signer, so your account can run on the brain while your key stays in an isolated key zone; an optional Lightning node on the same signer; a local model and a PII filter before hosted AI; maybe a threshold group (needs threshold ECDSA) | Either, with a signer |

## Milestones

Each milestone is something you can do at the end of it.

| Phase | Milestone | You can… | PRs |
|---|---|---|---|
| 0 | Today | Use Peel on Mac and iPhone as a Sphinx client. Talk to an agent that lives only in the Mac app. Automations fail if Peel is closed or the Mac locked; nothing is backed up | Done |
| 1 | 1. strut answers (dev preview) | Message the agent contact and get a reply from strut; "what did I miss?" reads through your Mac | S1, S2, B1, 1, 2, 4, 5 |
| 1 | 2. It acts for you, safely | Approve sends from a card; automations run in strut ("post to Hive at 13:03" with nobody at the Mac); Calendar | 3, 7, 8 |
| 1 | 3. One conversation everywhere | The same agent thread on Mac and iPhone, with jobs and their files in it | 6, 6b, 9 |
| 1 | 4. On for real | A week on your real account, then the Swift agent removed | 10 (waits on Evan), 11 |
| 2 | 5. Always on | Move the brain to a home server (Docker) and back; the agent answers with your laptop closed | brain-handover.md PRs 1–11 |
| 2 | 6. The phone helps too | Approve and act from the iPhone while the Mac sleeps | To plan |
| 2 | 7. Can't lose it | Memory, then the whole brain, backed up sealed; a fresh Mac gets it back from your words | memory-backup.md phases 1–4, on the handover snapshot |
| 2 | 8. Hardened | Model spending limits, real auth on strut, an optional Tailscale connection | To plan |
| 3 | 9. Remote signer | The agent acts as you with every device asleep; your key stays on a signing device | Direction |
| 3 | 10. Money | An optional Lightning node on the same signer | Direction |
| 3 | 11. Private AI | A local model, and a filter that strips personal details before hosted AI | Direction |

Phase 1 makes the agent useful anywhere, as long as your Mac is awake.
Phase 2 makes it dependable: always on, and impossible to lose. Phase 3
makes it fully yours. Backups moved from Phase 1 to Phase 2 on 2026-10-16
(Tom): handover needs the same snapshot format, so it is built once, and
until then Time Machine's copy of strut's folder is the fallback.

What gates the start of each phase:

- **Phase 1** starts with the build plan in [agent-on-strut.md](agent-on-strut.md)
  (#303, #306). Turning the agent on for real accounts waits
  on Evan's two answers below.
- **Phase 2** starts when Phase 1 is in daily use. It builds on
  [brain-handover.md](brain-handover.md) and [peel-brain.md](peel-brain.md).
- **Phase 3** is a direction, not yet planned. VISION open question 8.

## Where the work stands (2026-10-16)

| Piece | State | Where |
|---|---|---|
| Five foundation decisions | Answered | [foundation.md](foundation.md), #301, #302 |
| Ladybug snapshot round trip | Proven: memory and workspace graphs round-trip losslessly; a whole-brain snapshot needs format 2 | stakwork/strut#193 |
| `sphinx/runner` as the bridge | Spike works on the local stack: key exchange, replies, catch-up, about 360 lines | [research/runner-bridge-spike.md](research/runner-bridge-spike.md), #304 |
| Phase 1 design and PR plan | Merged: the layers, S1, S2, B1 and Peel PRs 1–11 with 6b; not started | [agent-on-strut.md](agent-on-strut.md), #303 |

## Open

- **For Evan:** whether the bridge is a strut mode of `sphinx/runner`, and the
  key derivation scheme (it starts from the seed either way).
- **For Evan:** where the second backup copy goes. A Phase 2 question.
- **For Tom:** how the agent account is funded. Accepting the owner's key
  exchange costs the agent 3,000 msat plus a ping, so either the owner funds
  it on pairing or the bridge adds the owner, who then pays.
- **Sphinx team:** whether the push hub accepts Peel's iPhone app (spike S4).
