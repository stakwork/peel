# Screen recording

Last updated 2026-10-28. **v1 built** on `screen-recording`, reviewed
(code review, simplify, security review), and tried end to end by
Tom on 2026-10-28: the camera bubble, Record, captions.

Loom, without the hosting. Record your screen, your voice and a camera
bubble on this Mac; Peel's own strut transcribes it, and the result is a
file in Downloads you send as an attachment like any other. Nothing leaves the Mac
until you send it.

## Decided (Tom, 2026-10-28)

1. **No sharing links in v1.** A hosted link needs a host (Hive, or a strut
   reachable from the web); v1 makes a file, sent as an attachment.
2. **Local capture, not LiveKit.** LiveKit records on the call server
   (Egress), which is the hosting v1 leaves out. ScreenCaptureKit writes the
   file here. What it shares with calls is the system picker
   (`ScreenShare.pick`) and keeping Peel's windows out of the picture
   (`WindowCloak`).
3. **Started from Account › Recording** for v1: the camera switch, New
   recording, and the recordings made.
4. **Camera bubble, on by default**, off with one switch before recording.
5. **Captions in the file, nothing beside it.** Only the MP4 goes to
   Downloads; the message text stays the sender's.
6. **Recording starts on Record.** Picking a screen puts up the camera
   bubble and the bar; nothing is recorded until Record on the bar.

## How it works

- **What is recorded.** One display, chosen in macOS's sharing picker, so
  Peel needs no standing Screen Recording permission. The picker is asked
  to keep Peel in the picture (`includePeel`), so the bubble is in it; the
  cloak hides every other window of Peel's. A window alone is
  v2: the bubble is a window on the display, so it is only in a display's
  picture (a window recording would need it composited afterwards).
- **Capture** (`ScreenRecorder`). An `SCStream` on the picked filter with
  `SCRecordingOutput` (macOS 15) writing H.264 and AAC to an `.mp4` in
  Peel's temp folder: the screen at up to 1920 px on its longest side, 30
  fps, in the encoder's pixel format (`SCStreamConfiguration.fitting`,
  shared with a call's share), the cursor, and the microphone (`captureMicrophone`, bound to the
  default input, as dictation learned to). No system audio in v1. The
  attachment limit is 100 MB: the recording stops itself at 95 MB and says
  why.
- **Peel's windows** are hidden from the capture as for a shared screen
  (`WindowCloak`), all but the camera bubble (`ShownInCaptures`). Each
  capture takes a `WindowCloak.Hold`, so a recording made while a call
  shares the screen ends without showing your chats in the call. The
  control bar is never captured (`sharingType = .none` from its first
  frame). The bubble's exemption is the window's, so it is in a call's
  shared screen too while both run.
- **Camera bubble** (`CameraBubblePanel`). A round, floating panel with the
  camera's preview, mirrored, 200 pt, bottom left of the recorded display,
  dragged anywhere. ScreenCaptureKit records it as part of the display.
- **Control bar** (`RecordingBarPanel`). The dictation HUD's pill, at the
  bottom centre of the recorded display. Once a screen is picked: Cancel
  and Record, with the camera bubble already up to place. Recording: a red
  dot and the time, Discard (X) and Stop (tick). macOS's own menu bar Stop ends it too, and keeps
  the file.
- **After Stop** (`RecordingController`). The file moves to
  `~/Downloads/Peel Recording <date> at <time>.mp4`. Its audio is read out as
  16 kHz mono WAV (`RecordingMedia.extractAudio`), sent to Peel's strut
  (`POST /audio/transcribe`, the dictation engine and the user's vocabulary)
  and comes back with each word's start time. The words become caption
  cues (`RecordingCaptions`, at most 42 characters and 6 s each), written
  into the file as a `tx3g` subtitle track (`RecordingMedia.addCaptions`, a
  passthrough remux, nothing re-encoded). With no
  strut, or no speech heard, the video is kept without captions and the
  row says why.
- **Account › Recording** lists Peel's recordings in Downloads (plain
  files by their name, never a link planted under one), newest first:
  the name, length and size, each row draggable into a chat, with Show in
  Finder. A row being transcribed says so.

## Not in v1

Sharing links, a window or app alone, system audio, pause, trimming, a
title or summary from the agent, the iPhone.

## Review (2026-10-28)

`/code-review` (8 found, all fixed): a recording ending during a call's
screen share showed Peel's windows in it (now `WindowCloak.Hold`); a
recording macOS stopped could be deleted while its file was still being
finished (now 60 s, and a whole file is kept even after an error); the bar
could be in the video; a capture failing as it started left the phase stuck;
a failed caption copy could wait forever; the camera's start and stop were
unordered; the folder was read in full on every redraw.

`/simplify` applied: one `HUDPanel` for the three overlays; the stream setup
shared with a call's share; `MediaInfo.format(duration:)`,
`AttachmentFormat.size`, `FilePanels.reveal` and `Engine.attachmentLimit`
reused; one map of caption states; the audio written from the reader's own
bytes; the WAV mapped, not read in, for strut; the camera at 640×480.
Not applied, with the reason:

- A window opened mid-capture is hidden only after Peel's next event (the
  cloak's `didUpdate`); the bar sets its own `sharingType`. Covering every
  window as it is ordered in is a change to the cloak for calls too: later.
- The bubble is in a call's shared screen while both run: `sharingType`
  is per window, not per capture. Documented above.
- Recording uses dictation's `DictationSpeech` for strut: an app-level
  speech owner is a refactor of dictation; later. Captions fetch the 57 MB
  model if dictation never has.
- The four copies of "ask for the camera or microphone" (calls, voice
  messages, dictation, recording) are not folded into one here.
- The `.microphone` stream output is kept beside the recording output:
  whether the recording output needs it is not checked without recording.

`/security-review`: no findings over the bar. Applied its hardening: links
and anything but a plain file under a recording's name are not listed.

Risk: high (`Sources/PeelCore/Engine.swift`, `attachmentLimit` made public;
1575 lines). Needs an independent review, and Tom's sign-off.
