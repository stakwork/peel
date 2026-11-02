# Voice mode

Talk to the Peel agent entirely by voice and listen to its answers, for
example while driving: work on features, start jobs. The phone matters most;
the Mac gets the same thing.

**Status: written without a build or a device. Nothing here has been
compiled, run or tested; see "Untested".**

Serves `docs/VISION.md`: principle 1 (privacy: speech is recognised and
spoken on the device, no reply leaves it) and principle 3 (the human
controls the agent: voice mode sends and stops it only on your words).

## Design

### State machine

`VoiceMachine` (`Sources/PeelUI/Voice/VoiceModeState.swift`) is a pure
reducer: events in, effects out. `VoiceModeController` runs the effects.

```
idle ──start──▶ listening ──words──▶ hearing ──send it / silence──▶ sending
  ▲                ▲  ▲                 │ scratch that                 │ sent
  │                │  └─────────────────┘                              ▼
  │                │◀──── speech ends ──── speaking ◀──reply──── waiting
  └── exit / error / interruption, from any state (failed(reason) on error)
```

- listening: nothing said yet; hearing: a draft, shown live.
- sending: the draft is going out. waiting: the agent is answering.
- speaking: the reply is read; only whole-utterance controls are heard.

### Files

| File | What |
|---|---|
| `Sources/PeelUI/Voice/VoiceCommand.swift` | `VoiceCommand`, the phrase table `VoiceCommandPhrases`, `VoiceCommandParser`, `VoiceContext` |
| `Sources/PeelUI/Voice/SpokenText.swift` | markdown reply to sentence chunks, the short version |
| `Sources/PeelUI/Voice/VoiceModeState.swift` | `VoicePhase`, `VoiceMachine`, `VoiceDefaults`, `VoiceSettings` |
| `Apps/Shared/Voice/VoiceSpeaker.swift` | `SpeechSynthesizing` seam, `VoiceSpeaker` (`AVSpeechSynthesizer`), voice quality |
| `Apps/Shared/Voice/VoiceListener.swift` | `SpeechListening` seam, `VoiceListener` (`SFSpeechRecognizer` on an `AVAudioEngine` tap), authorization |
| `Apps/Shared/Voice/VoiceModeController.swift` | the controller: session, listener, speaker, send, reply |
| `Apps/Shared/Voice/VoiceModeViews.swift` | the button, the panel, the settings fields |
| `Apps/iOS/Peel/ConversationScreen.swift`, `YouTab.swift` | the phone's button, panel and settings |
| `Apps/Mac/Peel/AgentViews.swift`, `AgentSettings.swift` | the Mac's |

Tests: `VoiceCommandParserTests`, `SpokenTextTests`, `VoiceModeStateTests`
(`Tests/PeelUITests`).

### Flow

1. The button (or "Hey Peel", below) calls `start()`: refuses during a call
   (`model.calls.call`) or a Mac dictation (`hooks.blocked`), asks for the
   microphone and speech permissions (a denied one leaves a notice in
   `model.conversationNotices[agentChat]`), configures the audio session,
   starts the listener, says "Voice mode on. Say send it when you are done."
2. The transcript is the draft, live. Send happens on a trailing send phrase
   or after the pause (default 2.0 s, a setting, can be off).
3. The draft goes through `AppModel.send(_:from: .chat(agentChat))`, the
   composer's own path. No new send path.
4. `pollReply` (every 0.25 s with the meter) finds the message just sent in
   `model.timeline` (new uuid, same words), then waits for the agent's text
   that names it (`replyUUID`, the bridge's "one reply per message"), which is
   the turn's final text, not partials. A card waiting
   (`agentWaiting`) is announced once: "Peel is waiting for your approval.
   Approve it on your Mac." (cards stay on the Mac, `docs/design/iphone.md`
   decision 9). A turn stopped on the Mac that never answers is given up
   after 3 s.
5. The reply goes through `SpokenText`, then `VoiceSpeaker`. While it plays,
   the listener runs for barge-in; anything that is not a whole-utterance
   control is ignored (not user speech: it may be the speech itself).
6. After the speech: listening again; the transcript is reset.

The phone has no `agentAnswering`, `agentWaiting` or `stopAgentTurn` (they are
the Mac's, `AppModel+Bridge.swift`): the phone uses `agentUnanswered` and
`waitingCards` (PeelUI), and "stop the agent" says it cannot from here.

Errors: a recogniser that fails three times in a row without words is
reported; the controller says "I lost the microphone. Trying again.", retries
after 1, 2, 4 s, and after the third leaves voice mode with a notice. (It
does not speak when it gives up: the session is already released.)

## Phrases

English, in `VoiceCommandPhrases.english`: edit or add a table to localise.
Text is lowercased, punctuation removed, spaces collapsed before matching.

"Trailing" commands also fire as the last words of an utterance, and the text
before them is kept ("add a login screen send it" sends "add a login
screen"); "whole" ones only as the whole utterance, so a word in a sentence
never fires. The longest phrase wins ("start over" is a discard, not "over").

| Command | Phrases | Match | Heard |
|---|---|---|---|
| activate | hey peel, voice mode, start voice mode | trailing, in the wake listener only | wake listener armed |
| deactivate | exit voice mode, stop voice mode, end voice mode, goodbye peel | whole | any time |
| send | send it, send message, send that, over | trailing | listening |
| discard | scratch that, cancel message, never mind, start over | trailing | listening |
| stop speaking | stop, quiet, stop talking, pause | whole | speaking |
| repeat | say that again, repeat that, repeat, what did it say | whole | listening, waiting, speaking |
| skip | skip, next | whole | speaking |
| read it all | read it all, read everything, full version | whole | listening, waiting, speaking |
| stop the agent | stop the agent, cancel the agent, abort | whole | listening, waiting, speaking |

Known edges: "over" is a loose send word (a draft that ends in "over" sends);
a barge-in "stop the agent" is first heard as "stop" in a partial result and
stops the speech, then is lost. Whole-utterance controls need a transcript
that is only that phrase, which the recogniser gives after a pause.

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
`.interruptSpokenAudioAndMixWithOthers` (music pauses or ducks while Peel
speaks; not `.duckOthers`). Active on entering, deactivated with
`.notifyOthersOnDeactivation` on leaving. `.voiceChat` gives echo
cancellation, so barge-in and speech coexist; the trade-off is that speech is
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

Voice mode (iOS You tab, Mac Account › Agent): spoken replies, send after a
pause (and the seconds), "Listen for Hey Peel while this chat is open",
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
| Privacy | on device with `requiresOnDeviceRecognition` | on device | the user's own strut | audio leaves the device |

### Recommendation

v1: on-device recognition (`SFSpeechRecognizer` now, `SpeechAnalyzer` when it
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
   a `.playAndRecord` / `.mixWithOthers` session.
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

- the build itself (Swift 6 strictness around the audio tap, the recogniser's
  callbacks and `NotificationCenter` closures were written to avoid main-actor
  isolation traps, but not compiled)
- the unit tests (`VoiceCommandParserTests`, `SpokenTextTests`,
  `VoiceModeStateTests`): written, not run; checked by hand only. One
  mismatch was found that way and fixed: the sentence splitter does not break
  before a lowercase word, so a quoted line is now its own sentence
- Bluetooth HFP and a car stereo, in and out of range
- the lock screen with voice mode running; the orange indicator
- Siri and phone-call interruptions, with and without resume
- echo and barge-in on the speaker (does `.voiceChat` with voice processing
  keep the speech out of the transcript; does it lower the volume too much)
- Premium and Enhanced voice availability and the Settings line
- the one-minute recogniser restart, and the 50 s rotation, with no lost words
- the Mac microphone and speech permission prompts, and a default-input change
- a call starting during voice mode; a Mac dictation starting
- engine rebuild loops (voice processing may post configuration changes)

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
