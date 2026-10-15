# Peel: what it is for

Draft, 2026-10-15. The goal of Peel and the experience it must give, written
for someone who knows nothing about how it works. Everything else in `docs/`
serves this page. When a plan conflicts with it, change the plan or change
this page on purpose.

## In one sentence

Peel is a private assistant that lives with you, remembers what you tell it,
runs errands within limits you set, and answers to you alone.

## Guiding principles

1. **Privacy is a human right.**
2. **Personal agents will be a powerful helper to humans.**
3. **They must be controlled fully by the single human.**
4. **Security and backups apply the lessons of bitcoin self-custody. Losing
   data or a security fault is not allowed.**

In plain words, for the person using it:

- **Private:** what you tell it stays with you. No company reads it, sells
  it or trains on it.
- **Helpful:** it saves you time from the first minute and gets more useful
  the longer you use it.
- **Yours:** it does what you say, only what you say, and you can see and
  stop everything it does.
- **Safe:** you cannot lose it, and nobody else can take it over.

## How we talk about it

People should never need to learn our system to use it. Use the words on the
left. The words on the right are for builders and never reach the screen.

| Say | Not |
|---|---|
| your assistant | agent, front agent, LLM |
| errand | job, run, sub-agent |
| routine ("every Friday…") | workflow, automation, Strut |
| what it remembers | memory graph, ontology, episodes, facts |
| spending limit | budget, cap, macaroon, delegation |
| at home / always on | brain, home server, swarm, node |
| your recovery words | mnemonic, seed |
| asks you first | approval gate, grant |

## The experiences

Each one is told from the user's side: what you do, what you see, and what
you never have to think about. If an experience needs a manual, the design is
wrong.

### 1. It works the first minute

You open Peel, and your assistant is already there, in your chats like a
friend. You connect your AI account once (sign in to a subscription you
already have, or paste a key) and it answers. That is the only setup: no box
to buy, no server to run.

You message it from your phone or your laptop, the same chat on both.

### 2. It remembers you

You tell it things once: your sister's birthday, that you don't eat meat, the
plumber's name, that you're moving in March. Next time, it already knows.

Ask "what did I say about the lease?" and it shows your own words and when you
said them, not its guess. Ask "what do you know about me?" and you see it all,
in plain sentences. Fix anything that is wrong. Tell it to forget something,
and it is gone.

### 3. It catches you up

"What did I miss in the climbing group?" A short summary of what matters to
you, with links to the messages.

"Help me reply to Sam." It writes a draft; you change it and send it. It never
speaks as you without showing you first.

### 4. It runs errands while you get on with your day

"Find a dentist near me that's open Saturdays." You put your phone away. When
it is done, it messages you with the answer and how it got there. If it needs
a decision, it asks, and waits.

Some errands cost money: a paid search, a report, a bigger AI. You give it a
spending limit, like handing someone a prepaid card: "spend up to $5". It
cannot go over. When the money runs out, it stops and tells you what it found
so far and what it spent.

You can have several errands going at once. You always see what each one is
doing, and you can stop any of them.

### 5. It does things for you regularly

"Every Friday, tell me which bills are due." "Let me know when train tickets
to Leeds drop under £40."

It says back what it understood, in one sentence: "Every Friday at 9 am I'll
check your bills and message you a list." You say yes. All of these sit in one
list you can pause, change or delete.

### 6. It asks before it acts for you

Anything that speaks or pays for you (sending a message, paying, posting,
signing up) it asks first, and shows you exactly what it will do.

When you trust it with something, you say "you don't need to ask for this
again". You decide how much freedom it has, one thing at a time, and you can
take it back.

### 7. It lives with you, not with a company

*This experience is still being worked out (see open question 2). What is
fixed: it works fully without a box at home, and it works with one.*

At first it lives on your computer. When you want it on all the time, even
with your laptop closed, you move it to a small box at home. Moving it is as
easy as setting up a printer, and everything it knows comes with it.

Nothing about you is kept on a company's computer. When it needs a big AI
service for a hard question, it sends the question without your name or
details attached. If you prefer, it uses only AI that runs in your home.

### 8. You can see everything and stop anything

One place shows what your assistant is doing, what it has spent, what it
remembers and what it may do without asking. One button stops everything.

### 9. You can't lose it, and nobody can take it

When you start, you get twelve recovery words. They are the key to
everything: your chats, your money, your assistant and everything it
remembers. Peel checks you wrote them down correctly before you rely on them.

Lose your phone: install Peel, enter your words, and everything is back. Lose
the box at home: set up a new one, enter your words, and everything is back.

Your words never sit on the box at home or on any server. Nobody, us
included, can read your assistant or act as it.

## For builders: what the experience asks of the system

The experiences come first. These follow from them.

| Experience | What it asks of the system |
|---|---|
| 1. Works the first minute | One step to connect the user's own AI account: a subscription sign-in or an API key. A built-in model needing no account may come later, not now. The assistant is a Sphinx contact, so every client reaches it. |
| 2. Remembers you | Recall must return the speaker's own words with date and chat (Episodes), not only extracted facts. "What do you know about me", correct and forget are first-class. Facts expire, never overwrite. |
| 3. Catches you up | Read access to chats and tribes; drafts, never sends, without approval. |
| 4. Errands | Jobs in Strut. Each errand gets its own identity and a spending limit enforced outside it: model spend by a Mothership macaroon attenuated from yours (it can only narrow); sats by its own Sphinx balance. A graceful stop when the limit is reached: write up, then end. Strut today fails the step on a 402. |
| 5. Routines | Strut workflows and automations, built from plain words, confirmed back in one plain sentence before they run. |
| 6. Asks first | Effects are labelled and gated. Grants widen only by the user's signed action; an agent can only narrow its own limits. |
| 7. Lives with you | Everything works with no home server, and again with one. The brain runs on the user's machine and moves (one writer, never synced) to an always-on box. Pairing must be one step: scan or link, no URLs or keys typed. A PII layer before any hosted model. A local model option. |
| 8. See and stop | One record of runs, spend and memory changes that the agent cannot edit. A kill switch that revokes keys. |
| 9. Can't lose it | Everything derives from the twelve words. Errand and assistant identities use a hardened derivation (for example `hkdf(seed, "peel agent <n>")`), so a leaked agent key never reveals the root. Sphinx's per-contact child keys cannot serve: they are unhardened under an xpub the server sees, and broker login needs the root key. Backups encrypted with a key from the words, to more than one place, with restore checked at setup. The box at home holds derived keys, never the words. |

## Decided

- **One assistant first** (2026-10-15). Peel starts with a single
  assistant. Starting more, each with its own identity and spending limit,
  comes later.
- **Bring your own AI account** (2026-10-15). The user connects an API key or
  a subscription. A built-in model needing no account is for later, not now.

## Open questions

1. **Errands vs assistants on screen.** With one assistant first, errands are
   its work. When users can start more assistants, how do they tell the two
   apart?
2. **With and without a home box.** Experience 7 must work both ways. How do
   routines and errands (Strut automations) run when the assistant lives on a
   laptop that sleeps, how do they run on a box at home, and what does the
   user see when they move from one to the other?
3. **Where the money sits.** In Sphinx v2 the balance is a ledger at the
   server (LSP); your key signs messages, not channels. A home Lightning node
   with a separate signing device is a different model. Which one does "safe,
   like bitcoin self-custody" promise?
4. **A lost phone.** Every device holds the same words, so one phone cannot
   be cut off on its own. Per-device keys need a protocol change.
5. **Privacy toward AI services.** No PII layer exists yet. What counts as
   "your name or details", and how does the user see what was sent?
6. **"Your words, not its guess."** Episodes keep the words, but recall and
   merges work on facts. Quoting the source with its date needs work.
7. **Plans disagree** on where the agent loop runs (Swift in Peel or Strut
   on the brain), Ladybug or Neo4j on the box, and whether the phone talks to
   Strut directly or only through Sphinx.
