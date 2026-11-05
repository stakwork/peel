# What it learned

**Not verified on a Mac.** This was written on Linux with no Swift toolchain
and no Xcode. Nothing in it has been built, launched or run against a live
strut. See "Not verified" for exactly what that leaves open. Nothing is
written to Hive; Hive's Glimmer and its `cause-*` workflows are untouched.

The same Cause / theme process Hive's Glimmer uses, on the person's own
memory on Peel's own strut, as a Mac screen of its own (Apps › "What it
learned", source "On this Mac · only you", tabs Habits, Waiting for you,
In use). Only the person sees it and only the person approves.

## Fields (Hive's, no second schema)

- Cause: `statement` ("When <situation>, the assistant <wrong behaviour>.",
  one sentence, at most 25 words, no names), `cause_type`, `severity`,
  optional `mechanism`, `identity_key`.
- `identity_key` mirrors Hive's `cause/families` `familyKey`, in
  `CauseRules.identityKey`: `"ck1_"` plus the first 16 hex characters of
  SHA-256 over `cause_type + "\n" + mechanism + "\n" + normalise(statement)`
  (a real newline; UTF-8). `normalise` is Hive's: lower case; fenced code,
  inline code and double-quoted spans out; digits and anything but a-z to a
  space; stop words out **before** stemming; Hive's stem (first matching rule
  only); stems of two or more letters, sorted, joined by a space
  (`CauseRules.familyNormalise`). The mechanism is the Cause's, one of Hive's
  (`ignored_user_input`, `over_building`, `wrong_route`, `unverified_claim`,
  `misread_intent`, `wrong_direction`, `style_or_naming`, `design_choice`,
  `other`), `other` when absent or not one of them; `cause_type` defaults to
  `correction`. A theme's key is Hive's parent key, `"ck1_"` plus 16 hex of
  SHA-256 over `"parent\n" + mechanism` (`CauseRules.parentKey`), for a parent
  only. Parity is tested in `LearnedTests` against vectors computed by running
  Hive's own code in node: four leaf keys and the `over_building` parent key
  (`ck1_89f3278ea817e5c9`, `ck1_1371245500ebc20d`, `ck1_63b1441fd22954a4`,
  `ck1_c2b47fd395661d9e`, `ck1_36e9426465411668`).
- **Legacy keys are not familyKey outputs.** `ck1_5d83d811207e124f` was said
  to be the key of the catalog entry `ob_more_than_asked`, but Hive's own code
  gives `ck1_89f3278ea817e5c9` for it. `ck1_5d83d811207e124f`,
  `ck1_17b4c518f28a2180`, `ck1_a6bb5b9eed250a84` and `ck1_0d0ac1fd6a8b7e1c` are
  legacy keys of older Causes that Hive maps to catalog ids through its
  `aliases` table. Peel does not try to produce them, and a test documents that
  they are not the current key. Statements are not forced into Hive's
  15-entry catalog.
- Grouping (`GroupingRules`): a theme is one mechanism that explains two or
  more leaves (one only to join an existing theme). It need not share a
  `cause_type`; the judge's stated mechanism decides, with guards: a new theme
  must have a non-empty mechanism and a valid statement, and is refused when the
  judge says `needs_different_fixes`. Each leaf in at most one theme.
  A new theme's mechanism is one of Hive's (its parent key follows from it), and
  a second theme with a known mechanism the person already has is a duplicate,
  reported, not merged. Near-duplicates are reported, never merged. A rejected grouping, and any
  superset of it, is never proposed again.

## How it is stored (memory entities and facts, no per-edge properties)

All through `MemoryServer`'s memory steps (`remember`, `get`, `recall`,
`forget`); no second store, no other strut, nothing outside `MemoryServer`.

- Cause: entity type `Cause`, named by its statement, with one
  `learned_record` fact (its fields as JSON; never its evidence or parent).
- **Evidence is an edge**: an entity of type `Turn` named by the orchestrator
  turn (the run's id on Peel's strut) and a fact `EVIDENCED_BY`, subject the
  leaf, object the Turn. The fact's `text` is the excerpt; the edge's other
  fields (`confidence`, `kind`, `why`, `previous_ref`, `turn_at`) are JSON in
  the fact's `value`. A dictation fix has no orchestrator turn: its Turn is
  named `dictation/<time>`. Only a leaf has evidence; a parent never does.
- **Parent link**: a fact `CAUSE_CHILD_OF`, subject the child, object the parent.
- A Concept's shape is `{ name, statement, keywords }`, with edges to the
  theme it answers (`answers`) and the topics it is about (`about`).
- **Live = a Concept in memory.** Approving writes an entity of type `Concept`
  with a `statement` fact, a `keywords` fact, `about` facts to `Topic` entities,
  an `answers` fact to the theme it answers, and a `learned_record` (in use,
  and the prior state so Undo restores it). So `memory/recall` and
  `memory/get` surface it on a related task. The orchestrator's memory prompt
  has one generic sentence telling it to `memory/recall` for approved habit
  Concepts before booking, sending and similar tasks. Nothing about habits goes
  in the prompt or the personal note, and there is no file for them. A proposed
  Concept is never written.
- If strut's memory refuses these types or edges, the store fails with one
  plain sentence on screen ("Your assistant's memory on this Mac cannot keep
  habits yet. It needs an update first."), never a crash, and writes nothing
  else. There is no fake or second store.
- An index entity (`LearnedIndex`) lists the ids, since the steps have no list verb.
- Undo: a Concept goes back to its prior state, or is removed if it was new;
  a theme is taken apart (its parent goes, the leaves stay).

## What reads and what runs

- Corrections the person already makes: a card answered No, dictated text
  edited by hand (kept in `learned-signals.jsonl` in the profile folder), and a
  "No, not that" reply in the assistant DM (read on open). Never another chat.
- Opening the screen runs the check (`LearnedService.check`): a dry run that
  writes nothing. Approve writes; Reject is remembered.
- The workflows `peel-learned-detect`, `-group`, `-concept` and
  `peel-learned-check` are published on Peel's own strut by
  `AutomationsClient.installLearned()`, the way `peel-automation-run` is
  (`publish`: one version per content, `p-` and its hash; category `peel`). Each
  judge is one sealed `agent` step with no tools.
- The daily check is one automation on `peel-learned-check`, created if
  missing, shipped **off** with `{ "every": "day", "at": ["20:30"] }`, like
  strut's own built-ins. The screen has its switch and Run now (the existing
  `AutomationsClient` update and run-now calls). Opening the screen never turns
  it on or changes its schedule. Its agent can only `memory/recall` and
  `memory/get`, so a run proposes in words and can write nothing or make
  anything live. It sees what memory holds, not the Mac's correction log, so new
  corrections reach "Waiting for you" when the screen is opened.

## Depends on the strut migration (another job, stakwork/strut)

Memory step calls Peel makes, all through `MemoryServer`: `memory/remember`
(`episode`, `entities[{name,type}]`, `facts[{subject,predicate,text,object?,value?}]`),
`memory/get` (`ref_id`; reads `facts[].predicate/text/value/object`),
`memory/recall` (`q`; reads `{ref_id,name,node_type}`) and `memory/forget`
(`ref_id`).

The bundled strut's ontology may not have these yet; Peel calls the steps with
these names and strut keeps unknown ones as proposed until it does:

- entity types `Cause`, `Concept`, `Turn` (and Peel's `Topic`, `LearnedIndex`,
  `LearnedRejection`);
- predicates `EVIDENCED_BY`, `CAUSE_CHILD_OF`, `answers` (and Peel's `about`,
  `statement`, `keywords`, `learned_record`);
- per-edge properties: the memory graph has none, so the edge's fields ride in
  the fact's `value`. If the migration adds real edge properties, move
  `EvidencePayload` there.

## Not verified

- Nothing was built or run on a Mac, and the UI was not run.
- The memory step shapes `GraphLearnedStore` assumes (`remember`'s `entities`
  and `facts` with `object` and `value`, `get`'s `facts[].predicate/text/value/
  object`, `recall` returning `{ref_id, name, node_type}`) follow this repo's
  prompt and tests, not strut's `remember.ts`. The fake graph in
  `LearnedTests` only checks Peel's side.
- The judge's routes (`POST /workflows/<name>/run`, `GET .../runs/<id>`) and
  the `pack` text as the answer are assumed.
- The automation create, update and run-now calls reuse `AutomationsClient`'s
  but were not run on a live strut with a non-`yours` workflow.
- The strut migration above.
