# Screen recording

Last updated 2026-10-29. **v1 built** on `screen-recording`, reviewed
(code review, simplify, security review), and tried end to end by
Tom on 2026-10-28: the camera bubble, Record, captions.

Loom, without the hosting. Record your screen, your voice and a camera
bubble on this Mac; Peel's own strut transcribes it, and the result is a
file in Downloads you send as an attachment like any other. Nothing leaves the Mac
until you send it.

Its name in Peel is **Segment** (Tom, 2026-10-29): an orange's segment, and
a clip. A segment is what you make; recording stays the action (the bar's
Record, "Recording…").

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
- **Capture** (`ScreenRecorder`). An `SCStream` on the picked filter: the
  screen at up to 1920 px on its longest side, 30 fps, in the encoder's
  pixel format (`SCStreamConfiguration.fitting`, shared with a call's
  share), the cursor, and the microphone (`captureMicrophone`, bound to the
  default input, as dictation learned to). No system audio in v1. Peel
  writes the `.mp4` in its temp folder itself
  (`RecordingMedia.recordingWriter`, since 2026-10-29; before, ScreenCaptureKit's
  `SCRecordingOutput`, which has no size setting and wrote 25 MB a
  minute): H.264 at constant quality 0.75, a keyframe at most every 10 s,
  the mic as mono AAC at 64 kbit/s, about 4 MB a minute on a screen like
  Tom's test (Loom's is about 2; a video playing full screen costs far
  more). Constant quality, not a bitrate: a still screen costs almost
  nothing and text stays sharp when it moves; at the same size a fixed
  bitrate's worst frame is far softer, and a cap on top starves the
  keyframes (measured on Tom's recording; the comparison encodes are in
  `~/Downloads/Peel bitrate test 2026-10-29`). An encoder that refuses
  quality mode (an Intel Mac, not checked) gets a fixed 800 kbit/s. The
  file is written in 2 s fragments, so a quit or crash mid-recording
  leaves what was written playable; after Stop it is written again
  whole, index first, captions or not, so a chat's player starts before
  the download ends. The file starts at the first whole frame;
  sound before it is dropped. A Mac with no mic records the picture alone.
  The recording runs up to Account › Segments' Segment limit (5, 15, 30
  or 60 minutes; 30 by default), only so a forgotten one cannot fill the
  disk. The Ready bar says "Up to 30 min"; in the last minute the bar
  counts down the time left, and at the end the dictation HUD says
  "Stopped at 30 minutes. Saved to Downloads" (board: option A, Tom,
  2026-10-28). H.264, not HEVC: a recording over what a chat takes is
  shared outside Peel, to any device (Tom, 2026-10-29).
- **Sending.** Peel sends up to 32 MB (`Engine.sendLimit`, what the
  hosted memes server takes), about 8 minutes of a typical segment. A recording over it says "Too large to send in Peel" in
  Account › Segments, and is shared from Finder (Drive, Dropbox): it
  still drags out, to a browser's upload or Finder.
- **The mic** is macOS's default input at Record, for the whole
  recording. With `SCRecordingOutput`, any `updateConfiguration`
  mid-recording, another mic or the same one reopened, finished its file
  there (AirPods connecting, Tom, 2026-10-29); Peel's own writer has no
  such rule, but following the default mid-recording is not built yet.
  The mic's first sample time is logged beside the first frame's, to
  check they are on one clock. A mic
  that sends only zeros for 2 s is deaf (a Bluetooth headset dropped its
  voice link, Tom's recording of 2026-10-28: silence from 0:03 to the
  end); the bar says "No sound from your mic" until it is back.
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
  dot and the time, Discard (X), Pause and Stop (tick). macOS's own menu bar Stop ends it too, and keeps
  the file.
- **Pause** (board: option A, Tom, 2026-10-30). For a wait mid-recording:
  Pause swaps to Play in place, the bar keeping its size, the time held
  and dimmed and the dot a ring. The capture keeps running so Resume is
  instant, so macOS's screen and mic indicators stay on, but nothing is
  written (`RecordingPauses`): on Resume the later samples are moved back by the time paused and the
  file joins with a hard cut, captions following it. Paused time is not in
  the file or counted toward the Segment limit, and a pause lasts until
  you end it. A still screen sends no frames, so the last one seen while
  paused is written at Resume, or the file would show the screen as it was
  before the pause. The first 0.2 s after Resume is dropped: samples arrive
  a moment after they are captured, so these hold the end of the pause.
- **After Stop** (`RecordingController`). The file moves to
  `~/Downloads/Peel Segment <date> at <time>.mp4` (ones named "Peel
  Recording …" before the name are still listed), numbered if that is
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
- **Account › Segments** lists Peel's segments in Downloads (plain
  files by their name, never a link planted under one), newest first:
  the name, date and size, each row draggable into a chat, with Show in
  Finder. A row being transcribed says so.

## Not in v1

Sharing links, a window or app alone, system audio, trimming, a
title or summary from the agent, the iPhone.

## Review of pause (2026-10-30)

`/code-review`, then one independent agent for `/simplify` and
`/security-review` together. Fixed: the last moments of a pause reaching the
file on Resume (now the settle), the seam shorter than a long mic buffer, a
frame held past the end, and the bar's two near-copies made one. A test writes
a file through the real writer with a two minute pause in it. Not applied:
the `state.done` guards in the stream callback are redundant now but older
than this change. Not tried yet in a real recording.

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
recording's limit is its own (`longest`), and sending uses
`Engine.sendLimit`.

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
