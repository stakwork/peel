# Phase 3 — Tribes, threads and attachments

Status: tribes built and reviewed on branch `phase3/tribes`, rebased onto
the status branch (2026-10-07); threads and attachments planned.

## Tribes

Done means: list joined tribes, join from a link, read a tribe's messages
with each member's name and photo, post, see members, leave. Every action an
engine operation with a CLI command; verified on a local stack.

### How tribes work (checked against the code, 2026-10-07)

- A tribe is a core contact with no contact key (people always have one).
  The tribes server (`sphinx/tribes`) is both an MQTT client that forwards
  messages and an HTTP registry: `GET /tribes/<pubkey>` gives name, `img`,
  `description`, `route_hint`, `price_to_join`, `price_per_message`,
  `escrow_amount` (all msat), `private`, `deleted`.
- The tribes server rewrites what it forwards (`mutate_msg_to_forward`):
  `sender.pubkey` becomes the tribe's, `contact_pubkey` is removed, the alias
  is made unique in the tribe (`name_2`), `date` is set and the sender's uuid
  kept as `originalUuid` under a new uuid. So a tribe message arrives exactly
  like a DM from the tribe: the topic's child index and the signed sender
  both name the tribe, and the existing "sender names only themself" check
  holds unchanged. The member is only the alias and photo in `sender`.
- Our own messages come back from the tribe (`bounce_back_pubkey`), marked
  `fromMe`. A tribe send has no copy to self (`send.rs`).
- Link: `sphinx.chat://?action=tribeV2&pubkey=<pubkey>&host=<host>`.
  Production host comes from the config endpoint's `tribe_host`
  (`tribes.v2.sphinx.chat`); https except for a loopback host.
- Only the owner gets the member list (`TribeCmd::ListMembers` checks the
  owner); the answer comes back on the management topic as `tribe_members`.
- Leaving sends type 15 (GroupLeave), as the official apps do. The tribes
  server does **not** remove the member on a leave (`GroupLeave => {}` in
  `forward.rs`), so the tribe keeps sending; the Mac app ignores it through
  `deletedTribesPubKeys`.
- Costs, as the Mac app: join pays `price_to_join` or 1 sat; each message
  pays `max(price_per_message + escrow_amount, 3 sats)`. Aliases in tribes
  are letters, digits and underscores (`fixedAlias`).

### Built

- `Tribe.swift`: the `Tribe` record, `TribeLink` parsing, `TribeInfo` from the
  registry, `NewTribe` (what a tribe is created with), `TribeMembers`.
- Storage migration `v6`: the `tribe` table (registry fields, `isOwner`,
  `left`) and the `message_unread` index (chat, fromMe, type, serverIndex), so
  unread counts read only the index even when a tribe's whole history is
  unread. v6 is a plain create: during the rebase onto the status branch a
  `.ifNotExists` repair covered dev profiles made before the rebase (where the
  tribe table had been recorded as "v4"); Tom deleted those profiles, so the
  repair was dropped and v6 cannot mask a real schema problem. Profiles that
  ran the interim v6 (with an `ownerAlias` column, no `message_unread` index)
  still work: the extra column is nullable and unread counts fall back to
  `message_chat_serverIndex`.
- `conversations()` and `readStates()` share one chat set (ready contacts
  UNION ALL joined tribes; a tribe has no contact key, so it is never a ready
  contact). Tribes get unread counts and mute levels like DMs: the read
  marker and mute level are the server's, per chat pubkey. Messages of types
  14/15 (joins and leaves) are shown alongside text.
- `Engine`: `tribeInfo(link:)`, `joinTribe(link:agreedJoinMsat:)`,
  `leaveTribe`, `tribeMembers`, `createTribe(NewTribe)`, and `sendText`/`resend`
  to a tribe through the shared `deliver` (sats, tribe alias, `isTribe`).
  A send to a left tribe throws `notInTribe`. In `commit`, a message whose
  chat is a tribe does not rename the contact, takes its time from the
  tribe's `date`, and is dropped if the tribe was left (the sync cursor still
  advances past it, `Setting.droppedIndex`, cached in the engine). Our own
  message coming back from a tribe takes over the row written at send
  (matched on `originalUuid`, decided in the engine and passed to storage as
  `replaces`) and is marked delivered. Our own join or leave (replayed on a
  restore, or sent from another device) sets whether we are in the tribe.
- Tribes host (`Setting.tribeHost`): set only by `Account` (config on signup
  and restore, `--tribe-host` in the CLI) or, for accounts without one, from
  the public config on coming online (not for a loopback server). A joined
  link never sets it: anyone can write a link, and the host decides which
  discovered tribes are looked up.
- Restore: a tribe is recognised from a join that carries the tribes server's
  `host`, only for a contact with no contact key; its name is looked up only
  when that host is the account's `tribeHost`. A tribe found on another host
  stays nameless until its link is pasted, which then looks it up without
  joining again. Registry details are refreshed for joined tribes on each
  connect, four at a time, one write, one refresh in flight.
- `createTribe` is fit for production: name, description, price per message,
  price to join, escrow, private, unlisted, owner alias (the account's tribe
  alias); prices in msat as the official apps send them. It needs the tribes
  host so the new tribe has a link. CLI only; no app UI yet.
- CLI: `tribes`, `tribe-join <link>`, `tribe-members <pubkey>`,
  `tribe-leave <pubkey>`, `tribe-create <name> [--description]
  [--price-per-message <sats>] [--price-to-join <sats>]`, one `messages
  <pubkey>` for contacts and tribes, `send` to a tribe pubkey, `--tribe-host`.
- App: Tribes section in the sidebar using the shared `ConversationLink` row
  (`#` or the tribe's image on a rounded square; bold with a count when
  unread, dimmed with a crossed-out bell when muted, Mute/Unmute in the
  context menu); "Join a tribe" popover (paste link, Look up shows name,
  description and exact costs, Join pays only the price shown); tribe header
  with description and price per message; a members popover with the list
  (or "seen in this tribe" for non-owners), Copy link and Leave with an
  inline confirmation; sender name and photo over each run of a member's
  messages (new run after someone else, five minutes, a new day, or a
  join/leave note); "X joined/left" notes; composer "Message #Tribe".
- Tribe sends behave like DMs: pending, delivered bolt, failed with Retry and
  Discard, and errors shown inside that tribe. A retry pays the tribe's
  current price, but never more than the price the message was first sent at
  (recorded on the row): if the tribe has raised it, the retry is refused and
  the message must be sent anew, at the price the header shows.

### Verified (local stack, see AGENTS.md "Local tribes server")

Before the rebase, profiles `tralice`, `trbob`, `trcarol` on `127.0.0.1:1884`:
create, join by link, posting both ways under the right aliases, own message
merged into one row, owner member list and the non-owner "seen posting"
list, late joiner gets history with original times, leave drops what the
tribe still forwards (cursor advances), rejoin without duplicates, restore
brings the tribe back with its name and history. App rendering on Bob's
profile (screenshot only).

After the rebase onto the status branch (2026-10-07), on a fresh local stack:

- Create, join, and posts both ways delivered (green bolt on both sides).
- Unread 2 on the joiner, `read` → 0; mute set and read back from the server
  (round trip).
- A DM between the same accounts still delivered.
- A tribe send with the connection down failed; `resend` of the same row
  delivered it (one row, no duplicate).
- After `tribe-leave`, `send` to the tribe is refused.
- Migrations on copies of a pre-rebase tribes profile and a status-only
  profile both reached v1–v6.

The review fixes below were made after that run and are verified by
`swift build` only: plain v6, `message_unread`, tribe host from config, own
join/leave setting membership, delivered on echo, resend price cap,
`createTribe(NewTribe)`, `read`/`mute` waiting again.

Not verified: anything on production (no production tribe was touched); in
the app, the join popover, members popover, inline leave, Retry/Discard on a
tribe message, the mute context menu on a tribe row and the unread badge on
a tribe row were not clicked through; private tribes (join sends a member
request; approval UI not built); tribe images (the local tribe has none);
`createTribe` with prices; a restore that replays a leave.

### Reviews (2026-10-07, after the rebase)

`/simplify` (reuse, simplification, efficiency, altitude), applied: one
`httpsOnly` rule for photos (scheme case-insensitive); `nilIfEmpty` public;
`SidebarActionLink` for "Join a tribe" and "Add contact"; `FormFooter` and
`ProblemText` for the popover forms; `ConversationIcon`; `DetailHeader`
without a trailing slot; `Formatting.sats` for the balance; `tribeCosts`
inlined; link trimmed once (in `TribeLink`); registry fetched once per join;
`deliver` back to text only, `leaveTribe` calls the core directly; `deliver`
finds the tribe itself; member lists stored raw and built once; one `json`
helper; `poll` shared by registration and tribe replies; `record` keeps the
tribe cache and the table in step; one chats SQL fragment; message types
interpolated; unused `memberCount` and `ownerAlias` dropped; `MessageRow.Sender`
an enum; message runs worked out in one pass with each alias decoded once;
the open tribe observed rather than read on every conversations change;
`droppedIndex` cached; discovery checks each chat with a key once per call;
`refreshTribes` coalesced, four at a time, one write; tribes host set in one
place; the CLI's shared `load()` and `Session.line`; v6 plain.

Not applied, with reasons:
- Storing left tribes' messages instead of dropping them (removing
  `droppedIndex`): a rejoin would then surface everything sent while away as
  unread, and a generic "advance past every dropped index" cursor would lose
  history that a restore drops for a sender not yet known (those must stay
  re-fetchable). Kept tribe-specific.
- Keyed continuations instead of polling for tribe replies: the reply can
  land while `run` is still publishing, before a continuation could be
  registered, so it needs a stored-reply slot plus timeout tokens anyway;
  more code than the 200 ms poll for two rare calls.
- Writing join/leave in the same transaction as the core call: on a publish
  failure the current rollback lets a join be retried; committing the tribe
  with the state would leave a joined-looking tribe the server never heard of.
- Including this account in the "seen posting" list in the engine: display
  only; left in the view.
- Setting the read marker to the newest index on join: the replayed history
  arrives after the join with later indexes, so a marker set at join would
  not cover it.
- Coalescing `tribeConversations`/`directConversations` filtering, caching the
  tribe server pubkey, an indexed alias column for `tribeSenders`: small.
- Squashing the review commits: left for when the PR is opened.

`/security-review`: no finding at confidence 8 or above. Near-misses fixed:
retry capped at the price first paid; a tribes-server reply naming a person
is not turned into a tribe; the sync cursor cannot overflow; a lookup that
returns after the link was edited is ignored. Near-misses not applied: the
per-message price is not pinned at join (the header always shows the live
price, as the official apps do); a pending contact sending a forwarded join
with our tribes host could be taken for a tribe (needs our own tribes
server to name it; low impact); CLI `tribe-join` pays without showing the
price (the CLI user is trusted); IDN letters in hosts and redirects followed
by `TribeInfo.fetch` (only from a host already trusted for that tribe).

`/code-review high`, all fixed: `read`/`mute` lost their wait before exit
(merge slip); a tribe found on another host could never be named (pasting its
link now looks it up); a restore replaying our leave brought the tribe back
(own join/leave now set membership); a joined link could set the account's
tribes host (now config or flag only); a tribe's echo of our message did not
mark it delivered (Retry would have paid twice); a join/leave note could hide
the time under the message before it; `tribeSenders` counted joins/leaves and
kept non-https photos; prices rounded down to whole sats before paying (now
exact, e.g. "1.999 sats"); `isPerson` duplicated the contact lookup.

### Open

- Private tribes: show "waiting for approval", and approve/reject for owners.
- The invite's default tribe (`initialTribe`) is not joined at signup:
  decided, Peel will not auto-join it.
- Next real-world test, after this branch is merged: the throwaway account
  creates its own tribe on production with `tribe-create` (its tribes host
  comes from the config) and posts to it; nobody else's tribe is touched.
- Creating and editing a tribe in the app; owner-only actions (kick, delete,
  pinned message).
- Mentions (the tribes server marks them with a mention tag), escrow refunds.

## Threads and replies

- `replyUuid` and `threadUuid` in the message JSON; quote rendering; a threads
  list per chat. Reference: `formatMsg` in `SphinxOnionManager+ChatExtension.swift`.

## Attachments

- Encrypt with a random key, upload to `memes.sphinx.chat` (auth by signed
  challenge), `makeMediaToken` (or `makeMediaTokenWithPrice`), send type 6 with
  `mediaToken`, `mediaKey`, `mediaKeyForSelf`, `mediaType`. Download and decrypt
  on receive; thumbnails; file, image, audio, video.
- Reference: `SphinxOnionManager+ChatExtension.swift`, the Mac app's
  `Managers/Attachments` and `Managers/S3 Uploader`.
