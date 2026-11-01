# What it learned

Status: built, Mac only, not yet run against a live strut or in the app (see
"Not verified"). Nothing is written to Hive; Hive's Glimmer and its `cause-*`
workflows are untouched.

The same Cause / theme process Hive's Glimmer uses, on the person's own
memory graph on Peel's own strut, as its own Mac screen (Apps › "What it
learned", source "On this Mac · only you"). Only the person sees it and only
the person approves.

## Fields and edges (Hive's, no second schema)

- Cause: `statement` ("When <situation>, the assistant <wrong behaviour>.", at
  most 25 words, no product or person names), `cause_type`
  (prompt_gap, reasoning_error, missing_context, format_violation, correction,
  inefficiency, concept_issue), `severity`, optional `mechanism`,
  `identity_key = hash(cause_type + normalized statement)`: a repeat attaches
  to the Cause that exists.
- `Cause -[EVIDENCED_BY {excerpt, confidence, kind, why, previous_ref, turn_at}]->`
  the person's own orchestrator turn. Evidence stays on leaves.
- `Cause -[CAUSE_CHILD_OF]-> parent Cause` (child to parent). Rules:
  `GroupingRules` (at least two leaves, one only to join an existing theme;
  each leaf in one theme; leaves of a theme share a cause_type, standing in
  for "needs the same fix"; a new theme needs a mechanism and a valid
  statement; near-duplicates are reported, never merged; a rejected grouping
  and any larger one holding it is never proposed again).
- Concept: the live record (`PersonalConcept`), with the previous state
  kept on it so Undo restores it.

## Where it lives

- `Sources/PeelAgent/Learned*.swift`: `LearnedCause` (types, normalising,
  key, validation), `LearnedGrouping`, `LearnedDetect` (signals and
  candidates, `LearnedSignalLog`), `LearnedStore` (`GraphLearnedStore`, over
  `MemoryServer`'s `memory/remember`, `get`, `recall`, `forget` only),
  `LearnedWorkflows` (the seeded workflows and the judge),
  `LearnedService` (check, answers, undo, `LearnedInstructions`).
- Stored as memory entities of type `Cause`, `Concept` and `LearnedRejection`
  (and an index entity, since the memory steps have no list verb), each with a
  `learned_record` fact holding its fields as JSON, plus real edge facts
  (`evidenced_by` to a `Turn` entity, `cause_child_of`, `answers`).
- Seeded the way `peel-automation-run` is: `AutomationsClient.installLearned()`
  publishes `peel-learned-detect`, `peel-learned-group`, `peel-learned-concept`
  (category `peel`; sealed, one `agent` step, no tools, no schedule). They are
  Peel's, not Hive's; nothing is installed and Hive's copies are not edited.
- Mac: `AppModel+Learned` (`LearnedModel`), `LearnedView` and `LearnedCard`,
  opened as `Destination.app(peer: nil, name: "what-it-learned")`.

## What it reads

Corrections the person already makes: a card answered No
(`DeviceActions` `rejected`), dictated text edited by hand
(`DictationController.corrected`), and "No, not that" next to an assistant
reply in the assistant DM (read on open). Rejections and dictation edits are
kept in `learned-signals.jsonl` in the profile folder (owner-only, newest 200).
Never another chat. A dictation edit has no orchestrator turn: its evidence
turn is `dictation/<time>`.

## Flow

Opening the screen runs `LearnedService.check`: a dry run that reads, asks
the judge, applies the rules and writes nothing. Approve writes (a habit, a
theme with its leaves, a concept); Reject remembers the answer. Undo: a
concept goes back to its prior state (or away); a theme can be taken apart.
Live concepts are passed as a line to the personal-instructions slot
(`Orchestrator.hostConfig(learned:)`, from `learned-instructions.txt` in
strut's data folder, read at each launch); the graph stays the record and the
assistant may read the Concepts with `memory/recall`. No unattended schedule.

## Not verified

- Nothing here was built or run on a Mac. The code was written on Linux with no
  Swift toolchain; the new tests (`LearnedTests`) are unrun.
- The memory step shapes `GraphLearnedStore` assumes (`remember`'s `entities`
  and `facts`, `get`'s `facts[].predicate/text`, `recall` returning
  `{ref_id, name, node_type}`, a new predicate not replacing the old
  record fact) follow the prompt and tests in this repo, not strut's source.
- The judge's two routes, `POST /workflows/<name>/run` and
  `GET /workflows/<name>/runs/<id>`, and the `pack` text as the answer, are
  assumed; the parsers are tested, the routes are not.
