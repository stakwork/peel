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

**The menu** (Mac, `CallHeaderButton.showMenu` in
`Apps/Mac/Peel/CallViews.swift`) gains a section under the two buttons:

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
- **iPhone:** no menu yet. Calls are not on the phone
  (`CallProvider.unavailable`), so its call button posts nothing. When they
  come, the same `CallStore.start` takes a `jamie`.

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
   is speaking (sphinx-voice `AGENTS.md`). In a large public tribe that is
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

## Found along the way

The Mac app makes an audio call with `link + "&startAudioOnly=true"`
(`NewChatViewController+BottomTopBarsExtension.swift`). That assumed Hive's
link already had a `?callKey=…` query. Since hive#5638 it has no query, so
the room name now ends in `&startAudioOnly=true`. That is not the room
Jamie was dispatched into. Not checked on a device.

## Work

1. Hive: `lib/calls/startCall.ts`, the route, the middleware entry, tests.
2. Peel: `HiveClient.startCall`, `CallLink.hive`, the engine's
   `hiveLink`, `CallStore`, the Mac menu and the default from `app_url`.
   Built on this branch, with an entry in `docs/phases/06-calls.md`. To
   check against a Hive that has the route.
