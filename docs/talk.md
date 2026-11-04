# Talk to Jamie

Status: step 1 built 2026-11-03 (Peel's side), checked against a stand-in
for the home and the agent (below). Step 2, end-to-end encryption, built
2026-11-04 (below); it needs the voice service that takes the key
(stakwork/sphinx-voice, `encryption.ts`).

A member taps **Talk to Jamie** on a paired org and has a live voice call
with that org's agent. The design is strut's `plans/private-voice.md` (§3.5,
§4.1 "The contract", §10 "Step 1 in detail"). This page is Peel's side of
it.

## Where it is

- **iPhone:** Chats › Apps. A "Talk to Jamie" section above the apps, one
  row per workspace in use (`AppModel.talkHomes`). The Apps row shows once
  there is a workspace to talk to.
- **Mac:** Account › Connections › Stadeum workspaces. A "Talk to Jamie"
  button on each paired workspace's row. It opens the Talk window.
- Not in the agent DM: stakwork/peel#468 puts its own voice mode there.

## How a call goes

1. `TalkHome.startCall()` (`Sources/PeelCore/TalkCall.swift`) sends
   `POST {home}/voice/calls`:
   - `{home}` is the org's strut, the workspace's `HivePeer.baseUrl`;
   - the bearer is the person's token for it, from Stadeum's pairing;
   - the body is `{ "key": "<base64>", "voice": "af_heart", "artifacts": true }`:
     the call's key (below), Jamie's voice as kept on this device (below),
     and the capability: this Peel shows artifact cards (below). A 400 is
     a voice the home does not know, said in its words.
   It goes through `Web.requestStrut`: https anywhere, plain http only to this
   device.
2. The answer is `{ url, room, token, identity, agent, encrypted, voice }`
   (`TalkTicket`). `voice` is the voice in effect, which the screen shows; one
   Peel does not know, or none, leaves the screen on the one asked for. Peel takes the LiveKit `url` the home names. It does not
   apply the call server's media-host rule (`CallServer.mediaURL`), since
   the member's own home named it in answer to their own request. Three
   checks still hold:
   - `wss://` anywhere, `ws://` only on this device;
   - the token must be for the room named;
   - `encrypted` must be true: the agent joined with the call's key. A home
     whose voice service predates it answers false, and the call is refused
     ("can't make an encrypted call yet"), never made in the clear.
3. `TalkStore` (`Sources/PeelUI/TalkStore.swift`, `AppModel.talk`) joins the
   room through the platform (`CallProvider.talk`), as a `TalkSession`
   (`Apps/Shared/TalkSession.swift`, both apps). It sits beside `CallStore`,
   not in it: no `CallLink`, no call server, no chat message. One call at a
   time: Talk will not start while the device is on a group call, and a
   group call will not be joined or started while Talk is on (`CallStore.busy`);
   each says to leave the other first. A Talk call joins only once the rooms
   left before have said goodbye, so on the phone their leaving cannot take
   the audio session from it.
4. The call screen (`Apps/Shared/TalkView.swift`) reads two things from the
   room:
   - the agent participant's `lk.agent.state`, folded with the room's
     connection into `TalkPhase` ("Listening", "Thinking…", "Speaking", …);
   - the text streams on `lk.transcription`, folded into lines by
     `TalkTranscript`, the way LiveKit's own `TranscriptionStreamReceiver`
     folds them (one line per speaker and `lk.segment_id`). A line is the
     member's when `lk.transcribed_track_id` names one of their tracks, or
     the stream came from their identity.
   - the text streams on `sphinx.artifacts` (`TalkArtifacts`, sent to the
     member only, inside the room's end-to-end encryption like the
     transcript): one as strut's run for a turn ends, and one as a finished
     job's summary is queued to be spoken, JSON `{ id, timestamp, artifacts:
     [strut's ArtifactRef…] }`. Each entry is resolved against the call's
     home (the org's peer id) as in a call's chat
     (`AgentArtifact(strutEntry:workspace:)`), capped at 20 a stream; a
     payload id seen before is ignored. `TalkSession` keeps up to 30 cards,
     each shown in the transcript under the reply it came with
     (`TalkCardAnchor`, in `TalkStore.swift`). A card usually comes before
     that reply's line, which LiveKit Agents send in time with the audio. So
     it goes under Jamie's line being said when it came; else it waits at
     the end, then goes under the next line if that is Jamie's, or stays
     above it if it is the member's. It never moves; once the 200-line cap
     has dropped its lines it is at the top. Each card is a row
     (`TalkArtifactRow`) that opens the page. On the phone the page opens in
     a sheet of the call screen (the full-screen cover hides the root's
     sheet), an https link in an in-app Safari sheet; the call stays up. One
     that cannot open here says why.
   The circle above the words is a waveform (`TalkWaveView`; the pure parts
   are `TalkWave` in `Sources/PeelUI/TalkWave.swift`):
   - Speaking: rounded bars in the accent colour move with the agent's
     audio. Listening: they move with the member's microphone, in a lighter
     neutral; muted, they lie low, flat and dimmed.
   - Thinking: a calm wave travels across them. Calling, connecting or
     getting ready: a slow breath. Jamie gone: still.
   - The level is sampled about 30 times a second: the loudest buffer since
     the last frame. It rises fast and falls slowly (`LevelSmoother`), each
     bar wobbles at its own pace, and a change of phase glides.
   - With Reduce Motion the bars hold their shape, and only their size
     follows the level, slowly.
   - VoiceOver reads the words under the circle.
5. Mute is for talking to someone else in the room. The member interrupts
   the agent just by speaking: Apple's voice processing stays on (LiveKit's
   default; on the phone a `.voiceChat` audio session, as for calls), so the
   agent never hears itself.
6. Jamie's voice (below) switches mid-call.
7. Hanging up is leaving the room (`TalkStore.hangUp`). The phone's cover
   and the Mac's window go with it; closing the Mac's window hangs up too.

A refusal is the home's own `{ error }`, after what the status means
(`TalkRefusal`). 402 (step 3) says the balance and the minimum.

## Jamie's voice

A small round button beside Mute shows Jamie's voice: ♀ for `af_heart`
(female, the default), ♂ for `am_michael` (male). The glyphs are text, with
the variation selector U+FE0E, so they never show as emoji. VoiceOver reads
"Jamie's voice: female" or "Jamie's voice: male" (`TalkVoice`, in
`TalkCall.swift`). A tap switches it (`TalkStore.toggleVoice`):

- The choice is kept per device, in `UserDefaults` under `talkVoice`. Each
  call starts with it.
- While calling, the switch waits: the room is told once it is joined and
  connected, and it wins over the answer's `voice`, which was for the voice
  asked before.
- On a call, Peel sets its own participant attribute `voice` to the voice's
  name (`TalkSession.setVoice`). The member's LiveKit token allows updating
  its own attributes. The agent switches from its next sentence; what it is
  saying finishes in the old voice. A set that fails says so quietly under
  the buttons.

## LiveKit 2.10.2

Peel's pin has everything this needs:
- `Room.registerTextStreamHandler(for:onNewStream:)`, with
  `TextStreamReader.info.attributes` and `.id`;
- `Participant.attributes`;
- `LocalParticipant.set(attributes:)`, for Jamie's voice;
- `Participant.trackPublications`, for the member's own track ids;
- `RemoteAudioTrack.add(audioRenderer:)` and
  `AudioManager.shared.add(localAudioRenderer:)`, for the waveform:
  - each hands an `AudioRenderer` the decoded agent audio, or the microphone
    after voice processing, about every 10 ms;
  - `TalkLevelMeter` keeps the loudest RMS of each.
  `Participant.audioLevel` is too slow for this: the server's active-speaker
  updates set it a few times a second, and only while someone is speaking.

It also has `AgentState`, `Participant.agentState` and an internal
transcription receiver. Peel reads the attribute and the streams itself, so
its pure parts stay testable without LiveKit.

## End-to-end encryption (step 2)

Every call is end-to-end encrypted with a key made for it, so the LiveKit
server forwards the audio both ways and the live text without being able to
read them (strut's `plans/private-voice.md` §4.1).

- `TalkHome.newKey()` makes 32 random bytes and sends them as base64 in
  `POST /voice/calls`; the ticket carries the same string (`TalkTicket.key`,
  never described or logged, like its token).
- `TalkSession.options(key:)` joins with
  `RoomOptions(defaultAudioPublishOptions: AudioPublishOptions(dtx: false, red: false), encryptionOptions: EncryptionOptions(keyProvider: BaseKeyProvider(isSharedKey: true, sharedKey: key)))`:
  - `encryptionOptions`, not the deprecated `e2eeOptions`, which leaves the
    data channel, and so the `lk.transcription` text, in the clear;
  - the SDK keys with the string's UTF-8 bytes, and the agent does the same
    with the string it was sent, so both derive one AES key;
  - Opus RED off, which this SDK (2.10.2) leaves on under encryption and the
    server cannot repackage for an encrypted track; DTX off, so packets keep
    a steady rate through silence.
- What stays in the clear is LiveKit's signaling: the room name, the random
  identities, the `lk.agent.state` and `voice` attributes.
- A failure is said, not hidden. The agent's state comes over that
  signaling, so a call whose key doesn't match would still say "Speaking"
  over silence. `TalkSession` hears LiveKit's encryption state for each
  track, and any text packet that won't decrypt (`TalkEncryption`). The call
  screen then says "This call's encryption failed: Jamie can't be heard" (or
  "can't hear you", for the member's own track) before anything else.
- The key crosses TLS to the home: whoever runs the home (a swarm, the demo
  box) could read it there. Sealing it to an attested home is step 4.

## Trying it locally

A development profile names a home with launch arguments, as `-hiveURL`
does:

```sh
-profile <dev> -talkHome http://127.0.0.1:3000 -talkHomeToken <person token>
```

- The token is strut's `POST /peers/tokens { actor }`, called with the API key.
- The home shows as a row of its own in both places above.
- `-talkAtLaunch YES` starts the call as Peel opens, with or without an
  account. That is how the iPhone simulator was checked, since a new
  development profile has no account:

```sh
xcrun simctl privacy <udid> grant microphone com.sphinx.peel
xcrun simctl launch <udid> com.sphinx.peel -profile talkdev \
  -talkHome http://127.0.0.1:3999 -talkHomeToken <token> -talkAtLaunch YES
```

The real home runs on a Mac too: strut and the voice service's 1:1 mode
beside `livekit-server --dev` (sphinx-voice's AGENTS.md, "Running it locally
on a Mac"). Or a stand-in can play the home and the agent:
- `livekit-server --dev --bind 127.0.0.1` (`brew install livekit`);
- a small server answering `POST /voice/calls` with tokens minted for
  `devkey` / `secret` and `encrypted: true`;
- a participant that joins with the request's `key` (shared-key encryption,
  the key string's UTF-8 bytes, `encryption` not `e2ee`), sets
  `lk.agent.state` and streams `lk.transcription` text, as agents-js does
  (the Python `livekit` SDK's `set_attributes` and `stream_text`).
