# System-wide dictation

Last updated 2026-10-23. **Milestone 0 built (unverified on a Mac):** the
global hotkey and the capture. A stub stands in for transcription.

Hold a key anywhere on the Mac, speak, let go. Peel records on this Mac,
nothing leaves it. Milestone 1 (not built) sends the recording to a
transcriber; a later feature types the text into the focused field.

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
  to 16 kHz mono PCM16 and written to a temp WAV (mode 0600); a 200 ms ring
  is put in front of each recording. The file is deleted after the stub has
  seen it, and on cancel.
- **HUD** (`DictationHUDPanel`): non-activating panel, never key or main,
  bottom centre of the screen the pointer is on; takes the mouse only when locked.
  A small dark pill: 24 pt with a live waveform (the last eight levels) while
  the key is held, 28 pt with a grey X and a white tick either side when
  hands-free. Fades in over 150 ms, out over 110 ms.
- **Hand-off:** `DictationSession { id, audioURL, duration, mode }` to a
  `Transcriber`; `StubTranscriber` returns canned text, shown in the HUD
  for 3 s and logged.

## Turning it on

Account › Dictation. Allow Microphone, Input Monitoring and Accessibility
(without it Space and Esc also reach the app), then the switch. With no choice made it
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
| Pre-roll | 200 ms |
| Format | 16 kHz mono PCM16 WAV |
| HUD | bottom centre, 56 pt above the visible area |
| Mic kept warm | yes (the mic indicator stays on while dictation is on) |

The key is Right Option for now. Choosing another (R3) is open: the
Settings recorder, an `NSEvent` local monitor, never received a key when
tried on a Mac, so it was taken out. `HotkeyConfig` keeps the rule for
when it comes back: a modifier on its own or a function key, since any
other key would type itself in every app; Fn needs System Settings ›
Keyboard › Press 🌐 key › Do Nothing.

## Open

Start and stop sounds; muting system audio while recording; a login item
(SMAppService); the real transcriber (milestone 1); typing the text
(Accessibility); whether a warm mic is acceptable or should start at key-down
(a warm Bluetooth headset mic holds AirPods in call quality);
macOS 13+ is already the minimum (the project targets 15.6).

## Journal

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
