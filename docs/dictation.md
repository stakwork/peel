# System-wide dictation

Last updated 2026-10-23. **Milestones 0 and 1 built:** the global hotkey,
the capture, typing into the focused field, and speech-to-text on Peel's
own strut.

Hold a key anywhere on the Mac, speak, let go, and what you said is typed
where you were typing. Peel records on this Mac and its own strut, running
on this Mac, turns it into text: nothing leaves it.

## How it works

- **Hotkey.** A CGEventTap on its own thread (`DictationHotkeyTap`) sees
  flags-changed, key-down and key-up. It is an active tap, because the
  Space that locks must be swallowed (and the Escape that cancels, and the
  Return that finishes); every other event goes on untouched. Without
  Accessibility an active tap is refused, and a listen-only one is used
  instead (those keys then also reach the app); granting Accessibility later
  makes the tap again. Not started before Input Monitoring is granted.
  Re-enabled when the system turns it off, and by a 2 s watchdog, which also
  ends a hold whose key-up was missed.
- **State machine** (`DictationStateMachine`, PeelUI): Idle, Pending,
  Recording, Locked, with time passed in. A tap under the threshold passes
  through. Hold: push-to-talk, release submits. Hold past the threshold, then
  Space: locked, hands-free, Space swallowed; X or Esc discards, the tick,
  Return or pressing the key again submits. Any other key (Space included)
  before the threshold, or any other key while holding, means the key is part
  of a shortcut (Option-Space, Option-arrow, Command-Tab): the recording is
  dropped and the key goes on to the app.
- **Capture** (`DictationAudioCapture`): AVAudioEngine's input, converted
  to 16 kHz mono PCM16 and written to a temp WAV (mode 0600). The engine
  runs only from key-down to the recording's end. The file is deleted once transcribed,
  and on cancel. An engine stays on the input it started with, so a new one
  is made when the input changes (AirPods connecting while Peel is open, or
  another mic chosen): on macOS's notice that the default input changed, on
  the engine's that its configuration did (one new engine per burst, as a
  Bluetooth headset switches profile when its mic opens). A recording under
  way carries on into the new engine.
- **HUD** (`DictationHUDPanel`): non-activating panel, never key or main,
  bottom centre of the screen the pointer is on; takes the mouse only when locked.
  A small dark pill: 24 pt with a live waveform (the last eight levels) while
  the key is held, 28 pt with a grey X and a white tick either side when
  hands-free. Fades in over 150 ms, out over 110 ms.
- **Hand-off:** `DictationSession { id, audioURL, duration, mode }` to a
  `Transcriber`: `StrutTranscriber` (`DictationSpeech`, the app; the HTTP
  calls are `StrutSpeech`, PeelAgent). `StubTranscriber` stays for tests.
- **Speech-to-text** (strut's `plans/native-dictation-client.md` §3, §6).
  Peel's bundled strut (the open account's, started with its agent; never
  a home server's) is staged with its speech engine, sherpa-onnx, in
  `native/` (`scripts/stage-strut.sh`, no longer `--no-stt`; +32 MB). The
  recording's WAV goes to `POST /audio/transcribe`
  with the strut's key, and the text comes back cased and punctuated (about
  1.3 s for a short sentence cold, tens of ms of decoding), on the slow
  strut session (a download or a long recording outlasts a minute). The
  default model (the one Peel checks for and sends no `model` for, so the
  user's pick in Models, below, wins once installed), 57 MB, is fetched
  once into the account's strut cache, as soon as
  dictation is on and the strut is up: the app tells dictation whenever
  its strut starts, stops or changes (`AppModel.strutChanged`), which
  checks the model again for that strut. A recording that finds it still
  downloading says so in the HUD, and one made while the strut is starting
  waits up to 10 s for it. Account › Dictation › Speech to text shows the
  model in use, or, before strut has listed its models, the default
  model's state; Try again after the default model failed. Strut's refusals come back as
  `StrutSpeech.Failure`, in Peel's words for the HUD, never strut's own
  (which can carry its paths). Nothing said is logged; what is kept is
  History's, below. `embed-strut.sh`
  refuses a stage without the speech engine.
- **History** (`DictationRecord`, PeelCore's `dictation` table, v28; the
  window `DictationHistoryView`). Each dictation is kept in the open
  account's own database, on by default, for 30 days (dropped as each new
  one is kept), and goes with the account: the text that was typed or
  copied, when, how long, the app's id and name (never its window title)
  and where the text went (typed; copied, and why; blocked: a password
  field, no text; failed, and why), and what dictation heard when the
  vocabulary rewrote it (`heard`, v29: "heard “ask the stack work team”").
  Never the recording, which is still
  deleted once transcribed. Nothing is kept, and the window shows nothing,
  while the account is locked (`AppModel.unlockedStorage` is nil: locking
  leaves the engine open, so the engine alone is not the test) or with History off (Account › Dictation › History). The
  window (app menu › Dictation History…, or Open in Settings) lists the
  newest 500 by day with Copy and Clear History; opening it also drops what
  is past 30 days. Clear overwrites the text in the file (`secure_delete`)
  and folds in the log. A "Copied: press ⌘V" note adds "(also in History)"
  only when it was kept. Time and account are taken when the key is let go.
  Strut's sessions are not used: they keep the recogniser's raw text with
  no app or outcome, and cannot be cleared.
- **Vocabulary** (`DictationLingo`, a thin client: strut is the brain).
  The user's words live in the memory graph on Peel's own strut: a `Lingo`
  entity type for jargon, acronyms and product words, and on any entity
  `heard_as` facts, how dictation mishears it ("stack work" for Stakwork),
  kept out of strut's alias matching (stakwork/strut#297). All the judging
  is strut's too (stakwork/strut#301, its `plans/native-dictation-client.md`
  §7a, the contract any client follows): `/audio/transcribe` returns the
  text with the vocabulary applied (known mishearings, new spellings of a
  taught word, casing; never one everyday word on its own) and `heard`,
  what the recogniser wrote, when that changed it. Peel types `text` and
  keeps `heard` in History. Peel has no rules of its own.
  - **Learning.** After typing, `DictationEditWatch` rereads the field every
    0.5 s while it keeps the focus, for up to 45 s, and takes the span
    between the text that was around Peel's (`DictationEdit`, PeelUI). The
    edit is sent **once**, when it has settled, because strut runs the
    user's fixer model on it: 2 s after the last change, when the field is
    emptied (Return in a chat sending it: the last reading before stands),
    when words are written on after it, when the focus leaves the field, or
    when the next dictation or insertion starts. Nothing is sent when the
    text is unchanged. Words added after the dictation (by word: the same
    words first, then more) are the user's own writing, never sent: the
    edit is the reading before them, and a span 200 characters longer than
    the dictation ends it whatever its words. No watch without a fixer in
    use (`active` in `dictation/models`; with none strut learns nothing), in
    a terminal (Terminal, iTerm2, Warp, kitty, Ghostty, Alacritty, WezTerm:
    the field's value is the scrollback) or in a password field. The watch
    takes the strut and the unlocked account as it starts and drops the
    edit if either changed; it ends when the strut changes or the account
    locks, and the learn and its Undo go to that strut. A field over 100,000
    characters is not read (its length is asked first). It goes as `{typed, edited}`
    to `dictation/correction`, which judges and writes each mishearing
    (only the pair, never the sentence) and returns what it learned with
    the ids to undo; the HUD says "Learned P8" with Undo for 5 s, and Undo
    is `dictation/undo`. "Learned" waits for a dictation under way and its
    insertion to finish. Only while Peel is unlocked (locking also drops
    the vocabulary read for Settings and the window), never for Peel's own
    fields, and only where Accessibility can read the field (not most
    Electron apps; the rewrite still works there).
  - **The Vocabulary window** (Account › Dictation › Vocabulary › Open): each
    word with how it is misheard (`memory/lexicon`), Remove
    (`dictation/remove`), a switch to leave it alone (`dictation/enable`),
    and Add (`dictation/add`). A view over the graph, not a second list.
- **Models** (`DictationModels`; Account › Dictation › Speech to text and
  Clean-up and learning). Strut runs dictation on a small local model for
  each job, which the user picks: speech Kroko (`zipformer-en-kroko`, 57 MB,
  the default) or Parakeet (`parakeet-tdt-en-0.6b-v2`, 482 MB); clean-up
  Off, Qwen3 0.6B (`qwen3-0.6b-q4`, 397 MB) or Qwen3 1.7B (`qwen3-1.7b-q4`,
  1.1 GB, recommended). Clean-up is what puts dictation right and learns
  from the user's edits. Strut names and describes each model (`name`,
  `summary`, `recommended`); Peel's only words are Off's. Each job is one
  row: the model in use (`active`), what it does, its size, and for
  clean-up how many words it has learned; Change opens Peel's menu beside
  it with every choice, what it means (a second line, "Recommended." first
  for strut's choice) and its size on the right, and Remove for what strut
  says can go (`removable`). Choosing calls `dictation/use` (`{speech}` or
  `{fixer}`, `fixer: null` for Off), which downloads a model that is not
  installed, and strut switches to it once it is there. While the pick
  downloads its progress shows under the row (`downloaded`), from
  `dictation/models` read every second, only then and only while the
  section is on screen; a failed download shows strut's reason. Before
  strut lists a speech model the row shows the default model's state.
  Every step returns the whole list. `/audio/transcribe` goes without a
  `model`, so the pick is used, and its reply names the `fixer` that ran.
- **Typing it** (`DictationTextInserter`; the decision is
  `TextInsertionPlan`, PeelUI). The frontmost app and its focused element
  are read when the key goes down (just the element and whether it is a
  password field) and again, in full, when the text is ready:
  - a password field (`AXSecureTextField`) or secure keyboard entry at
    either end: nothing is recorded, typed or copied; the HUD says which;
  - another app, or another field in the same app, took the focus
    meanwhile, or the focus is a control that takes no text (a button, a
    list): the text is left on the clipboard and the HUD says ⌘V;
  - a text field in Notes, TextEdit, Mail or Messages: Accessibility's
    selected text, checked by the field's length (it must grow by the text
    less the selection), else a paste;
  - everywhere else, an app that shows Accessibility no focused element and
    Peel itself included: ⌘V with the clipboard saved (every item and type),
    the text marked transient and concealed for clipboard managers, and the
    old contents put back 750 ms later, unless something new was copied
    meanwhile or what was there was itself concealed or transient (a
    password: putting it back would outlive its manager's clear).
  The ⌘V carries a marker so Peel's own tap lets it by. One insertion at a
  time. Without Accessibility the ⌘V would be dropped, so the text is copied
  instead. Plain text, replacing the selection; never Return, no trailing
  space. Known gap: a paste that lands nowhere (focus on nothing
  Accessibility can see) loses the text once the clipboard is put back.

## Turning it on

Account › Dictation. Allow Microphone, Input Monitoring and Accessibility
(without it the text is only copied, and Space and Esc also reach the app),
then the switch. With no choice made it
is on once Microphone and Input Monitoring are granted. A bar offers it once.
The app menu has Turn Dictation On/Off. macOS may need Peel restarted after
Input Monitoring is granted, and a stable signature (Developer ID) for the
grant to stick. The Mac App Store build is sandboxed: the tap cannot start there.

## Defaults (`DictationDefaults`)

| | |
|---|---|
| Key | Right Option (fixed for now) |
| Hold threshold | 200 ms |
| Longest recording | 5 min, then submitted |
| Format | 16 kHz mono PCM16 WAV |
| HUD | bottom centre, 10 pt above the visible area (just above the Dock) |
| Microphone | on from the key going down to the recording's end, off otherwise |

The key is Right Option for now. Choosing another (R3) is open: the
Settings recorder, an `NSEvent` local monitor, never received a key when
tried on a Mac, so it was taken out. `HotkeyConfig` keeps the rule for
when it comes back: a modifier on its own or a function key, since any
other key would type itself in every app; Fn needs System Settings ›
Keyboard › Press 🌐 key › Do Nothing.

## Open

Start and stop sounds; muting system audio while recording; a login item
(SMAppService); live text while speaking (strut's `/audio/stream`);
retrying a recording whose transcription failed (it is deleted); dictation
when the account's memory is on a home server (no bundled strut runs then);
learning from corrections (milestone 2); terminals' bracketed paste, remote
desktops and input methods for non-Latin scripts, untried;
macOS 13+ is already the minimum (the project targets 15.6).

## Journal

- 2026-10-23: review fixes to learning: no watch without a fixer in use,
  in a terminal, or across a strut or account switch (the learn and Undo
  go to the strut the text was typed with); words written on after the
  dictation are never sent; a cancelled watch never reads the next
  insertion; the vocabulary is dropped on lock; the 30-day prune overwrites
  (`secure_delete`); "Learned" waits for the dictation under way without a
  poll. Strut owns the models' names, summaries, recommendation and what
  can be removed; the Vocabulary's switch is `dictation/enable`. Unit
  tested: appends, the size backstop, the new model fields. Not yet run
  against a strut with these fields.

- 2026-10-23: strut judges with a local model the user picks (speech and
  fixer): the Speech to text and Clean-up and learning rows in Account › Dictation; the
  edit watch sends each edit once, when it settles, as `dictation/correction`
  now runs the fixer (no more `dry_run` polling); `dictation/add` no longer
  says whether a word applies. Unit tested: reading the models reply, when
  an edit is done. The pickers not yet seen against a strut with the
  `dictation/models` steps.
- 2026-10-23: the vocabulary's rewrite, classifier and common-word test
  moved from Peel (Swift) to strut (stakwork/strut#301), so any client gets
  them; Peel calls `/audio/transcribe`, `dictation/correction`, `add`,
  `remove`, `undo`.
- 2026-10-23: Vocabulary (steps 1–4 of the dictation lingo design): strut
  pinned at #297; the rewrite, the edit watch, the classifier (spoken forms
  for acronyms and numbers; nothing learned when dictation's text is
  something the user could mean) and Undo in the HUD; the Vocabulary
  window. Checked against a real staged strut: a learn, the read, Undo.
  Not yet: hotwords, the LLM clean-up, measuring corrections per 100 words.
- 2026-10-23: the mic goes on when the key goes down and off when the
  recording ends (or the press turns out to be a tap). It was kept warm with
  a 200 ms pre-roll, which left the mic indicator on and AirPods in call
  quality the whole time dictation was on. The 200 ms hold threshold covers
  the engine's start.
- 2026-10-23: History (step 0 of the dictation lingo design): on by default,
  30 days, text only. Not built from that design yet: a choice of keep
  time, deleting one entry, opening the window at an entry from the HUD,
  and the one-time HUD note about History.
- 2026-10-20: milestone 0 written without a Mac to run it. Unit tested:
  the state machine, hotkey encoding and flags, pre-roll ring, PCM and
  level maths, WAV writer. Not run: the real tap, capture, HUD focus,
  permissions.
- 2026-10-23: built and unit tested on a Mac; review fixes. Space locks only
  after the hold threshold and any other key while holding drops the
  recording, so the hotkey's own shortcuts work; Return submits when locked;
  the hotkey is limited to modifiers and function keys; the tap is made again
  once Accessibility is granted; a microphone failure ends the recording and
  says so.
- 2026-10-23, tried on a Mac: push-to-talk, locking, the HUD and the
  permissions work. The key recorder in Settings received no key, so the
  key is fixed to Right Option until it is rebuilt.
- 2026-10-23: typing the text (R2, R11–R14): Accessibility in four native
  apps, else paste with the clipboard put back, else the clipboard; nothing
  in password fields. Unit tested: the plan. Review fixes: another field
  in the same app counts as moved focus, the Accessibility check is by
  length, the restore waits 750 ms and never puts a secret back, Peel's
  tap ignores the ⌘V. Not run by hand yet.
- 2026-10-23: milestone 1, speech-to-text on Peel's own strut. Checked
  against a real staged strut: the model downloaded in 4.4 s and a `say`
  sentence came back word for word. Unit tested: `StrutSpeech` against a
  stub strut (the WAV and key sent, refusals, the model list, the
  download's events).
