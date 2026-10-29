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
   (`ScreenShare.pick`) and the stream setup.
3. **Started from Account › Recording** for v1: the camera switch, New
   recording, and the recordings made.
4. **Camera bubble, on by default**, off with one switch before recording.
5. **Captions in the file, nothing beside it.** Only the MP4 goes to
   Downloads; the message text stays the sender's.
6. **Recording starts on Record.** Picking a screen puts up the camera
   bubble and the bar; nothing is recorded until Record on the bar.
7. **Peel is in the recording** like any other app on the screen, chats
   and all: a recording is often of Peel itself. Only the bar is left out.

## How it works

- **What is recorded.** One display, chosen in macOS's sharing picker, so
  Peel needs no standing Screen Recording permission. The picker is asked
  to keep Peel in the picture (`includePeel`). A window alone is
  v2: the bubble is a window on the display, so it is only in a display's
  picture (a window recording would need it composited afterwards).
- **Capture** (`ScreenRecorder`). An `SCStream` on the picked filter with
  `SCRecordingOutput` (macOS 15) writing H.264 and AAC to an `.mp4` in
  Peel's temp folder: the screen at up to 1920 px on its longest side, 30
  fps, in the encoder's pixel format (`SCStreamConfiguration.fitting`,
  shared with a call's share), the cursor, and the microphone (`captureMicrophone`, bound to the
  default input, as dictation learned to). No system audio in v1. The
  recording runs up to Account › Recording's Longest (5, 15, 30 or 60
  minutes; 30 by default), only so a forgotten one cannot fill the disk:
  H.264 at this size is about 1 MB every 2 s, so 30 minutes is about
  800 MB. The Ready bar says "Up to 30 min"; in the last minute the bar
  counts down the time left, and at the end the dictation HUD says
  "Stopped at 30 minutes. Saved to Downloads" (board: option A, Tom,
  2026-10-28). H.264, not HEVC: a recording over what a chat takes is
  shared outside Peel, to any device (Tom, 2026-10-29).
- **Sending.** The hosted memes server takes about 25 MB (Tom,
  2026-10-29; `RecordingController.sendLimit`), about a minute of
  recording. A recording over it says "Too large to send in Peel" in
  Account › Recording, and is shared from Finder (Drive, Dropbox): it
  still drags out, to a browser's upload or Finder.
- **The mic** follows macOS's default input, as dictation's does: when it
  changes, the stream is moved to it (`updateConfiguration`) and the bar
  says "Now using …" for 5 s. A mic that sends only zeros for 2 s is deaf
  (a Bluetooth headset dropped its voice link, Tom's recording of
  2026-10-28: silence from 0:03 to the end); it is opened again every 5 s,
  and the bar says "No sound from your mic" until it is back.
- **Peel's windows** are recorded as they are. The control bar is never
  captured (`sharingType = .none`). A call's screen share still hides
  Peel's windows (`WindowCloak`, a `Hold` per share) from every capture
  while it runs, a recording's too, all but the camera bubble
  (`ShownInCaptures`).
- **Camera bubble** (`CameraBubblePanel`). A round, floating panel with the
  camera's preview, mirrored, 200 pt, bottom left of the recorded display,
  dragged anywhere. ScreenCaptureKit records it as part of the display.
- **Control bar** (`RecordingBarPanel`). The dictation HUD's pill, at the
  bottom centre of the recorded display. Once a screen is picked: Cancel
  and Record, with the camera bubble already up to place. Recording: a red
  dot and the time, Discard (X) and Stop (tick). macOS's own menu bar Stop ends it too, and keeps
  the file.
- **After Stop** (`RecordingController`). The file moves to
  `~/Downloads/Peel Recording <date> at <time>.mp4`, numbered if that is
  taken; if Downloads can't have it, a save panel asks where, and it is
  never deleted for that. What a quit or crash leaves in the temp folder
  is swept at launch. Its audio is read out as
  16 kHz mono WAV (`RecordingMedia.extractAudio`), cut at pauses into
  pieces of 8 to 20 s (`RecordingMedia.pieces`): strut's fixer has 1.5 s,
  enough for a dictation's text but not a whole recording's, which would
  go out without the vocabulary. Each piece is sent to Peel's strut
  (`POST /audio/transcribe`, the dictation engine and the user's vocabulary)
  and comes back as text with the vocabulary applied, and each word as
  heard with its start time, moved by where its piece starts: strut
  leaves the timed words as heard. Of the fixer's changes only those that
  write a word where another was heard are kept (`StrutSpeech.swapped`):
  its clean-up, fillers and words it takes for taken back, is right for
  dictation but loses what was said. A fixer still loading misses its
  time, and strut leaves it out for 30 s after: a piece without it is sent
  again every 3 s, up to 45 s a recording, if a fixer is picked. The
  text's words take the heard words' times (`RecordingCaptions.retimed`:
  "Stakwork" at the time "stack work" was heard) and become caption
  cues (`RecordingCaptions`, at most 42 characters and 6 s each), written
  into the file as a `tx3g` subtitle track (`RecordingMedia.addCaptions`, a
  passthrough remux, nothing re-encoded). With no
  strut, or no speech heard, the video is kept without captions and the
  row says why.
- **Account › Recording** lists Peel's recordings in Downloads (plain
  files by their name, never a link planted under one), newest first:
  the name, date and size, each row draggable into a chat, with Show in
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

Risk: high when reviewed (`Sources/PeelCore/Engine.swift`, `attachmentLimit`
made public; 1575 lines). Since 2026-10-29 that change is gone: the
recording's limit is its own (`longest`, `sendLimit`).

Independent review (high tier, an agent that did not write it): fixed a
recording deleted when Downloads refused it; the camera and bar left up when
the capture failed as Record started; Stop with no answer from the recording
output stuck for ever, or an early error deleting a file still closing (now
the same 60 s grace as macOS's Stop); two pickers at once leaving one
waiting for ever; the clock stopping while the bubble is dragged; temp files
left by a quit. Peel's notification banners are macOS's own windows and can
be in a recording: not changed, as Peel itself now is.

Tom's test, 2026-10-28: Peel should be in its own recordings (decision 7,
the recording's `WindowCloak` hold removed), and the captions lacked his
vocabulary (strut applies it to the text only; `RecordingCaptions.retimed`).
Then that the vocabulary was still missing: strut's fixer scores the
whole transcript and has 1.5 s, so a recording's went out as heard. Now
sent in pieces cut at pauses (`RecordingCaptions.pieces`).
Then words missing and still no vocabulary, reproduced on a scratch strut
with Tom's models (Parakeet, the 1.7B fixer): the fixer cut 12 of a
piece's 34 words as clean-up, and a cold one missed every piece. Now only
its swaps are kept, and a piece waits for it.
