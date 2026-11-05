# Voice mode

Talk to the Peel agent entirely by voice and listen to its answers, for
example while driving: work on features, start jobs. The phone matters most;
the Mac gets the same thing.

**Status: both apps build and the unit tests pass (2026-11-05); not yet
tried on a device. See "Untested".**

Serves `docs/VISION.md`: principle 1 (privacy: speech is recognised and
spoken on the device, no reply leaves it) and principle 3 (the human
controls the agent: voice mode sends and stops it only on your words).

## Design

### State machine

`VoiceMachine` (`Sources/PeelUI/Voice/VoiceModeState.swift`) is a pure
reducer: events in, effects out. `VoiceModeController` runs the effects.

```
idle ──start──▶ listening ──words──▶ hearing ──Peel send / silence──▶ sending
  ▲                ▲  ▲                 │ Peel scratch that            │ sent
  │                │  └─────────────────┘                              ▼
  │                │◀──── speech ends ──── speaking ◀──reply──── waiting
  └── exit / error / interruption, from any state (failed(reason) on error)
```

- listening: nothing said yet; hearing: a draft, shown live.
- sending: the draft is going out. waiting: the agent is answering.
- speaking: the reply is read; only the speaking controls are heard (below).
- muted is a flag over the phase, not a phase (`VoiceMachine.isMuted`): "Peel
  mute" from any active phase freezes the draft, "Peel unmute" clears the
  flag, and the phase underneath (listening, waiting, speaking) carries on
  and is what you come back to.

### Files

| File | What |
|---|---|
| `Sources/PeelUI/Voice/VoiceCommand.swift` | `VoiceCommand`, the phrase table `VoiceCommandPhrases`, `VoiceCommandParser`, `VoiceContext` |
| `Sources/PeelUI/Voice/EchoFilter.swift` | `EchoFilter`: tells Peel's own speech heard back from the user |
| `Sources/PeelUI/Voice/SpokenText.swift` | markdown reply to sentence chunks, the short version |
| `Sources/PeelUI/Voice/VoiceModeState.swift` | `VoicePhase`, `VoiceMachine`, `VoiceDefaults`, `VoiceSettings` |
| `Apps/Shared/Voice/VoiceSpeaker.swift` | `SpeechSynthesizing` seam, `VoiceSpeaker` (`AVSpeechSynthesizer`), voice quality |
| `Apps/Shared/Voice/VoiceListener.swift` | `SpeechListening` seam, `VoiceListener` (`SFSpeechRecognizer` on an `AVAudioEngine` tap), authorization |
| `Apps/Shared/Voice/VoiceModeController.swift` | the controller: session, listener, speaker, send, reply |
| `Apps/Shared/Voice/VoiceModeViews.swift` | the button, the panel, the settings fields |
| `Apps/iOS/Peel/ConversationScreen.swift`, `YouTab.swift` | the phone's button, panel and settings |
| `Apps/Mac/Peel/AgentViews.swift`, `AgentSettings.swift` | the Mac's |

| `Sources/PeelUI/Voice/VoiceVocabulary.swift` | `VoiceVocabulary` (the lexicon as contextual strings), `LexiconRewriter` (the lexicon's mishearings rewritten) |

Tests: `VoiceCommandParserTests`, `EchoFilterTests`, `SpokenTextTests`,
`VoiceModeStateTests`, `VoiceVocabularyTests` (`Tests/PeelUITests`).

### Flow

1. The button (or "Hey Peel", below) calls `start()`: refuses during a call
   (`model.calls.call`) or a Mac dictation (`hooks.blocked`), asks for the
   microphone and speech permissions (a denied one leaves a notice in
   `model.conversationNotices[agentChat]`), configures the audio session,
   starts the listener and plays the start tone (a tone, not a sentence:
   what was said over a spoken greeting was lost).
2. The transcript is the draft, live. Send happens on a trailing "Peel send"
   (primary), or after a pause if the user turned that on (off by default).
3. The draft goes through `AppModel.sendDictated(_:to:)`: the text alone,
   so the composer's files, reply target and thread stay in the composer.
   A failed send keeps the draft: "I could not send that. Say Peel send to
   try again." is read over it (`heldDraft`) and the draft comes back after.
4. `pollReply` (every 0.25 s with the meter) finds the message just sent in
   `model.timeline` (new uuid, same words), then waits for the agent's text
   that names it (`replyUUID`, the bridge's "one reply per message"), which is
   the turn's final text, not partials. A card waiting
   (`agentWaiting`) is announced once: "Peel is waiting for your approval.
   Approve it on your Mac." (cards stay on the Mac, `docs/design/iphone.md`
   decision 9). A turn stopped on the Mac that never answers is given up
   after 3 s.
5. The reply goes through `SpokenText`, then `VoiceSpeaker`. While it plays,
   nothing reaches the draft; the listener runs only for barge-in, under the
   echo rules below.
6. After the speech: listening again with a fresh recognition task (empty
   text), the draft cleared, unless one was held over the speech.
7. While the agent answers you may already say the next message (`waiting`
   is a dictating context). A reply that comes while you talk waits until
   the draft has been still for 3 s, then is read over it and the draft
   comes back. A second message replaces the turn waited for; the first
   one's answer is then read as "Peel answered an earlier message."
8. The agent's other messages while voice mode is on (a job that finished,
   anything not the reply waited for) are read too, after "A new message
   from Peel." (`announceNew`). Messages there before voice mode are not.

### Sounds

`VoiceCues` (Apps/Shared/Voice/VoiceCues.swift), sine tones made in code
and played with `AVAudioPlayer` on voice mode's session, so the iPhone's
silent switch does not hide them: start, sent, ready (listening again
after a reply), thinking (every 10 s while the agent works), problem (a
failed send, a failure that ends voice mode) and end. The end tone plays
before the session is let go (400 ms later).

The phone has no `agentAnswering`, `agentWaiting` or `stopAgentTurn` (they are
the Mac's, `AppModel+Bridge.swift`): the phone uses `agentUnanswered` and
`waitingCards` (PeelUI), and "stop the agent" says it cannot from here.

Errors: a recogniser that fails three times in a row without words is
reported; the controller says "I lost the microphone. Trying again.", retries
after 1, 2, 4 s, and after the third leaves voice mode with a notice. (It
does not speak when it gives up: the session is already released.)

## The user's vocabulary (lingo)

Voice mode reuses the vocabulary of Peel's dictation (`docs/dictation.md`,
`LingoLexicon`: entries with the mishearings, "heard", and what the user
writes for them; strut judges and learns them). It does not reuse dictation's
recogniser: dictation records a WAV and strut's `/audio/transcribe` (sherpa-onnx
on the Mac CPU) returns the text once per recording, already corrected. That is
not streaming, so it cannot serve the live draft, "Peel <command>" detection,
the mute listener or barge-in; the streaming `SFSpeechRecognizer` stays the live
engine and the lexicon is applied around it:

1. **Contextual strings.** `VoiceListener` asks for them each time it starts a
   recognition task (about every 50 s, and after each reset), so a refreshed
   vocabulary is used by the next task. `VoiceVocabulary.contextualStrings`:
   "Peel", "Hey Peel" and the command phrases first, then the user's written
   values and names (entries with mishearings first), without repeats, at most
   100.
2. **Rewrite.** `LexiconRewriter.apply` replaces each enabled mishearing form
   (whole words, case aside, longest form first, one pass, punctuation kept)
   with its written value. Entries the user turned off ("leave alone",
   `dictationOff`) are never used. It runs on the dictation text only: the
   parser still sees the raw transcript (so "peel send" parses as before, and
   the echo filter sees what was heard), the draft shown is rewritten
   (`VoiceModeController.draft`) and the message is rewritten when sent. The
   machine keeps the raw words.
3. **The seam.** `VoiceModeController.Hooks.lexicon` returns the lexicon or nil.
   The Mac gives `DictationController.shared.lingo.lexicon`, read-only, and
   asks `DictationLingo.refresh()` (`Hooks.refreshLexicon`) whenever a listener
   starts. The lexicon is empty while the account is locked or the strut is
   down; voice mode then simply runs without vocabulary. **The iPhone has no source**: the
   vocabulary lives in the memory graph on the Mac's strut and the phone has no
   strut (and makes no call to one). TODO: sync the vocabulary to the phone
   through Peel Home, or a strut it can reach. Until then voice mode on the
   iPhone has a generic vocabulary.

**TODO, Mac, not written: "Use Peel's dictation model for the final text".**
The idea: an opt-in setting that records the utterance (16 kHz mono PCM16 WAV
as `DictationAudioCapture` writes it, mode 0600, deleted after) and on send
replaces the draft with `DictationSpeech.transcribe(wav)`, falling back to the
streaming draft plus the rewrite after about 8 s or on any failure. It needs a
second consumer of the voice engine's tap, and `DictationAudioCapture` owns its
own engine (it would fight voice mode's voice-processing engine for the
microphone), so it was left out rather than done unsafely. Next step: feed the
`VoiceAudioFeed` buffers to a WAV writer.

## Phrases

English, in `VoiceCommandPhrases.english` (one table: edit or add a table to
localise). Text is lowercased, punctuation removed, spaces collapsed before
matching.

**The prefix rule (the Alexa/Siri pattern).** A command is recognised only
when introduced by the wake word "peel", and the wake word plus the command
must be the **final words** of the utterance. The text before it is kept as
dictation: "add a login page to the backlog peel send" sends "add a login page
to the backlog". Without the prefix everything is dictation, including a bare
"send it" or "stop". Prose with "peel" that does not end in a command phrase
("peel the potatoes and then send") stays dictation. A command in the middle
of a sentence ("peel send it to the team") does not fire. The longest phrase
wins ("peel stop the agent" is not "peel stop").

The recogniser's variants of the wake word, "pill", "peal" and "feel", count
only as the wake word when a known command follows ("pill send"); "I feel fine"
is dictation. The variants are in the same table (`wakeVariants`).

| Command | Say | Heard |
|---|---|---|
| send | peel send, peel send it, peel send message, peel over (and "sent", "sent it", how the recogniser often writes "send" at the end) | listening |
| discard the draft | peel scratch that, peel cancel message, peel never mind | listening |
| stop speaking | peel stop | speaking |
| repeat | peel repeat that, peel say that again, peel repeat | listening, waiting, speaking |
| skip | peel skip | speaking |
| read it all | peel read it all, peel read everything | listening, waiting, speaking |
| stop the agent | peel stop the agent, peel cancel the agent | listening, waiting, speaking |
| mute | peel mute | listening, waiting, speaking |
| unmute | peel unmute | muted |
| end voice mode | peel end voice mode, peel end voice session, peel stop voice mode, peel exit voice mode, peel goodbye | any time, muted too |
| activate | hey peel, voice mode, start voice mode, peel start voice mode | the opt-in wake listener only (no prefix; "hey peel" alone is fine) |

`VoiceContext` decides which commands count: `dictating` (send, discard, end,
stop the agent, repeat, read all, mute), `waiting` (the same without send and
discard), `speaking` (stop, repeat, skip, read all, stop the agent, mute, end),
`muted` (unmute and end only), `armed` (activate). `contextualStrings` gets the
prefixed phrases.

Known edges: "peel over" is a loose send (a draft that ends in "peel over"
sends). A command said while the recogniser is still building the sentence is
first seen as a partial: "peel stop" can be heard as "peel" and then
"peel stop", which is fine, but "peel stop the agent" is first "peel stop" and
stops the speech, then is lost.

## Mute

"Peel mute" (or the panel's Mute button) freezes the draft: its text is kept
untouched, nothing more is appended, nothing is sent, nothing is said. A local
recogniser loop keeps running and its transcripts are matched solely against
the `muted` commands ("peel unmute", "peel end voice mode"); every other
transcript is discarded and never stored or sent (the loop's text is reset
when it grows past 120 characters, and at each mute and unmute). "Peel unmute"
resumes appending to the same draft (`VoiceModeController.draftBase` holds the
frozen text, because the recogniser's own text starts again at each mute and
unmute). The silence timer does not run while muted.

Muting is about the user's microphone input: spoken replies still play if they
are on. (Muting the speech too would be easy, but "mute" is taken to be the
mic; use the spoken-replies setting for the other.) The panel, on the phone
and the Mac, shows a mic.slash icon, "Muted — say Peel unmute", a dimmed
meter, and a Mute / Unmute button as the tappable alternative, with
accessibility labels.

## Echo: Peel's speech heard back

Replies read aloud must never be transcribed as dictation.

1. **Dictation is paused while speaking.** While `VoiceSpeaker` speaks, no
   transcript reaches the draft (the machine ignores them in `speaking`, and
   the controller does not forward them). The recogniser keeps running, only
   as a barge-in listener, and starts a **fresh task** when the speech ends
   (`resetTranscript`, empty text), the draft cleared.
2. **Barge-in by route**, decided when a speech starts
   (`VoiceModeController.isEchoSafeRoute`):
   - headphones / Bluetooth / CarPlay / USB audio out (iOS: `currentRoute`
     outputs `.headphones`, `.bluetoothA2DP`, `.bluetoothHFP`, `.bluetoothLE`,
     `.carAudio`, `.usbAudio`; Mac: the default output device's transport
     is Bluetooth, Bluetooth LE or USB): the speech does not come back into
     the microphone, so every `speaking` control works.
   - otherwise (built-in speaker, and anything that cannot be told
     confidently, including Mac wired headphones on the built-in device): only
     the exact "peel stop" counts, when the transcript, normalised, is that
     command alone (no text before it) and is not a substring of the text being
     spoken. On this route a transcript of more than six words is discarded
     and the recogniser's text reset, so the echo cannot pile up in front of the
     command. Mute and unmute use the same exact rule on the speaker. The
     panel's Stop speaking button is the reliable way.
3. **`EchoFilter` (fallback, pure and tested).** A transcript is an echo when
   its normalised words have a run of three words (the whole transcript when
   shorter) that is a contiguous run of the normalised text being spoken, or
   spoken in the last 3 seconds. The controller applies it to every transcript
   while speaking and for 1.5 s after the speech ends (the tail echo); in the
   tail an echo also resets the recogniser, so leftovers never join the
   draft. The session mode stays `.voiceChat` (echo cancellation).

Still risky on the speaker: the filter matches words as recognised, so a
badly misheard echo can get through; a user saying something that also
occurs in the reply is dropped while speaking; room reverb longer than 1.5 s;
a real "peel stop" mixed with echo words is not heard on the speaker route.

## Silence timeout

Auto-send after silence is secondary: "Peel send" is primary. A pause can cut
a driver off mid-thought (a road sign, a mirror check), and a message sent
half-formed to an agent that acts is worse than one that waits, so the default
is **off**. When switched on the timeout is 2–15 s (stepper, shown only when
on), 5 s when first switched on. `VoiceSettings` clamps it. The keys are new
(`voice.autoSend.v2`, `voice.autoSendSeconds.v2`): the first version stored
on / 1–5 s under the old keys, which are not read, so a stale 2 s is never
silently carried over. The timer restarts on every new partial result and does
not run while muted or while speaking. The settings footnote says: Say "Peel
send" to send. Auto-send after silence can cut you off, so it is off by
default.

## Long replies, markdown, code and links

`SpokenText` cleans the reply and splits it into sentences:

- fenced code is one phrase ("A code block of 3 lines, skipped."); inline code
  keeps its text without ticks; tables are "A table, skipped."
- `[title](url)` reads as the title; a bare URL as "a link to github.com";
  an image as "an image"
- headings, bold, italics, strike, quote marks, list markers, HTML tags
  are removed; list items and headings are their own sentences, so each is a
  pause
- emoji are dropped; UUIDs, hex of 12 or more characters with a digit, paths
  and very long tokens are "an identifier"
- over the budget (600 characters or 8 sentences, `SpokenText.Budget`) it
  speaks up to the last whole paragraph that fits (else the last sentence that
  fits), then "That is the short version. Say read it all for the rest."
  "Read it all" speaks `full`; "repeat" speaks the last chunks.

## Audio

iPhone session (`VoiceModeController.activateSession`): category
`.playAndRecord`, mode `.voiceChat`, options `.allowBluetoothHFP`,
`.allowBluetoothA2DP`, `.defaultToSpeaker`,
and, only when "Pause music while voice mode is on" is off,
`.interruptSpokenAudioAndMixWithOthers`. Paused is the default: mixed in,
music and podcasts are heard by the microphone and their words end up in
the draft. They resume when voice mode ends. A navigation app's prompts
still mix in and may be heard. Active on entering, deactivated with
`.notifyOthersOnDeactivation` on leaving. `.voiceChat` gives echo
cancellation (best effort; see "Echo" for what is done on top); the trade-off is that speech is
a little quieter and flatter than in `.spokenAudio`, which would suit a
speech-only moment but not listening. The engine's input also asks for voice
processing (`setVoiceProcessingEnabled(true)`). The speaker keeps
`usesApplicationAudioSession` true so the session applies, and
`mixToTelephonyUplink` false.

- Interruption (a call, Siri): speech paused, listener stopped. With
  `.shouldResume` the session and listener come back and speech resumes; else
  voice mode ends with a notice.
- Route change: a new or changed device rebuilds the engine (the input format
  changed). When the old device goes away (`.oldDeviceUnavailable`, a car or
  headset left) the speech is paused, not moved to the speaker; say "repeat
  that" or tap Stop speaking.
- Media services reset: voice mode ends with a notice (the safe reading).
- Background: `UIBackgroundModes` already has `audio` (checked in both iOS
  configurations of the project), so with the session active voice mode keeps
  running with the screen locked. It ends itself, releasing session and engine,
  when the user ends it, on an unrecoverable interruption, a failure, or leaving
  the chat.
- Calls: not started during a call; ended if a call starts (`IOSCallSession`
  owns the session then). `VoiceRecorder` and `VoicePlayer` set their own
  categories and `VoiceRecorder` deactivates the session when it ends: the
  composer is replaced by the panel in voice mode so no recording starts, but
  tapping a voice bubble while voice mode is on changes the category. Open.

Mac: no `AVAudioSession`. `AVAudioEngine` on the default input, rebuilt on the
engine's configuration change and on a new default input device (the lessons
of `DictationAudioCapture`). Voice mode does not start while a dictation is
recording and ends if one starts.

## Settings

Voice mode (iOS You tab, Mac Account › Agent): spoken replies, pause music
(iPhone only, on by default), send after a
pause (off by default; the seconds, 2–15, only when on), "Listen for Hey Peel while this chat is open",
speaking speed, and which voice quality is installed with the hint to
download one (iOS: Settings > Accessibility > Spoken Content > Voices; Mac:
System Settings > Accessibility > Spoken Content). Stored in `UserDefaults`
(`@AppStorage`, keys in `VoiceDefaults`), not `Preferences`: `Preferences`
owns the settings synced through the official apps' encrypted file, and these
are about this device's speaker, microphone and car. `DictationSettings` does
the same.

## Hands-free driving: options

### Speaking

| | A. `AVSpeechSynthesizer`, default voice | B. same, Premium or Enhanced voice | C. Cloud TTS (OpenAI gpt-4o-mini-tts, ElevenLabs Flash) |
|---|---|---|---|
| First audio | under about 100 ms | under about 100 ms (a large voice may load once) | about 300–800 ms plus streaming |
| Offline, tunnels | works | works (voice downloaded once) | needs network |
| Quality | robotic | good, clearly better | best, expressive |
| Cost | none | none | per character or per minute; roughly cents per thousand characters, check current prices before committing |
| Privacy | on the device | on the device | sends the agent's replies off the device |
| Background audio | works with the audio mode and session | same | needs a network while driving; playback is fine |

Not relevant: Personal Voice (it speaks as you); `AVSpeechSynthesisProviderAudioUnit`
(for shipping a voice, not using one).

### Recognising

| | SFSpeechRecognizer on device | SpeechAnalyzer / SpeechTranscriber (iOS, macOS 26) | Strut-side STT (Dictation) | Cloud STT |
|---|---|---|---|---|
| Offline | yes, where supported | yes | Mac only; the phone has no local strut | no |
| Streaming | yes, partial results | yes, long-form | no (a recording, then a result) | yes |
| Limits | about one minute per task: restarted | no task limit | none | by provider |
| Accuracy | fair | better | good (whisper-like) | good |
| User's vocabulary | contextual strings only | contextual strings only | full lexicon, applied by strut | no |
| Privacy | on device with `requiresOnDeviceRecognition` | on device | the user's own strut | audio leaves the device |

### Recommendation

v1: on-device streaming recognition for live text and commands, plus the
user's lingo from dictation applied as contextual strings and a rewrite (an
optional strut dictation pass on the Mac is a TODO; strut's transcriber is per
recording, not streaming, so it is not the live engine). On-device recognition (`SFSpeechRecognizer` now, `SpeechAnalyzer` when it
is written and tried) plus `AVSpeechSynthesizer` with the best installed
Enhanced or Premium voice, each behind a protocol (`SpeechListening`,
`SpeechSynthesizing`) so an opt-in cloud TTS (OpenAI or ElevenLabs, with the
user's own key) can be added for quality. Reasons: latency, working in
tunnels, privacy (principle 1: cloud TTS would send the agent's replies off
the device, so only opt-in with the user's key), no cost, and friendly to
background audio.

The iPhone's deployment target is already 26.0, so `SpeechAnalyzer` is
allowed there; it is left as a marked TODO (`SpeechListening`) because it was
not written without a compiler. The Mac floor is 15.6: it needs the 26 check.

If the system has no on-device model for the language, `VoiceListener`
falls back to the system's server recognition, which sends audio to Apple.
The usage strings say "where the system supports it". Open: refuse instead.

## The wake phrase, honestly

There is no public always-listening wake-word API for third-party apps. An app
can listen only while it holds a running audio session (foreground, or
background with the audio mode and an active session); the system shows the
orange microphone indicator and suspends or kills idle apps. So:

a. The button in the agent chat.
b. Opt-in "Listen for Hey Peel while this chat is open": a light on-device
   loop (`arm()`) only while the agent chat is on screen and foreground
   (iPhone: `scenePhase == .active`; Mac: the window is key). It matches the
   activate phrases, with the phrase at the end of what it has heard. It uses
   a `.playAndRecord` / `.mixWithOthers` session with `.allowBluetoothA2DP` and
not `.allowBluetoothHFP`, so AirPods stay in music quality while the chat
is open (the phone's microphone hears "Hey Peel").
c. System routes that do work hands-free: Siri, and App Shortcuts.

`StartVoiceModeIntent` ("Talk to Peel", "Hey Peel voice mode", an
`AppShortcutsProvider`, `openAppWhenRun = true`) is a **documented follow-up**,
not built: it needs the app to route an intent into the agent chat and turn
voice mode on (`PhoneRouter` and the controller, which lives in the view),
and could not be checked here.

CarPlay needs an Apple entitlement (the voice-based conversational app
category, iOS 26.4 and later) and is a later step. `peel-android` later.

## Untested

Everything: it was written without building or running. To try on a device:

- the build: both apps build (Xcode 26.2, 2026-11-05); the audio tap's and
  the recogniser's threads are not yet seen running
- the unit tests: all five suites (86 tests) pass, run on 2026-11-05 in a
  package holding only the voice sources
- Bluetooth HFP and a car stereo, in and out of range
- the lock screen with voice mode running; the orange indicator
- Siri and phone-call interruptions, with and without resume
- echo and barge-in on the speaker (does `.voiceChat` with voice processing
  keep the speech out of the transcript; does it lower the volume too much);
  the tail-echo window (1.5 s) and recent window (3 s) are guesses to tune
- route detection: iOS port types, and the Mac default-output transport type
  (Bluetooth, BLE, USB); a wrong "echo safe" lets echo commands through
- wake-word misrecognitions: "pill", "peal", "feel" are guesses; others
  ("peal", "pele", "pearl") may show up and are not accepted
- the mute listener: that it keeps running and only matches unmute / end, that
  "peel unmute" is heard against a long muted transcript, and the draft base
  after unmute
- the silence timer and the new keys on a device with the first version
- Premium and Enhanced voice availability and the Settings line
- the one-minute recogniser restart, and the 50 s rotation, with no lost words
- the Mac microphone and speech permission prompts, and a default-input change
- a call starting during voice mode; a Mac dictation starting
- engine rebuild loops (voice processing may post configuration changes)
- the vocabulary: lexicon refresh timing (the Mac's `DictationLingo` may still
  be empty or locked when voice mode starts; contextual strings are read again
  at the next task), the real effect of `contextualStrings` (the recogniser
  may ignore many), rewrite false positives (a mishearing form that is also a
  real word), the iPhone having no vocabulary at all, and the missing strut
  dictation pass (latency, once written)
- the tones: loud enough in a car, and not written down by the recogniser
- echo on the iPhone speaker: voice processing cancels what the engine
  plays, and `AVSpeechSynthesizer` plays outside it, so "Peel stop" over the
  speech may not be heard there. If so, render the speech with
  `AVSpeechSynthesizer.write` into a player node on the same engine

## Open questions and follow-ups

- Migrate to `SpeechAnalyzer`/`SpeechTranscriber`.
- Opt-in cloud TTS with the user's key.
- CarPlay; Android.
- Localisation: phrase tables and `SpokenText`'s English notes.
- A spoken summary from the agent itself: have the reply carry a short
  "spoken" field (a prompt hint), so a long reply is summarised properly and
  not cut at a paragraph.
- `StartVoiceModeIntent` and the router hook.
- Spoken "Voice mode off" and a spoken give-up message (the session is gone by then).
- Tapping a voice bubble during voice mode (see Calls above).
- Refuse server-side recognition when no on-device model exists.
- A shorter debounce so a barge-in's longer phrase is not cut by its first word.
