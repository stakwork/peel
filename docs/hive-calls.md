# Hive calls from Peel

Status: proposed 2026-10-27. Peel's side is built (below) and waits for
Hive's route. This reopens decision 5 of
`docs/phases/06-calls.md` ("Hive: join only"), which is Tom's to change.

Starting a call in Peel can bring Jamie into it, for an org the person
picks from the orgs Peel is already paired with (Stadeum). One new Hive
route, then a menu section in Peel.

## Why not the official apps' way

When you start a call in a tribe, the Mac and iOS apps:

1. take the tribe's `app_url` (else its `second_brain_url`) and keep the
   first label of its host as a swarm name (`swarm38.sphinx.chat` →
   `swarm38`, `VideoCallHelper.extractSwarmName`);
2. log in to Hive by signing a token with the node key
   (`POST /api/auth/sphinx/token`), which finds the Hive user whose linked
   `lightningPubkey` matches;
3. call `POST /api/workspaces/_/calls/generate-link?swarmName=swarm38`.
   Hive finds the swarm's workspace and uses that workspace's org.

So a call reaches an org only when the tribe has an `app_url` on that
org's swarm and the person linked their Sphinx key in Hive. A new org has
neither. And when step 3 fails, the apps silently post a plain call.

Peel already has what that lookup works out. The pairing (`HiveLink`,
`Sources/PeelCore/Hive.swift`, in the Keychain on Mac and iPhone) holds the
`hivedev_` device credential and one `HivePeer` per org. Each `HivePeer.id`
is that org's central workspace slug: the org's default workspace if the
person can reach it, else the first one with a swarm they can reach (Hive's
`resolveOrgSwarmWorkspaceForUser`). That is the workspace `generate-link`
wants, and always one the person owns or belongs to, so every turn of the
call passes Hive's per-turn workspace check.

What Peel lacks is a credential `generate-link` accepts: it takes a Hive web
session only, and the device credential opens only the pairing routes.

## How a call starts

1. The person opens the call menu in a chat and picks Audio or Video, with
   Jamie from one of their orgs, or with no Jamie.
2. No Jamie: as today. Peel makes a random room and posts it.
3. With Jamie, Peel calls Hive's new route with the device credential and
   that org's `HivePeer.id`. Hive does what `generate-link` does:
   - checks the person and the workspace;
   - mints the call's token and record (`lib/calls/callRecord.ts`);
   - dispatches Jamie into the room with the `callKey`;
   - answers with the link.
4. Peel checks the link against its own call server
   (`CallLink(link:server:)`), sets audio or video itself, posts it as a
   call message and joins.
5. Jamie is already in the room. Its turns run as the person, in that org,
   as for any Hive call.

If Hive fails, nothing is posted. Peel shows why in the chat, and the
person can start the call again with no Jamie. Peel never posts a plain
call in place of the Jamie call that was asked for.

## Hive

**`POST /api/strut-devices/calls`**, beside the pairing routes.

- Header: `Authorization: Bearer hivedev_…`, checked by
  `validateDeviceCredential` (`lib/strut-devices.ts`), which gives the
  user.
- Body: `{ "workspace": "<HivePeer.id>" }`.
- `200 { "url": "https://chat.sphinx.chat/rooms/sphinx.call.-…" }`.
- Errors, as `generate-link` answers them:

| Status | When |
|---|---|
| 400 | no `workspace`; the workspace has no org; its swarm is not active |
| 401 | unknown or revoked credential |
| 403 | the person can no longer reach the workspace or its org |
| 404 | no such workspace |
| 502 | Jamie could not be dispatched (nothing is left behind) |
| 503 | LiveKit or the call base URL is not configured |

**Middleware:** one entry beside the other device routes in
`src/config/middleware.ts`:
`{ path: "/api/strut-devices/calls", strategy: "exact", access: "webhook", methods: ["POST"] }`.

**One copy of the code.** Move everything after the slug lookup out of
`generate-link` into `lib/calls/startCall.ts`:
`startCall({ userId, slug }) → { url } | { status, error }`. That covers the
workspace check, the active swarm, `mintOrgToken`, the call token and
record, and the dispatch. `generate-link` keeps its slug-or-`swarmName`
lookup and calls it, and the new route calls it with the device's user. The
two routes cannot drift apart.

**Tests:** an integration test in the shape of
`workspaces-calls-generate-link.test.ts`, covering:
- credential: none, revoked, valid;
- workspace: reachable, not reachable, no org;
- a failed dispatch leaves no token or record;
- the existing `generate-link` tests still pass against the shared code.

## Peel

Built 2026-10-27 on this branch; waiting for Hive's route.

**`HiveClient.startCall(_ link: HiveLink, workspace:) async throws -> String`**
in `Sources/PeelCore/Hive.swift`, beside `renew`: the link as Hive wrote it.
What it says when Hive makes none:

| Hive answers | Peel says |
|---|---|
| 401 (a revoked device, or a Hive without the route: its middleware answers the same) | "Stadeum didn't accept this device for a call. If it was disconnected in Stadeum, connect it again." |
| any other error | "Stadeum could not start a call with Jamie: <Hive's error>." |
| 200 without a `url` | "Stadeum's call link could not be read." |

**`CallLink.hive(_:server:audioOnly:)`** (`Call.swift`) checks Hive's link
as any link against the account's call server. A link on another host is
refused, naming both hosts. Peel sets `startAudioOnly` itself, since Hive's
link has no query.

**Engine.** `startCall(in:audioOnly:hiveLink:)`: given Hive's link, it
posts that call instead of a new room, with the same rules (connected
only, 3 sats in a tribe).

**`CallStore.start(in:audioOnly:jamie:)`**, where `jamie` is a `HivePeer?`.
With a peer, it asks for the link first, through `hiveCall`, which
`AppModel` points at `Stadeum.callLink(on:)` (the `HiveLink` is
Stadeum's). Then it posts and joins as before. Nothing is posted until Hive
has answered, and nothing at all if Hive fails.

**The pick.** `CallStore.jamiePicks` maps a chat to a peer id, "" for No
Jamie. `pickJamie` stores it in `Setting.callJamie`: the account's, on this
device, not synced. `AppModel.callJamie(in:)` works out which workspace a
call in a chat uses (`HivePeer.jamie`):
1. the chat's pick, while that org is still live;
2. with no pick, the org whose swarm matches the tribe's `app_url` or
   `second_brain_url` (the first label of the host on both sides: the
   tribe's URL and the peer's `baseUrl`), so a tribe that works in the
   official apps works the same here;
3. else No Jamie.

**The menu** gains a section under the two buttons. On the Mac it is
`CallHeaderButton.showMenu` in `Apps/Mac/Peel/CallViews.swift`; on the
iPhone, an inline picker in the Call menu (`ConversationScreen.jamiePicker`),
with `PendingCall.run` passing the pick:

```
Start a new call
  Audio call            ⌥⌘A
    With Jamie from Stakwork
  Video call            ⌥⌘V
    With Jamie from Stakwork
Jamie
✓ Stakwork
  Open Health
  No Jamie
```

- One row per live `HivePeer`, by `name`. An org in `HiveLink.errors` is
  not listed. With no pairing, or a revoked one, the section is not shown.
- Picking a row closes the menu, as every Peel menu does. The next Audio or
  Video call, or ⌥⌘A or ⌥⌘V, uses it.
- It is in every chat, DMs included: Hive does not care where the link is
  posted.
- **iPhone:** the same picker, without the "With Jamie from …" lines under
  Audio and Video. Its code was type-checked against `AppModel` on macOS;
  the iPhone app was not built here (no iOS core slices on this Mac), and
  CI does not build it.

**Tests:**
- `HiveTests`: the request, Hive's refusals in words, and the default
  pick.
- `CallTests`: `HiveCallLinkTests`, and the pick kept with the account.

## Unchanged

- Joining a Hive link from anyone (06-calls: `callKey` and `hiveToken`
  passed on).
- The official apps' `app_url` path and `generate-link`'s contract.
- Hive's room names, `sphinx.call.-<swarm>.sphinx.chat-.<unix seconds>`.
- sphinx-voice: it gets the `callKey` from the dispatch either way.
- The pairing and its daily renewal.

## For Tom

Reopening "Hive: join only" (06-calls decision 5).

## Decided (2026-10-27)

For each of these, the simple choice for now, to revisit once it is in use:

1. **Who speaks as you.** The same as the official apps today. Hive runs
   every turn of a call as the person who started it, whoever on the call
   is speaking (sphinx-voice `AGENTS.md`). Reopened 2026-11-02: a paired
   Peel now joins as its own person ("Who is speaking", below); everyone
   else still speaks as the starter. In a large public tribe that is
   everyone who joins. Some of Jamie's writes wait for your approval, but
   what it reads, and the jobs it starts, run as you. For now, no warning
   in the menu and no rule by tribe size.
2. **The call server's host.** Peel accepts a link only on its own call
   server (`chat.sphinx.chat` unless set) and refuses any other, naming
   both hosts. Hive's production `LIVEKIT_CALL_BASE_URL` is most likely
   that host: Peel joined the real #hive call (06-calls, 2026-10-12). The
   first real call confirms it.
3. **Room names** stay as Hive makes them today, ending in a timestamp
   anyone can guess. Making them random would change the official apps'
   Hive links too, so it is a change of its own.
4. **No limit** on how many calls a device starts.
5. **The call's org token stays.** `startCall` mints it as `generate-link`
   does, though sphinx-voice no longer uses it: it sends the `callKey` to
   `/api/calls/*` and never calls `/api/calls/exchange-token`. Dropping the
   token is a separate cleanup.

## Who is speaking (2026-11-02)

Hive's plan: `docs/plans/call-speaker-identity.md` in hive
(stakwork/hive#5699; voice's half is stakwork/sphinx-voice#23). Tom starts
a call, Evan asks Jamie for a PR, and today the turn runs as Tom: his strut
actor, his budget. Hive can only run it as Evan if it knows which voice on
the call is Evan's, and nothing a participant gets from the call server
says so. The server mints any identity for anyone who asks, and passes
whatever metadata the joiner sends. So a paired Peel asks Hive for its
ticket instead.

- **Which calls.** A room Hive made, `sphinx.call.-<host>-.<stamp>`
  (`CallLink.isHive`, the whole shape): Peel's own rooms and the apps'
  never start with `-`. A plain call in a DM never reaches Hive.
- **How long.** 5 s for Hive to answer, then the call server: a Hive that
  is down never holds a join for long. A join given up meanwhile stays
  given up.
- **The request.** `POST /api/strut-devices/calls/ticket { room,
  participantName, metadata? }` with the device credential
  (`HiveClient.callTicket`): the same name and photo the call server would
  get. Hive answers in the call server's shape, with a token whose
  identity it minted (`hive_<32 hex>`) and recorded against the device's
  person. Voice sends that identity with each request it hears, and Hive
  runs the turn as that person.
- **The checks.** Hive's answer goes through the same checks as the call
  server's (`CallServer.ticket`): the media host allowed for the account's
  call server, the room, the expiry. A ticket from Hive is never trusted
  any further than one from the call server.
- **Any failure joins as before.** No Stadeum, revoked, a Hive without
  the route, a 403 / 404 / 503, an answer that fails the checks: Peel
  asks the call server as it always has, and the call runs as its
  starter. The failure's kind goes to the diagnostics ring; nothing is
  shown, since the join still works.
- **Where it lives.** The engine decides (`Engine.callTicket(for:in:hive:)`,
  the name and photo built once), Stadeum asks
  (`Stadeum.callTicket`), `CallStore.join` hands one to the other
  (`CallStore.hiveTicket`, wired by `AppModel`). The CLI's `call-ticket`
  asks the call server only.

Review (2026-11-02, /code-review): fixed the cancel (URLSession's own
error was taken for a failure), the 30 s wait (now 5 s) and a prefix-only
room check. Not applied: a 401 here does not mark Stadeum revoked (its
renewal does); a misconfigured Hive is only an error kind in the ring (the
join still works, and the ring keeps no words); AppModel's three-line
wiring has no test of its own (a real join is its owner).

Done when: a Hive room's join asks Hive first and uses its ticket, any
failure falls back to the call server, another room never asks Hive, and
the tests say so.

## From a box (2026-11-24)

stadeum `plans/group-calls.md` (work item 3) and `plans/call-canvas.md`
(work item 6); strut#881 (`GET /voice/calls`, `POST /voice/calls/ticket`,
`POST /voice/calls` forwarded to the box's voice service as the person);
stakwork/sphinx-voice#45–#47 (the group session). A box has no Hive: its
own voice service joins a Peel call itself, end-to-end encrypted with the
call's key, hearing and speaking with the box's own models. Peel asks the
box's strut as the person, with the token it keeps for the box
(`BoxLink`). Hive's calls are unchanged and stay in the clear.

- **Which boxes the menu offers.** Each linked box is asked
  `GET /voice/calls` as the person when a chat opens (unless asked in the
  last minute) and again as the Mac's menu opens (`Boxes.readCalls`). A
  box is listed beside the Stadeum orgs only when it answers
  `group: true` and its `livekit`, read as LiveKit reads it, is a media
  server this account's call server may name in its tickets
  (`BoxCalls.joins`, `CallServer.mediaURL`): a box on another LiveKit
  would sit in a room nobody on the call is in. A box picked earlier stays
  listed while Peel is linked to it, so the menu says what is true. The
  pick is kept per chat with the org picks (`Setting.callJamie`, the box
  as `box:<address>`, as a tribe's Jamie row names it; `CallJamie`).
- **Record on the canvas.** Beside a box pick, off unless chosen, per
  chat and for this run of Peel: everything said then reaches the box's
  model (call-canvas.md §7). Sent as `record: true`. Offered only while
  the box's `GET /voice/calls` does not answer `record: false`, its voice
  service having no package that says what to record onto (call-canvas.md
  §8); a voice service from before says nothing and is offered it as
  before (`BoxCalls.records`, `AppModel.offersRecording`). Chosen earlier
  on a box that now can't, the call brings Jamie without (`Boxes.startCall`).
- **Starting** (`CallStore.start` with `.box`). The engine makes the room
  and a fresh key (`CallLink.newKey`: 32 random bytes as base64) and checks
  it could post the call (`Engine.newCall`); the box is asked in,
  `POST /voice/calls { mode: "group", room, key, record? }`
  (`Boxes.startCall`, which first asks the box again whether it can join a
  call on this call server, unless it said so in the last minute); only
  then is the link posted with its key (`Engine.postCall`) and joined. A
  refusal posts nothing and is said in the chat, as for Hive: 400 in the
  box's words, 409 Jamie already in that room, 503 not ready or could not
  join, and an answer from a voice service before group calls (a room of
  its own, or not `encrypted: true`).
- **The key in the link.** `https://<call server>/rooms/<room>?startAudioOnly=true#<key>`,
  the key percent-encoded as meet's `encodePassphrase`
  (`encodeURIComponent`) writes it and read as its `decodeURIComponent`
  reads it, so a key written bare reads the same (`CallLink.encryptionKey`;
  never in a description). A fragment that is not a key (1–2048 of
  base64, base64url or JWT characters) refuses the whole link, so a link
  meant to be encrypted is never joined in the clear; a bare `#` is a call
  in the clear. The official apps join such a link in the clear and hear
  nothing.
- **Joining encrypted** (`CallRoom.options`, `Apps/Shared/CallEncryption.swift`):
  `encryptionOptions` with `BaseKeyProvider(isSharedKey: true,
  sharedKey: key)`, the key's UTF-8 bytes as the box and meet key it, and
  the microphone without DTX or RED, as Talk. What is wrong is said under
  the call (`CallEncryption`), the worst first: your own track in the
  clear, who can't be heard (by the name they joined with), who joined
  without encryption (LiveKit plays a track in the clear on an encrypted
  call without a word, `E2EEManager.addRtpReceiver`, so Peel looks at
  every publication's `encryptionType`, `Room.publishing`), that no one
  hears you, messages that can't be read. On a call in the clear whose
  others encrypt (its link posted again without the key), that it has no
  key. The header's Join takes the keyed link of a room over a keyless
  one, and the same room with another key is another call
  (`CallStore.join`).
- **Who is speaking** (group-calls.md §7). A join of an encrypted call asks
  every linked box at once, but one that said `group: false`, for the
  person's own ticket (`POST /voice/calls/ticket { room, name }`,
  `Boxes.callTicket`), takes the first, waits at most 8 s and otherwise
  joins through the call server, as the call's starter (404: that box's
  Jamie is not in the room). The box's ticket goes through the call
  server's checks (`CallServer.ticket(fromBox:)`); its identity must be
  `box_<32 hex>`, never another participant's, and the token's `sub` that
  identity. It carries the name only: no photo. A join given up ends the
  asking at once.
- **Recorded.** While Jamie's `recording` attribute is `"true"`, the call
  shows Recording, with its toast, on the Mac and the iPhone
  (`CallChatWire.jamieRecords`); the iPhone's call screen shows the
  indicator for the call server's recording now too.

Checked live (2026-11-24, strut `main` @11517b34, voice #47 @c7f9068,
LiveKit 1.13 dev): Peel's `BoxClient` through strut as a person (ready,
asked in with `record: true` and the box's scribe job started, the same
room again 409, a `box_` ticket that passes the call server's checks,
another room 404); and the LiveKit Swift SDK 2.10.2 with these room
options and that ticket, which saw Jamie with `tts` and `recording: "true"`,
its audio decrypting, and its history line ("Jamie is taking notes on the
canvas.") decrypted; with a wrong key, that line failed to decrypt. Not
checked live: the menus in the apps, Jamie heard aloud or answering, meet
in the same call, a call message posted on a real server.

Not done: captions on group calls (the box sends them as `lk.transcription`
text streams, the speaker by `lk.transcribed_track_id`); meet (work item 4).
Known: on LiveKit Swift 2.10.2 a decrypted data packet reaches the room's
delegate with `encryptionType` none and no sender (the SDK replaces the
packet's encrypted case with the user packet, and looks the sender up from
the inner packet, which senders leave empty). So chat sent in the clear
into an encrypted call, by someone holding the LiveKit admin key every box
shares, cannot be told apart and is shown; and Jamie's artifacts in the
call chat, read only from a sender known to be Jamie, are not shown on a
box's call.

### Jamie's screen, live (2026-11-24)

stadeum `plans/call-canvas.md` §6.5 and §8, work item 12. A box's Jamie
shares the canvas as a screen-share video, which nobody can scroll. For a
person linked to the box, the tile shows the app itself:

- **Where.** Jamie's `screen` attribute, set by voice while its screen
  track runs: strut's deep link on the box,
  `https://strut.<host>/?app=<name>&input=<query>`
  (`CallChatWire.jamieScreen`; an empty one, or anything but http or https,
  is none). Read only from Jamie's screen tile (`Tile.app`).
- **When it opens.** Only from the screen of the box's own Jamie, in a
  call this device knows that box's Jamie is in (`Boxes.inCall`, by room
  and key: the same room with another key, or none, is another call). The
  box is the one Peel asked in or the one that gave the person's ticket.
  Its Jamie's LiveKit identity is what the box answered: `agent` to
  `POST /voice/calls`, and `agent` beside a ticket, which voice does not
  send yet (until it does, a person who joined sees the video). The
  link's address is that box's own (scheme, host and port), in its UI's
  folder, and names one of the box's own apps, never `@<peer>/…` or
  another server's public app (`BoxApp`, through `StrutAppLink`). Peel builds the
  page itself from the app and its view (`OrgPageRequest.showing`, with
  `&solo=1`), never loading the attribute as given, and opens it as the
  box's member, the token checked first and renewed once if refused
  (`Boxes.screen`), as a box's page opens anywhere: a store that keeps
  nothing, the token as the first request's bearer and in the page's
  storage, never in an address; nowhere but that strut's UI; a link out or
  to another of its apps only on the person's own click or tap. Anything
  else, or a page that does not load, keeps the video.
- **The tile.** The app shows only while Jamie's screen is the large tile
  (focused, as a screen is when it starts, `refocus`): clicks and taps go
  to the page, and a button at its top right goes back (on the Mac,
  Escape too, but while the page has the keyboard Escape is the page's). Small, in the grid, the strip or the row, it is the video
  and a click focuses it. Going back and focusing again opens the app
  again, at the view the attribute names, so it follows again.
  The Mac's layout is as before (`CallStage`); on the iPhone, everyone
  else sits in a row above the focused tile (`IOSCallStage`).
  - Mac: `BoxPageView` (`StrutPage.swift`), the web pane's rules for a
    box's page, which share `StrutPage.newWindow(for:from:box:open:)`.
  - iPhone: `OrgPageInPlace` (`OrgPageSheet.swift`), the sheet's page
    and prompts (the app wallet's sheets, location) with no sheet.
- **Who can set it.** Attributes pass outside the call's encryption, and
  anyone on the call can join under Jamie's name with a `tts` attribute.
  Hence the box's own Jamie alone, by the identity the box gave: the call
  server names each joiner `<name>__<4 random>`, so no one else takes it.
  A person who joined through the call server (no box answered in time)
  sees the video.
- **In the tile, a page is no more than a page.** No camera or microphone
  (the call holds them) and no sound before a click or tap, on both. On
  the Mac no download; on the iPhone the sheet's prompts (the app wallet,
  location, a download to share) as anywhere else.

Not checked live: voice does not set `screen` yet (work item 11), and the
call test room needs Tom at the Mac. Tested: the link read and matched
(`BoxCallsTests.jamiesScreenOpensOnlyALinkedBoxsOwnApp`), Jamie's identity
from both answers (`askingJamieInPostsTheRoomAndTheKey`,
`thePersonsTicketIsTheBoxsOrNone`), the page opened as the member from
that Jamie in that call only (`BoxesTests.jamiesScreenOpensOnTheBoxInTheCallAsItsMember`,
an impostor and a keyless repost included, and the ticket's box),
`record` (`aBoxSaysWhetherItRecords`, `aBoxThatCantRecordIsNeverAskedTo`).

## Jamie leaves (in-call picker)

The Jamie card in the Mac call chat shows what the room has, not the
start preference (`calls.jamiePicks`, the tribe's org): Jamie's source
(the chat's pick, else the first option) while Jamie is in the call
(`CallSession.jamieInCall`), No Jamie while it is not. Choosing a Jamie with
none in the call only sets the preference for the next call; Peel does not
bring Jamie into a running call. The iPhone's picker is the start-call
setting only, and is unchanged.

Choosing No Jamie while Jamie is in the call (`CallSession.removeJamie`)
asks Hive, then asks Jamie itself to leave (`CallChatWire.leave()`,
`{"type":"leave"}` to its identity on `lk-chat-topic`, best effort). On
success the picker says No Jamie, the chat notes that Jamie left and
transcription stopped; on failure the picker keeps showing Jamie and a notice
says Jamie could not be removed. The chat's start preference is left alone.
A box's Jamie is not Hive's: no Hive request is made, and the leave message
is all Peel has (a box that ignores it stays in the room; a box route to
leave is not built).

**Hive must implement this route (Peel side is built):**
**`POST /api/strut-devices/calls/jamie/remove`**

- Header: `Authorization: Bearer hivedev_…`, as `/calls`.
- Body: `{ "workspace"?: "<HivePeer.id>", "room": "<room name>" }`.
- `200`: Jamie's agent participant is removed from the LiveKit room
  (`RemoveParticipant`), and transcription and transcript saving stop for
  that call's record. Other statuses are shown as Hive's error; 401 reads as
  a revoked device.

Until Hive has it, the picker's No Jamie fails for an org's Jamie and says so.
Tests: `HiveTests.jamieIsRemovedFromACallWithTheDeviceCredential`,
`aRemovalHiveRefusesIsSaid`, `CallChatTests.theLeaveRequestSaysLeave`.

## Found along the way

The Mac app makes an audio call with `link + "&startAudioOnly=true"`
(`NewChatViewController+BottomTopBarsExtension.swift`). That assumed Hive's
link already had a `?callKey=…` query. Since hive#5638 it has no query, so
the room name now ends in `&startAudioOnly=true`. That is not the room
Jamie was dispatched into. Not checked on a device.

## Work

1. Hive: `lib/calls/startCall.ts`, the route, the middleware entry, tests.
2. Peel: `HiveClient.startCall`, `CallLink.hive`, the engine's
   `hiveLink`, `CallStore`, the Mac and iPhone menus and the default from `app_url`.
   Built on this branch, with an entry in `docs/phases/06-calls.md`. To
   check against a Hive that has the route.
3. Peel: who is speaking (above): `CallLink.isHive`,
   `HiveClient.callTicket`, `Engine.callTicket(for:in:hive:)`,
   `Stadeum.callTicket`, `CallStore.hiveTicket`.
