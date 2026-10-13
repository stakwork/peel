# Finding the bugs we have not seen

Status (2026-10-11): proposed, for the team. Base: `origin/main` at `79b0fe0`
(#164). The first pass's findings, and the 205 bugs this draws on, are in
[reviews/2026-10-11-bug-hunt.md](reviews/2026-10-11-bug-hunt.md).

Tom's question: Peel is at parity with the official apps, and its
architecture looks better. How do we get to no bugs that matter before the
team relies on it? He listed what that means:
- no lost sats;
- no lost accounts;
- restores and imports that come back whole;
- nothing that makes the app feel broken.

Using the app shows the UI bugs. How do we see the logic underneath? And
which of these finds it: more tests, the `test-audit` skill (#159), more
use, or reading the code?

This answers from the repo's own history and proposes the work. Phase 8
([phases/08-audit.md](phases/08-audit.md)) stays the whole-repo read with
features frozen. This is the part of it that hunts bugs, and it starts
now rather than at the freeze.

How I put it together:
- I read every PR, every commit on `main`, the open `fix/*` branches, the
  reviews and the phase journals.
- I classified the 205 bugs found so far by who found each one, where it
  lived and how bad it was.
- I traced money, accounts and restore, the engine and sync, and the UI
  against the core, the mixer and the official Mac app.
- I checked every finding marked verified on both sides by hand.

## The short answer

1. **Each method finds its own kind of bug.** Of the 124 bugs that reached
   `main`:
   - written reviews and audits found 50, including 7 of the 10 that lost
     or stranded money and 5 of the 6 that put a secret or an account at
     risk;
   - Tom found 32, each with a visible symptom;
   - the journeys, measurement and unit tests found 9 between them.

   Before merge, agent review of each PR caught 74 more. The per-PR chain
   catches logic inside one diff. Reading against a written list finds
   the serious bugs that get past it. Tom's use finds what can be seen.
   Tests hold the line once a bug is known.
2. **The serious bugs have been at the boundaries with the server and the
   core.**
   - Nineteen bugs came from a false belief about the server, and 16 of
     them got past review.
   - Fourteen came from a false belief about the core, and 7 got past.
   - The payments review put it in one line: "What is wrong comes from
     what Peel believes about the server and the core."
   - This pass found two more of the same kind:
     - the core we link lacks seven of upstream's September client
       security fixes, while `Engine.swift` and `AGENTS.md` describe one
       of them as already there;
     - nobody here knows which server version production runs.
3. **Many logic bugs show up as two copies of one fact that disagree.**
   Peel keeps several such copies:
   - its rows and the server's history;
   - the sender's view and the recipient's;
   - two devices of one account;
   - the live account and the same account restored from its words;
   - Peel and the official app reading the same message.

   The UI shows one copy at a time, so a disagreement stays invisible
   until someone compares. Most of the payments review's findings came
   from comparing two copies by hand. Nothing compares them by machine
   yet.
4. **Interruptions are argued in prose, not tested.**
   - The journeys cover a dropped connection and one relaunch, and #164
     added unit tests for a connection cut partway through a money send.
   - No test kills the app between a money send's commit and its publish,
     or cuts a signup, a restore or a purchase short.
   - This pass found two ways to lose sats in exactly those windows (N2
     and N3).
5. **Nothing runs the tests, and nothing records what happened.**
   - There is no CI. The 544 unit tests and the 22 journeys run when
     someone remembers to run them.
   - PeelCore and PeelApp log nothing, so a wrong state on Tom's real
     account leaves no trail.
6. **Only Tom's account has run on Peel, and only for four days.**
   - It is the one real official-app account restored into Peel so far.
   - The official apps have years of accounts with odd histories.
     Importing those is where the next restore bugs will come from.

## The questions, in short

- **Is it testing the app?** That finds what you can see. Keep doing it,
  with more people, other accounts and a script (sections 7 and 8).
- **How do I see the logic bugs underneath?** Read the code against a
  written list of beliefs about whatever it talks to (section 2), and make
  the copies of each fact compare themselves (section 3).
- **Unit, integration, end to end?** Unit tests hold the line. The
  journeys can find more than their 3 once they check that records agree
  and a machine chooses the steps (sections 3 and 4). For the UI, end to
  end means snapshots and drive files, not XCUITest (section 7).
- **The `test-audit` skill?** It makes the suite trustworthy. Its first
  two runs fixed four assertions that could not fail and removed five
  duplicates (#161), then pinned the double-pay paths that had no test
  (#164). Neither found a product bug, and the skill is not built to. Use
  its gap sweep as one input to section 2, and its gate on every test this
  plan adds.
- **Using it more, or reading the code?** Both, aimed: more people on
  their own accounts, in stages (section 8), and reading pointed at the
  boundaries nobody has read that way yet (section 2).

## What each method has found here

| Method | What exists | Reached `main` / caught before | Blind to |
|---|---|---|---|
| Agent review of each PR (`/code-review`, `/security-review`; tiered by `scripts/risk.sh`, with an independent review for high risk, since #132) | every PR | 13 / 74 | Anything outside the diff: runtime layout, the real server, effects across PRs. 37 of 48 SwiftUI and AppKit bugs and 16 of 19 false server beliefs got past it |
| Written reviews and audits (a threat or belief list, traced in our code and theirs) | seven in `docs/reviews/` before this one, not counting the parity sweep | 50 / 2 | Timing, and anything not on the list. Two of their "holds" were later overturned |
| Tom using the app | daily on his real account since 2026-10-07 | 32 / 3 | Anything with no visible symptom, and what one person on one account never does: another device, an offline contact, a restore, someone else's message formats |
| Integration journeys (real core, local stack, wire tap) | 22 | 3 / 1 | Lightning, production's server version, crashes, the official apps, combinations nobody wrote down |
| Unit tests | 544 | 2 / 0 | The core and the server: sends, receipts and payments run against fakes |
| Measurement (benchmarks, profiling) | `Tests/PeelBenchmarks` since #158 | 4 / 0 | Correctness |
| Parity sweep against the official Mac app | one, 2026-10-09 | 2 / 0 | Behaviour behind the screens |
| Offscreen app check (`scripts/check-app.sh`) | used per PR; no drive files kept, no assertions | — | Clicks, scrolling, anything not snapshotted |

Eighteen more were found in passing, or by a route nobody wrote down. The
history also shows:

- **Repeat offenders.** The message list had nine bugs reach `main`, and
  Tom found eight of them. Payment status and history had about twenty.
- **Fixes that broke something.** Five fixes broke something else after
  merge, and one did not fix its bug. #80 stopped new accounts adding
  contacts. #110's fix cost 25–30% idle CPU the same day.
- **Bugs in the tests.** Three could pass without testing their target
  (#32, #37, #151), and #161 fixed four more.
- **Checks never written down.** About twenty PRs say parts of the change
  were never clicked or driven. Eight investigations built a seed or a
  harness and threw it away.

## What this pass found

The details, the smaller items and what held up are in
[the review](reviews/2026-10-11-bug-hunt.md).

| # | Finding | Severity | Confidence |
|---|---|---|---|
| N1 | The core we link lacks seven of upstream's client security fixes, among them the sender check on contact records. The official apps ship the same core | contact keys and routes can be rewritten by anyone; three remote panics | verified |
| N2 | A signup whose registration reply is late or lost deletes the words of an account the server has already registered and funded | the invite's sats and the account, lost | verified |
| N3 | A paid attachment's key is never sent if the seller's Peel stops between storing the purchase and answering it | the buyer's sats, lost | verified in Peel, not run |
| N4 | History catch-up starts above the newest stored message, so a catch-up cut short by a quit leaves a permanent gap | messages lost | logic verified, timing inferred |
| N5 | Nothing makes sure the words were written down; the confirmation is a checkbox held in view state | the account, lost later | verified |
| N6 | Nobody here knows which server version production runs | every belief about the server untested | verified in the deploy config |
| N7 | A tribe text whose publish failed part-way is marked failed and offered for Retry, which pays and posts again | a few sats, a double post | verified |

## The plan

### 1. Fix what this pass found

- **N2, N3, N5, N4 and N7**, in that order. Each goes through the normal
  chain at the high risk tier, with a regression test that fails before
  the fix.
- **N1** needs `sphinx-rs` moved to v0.6.29 or later and a library built
  from it: by the Sphinx team for every app, or by us. Until then, Peel
  refuses a live contact record that would rewrite a contact who is
  already ready.
- **N6** is a question for the server team.

### 2. Read the boundaries

Written reviews found most of the serious bugs. The ones that worked
wrote down what Peel believes about the other side, then checked each
belief in our code and in theirs. The payments review's three false
beliefs came that way, and so did the threat list in the keys and money
audit (Audit A).

Do the same for the boundaries nobody has read that way:

- **Restore and history.** What the history code assumes about pages,
  counts, order and duplicates. N4 came from this, and so did the
  duplicate page in the review.
- **Two devices of one account,** Peel and the official app at once.
  What each assumes about the other:
  - which messages are "from me";
  - read markers;
  - tribes joined on the other device;
  - both devices answering one key exchange.
- **Tribes.** Prices, escrow and its refunds, replays and purchases,
  against the tribes server.
- **Lightning.** Route hints, the async path for invoices, and what the
  mixer records when a payment stays pending.
- **The core update itself.** Before a new rev is linked, read the diff
  from `bd9e140` for every behaviour Peel relies on.

Each review writes its beliefs in a table:
- each belief is marked as checked by a test, checked by reading, or not
  checked;
- a belief counts as checked only when its other side was read, not
  assumed;
- the unchecked ones become journeys, or steps in the walk (section 4).

### 3. Make the records compare themselves

Write down which records must agree, and check them by machine. Add an
agreement check, `Agreement`, to `Tests/PeelIntegrationTests`. Every
journey runs it at its end, and the walk in section 4 runs it after every
step. It checks:

- **Money.**
  - For each account, the change in the server's balance equals the
    history's rows in minus out, plus refunds.
  - Peel's stored balance equals the server's once settled.
  - Payments matches the server's history row for row, apart from a short
    written list (pings, key exchanges).
  - Nobody is shown more received than the history holds.
  - No money row is still pending a minute after connecting, unless its
    recipient is offline on purpose.
  - At most one outgoing payment goes out per action.
- **Messages.**
  - Every delivered message appears once on the other side, with the same
    content.
  - A deleted one stays deleted.
  - Nothing appears that nobody sent.
- **Devices.** Two devices of one account, once quiet, agree on contacts,
  tribes, messages, statuses, read markers and mutes.
- **Restore.** At the end of every journey, each account is restored from
  its words into a new directory and compared with the live one. Every
  difference is either on a written list (invites and invoices made here,
  local settings) or a bug. This alone would have caught the payments
  review's F4 and F8.

It needs three things:
- the server's own balance, from the mixer's `GET /api/balance`, behind
  its testing-only `http-api` feature;
- a helper that fetches the whole payment history;
- a reader for the wire tap's recording, to count publishes per tag.

In the product, read-only, and never showing message text, words or keys:

- **`peel check --profile <dev>`.** The same comparisons against the
  server's history, for development profiles.
- **Account › Check this account.** The money and history comparisons, for
  real accounts. It reports a list of disagreements to paste into an
  issue.
- **A local event log.** A ring buffer in the profile, with "Copy
  diagnostics" to export it.
  - It records what the engine did: core calls, tags, statuses, counts
    and failures. It never records content, keys or words.
  - The official app has a diagnostics window; Peel has nothing.
  - Without a log, a wrong state on a real account cannot be explained
    after the fact.

### 4. Let a machine choose the steps

The 22 journeys cover the cases someone thought of. The payments review's
F1 and F2 needed a combination: an offline contact, a second payment and a
balance near its limit. A random walk finds combinations.

- **The walk.**
  - The cast: three accounts, a second device for one of them, and a
    tribe owned by one of them.
  - Each step picks one of:
    - send, reply, delete;
    - pay, including the whole balance, the balance less the ping, and
      one sat;
    - boost; request and pay; join and leave; a paid post;
    - buy an attachment; invite and cancel;
    - take an account offline; restart an engine from its directory;
    - restore a device; restart the mixer.
  - After each step it waits for things to settle and runs the agreement
    check.
  - It is seeded. On a failure it prints the seed and the shortest prefix
    that still fails, so the failure can be replayed.
  - It is built on `Stack`, `Person` and `Bank`, which exist.
- **Faults.**
  - The wire tap can go down, come up or freeze. It also needs a one-way
    mode that drops the broker's replies and keeps ours, for N2.
  - Restart the mixer in the middle of a payment
    (`test-stack.sh mixer <dir> real`).
  - Close an engine in the middle of a call.
- **Crashes.** Use `kill -9`, so nothing gets to clean up.
  - Run the CLI as a subprocess on a development profile, start a money
    operation, kill it at a random moment, reopen, and run `peel check`.
  - A few hundred runs a night cover the windows the reviews argue about
    in prose: commit then publish, async pay then ping, purchase then key.
  - The engine gets no test-only hooks for this.
- **Thread Sanitizer.** Run the unit suite and the journeys once with
  `swift test --sanitize=thread`. It costs little, and 26 bugs so far were
  about concurrency.

### 5. Test against what people actually talk to

- **Production's server version.** The stack runs it beside master (N6),
  and every journey runs on both.
- **Lightning.** Put a regtest `bitcoind` and CLN behind the mixer. The
  core repo's own client tests already run against a regtest swarm with
  CLN (`wasm/test/swarm`). Invoices, route hints, fee reserves and
  failures (no route, expired) have never run at all.
- **The official apps' message formats.** Take golden JSON for every
  message type from `formatMsg` in `sphinx-mac-v2`
  (`SphinxOnionManager+ChatExtension.swift`). Compare as dictionaries,
  both ways:
  - what Peel builds must match it;
  - what the official app builds must parse to the same fields.

  Take the fixtures again whenever the official app changes. Today three
  are copied by hand, and the rest is checked by reading.
- **The official apps as the other party.** A checklist for the bug bash
  (section 7):
  - each message type sent from Peel and read on the official iPhone,
    Android and Mac apps, and the reverse;
  - one account on Peel and the official app at the same time.

### 6. The account itself

- **A fixed derivation vector.** Twelve known words go to a known seed and
  pubkey, with the values taken from the official app's build of the
  core. This one test catches a core update that would make every restore
  register a new, empty account.
- **N2 and N5.** Fixed, with a journey for each.
- **Forget on the lock screen.** It asks for the words or shows the
  balance first. This reopens Audit A's S21, which kept it unguarded by
  design.
- **A restore matrix.** Run it by hand once, then whenever the core or the
  history code changes:
  - accounts made on Peel, the official iPhone app and the official Mac
    app;
  - each with contacts, tribes, payments, paid attachments and more than
    300 messages;
  - each restored into Peel and compared with the device it came from;
  - restores interrupted by a quit and by a dropped connection, then
    resumed.
- **A change of signing team.** Write the migration down before any build
  is signed by another team: a last build under the old team makes each
  person confirm their words. Decide it before the team gets a build.
- **Migrations.** Move the schema snapshot from v17 to v23. Open a small
  database from each shipped schema through `Storage`, made from a
  throwaway account and never from Tom's.

### 7. The UI

UI bugs are found by eye, and they come back in the same places: the
message list, focus and keyboard, floating panels, and idle CPU.

- **A regression net.**
  - A committed seed account.
  - Check mode made deterministic: one injectable clock, no connection,
    no animation.
  - Baseline snapshots of about twelve screens, in dark mode, compared
    with a tolerance in the ship chain's verify step.
  - Then drive files for the top journeys:
    - sign up with an invite, which has never been done in the app;
    - restore;
    - send a message;
    - pay through the confirm step;
    - join a tribe.

    These need named steps or a click step, and `expect` steps against
    the model.
  - Commit the seeds and drive files, so the next investigation does not
    build them again.
- **The message list's own check.** Nine bugs reached `main` through this
  one list, so it gets a check of its own: a drive against the seed that
  logs the distance to the bottom after each of:
  - opening a chat;
  - sending;
  - the composer growing;
  - ⌘F.
- **Wording.**
  - A unit test over `PeelError.readable` that refuses Swift debug text
    and SQL.
  - The places that show a `Failure` on its own (`ProblemText`,
    `FormFooter`, the notice bar) give it a sentence of its own, not the
    bare fragment.
- **A bug bash.** Two ninety-minute sessions with three or four people who
  have not used Peel, each working from a script:
  - "You use Sphinx on your phone. Restore your account into Peel and go
    about your day."
  - "A stranger sends you an invite."

  Everything goes in one table: what, where, how bad. This pass's list of
  first-hour problems is the starting point:
  - restore asks for your name again;
  - a one-tap boost sends 100 sats, whatever the official app had;
  - a contact you add stays invisible until they answer;
  - ⌘, does nothing (#131);
  - errors read as debug output;
  - after sleep or a Wi-Fi drop, "Not delivered" stays up after the
    resend;
  - a ⌘F result lands on the newest message instead of the match. #160
    notes this, and nothing tracks it.

### 8. Real use, in stages

- **Stage 1.** It runs inside phase 8, after rows 1, 2 and 9 of the table
  below.
  - Three to five people from the team opt in, restore their own
    official-app accounts into Peel, and keep a small balance (under
    10,000 sats).
  - They use Peel for a week beside the official app, and report with
    Copy diagnostics and Check this account.
  - This is the import test, with real, old and odd accounts.
- **Stage 2.** The rest of the team, once the list under "Done means" holds.

Move on from stage 1 after a week with no new money, account or interop
bug.

### 9. Every bug, once

- **A test and a log line.** Every bug gets:
  - a regression test at the layer that owns it, which fails before the
    fix (the rule in the `test-audit` skill, #159, still open);
  - a line in one bug log, kept as GitHub labels: area, severity, where
    it lived, how it was found.
- **A sweep of its class.**
  - The forged-"ours" fixes in flight each patch one reader of `fromMe`.
  - The class is "a field the core reports that we trust".
  - The sweep is one rule at the entry point. The three branches need to
    agree on it; today they disagree.
- **A weekly count.** Count which method found what, and move the effort
  to whatever is finding bugs.

### 10. CI

A self-hosted Mac runner: a Mac mini, or Tom's Mac at night at background
priority.

- **On every PR:** the build, the unit suite and `risk.sh`.
- **Nightly:**
  - the journeys on both server versions;
  - an hour of the walk;
  - the crash runs;
  - the snapshot comparisons.
- **Setup:** the runner takes the core library from `build-ffi.sh` with the
  lock check, and needs an Apple Development identity for the app check.

## Order and size

Sizes as in the reviews: S is an afternoon, M a day or two, L more.

| # | Work | Section | Size |
|---|---|---|---|
| 1 | N2, N3, N5, N4 and N7 fixed, with a regression test each | 1 | S or M each |
| 2 | N1: Peel's guard now; a core at v0.6.29 or later once `sphinx-rs` has one; the rev check in `build-ffi.sh` | 1 | S now; L outside Peel |
| 3 | Belief reviews: restore and history, two devices, tribes, Lightning, the core diff | 2 | M each |
| 4 | The agreement check, and the restore comparison in every journey | 3 | M |
| 5 | CI on a self-hosted Mac | 10 | M |
| 6 | The walk, the one-way tap, crash runs, Thread Sanitizer | 4 | L |
| 7 | Production's server version in the stack | 5 | S, once the tag is known |
| 8 | Golden JSON, the derivation vector, the migration snapshot | 5, 6 | M |
| 9 | Event log, Copy diagnostics, Check this account, `peel check` | 3 | L |
| 10 | The restore matrix; the signing-team migration written down | 6 | M |
| 11 | The UI net, then drive files for the top journeys | 7 | L |
| 12 | The bug bash and its first-hour fixes | 7 | two sessions, then fixes |
| 13 | Regtest Lightning | 5 | L |
| 14 | The bug log's labels and the class sweep | 9 | S |
| 15 | Stage 1, then stage 2 | 8 | a week, then the team |

If only part of this gets done, do rows 1 to 5 and 9 first.

## Done means, before the team

- No open finding that can lose sats or an account without a written
  decision from Tom.
- The core we link contains every client fix upstream has shipped, and the
  build checks it.
- Each boundary in section 2 has its belief table, and nothing on it is
  unchecked without a decision.
- The journeys pass nightly for a week with the agreement check, on
  production's server version and on master.
- A week of nightly walks with no unexplained failure. Everything the
  walk found has a test.
- Invoices are paid and received on regtest Lightning, through the confirm
  step.
- The restore matrix matches, for accounts from Peel and from the official
  apps.
- The signing-team migration is written down and decided.
- The bug bash's second session finds nothing a person would call broken.
- Stage 1 has had a week with no new money, account or interop bug.

## Not doing

- **A coverage target.** Lines run are not contracts checked.
- **XCUITest.** Tom stopped it ("be really pragmatic"). Snapshots and
  drive files reach most of it without the Accessibility permission.
- **More unit tests for behaviour already pinned.** The `test-audit` gate
  applies.
- **Mutation testing tools.** The rule that a regression test fails before
  its fix covers the same ground, one bug at a time.

## Is the architecture better?

For finding bugs and keeping them out, yes.

- **One way in, one way to pay.** Every core call goes through one commit
  path, with the state and its rows in one transaction. Statuses only
  move forward, and there is one money gate. The payments review found
  Peel stricter than the official app in most flows. The official app has
  that review's F1 to F4 too.
- **The engine runs without the app.** Tests, the CLI and agents drive it
  directly, which is what makes the journeys, the walk and the crash runs
  possible.
- **The official Mac app is harder to test.** Its money and message logic
  sits in `SphinxOnionManager`, a shared singleton of about 8,300 lines.
  Its test target has 37 files, mostly for Strut and Hive; three are named
  for the onion manager (seed generation, server health, the connection).

What the architecture does not do is make a belief about the server or the
core true, and that is where the serious bugs have been.
