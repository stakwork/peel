# Phase 8 — Audit before sharing

Status: planned. Runs after the feature phases (1 to 7, and 10) and after
Tom has used the app on his real account for a while. Nothing goes to the team before it
passes. Added 2026-10-07.

## Why a separate phase

The shipping chain in `AGENTS.md` reviews one diff at a time. It cannot see
what accumulates when many sessions build in parallel: the same thing written
twice, naming and error handling that drift between files, abstractions that
grew sideways, code kept "just in case", tests that assert nothing, docs that
describe last month's design. That is what reads as slop to a colleague who
opens the repo cold, and it is the reason this phase exists: one whole-repo
read, against a written bar, with the features frozen.

## Rules

- **Features are frozen.** Only fixes land while the audit runs.
- **The reviewer has no history.** A fresh session, or a person, with the repo
  only and none of the conversations that built it. If the code needs the
  conversation to make sense, the code fails.
- **Findings are fixed, not filed.** The audit ends with a clean pass, not a
  backlog. Each fix goes through the normal chain. A finding deliberately left
  is written down with the reason.
- **Tom does the manual pass himself,** on his real account, phone and Mac.
- **Done means** a colleague can clone, build, run and read the engine in an
  afternoon, and nothing in it embarrasses us.

## The checklist, in order

1. **Cold read.** `AGENTS.md`, `docs/PLAN.md`, one phase file, then
   `Engine.swift` top to bottom. Time it. Anything that needed explaining gets
   a comment or a rewrite.
2. **Duplication and drift.** The same logic in two places (queries, message
   parsing, formatting, date handling); names and error handling that differ
   between files written by different sessions; dead code (unused functions,
   settings, CLI commands, flags); leftover prototype or debug code; comments
   that no longer match the code.
3. **Boundaries.** `PeelCore` has no UI types and no single-account
   assumption; every user action is an engine operation; message conventions
   live in the engine, not in views; views never reach storage directly. These
   are the `docs/agent-native.md` rules, checked rather than assumed.
4. **Concurrency.** Actor isolation holds; no `@unchecked Sendable` or
   `nonisolated(unsafe)` without a reason written beside it; no task outlives
   its owner; cancellation is handled where work is long.
5. **Storage.** Migrations run in order from v1 on a copy of a real database;
   every query that scans has the index it needs; no unbounded reads; the
   profile lock and read-only mode still behave with two processes.
6. **Security, with the threat model written down first.** Seed, PIN and
   Keychain handling; nothing secret in logs or stdout (grep for it, including
   the core's own debug lines); TLS and the trust-on-first-use path; the
   message trust rules (sender from signature, type 33 only when sent by me);
   every untrusted input (message JSON, invites, URLs, attachments, web apps in
   `WKWebView`, local runtime grants). Dependencies: each package pinned, its
   licence and maintenance checked, the vendored core matched to its lock.
7. **Tests that matter.** Not a coverage number: a list of the behaviours that
   would hurt if they regressed, each with a test. At least: state codec
   round trip, migrations, message trust rules, the PIN box, the restore plan,
   send and retry, and the engine against the local test stack in a form a
   machine can run.
8. **Failure behaviour.** Offline, server down, wrong PIN, corrupt state,
   certificate change, restore interrupted, out of sats. Each is handled and
   shown; no `try?` that hides a real failure; no crash.
9. **Performance.** Launch time, memory with a real history, nothing blocking
   the main thread (PIN derivation included), keep-alive and battery on the
   phone.
10. **Docs match the code.** `README.md`, `AGENTS.md`, `docs/PLAN.md`, the
    phase files and `docs/design/` describe what was built, with stale
    "planned" lines removed.
11. **The repo itself.** History readable, no secret ever committed (scan the
    whole history, not the tree), licence file present, `.gitignore` right, no
    checked-in build output or worktrees.

## Output

- `docs/audit/<date>.md`: what was checked, what was found, what was fixed,
  what was left and why. It goes to the team with the repo.
- The checklist above becomes the bar in `AGENTS.md` for new code, so the
  next audit is smaller.

## Checkpoint, earlier

Slop compounds and is cheapest to remove early. Once phase 3 lands, run items
1, 2, 3 and 10 as a half-day pass and fix what they find. Record it here.
