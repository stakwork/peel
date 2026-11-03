# Talk to Jamie

Status: step 1 built 2026-11-03 (Peel's side). strut's `/voice/calls` route
and the voice service it forwards to are not built yet; Peel was checked
against a stand-in for both (below).

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
   - the body is `{}`.
   It goes through `Web.requestStrut`: https anywhere, plain http only to this
   device.
2. The answer is `{ url, room, token, identity, agent, encrypted }`
   (`TalkTicket`). Peel takes the LiveKit `url` the home names. It does not
   apply the call server's media-host rule (`CallServer.mediaURL`), since
   the member's own home named it in answer to their own request. Two checks
   still hold:
   - `wss://` anywhere, `ws://` only on this device;
   - the token must be for the room named.
3. `TalkStore` (`Sources/PeelUI/TalkStore.swift`, `AppModel.talk`) joins the
   room through the platform (`CallProvider.talk`), as a `TalkSession`
   (`Apps/Shared/TalkSession.swift`, both apps). It sits beside `CallStore`,
   not in it: no `CallLink`, no call server, no chat message. Talk will not
   start while the device is on a group call; it says to leave that first.
4. The call screen (`Apps/Shared/TalkView.swift`) reads two things from the
   room:
   - the agent participant's `lk.agent.state`, folded with the room's
     connection into `TalkPhase` ("Listening", "Thinking…", "Speaking", …);
   - the text streams on `lk.transcription`, folded into lines by
     `TalkTranscript`, the way LiveKit's own `TranscriptionStreamReceiver`
     folds them (one line per speaker and `lk.segment_id`). A line is the
     member's when `lk.transcribed_track_id` names one of their tracks, or
     the stream came from their identity.
5. Mute is for talking to someone else in the room. The member interrupts
   the agent just by speaking: Apple's voice processing stays on (LiveKit's
   default; on the phone a `.voiceChat` audio session, as for calls), so the
   agent never hears itself.
6. Hanging up is leaving the room (`TalkStore.hangUp`). The phone's cover
   and the Mac's window go with it; closing the Mac's window hangs up too.

A refusal is the home's own `{ error }`, after what the status means
(`TalkRefusal`). 402 (step 3) says the balance and the minimum.

## LiveKit 2.10.2

Peel's pin has everything this needs:
- `Room.registerTextStreamHandler(for:onNewStream:)`, with
  `TextStreamReader.info.attributes` and `.id`;
- `Participant.attributes`;
- `Participant.trackPublications`, for the member's own track ids.

It also has `AgentState`, `Participant.agentState` and an internal
transcription receiver. Peel reads the attribute and the streams itself, so
its pure parts stay testable without LiveKit.

## Step 2 (not built)

Peel will make a 32-byte key per call and send `{ "key": "<base64>" }`. It
will then join with:
- `RoomOptions(encryptionOptions:)`, the shared key in a shared-key provider;
- `defaultAudioPublishOptions: AudioPublishOptions(dtx: false, red: false)`.

The places are marked in `TalkHome.startCall` and `TalkSession.room`. Until
then, an answer with `encrypted: true` is refused: step 1 sends no key.

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

Without strut's route, a stand-in can play the home and the agent:
- `livekit-server --dev --bind 127.0.0.1` (`brew install livekit`);
- a small server answering `POST /voice/calls` with tokens minted for
  `devkey` / `secret`;
- a participant that sets `lk.agent.state` and streams `lk.transcription`
  text, as agents-js does (the Python `livekit` SDK's `set_attributes` and
  `stream_text`).
