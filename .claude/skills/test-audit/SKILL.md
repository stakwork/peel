---
name: test-audit
description: "Invoke whenever writing, changing, reviewing, or auditing Peel's tests. Authoring gate for new tests, a gap sweep for untested contracts, and an audit for low-value, implementation-coupled, or duplicative tests and the test-only seams they keep alive."
---

# Test Audit

Adapted from OpenClaw's `test-audit` skill for Peel: Swift, Swift Testing,
`swift test`, a module-internal engine, and a test suite that is still young.

Three modes, one value bar:

- **Authoring gate** — every new or changed test, at write time.
- **Gap sweep** — find contracts that have no test at their owning boundary.
  While the suite is young this is usually the higher-value mode.
- **Audit** — find tests that re-assert source, duplicate stronger proof,
  couple to implementation, or keep a test-only seam alive.

Optimize for confidence, not test count or deletion count. Read `AGENTS.md`
(the "Tests" section above all), `docs/testing.md` and the phase doc for the
area before judging anything.

## Peel's test layers

| Layer | Where | Runs | Owns |
| --- | --- | --- | --- |
| Unit | `Tests/PeelCoreTests` | `swift test`, offline | parsers, codecs, storage, migrations, engine helpers and refusals that need no server |
| Integration | `Tests/PeelIntegrationTests` | opt-in, `PEEL_INTEGRATION=1`, local stack from `scripts/test-stack.sh` | anything protocol-level: journeys through the real core and broker |
| Benchmarks | `Tests/PeelBenchmarks` | opt-in, `PEEL_BENCH=1` | timing of hot paths; never correctness |
| App check | `scripts/check-app.sh` | offscreen drive file on a dev profile | UI flows; see "Checking the app" in `AGENTS.md` |

Each contract has one primary owner at the strongest layer that can reach it.
Protocol behaviour proven only by a unit test against a hand-built reply is
proving the fixture, not the protocol: its owner is an integration journey.

## Authoring gate

Before adding any test, answer four questions; a missing answer means do not
add it yet:

1. What observable behaviour, invariant, or independent contract does it
   protect?
2. What credible regression makes it fail?
3. Why does existing coverage not already catch that failure? Check the
   file for the area (`AGENTS.md` lists one per area) and the journeys.
   Prefer a new row in a parameterized `@Test(arguments:)` or a shared
   fixture in `TestSupport.swift` over a near-duplicate test.
4. Does it need a seam no production caller needs (a `#if DEBUG` hook like
   `Engine.useTransportForTesting`, a widened access level, an injection
   parameter)? If so, prefer the real boundary. `@testable import PeelCore`
   already exposes internals; that is not a licence to test private
   ordering that a refactor would change.

Then check the test against every [junk pattern](#junk-patterns). A test
that would break under a behaviour-preserving refactor asserts
implementation; rewrite it at the owning boundary before landing it.

Bug regression tests must fail on the pre-fix code for the intended reason
and pass after the fix. Show this once (revert the fix locally, run, restore)
and say so in the PR. One regression at the owner boundary covers the bug.

## Junk patterns

- assertion-free tests (no `#expect`/`#require` that can fail);
- self-comparisons and identity round-trips that cannot fail (encode then
  decode with the same lossy codec, comparing only fields both sides drop);
- copied fixtures, inventories, or expected values produced by the helper
  under test (markup rendered by the renderer, then compared to itself);
- exact source or string greps where a behavioural check is cheap;
- private helper or call-shape tests duplicated by a stronger engine or
  storage test;
- the same contract invoked twice in different files;
- tests whose only purpose is keeping a `#if DEBUG` hook or test-only
  initializer alive;
- dead production code whose only callers are tests;
- stubs that implement the asserted behaviour (a fake transport that
  returns the reply the engine is supposed to produce);
- fixtures that supply the ordering, ack, or stored row the engine should
  produce, or persistence asserted against a table the path never writes;
- negative controls that pass for an unrelated reason (a refusal from a
  different guard, a `Failure` case the path never reaches);
- names that promise more than the input exercises.

## Retention bar

Keep a test when it independently enforces a public type, protocol, config,
migration, storage, security, money, or platform contract. In Peel that
always includes:

- `MigrationTests` and the literals frozen into shipped migrations;
- `Audit*Tests` (secrets, money, network, adversarial input);
- money refusals and `commitAndPublish` failure marking;
- `Engine.Failure` cases and their user-facing words;
- `StateCodec` compatibility with stored state;
- call ordering when the order is observable (commit before publish).

Also keep regressions with a credible failure mode, and source inspection
when it is the cheapest guard that fails on a contract change and survives a
rename. A retained test that fails on the baseline is a possible product
bug: reproduce it and fix the owner rather than deleting it.

Static or slow is not a deletion reason.

## Gap sweep

Map production owners to tests, then rank untested owners by risk:

1. money (`MoneyWork`, payments, invoices, `commitAndPublish`);
2. storage and migrations (anything that writes the profile database);
3. the engine contract (`run`, `commit`, `complete`, `receive`, reconnect);
4. parsers fed by other people (codes, links, markup, metadata);
5. everything else.

For each gap record: the owner (file and symbol), the regression that would
ship unnoticed, the layer that should own the proof (unit, journey, app
check) and why, and any seam the test would need. Prefer fewer
high-confidence gaps over a long speculative list. `scripts/risk.sh` and the
phase docs' "open" lists are good inputs.

## Discovery

Keep discovery read-only and report evidence before editing. For a broad
sweep, run parallel read-only lanes along owner boundaries, for example:

- engine core and connection (`Engine*.swift`, `EngineTypes.swift`);
- storage, reads and migrations (`Storage*.swift`);
- money (payments, invoices, sats, templates);
- messages, tribes, contacts, markup, media;
- calls, web, notifications;
- the integration journeys and `TestSupport`.

Before judging a candidate, read the whole test, its production owner,
callers, callees, overlapping tests and journeys, and `git log` for both.
When a test claims behaviour of the core (`Sphinxrs`) or GRDB, read the
binding or dependency source rather than trusting the name.

## Candidate evidence

For each audit candidate, record before editing (a missing field means not
ready):

- test name and location;
- what failure it can actually detect;
- non-test callers of the covered code or seam;
- the stronger remaining proof, or why none is needed;
- history and why the test or seam exists;
- production or test-support code its removal unlocks;
- risk and the focused `swift test --filter` command.

Mark each one `R` (retain, naming the contract), `F` (retain, fix a vacuous
assertion), `C` (consolidate into a named owner), or `D` (delete, naming the
remaining proof).

## Edit shape

One coherent owner-boundary batch per PR. Delete test-only hooks and dead
production paths a deletion unlocks rather than keeping aliases. Move
retained regressions into the file that owns the area. Do not add
replacement tests that restate the same implementation.

When a test file is added, removed or renamed, update the file list under
"Project layout" and the "Tests" summary in `AGENTS.md`, and
`docs/testing.md` if a journey changes.

## Validation

1. `swift test --filter <Suite or test>` for the owner and its siblings.
2. `swift test` for the whole offline suite.
3. If a journey's area was touched and the stack is available:
   `PEEL_INTEGRATION=1 SPHINX_BIN_DIR=<cargo target>/debug swift test --filter PeelIntegrationTests`.
   Never run the local LiveKit room or anything that opens a window
   unasked.
4. `git diff --check`, then `git diff --numstat`: report production and
   tooling lines separately from tests and test support.

## Landing

Commit, push or open a PR only when asked. In a worktree, never use bare
`git stash`.

## Handoff

Report:

- for a gap sweep: the ranked gaps with owner, regression, and layer;
- for an audit: the R/F/C/D ledger, removed categories, and seams deleted;
- retained false positives and why they stay;
- proof actually run (commands and results), including any that could not
  run and why;
- production versus test LOC;
- named follow-ups.
