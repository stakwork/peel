# Phase 3 — Tribes, threads and attachments

## Status (2026-10-08)

**Built and merged:** tribes and parity with the Mac app (#4, #7, #11, #20),
replies and threads (#8), attachments (#9), the chat UI and Peel's menu
(#13), notifications and the Dock badge (#18), mark as unread and jump to a
message (#23, in `02-messaging.md` item 7).

**Open:**
- Tribe parity leftovers (app, feed and second brain URLs in the form, the directory): "Tribes", "Open". Tags, the details page, the link QR and how you appear in a tribe are built (branch `feat/tribe-details`, awaiting Tom's look): "Tribe details, tags, how you appear".
- A production run of tribe create, edit, pin and delete on the throwaway: "Tribes", "Open".
- Clicking through what no session could exercise: "Chat UI", "Open".
- A Reply action on notifications: "Notifications", "Open". (Payments and boosts notify since 2026-10-08: `04-money.md`, "Sats received".)
- Markdown beyond inline code and fences, search, voice messages and
  Giphy: added to v1 on 2026-10-08 (evening), planned in `10-v1-extras.md`.

**Decided:** no auto-join of the invite's tribe; delete sends only
`delete_tribe`; one Reply, threads grow from replies, no Copy link; files
only from the account's own memes host, at most 100 MB, never opened for
you. Paid attachments came later, in phase 4.

**Connection control (2026-10-15):** built and verified, ready for review. A
headerless status row and one check/reconnect icon; no explanatory copy or
last-checked timestamp. Done means a real server ping when connected, immediate
retry when offline, disabled action while busy, and the existing retry countdown.

## Journal

The build log, oldest first, kept as written. Branches named below have all
merged.

Status on 2026-10-07: tribes built and reviewed on branch `phase3/tribes`, rebased onto
the status branch (2026-10-07); tribes parity with the Mac app built on
`phase3/tribes-parity` (on top of it); replies and threads in the engine,
storage and CLI on `phase3/replies-threads` (on top of parity);
attachments in the engine, storage and CLI on `phase3/attachments`; the
UI for replies, threads, attachments and Peel's own menu on
`phase3/chat-ui` (on top of attachments, rebased onto main after the
Account screen), see "Chat UI"; local notifications on
`phase3/notifications`, see "Notifications" at the end.

## Tribes

Done means: list joined tribes, join from a link, read a tribe's messages
with each member's name and photo, post, see members, leave. Every action an
engine operation with a CLI command; verified on a local stack.

Parity (2026-10-07) adds: create and edit with every field the Mac app's
form sends, delete, private tribes (waiting, approve, decline), kick,
mentions (autocomplete, highlighting, mentions only), pinned message. Same
rules: an engine operation and a CLI command each, verified on a local stack.

### Parity with the Mac app

Checked against `sphinx-mac-v2` (SphinxOnionManager+TribesExtension,
+ChatExtension, GroupsManager, CreateTribeViewModel, TribeMembersDataSource,
MessageTableCellState, ChatMessageFieldView+MentionsMacrosExtension), the
core (`sphinx/src/bindings/tribes.rs`, `msg/mod.rs`) and the tribes server
(`sphinx/tribes/src/forward.rs`, `manager.rs`). Threads, attachments, long
messages, payments and boosts are separate tasks and not listed.

| Feature | Mac app | Core call / message | Peel |
|---|---|---|---|
| Join by link, paying the price to join | `joinTribe` | `join_tribe` (type 14) | Done |
| Read, post, leave | `sendMessage`, `exitTribe` | `send` (0), `send` (15) | Done |
| Members list (owner) | TribeMembersDataSource | `list_tribe_members` | Done |
| Copy link, QR | Share | — | Done (QR in the tribe details) |
| Create: name, description, image URL, price to join, price per message, escrow amount and time, private, unlisted | CreateTribeViewModel, `getNewGroupParams` | `create_tribe` (msat, millis) | Done: engine, CLI, app form |
| Create: tags | same form | `create_tribe` `tags` | Done (chips, the official apps' eight) |
| Create: app URL, feed URL and type, second brain URL | same form | `create_tribe` | Open (kept untouched on edit) |
| Image upload (rather than a URL) | `uploadPublicImage` | memes server | Done: app form picks a picture (`PictureField`); the CLI keeps `--image` |
| Edit | `updateTribe` (whole record) | `update_tribe` | Done: whole registry record sent back, edited fields laid over it |
| Delete (owner) | sends 22, then `deleteTribe` | `delete_tribe` (server sends 22) | Done: command only, see "Decided" |
| Owner cannot leave, only delete | `exitAndDeleteGroup` | — | Done |
| Private: join sends a request, "waiting for approval", composer off | `join_tribe(is_private)`, chat status pending | type 19 | Done |
| Private: owner approves or declines (inline in chat and on the members list) | `approveOrRejectTribeJoinRequest` | `send` 20 / 21 with `replyUuid` | Done (also sends `member` when known) |
| Private: member's state follows (approved, declined) | chat status | 20 / 14, 21 | Done, also on restore |
| Kick (owner) | `kickTribeMember` | `send` 16 with `member` | Done |
| Removed, declined or deleted: say so, remove locally | "Delete Tribe" row | — | Done ("Remove from Peel") |
| Deleted tribes left out of a restore | restores only tribes the registry still serves | — | Done (from the 22 in history) |
| Mentions: `@` autocomplete from aliases heard in 3 months | `aliasesAndPics`, `getAtMention` | — (plain `content`) | Done |
| Mentions: highlighted in messages | `\B@[^\s]+` | — | Done (bold) |
| Mentions: which messages mention me | badge `lowercased().contains("@alias")`, push `contains("@alias ")` | server `detect_mentions` (exact word) | Done: any case, punctuation after, per-tribe alias (see "Mentions fix") |
| Notification level: all, mentions only, mute | NotificationLevelView | `mute` 0 / 1 / 2 | Done (row context menu; count follows the level) |
| Mentions list across tribes | badge only | — | Done (sidebar Mentions) |
| Pinned message (owner pins, everyone sees it) | `shouldTogglePinState`, PinMessageBarView | `update_tribe` `pin` | Done (pin bar, context menu) |
| Owner recognised after a restore | `checkOwnerRole` (asks for members) | `role: 0` on own messages | Done (from `role`) |
| Per-tribe alias and photo | GroupDetails (local only) | `send` `myAlias`, `myImg` | Done (tribe details) |
| Tribe details page (created on, admin, member count) | GroupDetailsViewController | registry | Done (`TribeDetailsPanel`) |
| Browse or search the tribes directory | not checked | registry | Open |

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
  registry, `NewTribe` (what a tribe is created with; now `TribeSettings`), `TribeMembers`.
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
  tribe's `date`, and is dropped if the tribe was left (history still
  moves past it, `HistoryCursor.from`; phase 2, item 13). Our own
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
  host so the new tribe has a link. (The app form came with parity, below.)
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

### Built for parity (branch `phase3/tribes-parity`)

What the protocol does (checked against the tribes server):

- Kick, approve, reject and delete are ordinary tribe sends of types 16,
  20, 21 and 22 (no dedicated core calls); the tribes server accepts them
  only from the owner. Kick carries `member` (the member's key from the
  owner's list); approve and reject carry `replyUuid` (the request
  message's uuid, as the Mac app sends) or `member`, which the server reads
  first. Peel sends `replyUuid` and, from the members list, `member` too.
  They pay the tribe's message price, as the Mac app's `sendMessage` does.
- A request (19) goes only to the owner; a rejection (21) or a kick (16)
  only to that member and the owner; an approval (20) to every member, with
  the sender's alias rewritten to the approved member. Our own request does
  not come back in history, so a restore sees a declined member who asked
  again only through the approval.
- `update_tribe` replaces the tribe's whole registry record. Peel reads the
  record (`GET /tribes/<pubkey>`), lays the edited fields over it and sends
  it all back, so tags, feeds, the pin and the owner's alias survive. (The
  Mac app multiplies prices it read back from the registry by 1000 again
  when a field is left blank; Peel keeps msat throughout.)
- The pin is a registry field (`pin`, the tribe-assigned uuid); members see
  it on the next registry refresh. Our own message takes the tribe's uuid
  when it comes back, so every member's uuid matches.
- Mentions are plain `@alias` in `content`. The tribes server splits on
  spaces and matches aliases exactly to decide who gets a push (mute level
  1); the Mac app's local check is `contains("@alias ")`. Peel reads a
  mention case-insensitively and ended by any non-alias character (see
  "Mentions fix" below).
- The tribes server stamps `role: 0` on what the owner sends, including the
  join it sends the owner on creation.

Engine (`Engine.swift`, `Tribe.swift`):
- `TribeSettings` (replaces `NewTribe`): name, description, image (https),
  prices and escrow in msat, escrow time in ms, private, unlisted;
  `validated()` and `fields(over:)`. `TribeInfo.settings` for editing.
- `createTribe(TribeSettings)`, `tribeSettings`, `updateTribe`,
  `pinMessage`, `deleteTribe`, `kickMember`, `answerJoinRequest(in:_:approve:)`
  (`JoinRequest.message(uuid:)` or `.member(pubkey:alias:)`). Owner actions
  need an owned tribe this account is still in.
- `Tribe.status` (active, pending, rejected, removed, deleted) and
  `Tribe.pin`; `canPost`. A send to a pending tribe throws
  `awaitingApproval`, to any other closed one `notInTribe`. Joining a
  private tribe sets pending; a declined or removed member may join again.
  `leaveTribe` sends 15 only from an active member (anything else the
  server refuses) and refuses the owner.
- In `commit`, `membership(after:in:)` reads each tribe message: our own
  14/19/15 and `role: 0`; from the tribe, 20 or 14 (active again for a
  pending, declined or removed member), 21, 16, and 22 (for the owner too).
- Incoming tribe text that mentions this account's tribe alias is stored
  with `mentionsMe`.
- Storage migration `v7`: `tribe.status`, `tribe.pin`, `message.mentionsMe`
  and a partial index `message_mentions`. `ChatReadState.mentions` and
  `shownUnread` (all, mentions only, none by mute level);
  `mentionCandidates(in:)`, `mentions()`, the request lookup by alias.
  Messages of types 16, 19, 20, 21, 22 are shown in tribe chats.
- CLI: `tribe-create` and `tribe-edit` with `--name --description --image
  --price-per-message --price-to-join --escrow --escrow-hours --private
  --unlisted`; `tribe-delete`, `tribe-approve`, `tribe-reject`, `tribe-kick`,
  `tribe-pin`, `mentions`; `messages` prints uuids and mentions, `tribes`
  status and pin, `unread` mentions.

App:
- Sidebar: "Create a tribe" under "Join a tribe"; Mentions with an unread
  count and a list of messages that mention you (click opens the tribe);
  the row menu sets All / Mentions only (tribes) / Mute, and the badge
  counts by level (an @ beside a mentions-only row).
- Tribe header: "Private" in the subtitle; for the owner, an edit button
  opening the tribe form (create and edit share it; prices in sats, escrow
  time in hours; Delete tribe confirmed in place).
- Members popover: requests first with Approve and Decline; Remove beside
  each member for the owner, confirmed in place; no Leave for the owner.
- Chat: "X wants to join" with Approve and Decline (or the answer), "X was
  approved", "The owner removed you / declined your request / deleted this
  tribe"; the owner's own removals and declines are hidden, as in the Mac
  app. When this account cannot post, the composer gives way to a bar
  saying why, with "Remove from Peel" confirmed in place.
- Pinned bar under the header (when the message is loaded, as the Mac app);
  the bubble's context menu has Copy text and, for the owner, Pin for
  everyone / Unpin.
- Composer: typing `@` in a tribe offers matching aliases above the field
  (arrows, Return or Tab to take one, Escape to close); taking one inserts
  `@alias `. Mentions are bold in messages.

### Verified for parity (local stack, profiles `tp-alice`, `tp-bob`, `tp-carol`)

| Check | Command | Result |
|---|---|---|
| Create with every field | `tribe-create Parity Club --description … --image https://… --price-per-message 2 --price-to-join 5 --escrow 1 --escrow-hours 2 --private no --unlisted yes` | Registry holds 2000 / 5000 / 1000 msat, 7200000 ms, unlisted |
| Edit keeps the rest | `tribe-edit <pk> --name "Parity Club 2" --price-per-message 1 --unlisted no` | Name, price, unlisted changed; description, image, escrow, price to join kept |
| Private join waits | `tribe-join` (bob) on a private tribe; `send` | Status pending; send refused "not approved yet" |
| Owner sees the request | `tribe-members`, `messages` (alice) | bob listed pending; type 19 row |
| Approve by member key | `tribe-approve <pk> <bob key> tpbob` | bob receives 20, status active |
| Reject by request uuid | `tribe-reject <pk> <uuid>` | carol receives 21, status rejected; gone from the list |
| Ask again, approve by uuid | `tribe-join` (carol), `tribe-approve <pk> <uuid>` | carol pending, then active |
| Mention | bob sends "hi @tpalice welcome" and "no mention of tpalice here" | Only the first flagged; `mentions` lists it |
| Mentions only | `mute <pk> 1` (alice), `unread` | unread 2, mentions 1, shown 1 |
| Kick | `tribe-kick <pk> <bob key>` | bob receives 16, status removed, send refused; gone from the list |
| Pin | `tribe-pin <pk> <carol's message uuid>` | Registry `pin` set, other fields kept; carol sees the pin, and her own row has that uuid |
| Delete | `tribe-delete <pk>` | Members receive 22, status deleted; registry no longer serves it |
| Owner cannot leave | `tribe-leave <own pk>` | Refused |
| Restore | `restore` of carol, bob, alice into new profiles | carol active in the private tribe (21 then 20), bob removed, alice owner of hers with deleted ones marked deleted |

Not verified: anything in the app by clicking (built only; the form,
popovers, mention suggestions, pin bar, status bar and Mentions list have
not been clicked through); escrow being paid back; a Mac app member seeing
Peel's approvals, kicks and pins (no Mac app on the local stack); any of it
on production.

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
(own join/leave now set membership, once past the check for a member's
replay of our tag: `04-money.md`, "Our tag replayed in a tribe"); a joined link could set the account's
tribes host (now config or flag only); a tribe's echo of our message did not
mark it delivered (Retry would have paid twice); a join/leave note could hide
the time under the message before it; `tribeSenders` counted joins/leaves and
kept non-https photos; prices rounded down to whole sats before paying (now
exact, e.g. "1.999 sats"); `isPerson` duplicated the contact lookup.

### Open

- The invite's default tribe (`initialTribe`) is not joined at signup:
  decided, Peel will not auto-join it.
- Next real-world test, after these branches are merged: the throwaway
  account creates its own tribe on production with `tribe-create` (its
  tribes host comes from the config), edits, pins and deletes it; a second
  throwaway checks a private join, approval and kick against it; and the
  official Mac app (on a throwaway) shows Peel's approvals, kicks, pin and
  mentions correctly. Nobody else's tribe is touched.
- Click through the parity UI on a development profile (see "Verified for
  parity").
- From the parity table: app and feed URLs and the second brain URL in the
  form; browsing the tribes directory. (Image upload, tags, the details
  page, its link QR and per-tribe alias and photo are built.)
- (Done in "Mentions fix": back-fill of mentions stored before v7, and the
  alias the tribes server made unique for us, `name_2`.)
- Escrow refunds are the tribes server's job; nothing to build, not checked.

### Decided (parity)

- Delete sends only `delete_tribe`. The Mac app sends a type 22 first and
  then the command; on the local stack the command landed first, deleted
  the tribe's route, and the 22's payment failed at the mixer ("no root for
  scid", shown to the owner as an error, 3 sats spent). The tribes server's
  delete command sends every member a 22 itself, so members see the same
  thing. Check on production that its tribes server does this too.
- A declined, removed or deleted tribe, or a pending request, is only hidden
  when removed from Peel: the tribes server refuses a leave (15) from anyone
  it has not accepted, and it would still cost the message price.
- The owner's own removals (16) are not shown in the chat, as in the Mac
  app (the tribe's copy does not say whom); the owner's declines show as
  "You declined a request to join", and the request row as "Declined".
- Only the owner's decisions change a member's state: an incoming 16, 21 or
  22 must carry `role: 0` (the tribes server stamps it, and already refuses
  them from anyone else).

### Fixes after first use (2026-10-07)

Three things Tom saw on his own account, each checked before the fix:

- **Deleted tribes came back after a restore**, with the "deleted" bar.
  The Mac app restores a tribe only when the registry still serves it
  (`fetchTribeInfo` in the restore), so deleted tribes are simply absent;
  removed and declined tribes are restored (the registry still serves
  them) with the kick message or a rejected status and a "Delete Tribe"
  option, and a deletion heard while running stays in the chat with a
  delete button. Peel now matches: while a restore replays history
  (`Setting.needsRestore`, cached as `Engine.restoring`), a 22 that marks
  a tribe deleted also marks it left, so it is hidden and what the tribe
  still sends is dropped; removed and declined keep their bar; live
  deletions keep the bar. The Mentions list leaves out tribes no longer
  shown (it used to list mentions in tribes removed from Peel).
- **Member photos did not show in tribe messages.** Not the data: the
  core, the Mac app and the tribes server all use `sender.photo_url`, the
  tribes server forwards it untouched (`mutate_msg_to_forward`), and Peel
  stores and reads it under that key. On a local stack the photo was in
  every stored message, yet only the first run of a member's messages
  showed it; later runs showed the initial. Root cause: each row's own
  `AsyncImage` fetched the photo, and in the lazy message list rows are
  made and dropped while it lays out, so a fetch cut off with its row left
  that row on the placeholder for good. The sidebar shows each contact
  once, in a stable row, which is why DM photos worked. `Avatar` now loads
  through `PhotoCache` (app-wide, one fetch per URL shared by every row,
  owned by the cache rather than the row, kept for the session; a URL the
  server answered without an image is not asked for again, a network
  failure is). The CLI gained `--photo <https url>` (`Engine.setPhotoURL`),
  so development accounts can send a photo; before, Peel always sent none.
- **A tribe opened a second time was blank until scrolled.** The message
  list is now a fresh view per chat (`.id`, from `fix/blank-conversation`)
  and is made again once the chat's messages have loaded, so
  `defaultScrollAnchor(.bottom)` applies to the real content: before, it
  applied to the empty list and the jump that followed landed part way
  up, as a lazy stack only estimates heights it has not measured.

Verified on a local stack (broker 1893, mixer 8023, tribes 8823; profiles
`fx-alice`, `fx-bob`, restores into `fx-alice2`, `fx-bob2`):

| Check | Command | Result |
|---|---|---|
| Photo travels | `--photo https://… send <tribe> …` (bob), `listen` (alice) | `sender.photo_url` stored on every one of bob's messages |
| Photo shows on every run | app built with `bundle-app.sh` into the scratchpad, `-profile fx-alice`, 13 runs of bob's messages | Before: photo on the first run only. After: on every run (window screenshots) |
| First load lands at the bottom | same, on launch (the app opens the first chat) | Before: top, then part way up. After: newest message at the bottom |
| Live deletion keeps the bar | bob in "Doomed", alice `tribe-delete`, bob `listen`, `tribes` | bob: `(deleted)`, not left |
| Restore drops deleted | `restore` of bob and alice | Doomed `left, deleted` for both (hidden); Photo Club `(removed)` for bob, kept with its bar; alice still owner of it |
| After the restore, live again | alice2 creates and deletes "After Restore" with bob2 in it | bob2: `(deleted)`, not left |

Not verified in the UI: switching between chats and back (no way to
click in this session; the second open takes the same path as the launch,
which was checked); the restore in the app (CLI only); a production photo
URL (the local check used a gravatar URL and a dead memes URL).

`/code-review low` on `origin/main...HEAD` (it read the PeelCore hunks),
both fixed: the members list and mention candidates skipped senders whose
message has no time (`timestamp > 0` is false for NULL); approving or
declining by member key, when no request was stored, skipped the
"answered once" check and could pay twice (now refused unless the
server's latest list still shows the member waiting, and the member leaves
that list once answered).

Rest of the chain on the same changes (`cf632db..49fa5da`, reviewed on
main after the squash). `/simplify`, applied: `PhotoCache` decodes a
thumbnail off the main thread (max 256 px, enough for a 36pt avatar at 2x
filled from a 3:1 photo) instead of keeping the full photo and decoding it
while drawing, and a fetch that fails throws instead of returning a flag
pair; the restore rule (a deletion replayed in a restore marks the tribe
left) moved into `membership(after:in:replaying:)`, which owns every
membership rule; mention candidates use the `(chat, timestamp)` index again
(`IFNULL(timestamp, 0) >= ?` could not; the time condition is now left out
when `since` is 0, the only case that counts timeless messages);
`MessageListID` became `.id(messages.isEmpty ? nil : chat)`. `/security-review`:
nothing. `/code-review high`, fixed: answering by member key with no stored
request and no member list in this session (a fresh CLI) skipped every
"answered once" check, so it now fetches the list first and requires the
member waiting on it; our answer is stored only when the server echoes it,
so a second answer before the echo (chat note and member list, or a double
click) paid again: a request being answered is now held for the session and
the member leaves the cached list before the send (both undone if the send
fails); `Avatar` showed the previous person's photo in a reused view until
the new one loaded (the loaded image is now kept with its URL); a 429 or 5xx
from a photo host kept that photo off for the session (now retried).
Verified on a local stack (broker 11883, tribes 11811, mixer 11800;
profiles `rv-alice`, `rv-bob`, `rv-carol`, since deleted): a fresh
`tribe-approve <tribe> <member key>` with no stored list fetched it and
approved bob (server list: bob a member); the same again was refused ("not
waiting"); `tribe-reject <uuid>` for carol, then again, was refused
("already answered"); approving carol by key afterwards was refused.

Not applied: photo downloads have no size cap (a member's photo URL can
stream a large body; `AsyncImage` had the same, and capping needs a
streaming fetch); answering by request uuid does not take the member off
the cached list (the uuid path does not know the member's key; answering
again from the list is refused by the stored or held request); two empty
chats share the message list's `nil` id (nothing to anchor in an empty list,
and the id changes as soon as messages arrive); the restore rule now covers
only a replayed deletion, not a tribe already stored deleted and not left
(a restore starts from an empty profile, so there is none); `--photo` is
applied by the CLI after `Account` builds the engine rather than passed in
like `--alias` (same effect; it is saved before connecting).

### Mentions fix (branch `fix/mentions`, 2026-10-07)

Tom's Mentions list was empty on his real account though colleagues write
`@Tom_Smith`. Root cause: his account was restored (commit #6, 14:44) before
`mentionsMe` existed (v7, #7, 15:30); nothing ever re-read stored messages,
and later syncs fetch only newer ones. Hardened at the same time: the match
was exact case and needed whitespace after the alias, and used only the
account's own alias, never the one the tribe actually forwards.

Checked against the official apps and the tribes server:
- Alias in a tribe: both official apps send `fixedAlias` (spaces to
  underscores, only `[A-Za-z0-9_]`), as Peel's `tribeAlias` does. The tribes
  server does not convert; when the alias is another member's it rewrites it
  to `alias_2` (`uniqueify_alias`, also on history replays to a late joiner,
  so the earlier member can be the one renamed) and stores the newest alias.
  The echo of our own message carries the alias the tribe forwarded.
- Autocomplete: both apps insert `@<alias> ` from aliases seen on messages;
  Peel inserts the same (`ComposerField`), so its mentions notify official
  users. No change needed there.
- Detection: push in both apps `content.contains("@\(myAlias) ")` (exact case,
  needs a space after); Mac badge `lowercased().contains("@alias")` (any
  case, prefix matches too); server push: split on spaces, exact token.

Built:
- `mentions(_:aliases:)`: `@alias`, any case, after the start or a
  non-alias character, ended by the end or a non-alias character
  ("@Tom_Smith," and "@tom_smith:" count; "@Tom_Smith_2" does not count
  for "Tom_Smith"). Text messages and attachment captions.
- `ownTribeAliases(sent:echoed:)`: the aliases each tribe echoed back on
  this account's own messages (earlier names too), plus `tribeAlias` of the
  current name unless the tribe already echoed it as `<name>_2` (then the
  plain one is another member's).
- Storage: our own tribe message's echo now fills the row's `sender` (it was
  left empty), `echoedOwnAliases()`, and `rescanMentions` (chunks of 500 by
  id, each its own write, sets `mentionsMe` to the match).
- Engine: echoed aliases kept in memory and updated in `commit`;
  `checkMentionsIfNeeded` (end of every history sync, after a restore too;
  rename; an echo with a new alias) runs the scan detached when
  `Setting.mentionScan` (`MentionScan`: the aliases last scanned for, JSON)
  differs, only over the tribes whose aliases changed unless the name did,
  then records it; a change during a scan starts another after it. No
  migration.

Verified (local stack on 1895/8825/8025, profiles `mn-alice`, `mn-imp`,
`mn-tom`, `mn-tom2`, deleted afterwards): `mn-imp` took "Tom Smith" in a
tribe first, so `mn-tom`'s post came back as `Tom_Smith_2`. Live: "@Tom_Smith_2
can you check" and "thanks @tom_smith_2, great" flagged, "@Tom_Smith hi other
tom" (the other member) not; in another tribe "@Tom_Smith: ping" and
"@Tommy old name" (the name it joined with) flagged, "no mention here" not.
After clearing every flag and the scan setting (as history stored before v7),
`mentions` listed nothing; one `listen` later it listed the same four. A
restore into `mn-tom2` listed the same four.

Not covered: our own tribe messages whose echo arrived live before this
change have no `sender`, so their alias is not known after a restart (the
plain name still counts unless a restored echo shows `_2`). Echoed aliases
are read once per launch with a scan of our own messages (no index on
`fromMe`); acceptable at this size, a tribe column would need a migration.

Reviews: `/code-review high` fixed: the current name counts beside echoed
ones (unless echoed as `_2`); an echo with a new alias triggers the check;
a scan no longer cancelled on disconnect (it needs no network) and one that
ends re-checks; only changed tribes are rescanned; aliases computed once per
tribe in the scan. Not applied: echoed aliases on the tribe row (migration),
back-filling `sender` on rows echoed live before this change (data gone).
`/simplify` applied GRDB `databaseQuestionMarks`, a memberwise `MentionScan`,
`Result` for the scan outcome, one meaning of the alias (`sent`); skipped
precomputed `@word` lists and a read/write split per chunk (small).
`/security-review`: no finding at confidence 8 or above (a malicious tribe
server can only change mention flags within its own tribe).

### Reviews (parity, 2026-10-07)

`/code-review high`, fixed: Return took `@anna` over a finished `@ann`
(exact match listed first); the edit form rounded escrow time to whole hours
and refused prices with fractions of a sat (a field still showing the
tribe's value sends it exactly; `amount()` in PeelCore reads decimals exactly
and is shared with the CLI); delete hid the tribe before the server acted
(now waits until the registry stops serving it, so a failed delete can be
retried); two updates at once could take each other's reply (one change per
tribe at a time); a tribe with a non-https image from another client could
not be edited (its current image is kept); mention candidates stopped
refreshing at 200 messages and ran on the main thread (now loaded off the
main thread when an `@word` starts); Approve/Decline could be clicked twice
and pay twice (the buttons stay off once sent, and the engine refuses a
request already answered).

Not applied: candidates still include removed or declined members whose
last word in 90 days was not a leave (the Mac app's rule too); the request
for a member on the owner's list is found by alias (the tribes server keeps
aliases unique within a tribe).

`/simplify` (reuse, simplification, efficiency, altitude), applied: one
`InlineConfirm` for the five confirm-in-place controls (leave, delete,
remove member, remove from Peel); `TribeServerProgress`, `panelBoxed()`,
one `SectionLabel`; `MentionsView` reuses `EmptyPlace` (since design batch 13, `EmptyState`) and observes only
while open; `Tribe.canManage`; `String.isPubkey` shared with `TribeLink` and
the CLI; `changeOwnedTribe` for update and delete, and `poll` takes an async
check; one `seenInTribe` query behind the members list and mention
candidates; the owner's kicks hidden in SQL; `Message.isPinnable` enforced by
the engine; `ChatReadState.shownMentions`; registry "gone" only on 404 or
500, not any error; small hot-path guards.

Not applied, with reasons: a continuation-based reply registry for tribe
management (see the earlier decision on polling); moving the membership
wording into PeelCore (only the app words it; the CLI prints types); one
mention tokenizer for highlighting and detection (the Mac app highlights
`\B@[^\s]+`, the server detects exact words; both are kept as they are);
the account pubkey from the engine for "you, owner" (display only); showing
a pin older than the 200 loaded messages (the Mac app does not either);
`TribeOptions.apply` as key paths; `findMention` running twice a keystroke.

`/security-review`: no finding at confidence 8 or above. Applied the near-miss
hardening above (role 0 for the owner's decisions). Other near-misses: a
malicious tribe server can stamp `role: 0` on our own message and show
owner controls for its tribe (its owner actions are refused by our own
tribes server, and nothing is paid without a click); a transient 500 from
our own registry during a delete would hide the tribe locally.

## Tribe details, tags, how you appear (branch `feat/tribe-details`, 2026-10-09)

Tom: "the tribes details page, the tags, and image upload are per tribe",
plus a per-tribe alias and photo for yourself and the sweep's fuller
details (created date, admin, join price, QR for the link).

### Found (checked before building)

- Peel had `ChatInfoPanel` for both kinds of chat (icon, name, public or
  private, the time zone switch); Members, Edit, Copy link and Leave were
  in More. No date, owner, join price, tags or QR.
- The registry (`sphinx/tribes` `GET /tribes/<pubkey>`, the core's `Tribe`)
  has `tags`, `owner_alias`, `created` (ms, kept across updates by the
  server), `member_count`, `price_to_join` and `escrow_millis`; no owner
  key or photo.
- Mac app tags (`GroupsManager.getGroupTags`): Bitcoin, Lightning, Sphinx,
  Crypto, Tech, Altcoins, Music, Podcast, sent as `tags: [String]` of the
  selected names (`[]` for none), read back by name.
- Mac app per-tribe identity: `Chat.myAlias` and `Chat.myPhotoUrl`, Core
  Data only (`GroupDetailsViewController.updateChat`); nothing goes to a
  server when they change. `sendMessage` passes them to the core's `send`
  as `myAlias` (`fixedAlias`) and `myImg`, falling back to the account's;
  the core puts them in the message's `sender` (`alias`, `photo_url`),
  and the tribes server forwards that. The Mac app's push check uses the
  tribe alias too.

### Built

- `Tribe.myAlias`, `myPhotoURL` (migration v20), `sentAlias(account:)`
  and `sentPhoto(account:)`, used by every send to a tribe (`deliver`,
  `sendToTribe`), the call ticket's name and photo, and the alias that
  names this account in mentions and approvals. `Engine.setTribeIdentity`
  (https photo or none; empty is the account's); the mention scan keeps
  each tribe's own alias (`MentionScan.own`, older scans read as none).
- `TribeSettings.tags`, `tagChoices`; `TribeInfo` reads `tags`,
  `owner_alias`, `created`. `Engine.tribeDetails` reads the registry (and
  saves what changed, as the refresh does) with the owner's photo from
  what they posted.
- CLI: `tribe-info`, `tribe-alias <pubkey> [name|-] [photo|-]`, `--tags`.
- App: `TribeDetailsPanel` (`PeelApp/TribeDetails.swift`), opened from
  More's "Tribe details" (⌘I) below More, or from a click on the tribe's
  name or icon below them. Tags as chips (`TagChips`, a toggle set in
  the edit form). "How you appear in #tribe": name field (helper shows
  the alias members will read) and `PictureField`, Save and Revert. Your
  own rows in that tribe, the members list's "you" and mentions follow
  it. `ChatInfoPanel` is now a contact's; the time zone switch is
  `ChatTimeZoneSection`, shared by both.

### Verified

- Unit: tags and registry details round trip; the identity kept,
  refused (http photo, a tribe left or unknown), cleared; the mention
  scan with own aliases.
- Integration (`TribeJourneys.detailsTagsAndHowYouAppear`, local stack):
  tags from create read back by a member, edited by the owner; Bob's
  "Bobby Tables" and photo arrive at Alice as `Bobby_Tables` with the
  photo; Alice's `@Bobby_Tables` counts as a mention for Bob.
- Renders on seeded dev profiles (owner, member, alias draft, edit with
  tags), dark and light, kept outside the repo.

### Follow-up: member count and one place it opens (2026-10-09)

Tom, on his real tribe: "The tribe details is saying 0 members", and the
panel opened under the title from a click but under More from the menu.

- Found: the registry's `member_count` (`sphinx/tribes` `db/members.rs`)
  counts up on `add_member` (pending requests too) and down only on a kick
  or decline; `GroupLeave` removes nobody. `TribeCmd::Update` replaces the
  whole record, and the official apps' edit and pin
  (`GroupsManager.getNewGroupParams`) send no `member_count`, so it goes;
  a kick after that counts down from nothing to `Some(0)`. Reproduced on
  the local stack: three joined, an official-app-shaped edit, one kick,
  registry 0, the owner's list 2.
- Built: `TribeMembers.countLabel`, the one label: the owner's list
  ("2 members", pending not counted) or, for a member, who has posted and
  themself ("3 seen", as the Members panel's "Seen in #tribe"). The details
  row and a joined tribe's link card use it; a card for a tribe not joined
  shows no count. Cards read `AppModel.knownMembers` (the owner's list is
  asked of the server once a session, never twice at once).
- One place: `HeaderMoreButton` presents the chat's details below More for
  the menu's Details, ⌘I and a click on the header's name or icon (DMs now
  open their details from the name too). Members and Edit already opened
  below More.
- Left: a member who leaves stays on the server's list (and its count)
  until kicked; the header's "3 sats a message" and the details' "Per
  message: Free" disagree (`messageAmountMsat` against
  `pricePerMessageMsat`).

### Not done

- Setting how you appear before joining (the Mac app's join screen): the
  join goes under the account's name.
- App, feed and second brain URLs in the form.

## Threads and replies

Branch `phase3/replies-threads`, on top of `phase3/tribes-parity`. Engine,
storage and CLI only; the UI waits for Tom's design review. Parity's
member approvals and rejections name the request in `replyUuid` too; they
now read the stored `replyUUID` column (`isAnswered`, the app's answered
requests) instead of decoding the body.

Done means: send a reply and a thread message to a contact and to a tribe
(tribe pricing, delivery status and Retry unchanged); every stored message
knows its parent and thread, including history replayed on a late join or a
restore; storage answers "the thread T", "reply counts in a chat", "the
parent of this reply" (even outside the newest 200) and "threads I took part
in"; the main conversation applies the Mac app's rule for what a thread
hides; CLI `send --reply`, `send --thread`, `thread`, `threads`. Verified on
a local stack with a tribes server, both directions, DM and tribe.

### Conventions (checked against the code, 2026-10-07)

Sources: `formatMsg`, `sendMessage` and `MessageInnerContent` in the Mac
app's `SphinxOnionManager+ChatExtension.swift` and `+StructsAndHelpersExtension.swift`,
`NewChatViewModel+SendMessageExtension.swift`, the Mac data sources
(`NewChatTableDataSource+ResultsControllerExtension.swift`,
`ThreadTableDataSource`, `ThreadsListDataSource`), the core
(`sphinx/src/msg/mod.rs`, `ser.rs`), the tribes server (`forward.rs`) and
the reference client (`wasm/test/auto/send.ts`).

- **Wire.** Two optional keys in a text message's JSON, next to `content`:
  `"replyUuid"` and `"threadUuid"` (camelCase). Nothing else: no quoted
  text, no sender, no copy of the parent. The core packs both as 32 raw
  bytes (`Type::Bytes32`, `hex::decode` on send) and the receiving core
  rejects any other length (`read_bytes32_val`: "bad bytes32"), so each must
  be exactly 64 hex characters, i.e. a uuid the core issued. The reference
  client checks `length !== 64` before sending a `replyUuid`.
- **What the Mac app sends.**
  - Reply to message M from the main conversation: `replyUuid = M.uuid`,
    `threadUuid = M.threadUuid ?? M.replyUuid ?? M.uuid`. So every reply
    also starts or joins a thread, in DMs as in tribes.
  - Post in the thread view of thread T: `threadUuid = T`, no `replyUuid`.
  - Reply to M inside thread T: `threadUuid = T`, `replyUuid = M.uuid`.
  - Boosts, purchases and member approvals also carry `replyUuid` (other
    message types); none of them is a thread message.
- **The parent and the quote.** A reply names its parent by uuid only; the
  quote (parent's sender and text) is drawn from the receiver's own copy of
  the parent, looked up by uuid. No parent stored, no quote.
- **A thread** is every message in the chat whose `threadUuid` is T. Its
  original message is the message whose `uuid` is T; it carries no
  `threadUuid` itself.
- **Tribe uuids.** The tribes server forwards each message under a new uuid
  (the sender's goes in `originalUuid`), and the tribes server keeps
  `replyUuid`/`threadUuid` untouched. So in a tribe a parent is named by the
  tribe's uuid, which is what every member holds. Our own message gets the
  tribe's uuid only when its copy comes back (the row takes it over, as for
  tribes already); until then it cannot be replied to without the link
  breaking for everyone else.
- **Main conversation (Mac rule).** Threads are grouped only in tribes
  (`isPublicGroup`). A thread with two or more messages collapses: the
  original message and every thread message but the newest are hidden, and
  the newest shows as one thread row (original message, count, latest
  replies) at its own place in time. A thread with one message shows that
  reply inline with its quote, and the original stays. In DMs nothing is
  hidden: every reply shows inline with its quote. (The Mac app collapses
  only when the original is in the loaded page; Peel collapses whenever the
  original is stored, so a thread does not change shape as you scroll.)
- **Threads list (Mac).** Per tribe: originals with two or more thread
  messages, newest latest reply first. Peel's Threads list is the
  cross-chat, Slack-style version Tom asked for: tribe threads of two or more
  that this account started or posted in.
- **Unread.** The Mac app marks every received message seen when the chat
  is opened, thread messages included, and its server read marker is per
  chat. Peel counts a thread's unread as the other people's thread messages
  past the chat's server read marker; no per-thread marker.

### Built

- `Message.replyUUID` and `threadUUID`, stored columns filled from the
  body's `replyUuid`/`threadUuid` on every copy (live, history, our own
  send); like the body, kept from the first copy. `MessageUUID.isValid`:
  64 lowercase hex.
- Storage migration `v8`, after parity's `v7` (this branch is rebased on
  `phase3/tribes-parity`): the two columns, filled for
  messages already stored from their bodies, and partial indexes
  `message_reply (chat, replyUUID)` and `message_thread (chat, threadUUID,
  timestamp)`.
- Queries: `timeline(in:)` (the main conversation with the Mac rule above,
  plus the quoted parents, however old, and a `ThreadSummary` per collapsed
  thread: original, count, last time, unread); `thread(_:in:)` (original
  plus the newest 200 thread messages and their parents); `threads()`
  (tribe threads of two or more, original stored, that this account
  started or wrote in, joined tribes only, newest activity first);
  `replyCounts(in:)` (direct replies per message); `message(uuid:in:)` (the
  parent, same chat only). `messages(in:)` is unchanged, so the app shows
  what it showed until its thread UI is designed.
- `Engine.sendText(_:to:replyTo:inThread:)`: links set as the Mac app sets
  them (`inThread` may name any message of the thread; it resolves to that
  message's thread; a reply given with it must be that thread's original or
  in it, `notInThread`). Both must be stored messages of the same chat (64
  hex). Our own message must not be pending or failed (a Retry gives it a
  new uuid), and in a tribe it must have come back from the tribe, since
  until then the others know it under another uuid (`notDelivered`). A
  parent's own link that the core could not pack is skipped (the reply
  then starts a thread at the parent) rather than sent. Goes through the shared `deliver`, so tribe pricing, the pending /
  delivered / failed status and Retry are unchanged; a Retry re-sends the
  stored body and keeps the row, links included.
- CLI: `send --reply <uuid>`, `send --thread <uuid>`, `thread <pubkey>
  <uuid>`, `threads`; `messages` now prints the main conversation (uuids,
  "in reply to", collapsed threads).
- Tests: `ThreadTests` (uuid check, body keys, links kept from the first
  copy, the v8 backfill, parent beyond the newest 200 and only in its chat,
  DM shows every reply, lone tribe reply inline, collapse of two or more
  with count and unread, no collapse without the original, thread view,
  threads list, reply counts). Built with `swift build --build-tests`; not
  run here.

### Verified (local stack, 2026-10-07)

Broker 1897, mixer 8027, tribes server 8827; profiles `rt2-alice`,
`rt2-bob`, `rt2-carol`, `rt2-bob2`.

- DM, both ways: Bob `send --reply` to Alice's message → body
  `{"content","replyUuid":P,"threadUuid":P}`; Alice's `messages` shows it
  "in reply to me: hello bob". Alice `send --thread <Bob's reply>` → body
  has only `threadUuid` = the original (resolved through Bob's reply);
  Bob's `thread` shows the original and both messages; DM main view shows
  every message.
- Tribe, both ways: Alice's root, Bob's reply (paid 3 sats, delivered),
  Alice's reply to Bob's reply (`replyUuid` = Bob's, `threadUuid` = root),
  Bob's `--thread` post. Main view collapses to the newest with "thread of
  N"; `thread` shows all in order with quotes; `threads` lists it on both
  with unread past the server marker.
- Retry: broker stopped, Bob's tribe reply failed (row FAILED, links set);
  broker back, `resend` → same row COMPLETE with a server index, body and
  links unchanged; Alice received it with its quote.
- Late joiner: Carol joined after all of it; the replayed history kept
  every link (same tribe uuids), collapse and quotes as on Alice's side.
- Restore: Bob's words into `rt2-bob2`; tribe and DM came back with all
  links, the thread listed.
- Refusals: unknown uuid, a uuid from another chat, and a reply to our own
  failed tribe message (`notDelivered`).

After the rebase onto `phase3/tribes-parity` (v7 then v8), a smoke run on
fresh profiles: a private tribe, Bob's request, Alice's `tribe-approve`
(the answer stored with `replyUUID` = the request), a second approve
refused as already answered (`isAnswered` on the column), and Bob's tribe
reply to Alice's post delivered with its quote.

Not verified: the Mac app's rendering of Peel's replies and threads (the
JSON has the Mac app's keys and values; key order differs from run to run,
as it does in the Mac app's `JSONSerialization`, and the core reads it into
a struct, so order does not matter), but no official client was in the
loop; anything on production.

### Reviews

`/code-review high`, applied: a reply to our own pending or failed DM
message is refused (a Retry gives it a new uuid); `timeline` tracks its
region per fetch, so marking a chat read updates thread unread counts even
when the chat had no threads when it was opened; a parent's link the core
could not pack is skipped instead of failing with "no such message"; a reply
given with `inThread` must be in that thread (`notInThread`); the collapse
rule's "two or more" is an `EXISTS ... OFFSET 1`, not a count per row; the
doc no longer claims the JSON is byte-for-byte the Mac app's.

Not applied, with reasons:
- "A server echo under our own uuid could set `serverIndex` before the
  tribe's copy lands": a tribe send has no copy to self (`send.rs`, the
  `is_tribe` branch), so the tribe's copy is the only one with an index.
- Read-only CLI commands on a profile not yet migrated to v8 fail with "no
  such column": the existing rule in `AGENTS.md` (run a connecting command
  once); listed there now.
- `.sortedKeys` for the body: the Mac app's `JSONSerialization` order is
  not fixed either, and the core reads the JSON into a struct.
- `--reply`/`--thread` taken from anywhere in the arguments, even inside
  the text: same as every other CLI option (`--description` and so on).
- `replyCounts(in:)` and `message_reply` have no caller yet: asked for in
  the brief for the UI (a "N replies" marker), and the index also serves
  the parent lookups of a future "replies to this" view. Drop them if the
  design does not use them.

`/simplify` (reuse, simplification, efficiency, altitude), applied: one
`thread(of:)` rule (`threadUuid ?? replyUuid ?? uuid`, invalid links
skipped) for both `replyTo` and `inThread`, so `--reply R` and `--thread R`
agree on R's thread; the thread view's query built by `messagesSQL(also:)`;
`threads()` groups only threads with a message of ours instead of every
tribe thread on each change; the v8 backfill tests `LIKE` before parsing
JSON; unused `ThreadSummary.lastDate` dropped; tests share `first` and
`Message.fixture` takes `replyUUID`/`threadUUID`.

Not applied, with reasons:
- One body-to-row mapping shared by send and receive, and `deliver` taking
  typed fields instead of decoding the body: worth doing when attachments
  add the next convention, not for two fields.
- The collapse rule exists twice in SQL (`tribeTimelineSQL` and
  `threadsSQL`); one CTE would tie them together but is a larger rewrite.
  The tests cover both together (`tribeCollapsesAThreadOfTwoOrMore`).
- `timeline` work per change (tribe lookup, summaries, parents re-run on
  any message write): a second observation keyed on the visible uuids is
  more machinery than 200 rows warrant now.
- The app still reads `messages(in:)`: switching it to `timeline(in:)` is
  the UI work that waits for the design review.
- `replyCounts(in:)` kept, as above.

`/security-review`: no finding at confidence 8 or above. Checked: every
value interpolated into SQL is a constant or `databaseQuestionMarks`; peer
uuids are bound as arguments; parent, thread and count lookups are all
scoped to one chat, so a peer cannot get another chat's message quoted;
the upsert's same-chat guard and first-copy links still hold; a peer's
link reused in our reply is checked with `MessageUUID.isValid` first; no
key material in the new CLI output. Near-misses not applied: a non-string
`replyUuid` would make `BodyFields` fail and hide the content (the core
packs both as 32 bytes and hands them back as hex strings, so a peer cannot
produce one); a tribe member can forge thread links that change how a
tribe's threads collapse (display only, within that tribe).

### Decided for the UI (Tom, 2026-10-07)

- A thread reply stays in the thread only: no "Also send to #tribe" option,
  and no engine or CLI path for it (none was built).
- Hover bar order: Reply, then Reply in thread. No "Copy link": Sphinx has
  no message links.
- Images: a grid of up to 4 with "+N", grouping one sender's images sent
  within about a minute.
- DM rows get a context menu without Leave.

The open questions that stood here were answered by Tom on 2026-10-07;
the answers are under "Chat UI", "Decided".

## Attachments

Status (branch `phase3/attachments`): engine, storage and CLI; no UI yet (the
UI waits for the design review). (The UI came with "Chat UI" below, #13.)

Done means: send an image or any file to a contact or a tribe, encrypted and
uploaded exactly as the official apps do it, so their users see it; receive
and download one, decrypted and cached; Retry and tribe prices behave as for
text; every action an engine operation with a CLI command.

### How attachments work (checked against the code, 2026-10-07)

Sources: the Mac app (`Managers/Attachments/AttachmentsManager.swift`,
`AttachmentObject.swift`, `API/API+AttachmentsExtension.swift`,
`Managers/Encryption/SymmetricEncryptionManager.swift`,
`Helpers/MediaLoader.swift`, `CoreData/TransactionMessage/
TransactionMessageMediaExtension.swift`, `formatMsg`/`sendAttachment`/
`signChallenge` in `SphinxOnionManager+ChatExtension.swift`), the core
(`sphinx/src/msg`, `bindings/media.rs`, `msg/ldat.rs`), `sphinx-ffi`
(`sign_bytes`, `sign_base64`) and the tribes server (`tribes/src/forward.rs`).
The reference client (`wasm/test/auto/sendAttachment.ts`) only sends
`content`, `mediaKey`, `mediaToken`; the Mac app is the authority.

- **Memes server.** `https://memes.sphinx.chat`, hard-coded in the Mac app
  (`API.kAttachmentsServerUrl`, overridable by a `fileServerURL` default) and
  as the host inside every media token. It is not in the public config
  (`config.config.sphinx.chat` has only `tribe_host`, `default_lsp`, ...).
  Peel keeps it as `Setting.memesHost`, default `memes.sphinx.chat`;
  `--memes-host` sets it (loopback hosts are spoken to over http, all others
  https only).
- **Auth.** `GET /ask` → `{id, challenge}`. The challenge (URL-safe base64)
  is signed with the account key (child index 0) by the core's
  `signBytes` over the decoded bytes: a 65-byte recoverable Lightning
  signed-message signature, sent as URL-safe base64 with padding (the Mac
  app's `signBase64` branch gives the same bytes). `POST
  /verify?id=<id>&sig=<sig>&pubkey=<account pubkey>` (empty multipart body) →
  `{token}`, a JWT whose payload `exp` says how long it lasts. The token is
  sent as `Authorization: Bearer` on uploads and downloads; the Mac app keeps
  it until `exp` and asks again on failure. Peel keeps it in memory only.
- **Encryption.** RNCryptor v3, password form. The key is 32 random
  alphanumeric ASCII characters, hex-encoded: a 64-character lowercase hex
  string, used as the password (its UTF-8 bytes). Format: `03 01`, 8-byte
  encryption salt, 8-byte HMAC salt, 16-byte IV, AES-256-CBC with PKCS#7
  padding, HMAC-SHA256 over everything before it. Both keys are
  PBKDF2-HMAC-SHA1, 10,000 rounds, 32 bytes. CryptoKit has no PBKDF2 or CBC,
  so Peel uses CommonCrypto (part of the SDK, not a new dependency) for those
  two and CryptoKit for the HMAC.
- **Upload.** `POST /file`, multipart, `Authorization: Bearer`. Field `name`
  is `image`, `video`, `audio`, `text` or `file`; field `file` is the
  *encrypted* bytes with a file name and MIME type chosen by kind, as
  `AttachmentObject.getFileAndMime`: a still image `image.jpg` /
  `image/jpg` (whatever the real format; the bytes are sent unchanged), an
  animated image `image.gif` / `image/gif`, a video `video.mov` /
  `video/mov`, a recording `audio.wav` / `audio/wav`, a PDF its own name /
  `application/pdf`, anything else its own name / the MIME type of its
  extension (or `application/octet-stream`). The reply's `muid` names the
  file.
- **Media token.** The core's `makeMediaToken(seed, time, state, host:
  "memes.sphinx.chat", muid, to: <recipient>, expiry: now + 1 year)`
  (`makeMediaTokenWithPrice` adds `amt=<sats>` for a paid attachment). The
  token is `b64(host).muid.b64(buyer, empty).b64(expiry, u32 BE).b64(meta).sig`,
  URL-safe base64 with padding; `to` is ignored by the core.
- **The message.** Type 6 (`attachment`), JSON
  `{"content": <text or "">, "mediaKey": <key>, "mediaKeyForSelf": <key>,
  "mediaType": <MIME>, "mediaToken": <token>}` (plus `replyUuid` /
  `threadUuid` when set). The core moves `mediaKeyForSelf` (it must be 32
  bytes of hex, which the key is) into `encryptedMediaKey`, encrypted to this
  account, so our own copy (echo, other devices, restore) gets `mediaKey`
  back after decryption. The recipient reads `mediaKey` in the clear inside
  the onion-encrypted message. Amounts as for text: 0 to a contact; a tribe
  is paid its price per message plus escrow, at least 3 sats. The tribes
  server refuses an attachment without `mediaKey` or `mediaToken`
  (`valid_pld`), forwards both to every member (late joiners get them with
  the history), and strips `mediaKey` only when the token has a price.
- **Paid attachments** (types 7 purchase, 8 accept, 9 deny): to a contact the
  key is left out and sent in a purchase-accept; in a tribe the tribes server
  holds the key and sends it with its own accept. Not built in Peel: sending
  with a price is not offered, and a received paid attachment (token `amt`
  > 0 and no key) is reported as not supported.
- **Download.** `GET https://<host from the token>/file/<mediaToken>` with
  the bearer token; the file name comes from `Content-Disposition:
  ...filename=` (or `GET /media/<muid>` → `{filename, size}`). Decrypt with
  `mediaKey`. Kind by `mediaType` as the Mac app (`getMediaType`): contains
  `image` or `gif` → image; `video` → video; `audio` → audio (the Mac app
  plays only `audio/wav`); `sphinx/text` → paid text; `pdf` → PDF; else a
  file; an empty type is an image. The Mac app caches decrypted data in
  memory and images in SDImageCache with no size cap, and caches its own
  upload's plain bytes under the media URL right after sending.

### Decisions

- Peel downloads only from the account's own memes host. A token naming any
  other host is refused: otherwise any sender could make Peel fetch from a
  server of their choosing, and the bearer token must never go elsewhere.
  Redirects keep the bearer token only on the same host, and only to https
  (or loopback).
- What a download claims to be is checked against its bytes (image headers
  for images, container signatures for video and audio, `%PDF-` for PDFs);
  a mismatch is reported as a plain file, which nothing renders. Peel never
  opens or executes a file; `download` writes it where it is told and stops.
- Size cap 100 MB for sending and downloading (a `Content-Length` over it is
  refused before reading; a body that grows past it is cut off). The
  decrypted cache lives in `<profile>/media/cache`, one file per muid, and is
  trimmed to 500 MB, oldest first.
- The encrypted upload waits in `<profile>/media/outbox/<row id>` until the
  memes server has it, so Retry after a failed upload uploads the same bytes
  again; after a successful upload Retry only sends the message (the body,
  with token and key, is stored on the row).
- Received audio of any `audio/*` type is audio, not only `audio/wav` as in
  the Mac app (which shows other audio as a file): Peel can play it, and the
  bytes are checked against audio signatures first. What Peel *sends* for an
  audio file is the Mac app's generic file (its own name and MIME type).
- Paid attachments are out of scope for now (decided 2026-10-07).

### For the UI (decided 2026-10-07)

- Images download automatically when shown (they are small and decrypted
  locally); other files download on tap.
- "Save…" lets the person pick where a file goes; nothing is opened for them.
- Upload progress is a bar on the row, from `Engine.Event.transfer`
  (`.upload`); downloads report `.download` the same way.
- (The app hid attachment rows until the chat UI landed; it shows them now.)

### Built

- `Media.swift`: `MediaCrypto` (RNCryptor v3 password form, CommonCrypto for
  PBKDF2 and AES-CBC, CryptoKit for the HMAC), `MediaToken` (host, muid),
  `MemesServer` (ask/verify, upload and capped download through one
  chunked transfer that reports progress, an ephemeral URL session that
  keeps the bearer token off other hosts and plain http),
  `AttachmentKind` (from `mediaType`, and `verified(_:declared:)` from the
  bytes: ImageIO must decode an image; container signatures for video and
  audio; `%PDF-`; UTF-8 for paid text), `OutgoingFile` (the Mac app's names
  and MIME types), `MediaStore` (cache and outbox under `<profile>/media`,
  cache files named by a hash of muid and key, trimmed oldest first).
- Storage migration **`v9`**, after v7 (tribes parity) and v8 (replies and
  threads): `message.mediaType`, `fileName`, `fileSize`, `upload`
  (`PENDING`, `DONE`, `FAILED`), and a partial index on `upload`. The key and
  token stay in the body JSON only. Attachments (type 6) are "content" with
  text (`MessageType.content`): shown in `messages(in:)`, unread, a chat's
  newest message, retryable, counted as a tribe member's posts.
  `Setting.memesHost`.
- `Engine`: `sendAttachment(_:text:to:)` (DM or tribe; the row is written
  before the upload, with the key in the body and the encrypted file in the
  outbox; tribe price as for text), `downloadAttachment(messageID:)`
  (cache first; own memes host only; key required, paid attachments
  refused; capped; decrypted, checked, cached; file name and size recorded),
  `setMemesHost`. `resend` uploads again only when the upload never
  finished, claiming the row in the database so one upload runs at a time
  (an upload cut off by a quit is marked failed when the engine starts);
  otherwise it only sends. `discard` removes the outbox file. The bearer
  token is kept in memory and refreshed on expiry or a 401/403.
  `Event.transfer(messageID:direction:bytes:total:)` reports upload and
  download progress at most every 5% or 250 ms, and at the end. File work,
  decryption and the kind check run off the actor. Incoming attachment rows
  get `mediaType` from the body. `Account` takes `memesHost` like
  `tribeHost`.
- CLI: `send-file <pubkey> <path> [--text <caption>]`, `download <id> <out
  path>` (refuses an existing path; never opens anything), `--memes-host`,
  attachment details in `messages`.
- No new dependency: CommonCrypto, CryptoKit, ImageIO and
  UniformTypeIdentifiers are system frameworks.

### Verified (local stack, 2026-10-07)

Broker 1907, mixer 8037, tribes 8837 and a memes stub on 8857 (no real memes
server can be run locally, see AGENTS.md; the stub verifies the sign-in
signature with secp256k1 against the given pubkey, so the sign-in convention
is checked for real). Profiles `at-alice`, `at-bob`, `at-carol`, `at-bob2`.

- Sign-in: `GET /ask`, `POST /verify` accepted (signature over the
  challenge, account key, URL-safe base64).
- DM image Alice → Bob: uploaded as `name=image`, `image.jpg`, `image/jpg`;
  the stored blob decrypts with an independent Python RNCryptor
  implementation to the original file; body has `content`, `mediaKey`,
  `mediaKeyForSelf`, `mediaType`, `mediaToken`. Bob downloads it
  byte-identical; a second download is a cache hit (no request to the server).
- DM PDF and text file Bob → Alice: `application/pdf` / `text/plain`, file
  names from `Content-Disposition`, byte-identical; Alice's own image is a
  cache hit from the start.
- Tribe (5 sats per message): Bob posts an image, Alice a PDF; each row is
  one row, delivered (the tribe's copy merged), paid 5000 msat; each side
  downloads the other's intact.
- Late joiner Carol gets both tribe attachments in the history and
  downloads them intact. Bob restored from his words (`at-bob2`) downloads
  his own DM and tribe attachments and Alice's, all intact.
- Retry: memes server down → row `upload FAILED`, message failed, outbox
  file kept; `resend` with the server back uploads once and delivers, outbox
  emptied. Upload done but no broker → message failed; `resend` delivers with
  no second upload.
- Oversize: a 104.9 MB file is refused before anything is stored or
  uploaded; a download declaring 200 MB, and one streaming 101 MB with no
  length, are both refused with nothing written; the same attachment
  downloads intact afterwards.
- A token whose host is not the account's memes host is refused.
- Unit tests build (`swift build --build-tests`); not run in this session.

After the reviews and the rebase onto v7 and v8 (same stack; the existing
profiles migrated from the earlier v9 to v7, v8 in place):
- DM image Alice → Bob intact, second download a cache hit; an 8 MB file
  intact both ways.
- Progress through a slowed stub: `upload` events at 5.2, 6.3, 7.3, 8.4 MB
  and the end; `download` events about every half megabyte to the end.
- Tribe: a PDF each way (Bob's and Alice's, both sent by `resend` of rows
  left pending) delivered and downloaded intact on the other side.
- Memes stub down: row `upload failed`; `resend` with it back uploads once
  and delivers.
- Stack note: tribe sends failed with "malformed onion: Upstream node set
  CLTV to less than the CLTV set by the sender" after the stack had run for
  about half an hour; restarting the tribes server (which reads the block
  height once, while an auto-mining mixer keeps raising it) fixed it. Not
  an attachments issue; text sends failed the same way.

Not verified: anything against `memes.sphinx.chat` or with the official
apps (the conventions are matched from their code, and the stub enforces the
same endpoints); video and audio files; the 401 re-sign-in path (the stub's
tokens outlive a run); cache trimming at 500 MB (unit test only).

### Reviews (2026-10-07)

`/code-review high`, all fixed except the audio one (see Decisions): the app
drew attachments as "joined" notes (now hidden until their design); the
sidebar ignored them; a row looked retryable mid-upload; a row was left
without its outbox file when that write failed; an upload failure had no
tag (the row is emitted instead); a line break in a file name reached the
multipart headers; the download read a byte at a time; the file was
decrypted again just for the cache; videos other than .mov/.mp4/.m4v/.3gp
went as `video.mov` (now plain files, as from the Mac app).

`/simplify` (reuse, simplification, efficiency, altitude), applied: upload
state only in the database (a retry claims the row; no in-memory set);
`Storage.insert`, the `muid` column, `Conversation.lastType`,
`MediaToken.price` and `Failure.paidAttachment` dropped;
`MessageType.content` for every "text or attachment" list (which also puts
attachment senders in `tribeSenders`); `TribeLink.baseURL` shared with
`TribeInfo.fetch`; `withoutControlCharacters`; `Session.connectIfPossible`;
`memesHost` through `Account` like `tribeHost`; file work, decryption and
the kind check off the actor; the first send reuses its encrypted bytes and
a retry does not decrypt for the cache; encryption into one buffer; one
image source for "image" and "animated"; a partial index for the startup
check; test helpers shared with `StorageTests`.

Not applied, with reasons:
- `audio/*` stays audio (see Decisions).
- The `upload` column is not derived from the body and status: the UI needs
  "uploading" apart from "sending".
- The kind is checked again on every cache hit (off the actor) rather than
  stored: one column less, and a cached file is re-checked as it is now.
- The cache is trimmed on every store, not by a running total: a directory
  listing per download is small next to the download.
- Uploads are built in memory, not streamed from a file: 100 MB cap.
- The transfer's own redirect handler is kept although the session has one:
  it is the security path, so it does not rely on delegate fallback.
- The app hides attachments in the view only; unread and the sidebar count
  them until the attachment design lands.
- `EngineTests` keeps its own base64url helper (outside this change).

`/security-review`: no finding at confidence 7 or above. Checked: the
bearer token goes only to the configured memes host (a token naming another
host is refused; redirects drop it off-host and refuse plain http); the
media token only extends the path on that host; cache and outbox names
cannot be steered (hashes and row ids); the server's file name is cleaned
and never used as a path; the MAC is checked (constant time) before
decrypting; keys, salts and IVs come from the system CSPRNG; all SQL is
bound or built from constants; a remote sender sets only `mediaType`;
nothing logs keys or tokens. Near-miss not applied: a received `mediaType`
is printed raw by the CLI, like message text already is.

## Chat UI: replies, threads, attachments, Peel's menu

Branch `phase3/chat-ui` (2026-10-07), on top of `phase3/attachments`,
rebased onto main after the Account screen (#10) and the tribe follow-ups
(#11). Built from the boards Tom approved on the "Peel layout directions"
canvas (R1–R12), with his decisions below winning where they differ.

### Decided (Tom, 2026-10-07)

- No "Also send to #tribe" in the thread composer.
- One Reply (changed later the same day; "Reply in thread" removed from the
  hover bar, the menu, the T shortcut and the viewer): Reply opens the
  inline reply bar, or for a message folded into a collapsed tribe thread,
  the thread panel with the reply bar there. Threads emerge from replies, as
  in the official app; engine links are unchanged (a reply joins or starts
  the parent's thread).
- No "Copy link" anywhere (Sphinx has no message links).
- Shortcuts shown in a menu must work: R reply, ⌘C copy.
- DM rows: a menu without Leave. Mark as read and the notification level;
  no Delete chat, because the engine cannot delete a conversation.
- Collapsed tribe thread row: the original message, "N replies", the newest
  reply's sender and time, up to 3 participant avatars, bold (with "N new")
  when unread. DMs never collapse. The Threads list covers DMs and tribes;
  a DM thread is listed from its first reply (Tom, later the same day),
  a tribe thread from two messages, as it collapses.
- Thread unread clears when the chat is opened (the server read marker), as
  in the Mac app.
- A quote whose parent is not stored says "Original message not available".
  Approvals and other membership messages are never quoted; quotes only for
  text and attachments.
- Image grid: up to 4 tiles with "+N", one sender's consecutive images within
  about a minute (60 s), with the same reply and thread links, only the last
  carrying a caption.
- Images download automatically when shown; files on tap; Save… opens a save
  panel; nothing is ever opened for the person. Paid attachments are out of
  scope.
- Upload progress from `.transfer` events; a failed upload shows "Not
  uploaded · Retry · Discard", like an undelivered message.
- Previews of an attachment with no caption are words, never emoji: "Image",
  "File: name.pdf" (`Message.preview`).
- The pinned bar is the one from tribes parity.
- One Peel menu replaces every native context menu, pop-up button and
  picker in the app (Tom, after first use: also the Account screen's "Ask
  for the PIN" picker).

### Built

Engine and storage (PeelCore):
- `Message.isLinkable(inTribe:)` (the one rule for what a reply or thread
  message may name, shared by the engine and the app), `threadRoot`,
  `preview`, `isContent`, `senderDetails` (alias and photo from one decode).
- `sendAttachment(_:text:to:replyTo:inThread:stored:)`: attachments can be
  replies and thread messages (links kept through a retry); `stored` reports
  the row id before the upload, so the app shows the local file meanwhile.
- `links(replyTo:inThread:)` shared by text and attachments; `inThread` may
  name a thread whose original is not stored as long as messages of it are
  (`Storage.hasThreadMessages`), so such a thread can be answered.
- `ThreadSummary.latest` and `participants` (last three distinct senders,
  each sender's JSON decoded once per emission); `threads()` covers ready
  contacts as well as joined tribes.
- `uploadPhoto(_:)`: as the Mac app's `uploadPublicImage`, a JPEG at quality
  0.5 (at most 1024 px) posted in the clear to the memes server's `/public`
  route; `https://<memes host>/public/<muid>` becomes the photo. The muid is
  checked (ASCII letters, digits, `-_=`) before it goes into a URL.
- Own photo recovery also runs once on start, for accounts restored before
  the restore learned it: only when no photo was ever set on this Mac, from
  the newest own direct message (tribe copies skipped).
- `ImageDecoding.thumbnail`: one set of ImageIO options for attachments,
  avatars and the profile photo.
- `PeelError.readable`: system network and file errors in a short sentence
  instead of an NSError dump, for every notice the app shows.
- CLI: `send-file --reply/--thread`, `upload-photo <picture>`; `threads`
  lists DM threads too.
- Tests (`ThreadTests`, built, not run here): DM threads in the list with
  their latest message and participants; `Message.preview`.

App (PeelApp):
- `PeelMenu.swift`: entries (items with icon, shortcut, check, destructive
  with an in-place confirmation, headers, dividers), a presenter per window
  or popover (`.peelMenuHost()`), `.peelMenu { }` for right-click and
  Control-click (an NSView that takes only those clicks), `MenuButton` and
  `PeelDropdown`. Keyboard: arrows, Return, Escape and the item shortcuts,
  through a key monitor while the menu is open. Opens beside its trigger and
  flips at the window's edges.
- Menus: message (Reply, Reply in thread, Copy text, Copy image, Save…,
  Pin/Unpin for the owner), undelivered (Retry sending or Retry upload,
  Discard, Copy text), sidebar row (Mark as read, notification level, Copy
  tribe link, Leave or Remove from Peel), member row in the members popover
  (Copy name; Approve/Decline; Remove from tribe for the owner), the Account
  screen's PIN timeout dropdown. No native `.contextMenu`, `Picker` or `Menu`
  remains.
- Conversation: rows built once per timeline emission in `AppModel`
  (`ChatRow.rows`: image runs, quotes, collapsed threads, approvals, runs and
  day dividers in one pass); hover bar; quotes that scroll to and light up
  their parent, or open the thread that folded it; collapsed thread rows;
  the open thread's row tinted.
- Thread panel (360 pt, slides in, Escape closes): original, "N replies",
  replies, its own composer. On a window too narrow for both it takes the
  conversation's place. Drafts, reply targets and pending files live in the
  model per composer, so nothing is lost when it covers the chat.
- Threads list with unread dots, "Mark all read", and a sidebar badge.
- Attachments: image tiles and grids (decoded off the main thread at the
  size drawn, a 200 MB memory cache, decodes shared), file cards (type,
  name, size, Download, Save…), upload bars, the composer tray (thumbnails,
  file cards, remove, "+"), the paperclip, drop to attach on the chat and the
  thread panel, and the image viewer (Reply, Copy, Save…, arrows and arrow
  keys, caption, strip, Escape). Downloads belong to the model, not the row
  (a lazy row dropped mid-download used to cancel it).
- Mention suggestions (Tom, after first use): above the composer, inside the
  window, in the menu's style, scrolling after seven.
- Account screen: "Choose a picture…" uploads the photo.

### Verified (local stack, 2026-10-07)

Broker 1917, mixer 8047, tribes 8847, memes stub 8867 (with a `/public`
route added to the stub); profiles `ui-alice`, `ui-bob`, `ui-carol`, seeded
from the CLI with DM replies, a DM thread, an image and a PDF in the DM, a
tribe thread of four, five images in a run, a PDF, a reply, a failed DM send
and a failed upload. The app was built with `bundle-app.sh` into the
scratchpad and launched on `-profile ui-alice`; screenshots of each state
are in the session scratchpad (`ui-shots/`). This session could not click or
type in the app, so each state was reached by a temporary launch-argument
driver calling the model (deleted, never committed).

Seen in screenshots: the tribe with the image grid and "+1", PDF card,
reply quote and collapsed thread row; the DM with quotes (text, image) and
inline replies; the reply bar; the message, undelivered (with the in-place
Discard confirmation), tribe and DM menus; the thread panel beside the
conversation and on its own on a narrow window; a DM thread; the Threads
list; the image viewer; the composer tray; an upload in progress with its
bar; "Not uploaded · Retry · Discard"; mention suggestions above the
composer; the PIN dropdown. The memes stub received a 1024x640 JPEG from
`upload-photo` on `/public`.

Not exercised: real right-click and hover, keyboard in menus and the viewer,
clicking a quote, drag and drop, the save and open panels, Copy image, the
members popover menu, Escape, Retry clicked in the UI, the own-photo
recovery with a real photo (the local accounts have none), anything against
`memes.sphinx.chat` or with the official apps.

### Reviews

`/code-review high`, fixed: a second caller of a running download did not
wait for it (viewer, Save… read no file); the thread close button's Escape
took the key from the composer; a thread without its stored original could
not be answered; a covered chat lost its draft; a multi-file send's notices
overwrote each other; two composers shared Cmd-Return; the viewer's Reply
went to the chat composer for a thread image; an image tile did not load
after a retried upload; "Last reply" showed only the time.

`/simplify` (reuse, simplification, efficiency, altitude), applied: thread
anchoring and upload-preview matching moved into the engine (above); rows
built once per emission and each sender decoded once; drafts in the model
and the zero-width covered chat replaced by a plain `if`; the menu's
subject and open state observed apart from its highlight, so rows do not
redraw as the pointer moves over items; one `sender(of:)` for names and
photos; `Formatting.replies`, `OriginalNotAvailable`, `menuBoxed()`,
`Clipboard.copyImage`, one open-panel helper, `DetailHeader` in the thread
panel; `MessageContext` merged into `ComposerID`; grid tiles decoded at
their size and seeded from the cache; shared decodes; dead parameters
removed.

Not applied, with reasons:
- Files are sent one after another: `sendAttachment` awaits its upload and
  delivery, and the order must hold. An engine call taking several files
  (rows written first, uploads after) would show them all at once; a
  follow-up.
- The menu needs a host per window or popover (`.peelMenuHost()`); an
  app-level borderless panel would not, but is more AppKit than this pass.
  The popovers with menus (members) have one.
- The menu and the image viewer each install a key monitor; one router for
  the topmost overlay would be tidier. They never show together today.
- `threads()` re-runs on every message write and its "threads I wrote in"
  lookup has no index; an index needs a migration. Small at today's sizes.
- `HoverIconButton` and `HeaderButton` stay two buttons (the hover style
  differs); the pending-file badge does not reuse `AttachmentMark`.
- The viewer decodes at up to 4096 px.

`/security-review`: no finding at confidence 8 or above. Checked: the new
SQL is bound or built from constants; the muid is validated before it goes
into a URL and the photo must be https; the bearer token goes only to its
own host; own-photo recovery reads only our own rows; reply and thread
lookups stay within one chat; participant names and photos are display only
(https photos). The near-miss (a saved file carried no quarantine
attribute) is now fixed, below.

### Open

- Question for Tom: are menu-only shortcuts enough (hover shortcuts would
  clash with typing). (A DM thread with a single reply is now listed.)
- Click through everything listed under "Not exercised".

### Sidebar: you on top (S2, 2026-10-07)

Tom chose option S2 from the canvas (`SidebarYouOnTop`): the sidebar starts
with you (photo, name with a chevron, balance) and the connection bolt;
clicking you opens Peel's menu with your name, short key and balance,
"Account…" (⌘,) and "Copy contact info". Receive sats and Invite someone are
left out until they exist, and so is the compose button. The footer row and
the old logo header are gone; the development-profile banner stays.
`MenuEntry.view` shows the identity at the top of the menu. Seen in
screenshots on a fresh offline development profile (menu closed and open);
not clicked by hand.

`threads()` now lists a DM thread from its first reply (`HAVING` two or more
only for tribes); `ThreadTests` covers it (built, not run here).

### After Tom's first test of the branch build (2026-10-07)

Root causes, found in the code (no clicking here) and fixed:

- **Hover bar over the message.** It was an overlay pinned to the bubble's
  own top corner (top-trailing for theirs) with a small offset, so it was
  drawn inward across the bubble: on a short message it covered most of the
  text. It now sits in a gutter the row keeps free beside every bubble (84
  pt), outside the bubble's edge and top-aligned with it, inside the row, so
  moving the pointer onto it keeps the row hovered. Same in the thread panel
  and on a narrow window (the gutter is part of every row).
- **The "you" menu at the top did not work, nor did menus generally over
  lists.** Menus were SwiftUI overlays drawn at the window's root, over the
  sidebar's and the conversation's scroll views and the text fields. AppKit
  sends a click to the deepest AppKit view under it (each `ScrollView` is an
  `NSScrollView`), so a click on "Account…" over the sidebar went to the
  list underneath, never to the menu. Menus and panels now open in their own
  borderless windows (children of the window they open from), with clicks
  outside closing them (swallowed for menus, as native menus do), Escape,
  and closing when Peel goes to the back. The presenter knows its window
  from the view hierarchy, not from "the key window", which is nil when Peel
  is not frontmost.
- **Native popovers.** The connection card, Join a tribe, Create a tribe,
  Add contact, tribe settings and members were native `.popover`s; they are
  `.peelPopover` panels now, in the menu's surface, anchored like it.
- Right-click now also works on Threads cards (Open thread, Mark as read),
  Mentions rows (Open in #tribe, Copy text), the pinned bar (Copy text,
  Unpin) and "N replies". Text fields keep the system's text menu.

Then, from the same test:

- **One Reply** (see "Decided").
- **Files land in Downloads in one click**, decrypted, under a free name
  ("name (1).ext"), and the card offers Show in Finder (reveal only);
  "Save as…" stays in the menu. `UserFiles` (PeelCore) writes every file
  Peel saves for the person (Downloads, Save as…, CLI `download`) and sets
  `com.apple.quarantine` with Peel as the agent, removing the file if that
  fails, so Gatekeeper checks it before it opens: the security near-miss,
  done. The app is not sandboxed (its only entitlement is the keychain
  group), so ~/Downloads needs no entitlement; macOS may ask once for
  access to Downloads.
- **Delete for everyone.** Checked against the Mac app: a type 17 message
  with `replyUuid` naming the message (`sendDeleteRequest`); it allows
  deleting your own, or any in your own tribe (`canBeDeleted`), but not a
  thread's original while it has two or more thread messages; a received
  delete marks the target deleted ("This message has been deleted"). The
  Mac app applies any received delete; Peel only applies one from the
  message's sender (in a DM, the contact for theirs; ours for ours), or in
  a tribe from the owner (`role: 0`, which the tribes server stamps) or the
  member whose message it is (the tribes server already refuses anyone
  else's, `forward.rs`; the alias, unique in a tribe, must match too).
  Engine `deleteMessage(id:)` (pays the tribe price like any message; the
  row is emptied when the delete is sent), storage migration **v10**
  (`message.deleted`; content, body, key and file details cleared; a later
  copy of the message cannot fill them again), CLI `delete <id>`, menu
  "Delete" with "Delete for everyone?", the placeholder row.
  Verified on a local stack (profiles `ui3-*`, since deleted): DM, each side
  deletes its own (both see it deleted); Alice's attempt on Bob's DM refused
  by the engine; tribe, Bob deletes his own, Alice (owner) deletes Carol's,
  all three see both deleted; Bob's attempt on Carol's refused, and her
  message stays. A forged delete (a contact's delete of our message, a
  member's of another's) is covered by `ThreadTests` (built, not run); the
  tribes server refuses a member's in the first place.
  Not applied: a delete whose send fails leaves the row emptied here though
  the others still have it (as the Mac app); deleting a pending or failed
  message is Discard's job.

Screenshots (fresh `ui3-` profile): the hover bar beside a bubble, the
deleted placeholder, the "you" menu and the connection panel as Peel
windows. Not clicked by hand: everything above.

### Flat rows and system type (2026-10-07)

Tom picked readability option D on the canvas (`ReadFlatRows`): flat rows
instead of bubbles, the system font instead of Roboto (no longer bundled),
softer text and new link and mention colours (see the design README).
Built in `MessageViews` (rows, run header, gutter time on hover, hover bar
at the row's top-right, list items, link shortening), `Theme`, and the
attachment views, which now size to their column (grid tiles flexible up
to 148 pt, file cards up to 300 pt with the name truncated in the middle,
images at their shape up to 320 pt, never past the column). Run names and
photos are worked out with the rows (`ChatRow.People`: you, the contact,
or the tribe member).

Also from Tom's testing: the sidebar (220–420 pt) and thread panel
(300–560 pt) resize on their dividers (`PaneDivider`; double-click resets;
widths kept in UserDefaults); the thread panel reads from the top (its
original first, "No replies yet" under it) and scrolls to the bottom only
once there is more than fits; the main conversation scrolls to its newest
message on opening.

Run breaks: Tom saw a name and time on every message in his real tribe.
Not reproduced on a local stack: consecutive messages from one member (and
from a contact, and from yourself) share one header here, and the rules
(another sender by tribe alias, five minutes, a new day, a collapsed
thread row or a note between) match the README. The grouping inputs were
checked against the tribes server (`date` is milliseconds, aliases stay
stable per member). The real tribe's rows are needed to find the cause:
`peel --profile <profile> messages <tribe>` prints each row's alias and
time.

Verified with screenshots on fresh `ui4-` profiles (since deleted): a
tribe with a run, a list, a mention, a long link, an image grid, a file, a
thread row and a reply; a DM with runs, a quote, a file and an undelivered
message; a thread with a file original and no replies; resized panes.
Not clicked by hand; code-review, simplify and security-review wait for
Tom's test of this build.

### Two-click menu items and the final review chain (2026-10-07)

Tom's test of the flat-rows build: everything works except the look of
the delete confirmation. Every destructive menu item (Delete, Discard,
Remove from Peel, Leave, Remove a member) now takes two clicks in place:
the first turns the row into bold red text with a trash icon and "Click
again", the menu stays open; the second acts; another row or Escape puts
it back. Panel and screen confirms (`InlineConfirm`) are unchanged.

The chain ran over the whole UI branch, `origin/phase3/attachments...HEAD`
(`35446a6..HEAD`), each finding checked to be in that diff.

`/code-review high`, fixed:
- A thread could no longer be posted to once its original was deleted:
  `links()` takes a deleted original's thread root, and accepts an
  unstored uuid with stored thread messages.
- Our own delete was applied before the server had it: it now applies on
  the echo with a server index or on a delivered status, so a failed
  delete can be retried (test: "own unsent delete doesn't apply").
- The caption was lost when the file carrying it was refused: the text is
  sent alone, refused files go back to the tray, the reply target stays.
- The image viewer's key monitor ran under the Save panel; key monitors
  now stand down while a modal window is up.
- A grid tile's menu acted on the run's first image: each tile has its own.
- A later copy of a deleted message could set "mentions me" again.
- A deleted attachment's decrypted file stayed in the cache: it is removed.
- The UI's delete rule differed from the engine's: both use
  `Message.isDeletable(inTribe:ownsTribe:threadCount:)`.
- `cleanName(" .zshrc")` kept a hidden name: spaces and dots are stripped
  together.
- Rows went stale after a profile or contact change: rebuilt on both.

`/simplify` (reuse, simplification, efficiency, altitude), applied: dead
`MessageMeta` removed; `MenuEntry.copyText` used in three places; the
reply bar and "Last reply" use `sender(of:)`; `hasThreadMessages` folded
into `threadCount`; doc comments fixed.

Not applied, with reasons:
- Multi-file send in the engine, an event instead of the `stored:`
  callback, one sender resolver in PeelCore, `Engine.canDelete` by id,
  "mark all threads read" as one engine call, answered/settled kept in
  Storage, a result struct for `Storage.apply`: each moves logic across
  the core boundary for one caller; worth it with the next feature that
  needs them.
- Incremental row rebuilds, a text parse cache, one right-click catcher
  per row, an index for `threads()`, a stored unread-threads count, a
  `fetchOne` tribe lookup: not measurable at today's sizes; the index
  needs a migration.
- Presenter reads moved into leaf views, `ThreadSummary.ref`,
  `Conversation.displayName`, `leave` via `attempt`, one body-to-cache-key
  helper, a hoisted decoder in `threadParticipants`: small tidy-ups left
  for a later pass to keep this diff settled after Tom's test.
- One image cache with the photo cache, shared `MenuButton` labels and
  `listTime`: the pairs differ in size limits and styling.

`/security-review`: no finding at confidence 8 or above. Checked: names
saved into Downloads (no traversal, no hidden names, control and bidi
characters dropped, quarantined, never opened, never overwriting); type-17
deletes stay in their chat and apply only from the sender or the tribe's
owner; the cache path is a hash; the photo upload's token goes only to the
memes host, the muid is validated and photos must be https; only https
links are clickable; new SQL is bound or built from constants. Near-miss
(confidence about 5): a tribe delete is matched to its target by alias,
which relies on the tribes server keeping aliases unique and refusing a
member's delete of another's message; matching by sender key would not.

### Drop and paste beyond Finder (branch `fix/attachment-drop-paste`, 2026-10-08)

Tom, in real use: attaching only worked by dragging from Finder. The
screenshot thumbnail (Cmd-Shift-4/5) dropped on the chat or the composer did
nothing, and Cmd-V with an image or a copied file on the clipboard added
nothing.

Why:
- The conversation's drop was `.dropDestination(for: URL.self)`, which takes
  only URL items. The thumbnail offers a file promise
  (`com.apple.NSFilePromiseItemMetaData`, `promised-file-url`) and image
  data, not a file URL, so it was refused.
- Over the composer, the field's `NSTextView` registers its own drag types
  (file names, promises, PNG, TIFF, URLs, text) even as plain text, so it
  took the drag ahead of the conversation's drop. It cannot insert a picture
  (`importsGraphics` off), so images and promises did nothing there.
- Paste went to the plain-text `NSTextView`, which reads only text, URLs and
  file names: image data was ignored, and a file copied in Finder pasted at
  most its name.

Built:
- `IncomingFiles` (PeelCore, pure and tested): what a pasteboard item gives
  (file URL first, then a promise, then image bytes in PNG, JPEG, HEIC, TIFF
  order); an image with real words beside it pastes as text (rich text
  copied from a page or document carries a picture of itself), an image with
  only a link beside it (Copy Image) is the image. Image bytes are written to
  `$TMPDIR/Peel Attachments/<uuid>/Image 2026-10-08 at 14.05.png` (TIFF
  converted to PNG; " (2)" and on for more in one paste), over
  `Engine.attachmentLimit` refused before decoding. A promised file is
  accepted only as a plain file (no link, no folder) directly in the folder
  Peel gave it and within the limit; anything else is removed and refused.
  `discard` removes only Peel's own files.
- `PasteboardFiles` (app): reads a pasteboard in its order; promises are
  received at once into a new folder of Peel's (given up after two minutes).
  The drag's own pasteboard is read (`NSPasteboard(name: .drag)`) rather than
  SwiftUI's item providers.
- The conversation and thread panel drop (`FileDrop`) takes files, images and
  promises through a `DropDelegate` that only offers the drop when there is
  something for the tray. The composer's text view takes the same drags
  itself (and shows the same overlay through `AppModel.dropTarget`), so a
  drop anywhere on the conversation behaves the same; text drags still go
  into the field.
- Paste in the composer: files or an image on the clipboard go into the tray
  in order; anything else pastes as plain text, as before.
- Cleanup: Peel's files are removed when taken out of the tray, once
  uploaded (the engine keeps its own copy in the cache; the tile reads that),
  and when the account closes (a failed upload keeps its file as the row's
  preview until then). Refused sends keep theirs in the tray.
- Images still go out as `image.jpg` (`OutgoingFile`, as the official apps);
  the readable name shows in the tray and names files that are not images.

Tests: `IncomingFilesTests` (type decisions, names, PNG and TIFF writes,
limit, promise acceptance incl. links, `..` and folders, discard).

Not verified here: real drags and pastes (this session could not drive the
app's UI). Tom to try the steps in the PR.

Reviews: `/code-review high` fixed: one promise's several files shared a
folder that discard removed whole; a failed upload deleted its preview; a
promise that never finished hung the attach; the receiver kept alive; a
tray removal left a sent row pointing at a deleted file; an attach finishing
after the account closed; the overlay showing for drags it would refuse;
drag checks once per entry rather than per move. `/simplify` applied:
in-place drag handling in the text view instead of forwarding to the
SwiftUI host, one `release` for owned files, lazy text reads, the timeout
cancelled when a promise finishes, `attach` starting its own task, the
post-conversion size check dropped. Not applied: sharing an ImageIO encode
helper with `ProfilePhoto` and `MediaStore.write` (outside the composer
code); moving the pasteboard rules to the app (the only test target is
PeelCore); clearing the whole temp folder at launch instead of per file
(another Peel process on another profile may be using it).
`/security-review`: nothing at high confidence.

## Notifications (branch `phase3/notifications`, 2026-10-07)

Done means: while Peel runs, a macOS notification for each new message
from someone else that you would want, opening its chat on a click, gone
once the chat is read; the Dock badge equal to the sidebar's count. Remote
push stays off limits (one push token per account, the official app's);
these are local notifications posted by the running app.

### Checked against the official Mac app

`NotificationsHelper`, `SphinxOnionManager+NotificationsExtension`,
`TransactionMessage.shouldSendNotification`, `getReceivedUnseenMessagesCount`:
nothing for outgoing messages; muted chats never; mentions-only chats only
for a mention; join and leave notes only to the tribe's admin; title is the
tribe name with the sender as subtitle (DM: the sender); default sound;
userInfo carries the chat, and a click opens it; the Dock badge is the
received unseen count by notification level. Not taken: its choice of
sounds and banner/sound modes (System Settings does that), the Reply
action, the sender's photo as an attachment, notifying recently joined
tribes' backlog.

### Built

- `Engine.Event.message` carries an `Arrival`: `.live`, `.history` (a
  catch-up page) or `.restore`, from `msgsTotal` and `restoring` in `commit`.
  `ChatReadState.lastRead` (the read marker, from the same query).
  `Setting.notificationText` with `Engine.notificationShowsText` /
  `setNotificationShowsText` (per account; development profiles and the
  real one share UserDefaults, so it is not kept there).
- `Notifier` (PeelApp): permission, posting, removal, Dock badge.
  - Asks only once the account is open: a quiet bar under the window
    ("Peel can show a notification ... Not now / Turn on notifications");
    "Not now" is remembered on this Mac. The Account screen's
    Notifications group shows On / Off / Turned off in System Settings with
    Turn on or System Settings…, and a "Message text" dropdown (Show
    message text / Say only "New message"). Permission is re-read whenever
    Peel comes to the front. Denied: nothing posts, the screen says how to
    allow it.
  - What notifies: messages from others (text, attachments) and join
    requests to a tribe this account owns, past the chat's read marker, by
    mute level (all / mentions only: `mentionsMe` / muted: never; DMs follow
    their level too, as in the official app). Never: own messages, other
    membership notes, deleted rows, a restore, the first history run of a
    session (the sidebar counts it on opening), the chat open in front of
    you. Later catch-ups (after sleep or a dropped connection) notify;
    messages arriving within 400 ms are gathered and more than 3 from one
    chat become one "N new messages" notification.
  - Content: title the sender (DM: the contact's name), subtitle `#tribe`
    for tribes, body `Message.preview` ("Image", "File: name" for
    attachments) up to 400 characters, or "New message" when the setting is
    off; a join request says "X wants to join". `threadIdentifier` = chat
    so Notification Center groups by chat; userInfo has the chat key only.
    Default sound; Focus is the system's.
  - Lock screen and PIN: the category's hidden-preview placeholder is "New
    message", so with previews hidden the sender is not shown either. While
    Peel is locked, or its PIN timeout has passed even in the background,
    notifications say "Peel" / "New message". Delivered notifications are
    removed when Peel locks, when a PIN profile launches into the lock
    screen, when it quits, and when the account is forgotten.
  - Click: Peel to the front with that chat open (behind the lock screen
    if locked). Not scrolled to the message: the message rows belong to the
    chat UI work; cheap to add later from `ChatModel`.
  - Read: a chat's delivered notifications go when it is opened in front
    of you, or when its read marker moves (read here or on another device).
  - Dock badge: `AppModel.unreadCount` (sum of `shownUnread`), the
    sidebar's count, so it follows read markers and mute levels. Requested
    with `.badge`, which macOS needs to show it. (The brief said a Dock badge
    already existed; none did on main or any branch, so it is new here.)
- Entitlements: none. Local notifications need only the signed bundle
  (`bundle-app.sh`); all Peel builds share bundle ID `dev.peel.mac`, so the
  permission is shared with Tom's installed Peel.

### Verified (local stack on free ports, profiles `nt-app` in the bundled app, `nt-bob` CLI)

Decisions checked through a temporary log of what would be posted
(permission was never granted on this Mac; see below):

| Check | Result |
|---|---|
| DM from bob, another chat open | posted: title ntbob, body the text |
| Tribe message, level all, Peel in the background | posted: ntbob / #Hive / text |
| Mentions only: plain message, then `@ntapp ...` | only the mention posted |
| Request to join the private tribe nt-app owns | posted: ntbob / #Owned / "ntbob wants to join" |
| Bob's own join note, own messages | not posted |
| Relaunch with a message sent while Peel was closed | not posted (first sync), badge counts it |
| App paused, 5 DMs, broker restarted, resumed (reconnect catch-up) | one "5 new messages" |
| Dock badge value | followed the sidebar counts (1, 2, 5–7) |
| After rebasing onto main (attachments, chat UI) | DM posted as before |

Not verified: anything visible in Notification Center (needs Tom to allow
notifications once, see below); the click opening the chat; removal on
read; the lock-screen placeholder; attachments' "Image"/"File: name" body
(no memes server on the local stack); the Account screen's new group by
eye. Allowing: launch a build, click "Turn on notifications" in the bar at
the bottom, then Allow in the macOS prompt (or System Settings >
Notifications > Peel > Allow notifications). This applies to every Peel
build, including the installed one.

### Reviews

`/code-review high`, applied: a click while locked at launch left the chat
empty after unlock (messages now observed on attach); join-request
notifications swept away because unread counts only content (removal now
keys on the read marker moving); notifications stayed readable after the
PIN-timeout lock (removed on lock); the text setting failed open (now
closed); fetching all delivered notifications once per chat (one fetch for
all); a notification posted while a removal ran could be removed (only ones
delivered before it). Not applied: moving the decision into PeelCore — it
depends on what the window shows (frontmost, open chat, lock) and the engine
now supplies the facts it needs (`Arrival`, `lastRead`).

`/simplify` (four angles), applied: the engine tags arrivals instead of the
app guessing catch-up from history events and a timer; the read marker
from `readStates` instead of a database read per batch; tribe ownership
read only when a join request is in the batch; the badge from
`AppModel.unreadCount`, written only when it changes; shared session reset;
`Dictionary(grouping:)`; redaction while locked in one place; `trimmed` /
`nilIfEmpty`. Not applied: dropping the AppModel forwarders (kept so every
action goes through the model, AGENTS.md); a shared bottom-banner view
with `FileSecretsBanner` (MainView is the chat UI's file); a shared
`Message.senderName` for the five existing "Someone" fallbacks (outside
this change); a per-message dedupe flag from storage (the per-session uuid
set is enough with `Arrival`).

`/security-review`: one finding, fixed. Past the PIN timeout but still in
the background, Peel stayed `.ready` and kept posting text; and
notifications from before a quit stayed readable while the relaunched app
asked for the PIN. Now redaction follows `AppModel.isLockDue`, and
delivered notifications are removed on a PIN profile's launch to the lock
screen and on quit. Ruled out: clicks bypassing the lock (the lock screen
still shows), anything before unlock (no engine), userInfo (chat key only),
alias spoofing (tribe notifications always carry `#tribe`), the shared
bundle ID (same user, no new boundary; one Peel may remove another
profile's notifications).

### Open

- Two Peel processes (e.g. Tom's installed one and a dev build) share the
  bundle ID: either may receive the other's clicks and remove its
  notifications. Harmless for one user; a profile tag in userInfo would fix it.
- Scroll to the message on click; a Reply action.
- **Payments and boosts: built 2026-10-08** (`04-money.md`, "Sats
  received"). The note as written before then follows. Tom, 2026-10-07:
  payments to you and boosts on your messages should notify. The engine
  emits `Engine.Event.moneyReceived(Message)` after the row's `.message`:
  someone else's direct payment, or a boost on one of this account's
  messages, stored for the first time on this Mac, with real sats
  (`msat > 0`; a declared `amount` never counts), not deleted and past
  the chat's read marker (so a restore or catch-up of what was read stays
  quiet). `amountMsat` is the amount. It does not apply the chat's mute
  level or the frontmost check; `Notifier.received` would. `AppModel`
  ignores the event for now (`Sources/PeelApp/AppModel.swift`); the
  notifier can take it up with the same gathering and mute rules, text
  such as "Bob sent you 1,000 sats" or "Bob boosted your message, 100
  sats". The same rule decides unread (`Storage.readStatesSQL`).

## Web fetches hardened (branch `fix/url-fetch-hardening`, 2026-10-08)

From the calls-plan security review. Done means: no request goes through
`URLSession.shared`; a URL someone else chose is fetched only from a public
https host, size- and time-limited, with nothing kept on disk.

### Found on main

- `PhotoCache` fetched every sender, contact and tribe photo URL through
  `URLSession.shared`. `httpsOnly` kept the first request on https, but any
  host was allowed (`https://192.168.1.1`, `https://printer.local`, cloud
  metadata at `169.254.169.254`), redirects went anywhere including plain
  http and this network, the body had no size limit, and responses and
  cookies landed in the app's shared cache and cookie store.
- `TribeInfo.record` (tribes registry) and `ServerConfig.fetch` used the same
  session. The registry host comes from a tribe link someone else sends.

### Built

- `Web` (`Sources/PeelCore/Web.swift`): one session factory (ephemeral, no
  URL cache, no cookies, a redirect policy per session), now also used by
  the memes server; `Web.get` (a GET through `MemesServer.Transfer`: 200 only,
  size-limited, a public https host or loopback http for the local stack;
  redirects only to public https hosts); `Web.photo` (public https only,
  2 MB, 30 s per request and 60 s in all; 429/5xx is retried later, anything else is
  not); `Web.isPublic` (https, no credentials, only letters, digits, dots,
  dashes and colons in the host, no IP literal of any kind, no single-label
  name, no `.local`, `.localhost`, `.internal`, `.lan`, `.home.arpa`).
- `PhotoCache` fetches through `Web.photo`.
- Tribes registry and config: through `Web.get` as well (limits of 1 MB and
  100 KB). Warranted: the registry host is chosen by whoever sent the link
  (so it is now refused unless public, or loopback http), it was unbounded,
  and the shared cache kept a record of every tribe looked up. The config URL
  is fixed and first-party, so the main gain there is a fresh answer on every
  restore (never a stale cached config) and one rule for the whole module.
- `MemesServer.Transfer` no longer handles redirects itself; the session's
  delegate (`MemesServer.redirect` or `Web.publicOnly`) does. Checked with a
  local 302 server: a task delegate without the redirect method falls back to
  the session's, which refused it.

### Verified

`swift test`: `WebTests` pass (allowed and refused URLs, the redirect policy,
a refused photo, a registry on this network). The failures are the known
ones: `ThreadTests.threadsListHasDirectMessagesWithLatestAndParticipants`
(fixed by PR #35, still open) and the IPv6 `ServerAddress` known issue. Not
checked in the app: avatars against production photo URLs.

### Reviews

- `/code-review high`, applied: refuse private registry hosts, 6to4 and
  site-local IPv6 (later superseded by refusing all IP literals), reuse
  `httpsOnly`, longer timeouts, AGENTS.md. Not applied: the photo
  status-to-retry mapping has no test (it needs an HTTP server; tests here
  are offline).
- `/simplify`, applied: one session factory and one `Redirects` class for
  the memes server and `Web`; the redirect rule lives on the session, not
  `Transfer`; one bounded `Web.get` for photos, registry and config; IP
  literals refused outright instead of range tables; photo limit 2 MB.
  Not applied: moving `Transfer` and its errors out of `MemesServer` (photo
  errors are never shown; the move touches every memes call site) and an
  own thumbnail cache (deliberately nothing on disk; avatars are fetched
  again on each launch).
- `/security-review`: no findings at confidence 8 or higher. Applied its
  one note: a host with a NUL passed `isPublic` (it did not connect), now
  refused by the plain-host rule.

### Known limits

The host is judged by the name as written: a public name that resolves to
a private address (DNS rebinding) is not caught; https still needs a
certificate valid for that name.

## Inline code and following the newest (branch `fix/inline-code-and-scroll`, 2026-10-08)

From Tom's first sends on his real account: a backticked span showed as
plain text with its backticks, and his own message in a tribe did not
scroll into view.

Done means: `code` shows in a monospaced face on a soft fill without its
backticks, ``` fences as a code block; sending always ends at the newest;
someone else's message is followed only when you are at the bottom, and
scrolled up you stay put while the jump button says "N new messages";
clicking it goes down and clears it. "New messages" and the read marker
work as before.

### Markup

`MessageMarkup` (PeelCore, so the iPhone app gets the same reading; tested
in `MessageMarkupTests`) splits text into paragraphs, "- "/"• "/"* " items
and fenced code, and finds inline spans: code, https links, mentions.
`LinkText` and `MessageText` style them (`Theme.code`, `Theme.codeFill`, a
translucent fill so it shows on hovered and tinted rows too). Rules:

- `code`, ``code``, and ```code``` inside a line; one line, no backticks
  inside. An unmatched or empty backtick stays text.
- A backtick inside a link is part of the link; a link or mention inside
  code is code.
- A fence opens on a line starting with ``` and closes on the next line
  ending with ```; a language name after the opening fence is dropped, other
  text there is code; ```x``` on one line is a block. A fence nothing
  closes, or an empty one, stays text.

Compared with the official Mac app (`Scenes/Dashboard/Workspaces/MarkdownRenderer.swift`,
used for every text message), which also renders: bold (`**`/`__`),
italic (`*`/`_`), bold italic, strikethrough (`~~`), headings (`#`),
quotes (`> `), ordered lists, task lists (`- [ ]`), horizontal rules,
`[text](url)` links, emails, `sphinx.chat://` links and http links. Peel
showed those as typed; since 2026-10-09 it renders emphasis, headings,
quotes, numbered lists and https `[text](url)` links (`10-v1-extras.md`,
"2. Markdown"). Where both render, differences: the official
app pads inline code with spaces; an unclosed fence there runs to the end
of the message; text after an opening fence is always dropped as a
language name, so ```x``` on one line loses `x` and turns the lines after
it into code.

### Scrolling

Root cause, found in the code and reproduced in a standalone SwiftUI list
with the same anchors (200 rows, a new row that grows 400 ms after it
appears, as a sent row does when it is laid out again on delivery): every
"to the newest" scroll went to the last row's id with `anchor: .bottom`,
which stops 12 pt above the content's end (the list's bottom padding).
`defaultScrollAnchor(.bottom, for: .sizeChanges)` only holds a scroll view
that is at its very bottom, so from there a row that grew after the
scroll (the new message measured, its pending row replaced on delivery)
pushed the message below the fold: 54 pt short in every starting position,
including from the bottom. The same list never followed arrivals on its
own either. Scrolling to a zero-height marker at the content's end
(`MessageList.bottomID`, an overlay under the padding) ends at 0 pt and
stays there as rows grow, animated or not, and leaves a reader scrolled up
untouched as rows arrive below (offset unchanged in the same harness).

Changed in `MessageList`: every jump to the newest (opening, your sends,
following, the jump button) goes to the marker. Others' messages follow
only while `following`: the list is at its bottom (within 24 pt) or on its
way there, and you have not scrolled away by hand, jumped to a quote or
opened at "New messages" (before, anything within a screen followed). The
count starts when the list leaves the bottom: from above "New messages"
while what is below it is still unread (opened at it, or "Mark unread"
moved it, and you have not reached the bottom or scrolled away by hand
since), else from everything loaded. The jump button shows when
far up as before, and also nearer the bottom once something has arrived:
a blue "N new messages" pill with the arrow (the round arrow when
nothing is new).

Not verified by hand in the app: the send, the pill and the follow rules
on a live chat.

### Reviews

`/code-review high`, fixed: a message arriving during the follow animation
was not followed (now an intent, `following`, not the measured position);
"opened at New messages" was guessed from a one-screen jump (now set where
the list opens at it, cleared on reaching the bottom or scrolling away by
hand); a fresh list was taken to be at the bottom before it reported; a
language name after a space ("``` python") became code; code after a
backtick inside a link was lost; CRLF text never split into lines; the
99+ cap was written twice (`UnreadBadge.text`). Not applied: join notes
and other rows that never count as unread are neither followed nor counted
when you are just above the bottom (they are not new messages).

`/simplify`, applied: one `following` flag for the follow rule, the
divider looked up once, `reachedBottom()` clears the divider hold,
`LinkText` returns plain text untouched when there are no spans, the link
detector runs only when the text has "https", CRLF is copied only when
present. Not applied: a shared shadow helper with `menuBoxed` and
`Formatting.newMessages` shared with `Notifier` (outside this diff), a
seen high-water mark in place of the divider flag (a larger rework of
#23's count), renaming `LinkText`.

`/security-review`: no finding at confidence 8 or above. Only https links
are clickable, nothing parses markdown from senders, code that looks like
a link is never one. Near-misses carried from main: middle-shortened links,
bidi characters in link text.

Follow-up: `Message.preview` (quotes, thread rows, the reply bar,
notifications) still shows raw backticks; a plain-text flattener in
`MessageMarkup` would fix all of them in one place.

`swift test`: 207 tests, all pass but `ThreadTests.threadsListHasDirectMessagesWithLatestAndParticipants`
(fixed by #35) and the known ServerAddress IPv6 issue.

## Video and audio playback (branch `feat/video-attachments`, 2026-10-08)

Tom, in real use: Gonza's video in a tribe ("Demo of auto-park with
livekit server") showed as a file card, a "FILE" tile titled "File" with a
download arrow; the official Mac app plays it.

### Why it was a file card

- The kind was right. The Mac app sends a video as `video.mov` with media
  type `video/mov` (`AttachmentObject.getFileAndMime`), and both apps
  read any type containing `video` as a video (`getMediaType`;
  `AttachmentKind(mediaType:)`). The row's `attachmentKind` was `.video`.
- The view had no video case: `AttachmentView` drew `ImageTile` for images
  and `FileCard` for everything else, video and audio included.
- `FileCard` names a file by its download's name, else by
  `UTType(mimeType:)`. `video/mov` is not a MIME type UTType knows (the
  real one is `video/quicktime`), so it has no description and no
  extension: hence "File" and "FILE". Nothing was downloaded, so the
  server's `video.mov` never arrived to name it.

### The Mac app (checked, `sphinx-mac-v2`)

- `MediaMessageView` draws the poster frame (`MediaLoader.
  getThumbnailImageFromVideoData`: `AVAssetImageGenerator` two seconds in,
  the track's transform applied) with a play overlay, and shows no file
  name. A click opens `MediaFullScreenView`, an `AVPlayerView` that
  autoplays; Save writes `sphinx.<date>.mov`.
- It downloads videos whole as they show, with no size rule; audio plays
  only for `audio/wav`.

### Decided

- Videos and audio download as they show up to 25 MB
  (`Engine.autoDownloadLimit`, chosen by kind in `AppModel.autoDownload`); images have no size rule (they are
  small), so the brief's fallback applies. A larger one is held: the engine
  refuses it before reading the body (`downloadAttachment(messageID:upTo:)`,
  `Failure.largeAttachment(size:)`, the size from `Content-Length` or the
  row's known size) and the tile offers Load.
- The poster frame is a second in (a third of the way into a shorter
  video), not two: short clips have one.
- Nothing plays by itself, not even in the viewer (the Mac app autoplays
  there). One player at a time (`MediaPlayback`), for video and audio
  alike; it pauses when its row leaves the screen (another chat, scrolled
  away, locked) unless the viewer shows it, and the viewer pauses it when
  it closes.
- Decrypted media stays in the cache and is read in place: cached files
  have no extension, so `MediaInfo.asset` names the container's MIME type
  from its first bytes (`AVURLAssetOverrideMIMETypeKey`) rather than
  copying the file somewhere with one.
- A file the server gave no name takes the Mac app's own when its bytes
  are what it says: the engine names it "video.mov" (`AttachmentKind.
  fallbackName`), "audio.m4a" from the declared type.
- No Copy for a video in the viewer: it would put the decrypted cache file
  on the clipboard, outside the quarantine every saved file gets.
  Download (into Downloads, quarantined, then Show in Finder) and Save as…
  are there instead; the message menu keeps Save as….
- A small mark (quotes, the viewer's strip) shows a camera or a waveform
  for video and audio by what the bytes turned out to be
  (`AppModel.attachmentKind(of:)`, which `AttachmentView` also switches
  on), and a file badge falls back to the declared type's extension
  (`AttachmentKind.fileExtension`: "MOV" for `video/mov`).

### Built

- `PeelCore`: `MediaInfo` in `Media.swift` (`asset`; `load`, one asset
  read once for the duration, the turned picture size and the poster;
  `format(duration:)`); `AttachmentKind.container`, one signature reader for
  the byte check and AVFoundation's MIME type; `fileExtension` and
  `fallbackName`; `MemesServer.Failure.tooLarge` carries the size the server
  named; `downloadAttachment(upTo:)` (the cache first, whatever the size).
- `PeelApp`: `MediaViews.swift` (`VideoTile`, `AudioCard` with its
  `AudioScrubber` the only part redrawn as it plays, `PlayerSurface`,
  `MediaPlayback`, `MediaInfoCache` (one read per file, shared by rows),
  `MediaStatus` and the `MediaLoading` modifier both views use);
  `AttachmentHandle.State.held`; `autoDownload`, `play` and
  `attachmentKind(of:)` on the model; `AttachmentFormat.fitted`,
  `attachmentTile()` and `attachmentCard()` shared with images and file
  cards; `SavedNote`; the viewer plays a video with AVKit's floating
  controls.

### Verified

- Unit tests (`MediaInfoTests`): a generated two-second H.264 movie and a
  WAV, written without an extension as the cache names them: kind, MIME
  type, duration, picture size and a poster within the size asked; a shell
  script is not playable; containers named from their first bytes; clock
  formatting; kinds and fallback names; the size gate refusing a 30 MB
  video by its known size and serving it from the cache once there.
- Local stack (the running broker, a throwaway memes stub on
  127.0.0.1:8857, profiles `va-alice` "Gonza" and `va-bob`): Gonza's CLI
  sent a 4 s clip (`video/mov`, `video.mov`, as the Mac app), a 38 MB
  video, a WAV and an M4A with a caption. The bundled app on `va-bob`,
  launched in the background, drew the poster with play and 0:04, the
  large one as "Video · 38.3 MB" with Load, and both audio cards at
  "0:00 / 0:07". Nothing was clicked or played (no accessibility access;
  Tom may be on a call), so playing inline, the viewer, Load and Download
  are checked by code only.

### Open

- Click through: play inline, scrub, mute, another video pausing the
  first, scroll away, change chat, double-click and the corner button into
  the viewer, Space and Escape there, Load on the large one, Download and
  Show in Finder.

## The list's end after late height changes (branch `fix/open-bottom-gap`, 2026-10-08)

From Tom's real account: opening #Universe: AI, whose newest message is a
call card, left the list not flush with its last row.

Done means: the list ends flush with its last row above the composer (the
12 pt padding aside) after any late height change, while #41's rules hold:
a reader who scrolled up, jumped to a quote or opened at "New messages" is
never moved.

What was found, on the local stack (tribes of 45 and 200 rows, a presence
stub answering an empty `current_participants` 1.5 s after subscribe,
the scroll geometry logged from a debug build):

- Every recent call card grew 20 pt after the list had reached its end:
  `.unknown` drew no status line, then "No one on the call" arrived
  (56 to 76 pt, logged on every open).
- `.defaultScrollAnchor(.bottom, for: .sizeChanges)` held only a list
  exactly at its end, and not one opened with `scrollTo(divider)`, which
  anchors on the divider instead. Opened at "New messages" a few rows from
  the end, the end stayed 20 pt short per card (40 pt with two cards, the
  last message hidden) and the jump pill said "2 new messages" with
  nothing more to see. At the end without a divider it went short in 1 of
  3 launches.
- The lazy stack's estimated height swings on open (24 024 to 12 084 pt
  for 200 rows), and a scroll asked for inside a geometry callback was
  sometimes lost.
- Not reproduced: a blank gap *past* the end. A simulated 164 pt shrink
  at the end was clamped every time; the geometry once reported a list
  197 pt past its end that was drawn flush. Tom's 150–200 pt gap may come
  from rows the local stack has no copy of (images, videos, real presence
  sequences).

Changed:

- `CallCard` keeps the status line's room (24 pt, `lineHeight`, shared
  with `line` and `who`) while a recent call's presence is unknown, so it
  no longer grows when the call server answers. Rows should reserve their
  final size, as images do with their aspect ratio; the list's re-pin is
  the backstop for those that cannot.
- `MessageList`: when the content's height changes under a list that was
  at its bottom and is `following`, with no scroll in progress, it goes
  back to the end marker after the layout pass (`repin`, one per burst).
  `scrollToNewest` repins when its animation completes. The height rides
  on `BottomDistance`; the rest of its action still runs only when the
  position crosses its lines.

Before and after on the local stack: before, the newest call card cut off
under the composer with a "2 new messages" pill; after, flush with no pill;
a plain last message flush in both.

Reviews. `/code-review high`, applied: the re-pin requires `following` (a
list opened at "New messages" or jumped to a quote stays put); one geometry
callback, so the jump pill no longer flickers on a re-pin; the deferred
scroll re-checks `following` and hand scrolling and is coalesced; no
re-pin after a keyboard page scroll (only after Peel's own animation);
the 24 pt shared; rebased on main (video players, run spacing). Not
applied: a card whose presence never comes keeps an empty 24 pt line until
the call is 12 hours old (the feed reconnects with backoff, so it is "no
word yet"); a height change during a hand scroll's deceleration is not
retried. `/simplify`: the animation completion calls `repin` (one path),
comment names what does not reserve its size; not applied: dropping
`atEnd` and the `repinning` flag (both keep work off ordinary frames), a
`toEnd` helper (would touch #41's lines). `/security-review`: no findings.

Pre-existing, not changed: opening at "New messages" far up a list whose
rows are only estimated lands at the end, not at the divider (40 unread of
42 rows, before and after).

## The blank space under the last row (branch `fix/bottom-gap-2`, 2026-10-08)

From Tom's real account, after #68: #Universe: AI, whose newest message is
a call card, still showed about 80 pt of empty space between that card and
the composer. It stayed through scrolling and through the jump button, so
it was content at the end of the list, not an over-scroll.

Done means: a message with nothing to show takes no room in the list.

What was found: `ChatRow.rows` made a `.message` row for every text or call
message, and `MessageRow` drew nothing for one with no words while keeping
its padding and the hidden hover time in its gutter. Reproduced on a copy
of `gap-alice` with three empty type-32 messages after the call card: rows
of 22, 22 and 24 pt at the list's end, the same picture as Tom's
screenshot. Which messages make Tom's gap is not known yet; the debug
build's log (row kinds, types and heights only) will say.

Changed: `Message.isBlank` (PeelCore, tested): a text or call message whose
shown text is nothing but spaces or invisible (format) characters, not
deleted, and not our own pending or failed send (that row offers Retry and
Discard). `ChatRow.rows` leaves those out unless the row would still show
something: a collapsed thread (its newest message places the thread's
row), a quote, or boosts. "New messages" goes to the next message that
counts.

Before and after on the local stack (the copy above): before, about 80 pt
of blank list under the call card; after, flush with the composer, also
after going to another chat and back, and "New messages" still opens at
the same row.

Reviews. `/code-review high`, applied: our unsent blank keeps its row
(Retry, Discard); a blank reply or boosted blank keeps its row (the quote
or chip shows); zero-width and other format characters count as blank.
`/simplify`: comment ties the unsent rule to `isDiscardable`; kept the
skip in `ChatRow.rows` rather than Storage's timeline SQL (it needs the
threads, boosts and parents that meet only there). Follow-ups, not done:

- Blanks still count as unread (`countsAsUnreadSQL`): a badge with nothing
  new to see. A stored column from `Message.isBlank` would fix this, the
  thread's "N replies" count and the sidebar preview at once.
- A quote of a blank parent goes nowhere.
- An image, a blank and an image within a minute now share one grid.

## The gap under the newest row: a thread row twice (branch `fix/overscroll-gap`, 2026-10-08)

From Tom's real account after #72: #Universe: AI showed 72 to 84 pt of
empty space under the newest message, through scrolling, the jump button
and chat switches. The debug build's probe of where the last row ends put
it in the pixels (`drawnGap=84`). Only that chat, and its ROWS line said
`dupes=1`: one row id twice in the list.

Done means: one row per id by construction, and the list ends on its
newest row in every chat; #41's and #68's rules unchanged.

Cause: a call (type 32, in either form: `call::{…}` or the Mac app's bare
link) posted inside a tribe thread of two or more. `tribeTimelineSQL` hides
only a collapsed thread's text and attachments (`MessageType.content`), so
the call stays in the timeline next to the thread's newest message.
`ChatRow.rows` then took both for the thread and named both `t<thread>`.
A `LazyVStack` keeps room for both and draws one: a blank the size of a row
under the newest message. Universe: AI has two calls and a thread among
its newest messages; no other chat of Tom's has a call in a thread.

Reproduced on a copy of `gap-alice` shaped like Tom's newest 15 (bare-link
calls, a collapsed thread, boosts as replies) with the older call put in
the thread: `dupes=1`, the id kind `t`, and 62 pt of blank under the newest
message in the window capture, on every open after a switch, with the call
presence stub answering. Same with the `call::` form.

Changed:

- `Message.standsForThread` (PeelCore): a message stands for its collapsed
  thread only when it is text or an attachment in one, as the timeline
  counts thread messages. `ChatRow.rows` collapses only those; a call in a
  thread keeps its own row (`m<id>`), where the timeline already put it.
- `ChatRow.rows` drops a repeated id as a backstop, keeping the newest row,
  so a cause not found yet costs a row, not a gap.
- `RowIdTests` (written by a parallel investigation, adapted to the new
  rule, with the Mac app's call form added): unique ids over 40 generated
  chats with threads, boosts, calls in every form, deletes and blank
  messages, in a tribe and a direct message; and the call-in-a-thread
  shape. Both fail without the change.
- No runtime assertion: the app bundle is a debug build, and Tom runs it
  every day, so an `assert` on a repeated id would crash his Peel where
  the backstop leaves a row out. The tests carry the assertion.

Before and after, the lazy list kept (four opens after chat switches, call
presence answering), last row's end below the list's end: the duplicate
shape 62 pt blank before, flush after, in both call forms. Tom's shape and
the five mixed seeds: flush after (before, seeds 3, 4 and 7 reported 21, 73
and 25 pt in SwiftUI's geometry while the window capture was flush).
"New messages" far up still opens at the divider; a quote-style jump stays
up, and the jump button lands flush.

On the way (this branch's earlier commits, both replaced): steering the
scroll offset back to the end opened the chat blank on Tom's account, and
laying every row out in a plain `VStack` hid the gap at about 4.5 times
the open time (470 ms against 100 ms for 200 rows). Neither is needed now:
the list stays lazy. Tried and dropped as well: no `.sizeChanges` anchor,
and a plain tail after the lazy stack.

Reviews (inline). Simplify: the rule lives in PeelCore next to `isSaid`, and
the test's row-id mirror uses it; the backstop is three lines. Security:
row building only, no input parsing, storage, network or logging change.

`swift test`: 419 tests, all pass but the known IPv6 issue.

## Chat column fixes, cleanup batch 4 (branch `fix/batch4-chat-column`, 2026-10-08)

From the second review (`docs/reviews/2026-10-08-second-review.md`, row 4).
Each finding was checked on main first, on copies of `og-div2` (offline,
#Universe AI with 47 unread past marker 150) in a scratch build with a
temporary launch hook, not committed, that opened the chat or a thread,
sized the window and sent a file from the thread composer.

- **1.8, "New messages" far up.** Reproduced on main: the chat opened at
  its end with "47 new messages" and no divider in sight. The divider
  branch now waits 100 ms, as the focus branch does, so the initial bottom
  anchor cannot undo it, then scrolls again once the rows around it have
  real heights, unless you have scrolled or it reached the bottom. After:
  opens with "New messages" at the top.
- **1.7, thread notices.** Reproduced: with the thread in the chat's
  place, a refused file ("no memes server") showed nowhere. `ChatFooter`
  (notice, then the composer or `TribeStatusBar`) now ends both the chat
  and the thread; the thread shows the chat's notice only when it has
  taken the chat's place, so it never shows twice.
- **1.13, the end marker.** Not reproduced since #84: a chat without a
  divider ends flush on its last row. Left as it is.
- **1.1, quotes.** A blank parent is not quoted (its row is never drawn),
  and a blank reply whose quote would only say "Original message not
  available" gets no row.
- **Jumps (1.12).** A quote whose parent is folded in a collapsed thread
  opens the thread at it, lit (`focus(on:inThread:)`), rather than at the
  thread's bottom. Jumping to a payment request scrolls to it and lights it.
- **Shapes (1.12).** The day pill, the round jump button
  (`menuBoxed(style:)`) and the composer box use circular corners: their
  radius is half their height or more, where the continuous stroke draws
  square stubs.
- **5.3.** `SidePanelSplit` is the one split for the thread and the web
  pane (the panel takes the column's place when both do not fit).

Not changed: opening a thread beside a chat that opened at "New messages"
reflows the narrower column around its bottom anchor, so the divider can
move out of view (as on main, where the chat was at its end anyway). No
tests: the changed rules live in `PeelApp`, which has no test target.

## The blank timeline when the list's height changes (branch `fix/blank-timeline`, 2026-10-09)

From Tom on his everyday build: typing, then Shift-Return a few times, and
every message above disappeared; the list was empty and dark above a six
line composer. Also from Tom on main: opening ⌘F's search bar in a tribe
blanked the screen.

Done means: the list keeps drawing its rows while its own height changes
(the composer growing or shrinking, the search bar and its results opening
and closing), and still opens and stays flush with its newest row.

Reproduced on a fresh offline dev profile (80 text messages in one direct
message), in the bundled app driven by a temporary in-process hook, not
committed: the window kept off every screen and the app never active, text
and Shift-Return put in through the composer's text view, the search
opened and closed through the model, renders taken of the app's own
window, and the rows on screen counted from their `onAppear` and
`onDisappear`. On main every run blanked: growing the composer line by line
from the bottom left no row on screen within 4 cycles in 6 of 6 runs, and
opening the search bar blanked it in 19 of 20 cycles over 5 runs. Also
on 108f886, before the 2026-10-09 merges: not a regression of #117 to #126.
The anchor has been there since the chat UI (#13).

Cause: `.defaultScrollAnchor(.bottom, for: .sizeChanges)`. Each change of
the list's own height re-estimated the lazy stack (5 369 pt measured, 6 088
estimated, for 80 rows), and the anchor moved the offset to the end of
that estimate. Usually the rows were measured again and it came back;
sometimes the content height settled between the two (5 863 pt) with the
offset at 5 409 for a 454 pt list: the visible rect lay past the last
drawn row, every row had left (`onDisappear`), and the geometry said the
list was at its end. A scroll to the end marker could not move it (it was
there), which is why a re-pin with the anchor kept failed in every run.
Send brought the rows back in the one run tried (the composer shrank back
to one line); a wheel event handed to the list in-process did not.

Changed, in `MessageList`:

- No bottom anchor for size changes (`.alignment` and `.initialOffset` stay,
  and the lazy stack stays).
- The re-pin (#68) also runs when the list's own height changes at the
  bottom (`BottomDistance.container`), and again while a re-pin's scroll
  fell short (`pinning`, until the list reports its end): without the
  anchor, a scroll to the end marker through rows still estimated stopped
  about 60 pt short on opening, in every run. `pinning` starts only when
  the list was not already at its end (`atEnd`, the last report, kept for
  the re-pin and not read by `body`), and a hand scroll clears it.
  `BottomDistance.atEnd` also counts a list shorter than its space.
- Reaching the bottom hides the round jump button: a re-pin returns before
  the button's bookkeeping, and on opening it skipped the crossing back from
  far, leaving the button up at the bottom (6 of 8 runs before this line).
  Comparing against the button as shown instead also worked, but its
  animation carried the re-pin's scroll and the list opened 60 pt short.

Before and after, same hook and profile: growing the composer, 0 runs of 8
with a blank (4 cycles each); the search bar, 0 of 3 (4 cycles each of
open, no matches, matches, closed); every open flush with the end (0 pt,
as on main); the jump button down at the end of every run, never up while
the composer grew, and up for about 20 ms during the open in 4 of 8 runs.
Not checked: a real trackpad scroll out of the blank state (a wheel event
handed to the scroll view in-process did not scroll it), a reader scrolled
up while the composer grows (no hand scroll in the hook), a tribe with link
cards, videos and calls, and the thread panel's composer.

Behaviour that changes with the anchor gone: a reader scrolled up keeps
the rows at the top of the list in place when the composer grows (the
bottom ones go under it) where the anchor kept the bottom ones; and a
window resized at the bottom is brought back to the end by the re-pin, a
pass later, rather than held there.

Reviews (inline). Code review: a short list is at its end, so it neither
re-pins nor starts `pinning`; a re-pin that lands in the same place reports
nothing and stops; at the bottom the list is never far, so hiding the
button there cannot hide one that should show.

Independent review (before merge), applied: a re-pin with nothing to move
(at the end on opening, or after a send's scroll) left `pinning` set, since
no report came to clear it, and the next scroll with no phase away from the
bottom (a key, likely a plain wheel) snapped back to the end; and `pinning`
cleared 24 pt short of the end (`atBottom`). Now it starts only when not at
the end, clears at the end, and clears when you take the list by hand.
Rechecked with the same hook (window off every screen from its first
frame): composer 0 blanks in 4 runs, search 0 in 60 checks over 3 runs,
every open flush, and a scroll with no phase a screen up after opening
stayed put in 3 of 3 runs (offset 5 176 to 4 676, unchanged 2 s later). Simplify: the change stays in `MessageList`'s existing re-pin
rather than a second mechanism; dropped on the way, a scroll-phase re-pin
that did not help. Security: layout state only, no input, storage, network
or logging.

No unit test: the rule lives in `PeelApp`, which has no test target.

## Blank on opening at "New messages" (branch `fix/blank-timeline-on-open`, 2026-10-12)

From Tom on his build of main (2071689, and 002d77d before it): opening
"Sphinx & Stak", then "hive", showed the header and composer over an empty
list, no rows and no day divider, until one scroll brought every row back.
Both had one or two unread messages at the end (the newest arrived
overnight); sending in Hive cleared it, which also drops "New messages".

Done means: a chat opening at "New messages" never sits past its drawn
rows, near the end or far up, and the plain open and a far-up divider
behave as before. Plus an opt-in log Tom can turn on in his real app
(`TimelineLog`, `docs/testing.md`, "Timeline log").

Found with the new log on a local stack (dev profiles `tlog-alice-1012`
and `tlog-bob-1012`, a tribe of 95 to 120 rows with text, wrapped text,
lists, code, link cards and images; opened from another chat six times
per run in `check-app.sh`, the offscreen app never marks a chat read):

- Opening with "New messages" set `following = false` and waited 100 ms
  before its scroll to the divider, so it skipped the bottom scroll the
  plain open makes. In those 100 ms the initial anchor kept the offset at
  the lazy stack's estimated end while its estimate swung (5 154, 2 616,
  then 13 872 pt for 95 rows measured at about 9 500): the rows in view
  dropped to none (`visible NONE with rows`) on 6 of 6 opens with two
  unread at the end, and on 1 of 2 with 31 unread. Offscreen the scroll
  view clamped each time and the rows came back; a divider a row or two
  from the end then asks for an offset past the end, and with `following`
  false no re-pin runs, so a list left past its rows stays there. That is
  the state Tom saw; it was not seen to persist offscreen.
- The plain open (no divider) scrolls to the end marker in `onAppear` and
  showed no blank in 6 of 6.

Changed: `MessageList.onAppear` scrolls the chat's list to its end first
on every open, then (100 ms later, as before) to "New messages" or a
message asked for. After: two unread at the end, 1 transient blank in 6
opens (mid-way through the divider pass, recovered within the pass), every
open ending flush on the newest with the divider in view; 25 unread, 0 of
6, every open with "New messages" at the top as before; plain opens
unchanged.

Not changed: a list reported past its end (`below < 0`) counts as at its
end (`atEnd`, since #134); a scroll back to the end there is left until the
log shows it in Tom's app, since steering the offset back to the end once
opened chats blank (#84's branch).

Reviews. Independent review (agent, foreground), applied: the bottom
scroll is skipped when opening at a message asked for, since reaching the
bottom there would reset a timeline grown to reach an older message
(`chatListAtBottom`) before the jump; one `ChatRow.holds(_:)` for the row a
jump goes to, shared by `go(to:)` and the log; the chat tag is keyed afresh
at each launch (HMAC), so a pasted log cannot be matched to a tribe's key;
the log's different configuration with it on is noted in `docs/testing.md`;
`realised` (rows the lazy stack has made) added, so the log tells a drawing
problem from a placement one. Not applied: leaving `following` true until
the first divider pass, so re-pins would hold the end for those 100 ms; it
changes the jump button's count rules and is left until the log shows it
is needed. Security: nothing sent, one `UserDefaults` bool read, the log
at debug level with counts, indices, phases and points only.

Confidence: moderate. It removes the only state the log caught that
matches Tom's, but the blank never persisted offscreen. If it comes back,
the log on his account says which placement left it there.

## Blank on opening with nothing made (branch `fix/blank-timeline-unrealised`, 2026-10-12)

From Tom on his build of main (e28e764, with #196): "Sphinx & Stak" still
opened blank, now with the timeline log on. The log for that chat (200
messages, 199 rows, no divider, no focus): `place: appear scrollTo
bottom`, then the estimated content shrank in steps (65 097, 37 629,
26 647, 22 986 pt) and each time the offset was clamped back to the end;
`atEnd`, `following` true, no re-pin (the list was always at its end),
`realised=0` and no "visible rows" report for 5 s, until his first scroll,
when rows 198 and 195 to 198 appeared at once. Chats that drew showed the
same shrinking with rows reported within 20 ms, two of them after a
`repin: resized`. So the placement was right and the lazy stack made no
row there: an offset reached only by clamping, and a scroll to the end
marker (an overlay outside the lazy rows) that moved nothing, are not
drawn for. Also from his log (94acf4): every step of the composer growing
re-estimated the content about 7 500 pt taller and back within a frame,
the likely Shift-Return blank (#134) when that lands at the end.

Done means: a chat that opens at its end has rows made there without a
scroll by hand, and a list at its end with no row made after any height
change goes to its last row; thread lists, "New messages", jump to a
message, the composer and search bar resizes behave as before.

Changed, in `MessageList`:

- Rows made are tracked always (`ListTracking.made`, the ids of rows
  appeared and not gone, in a reference so writing it redraws nothing);
  the log's `realised` reads it. The log-only counter in `TimelineLog` is
  gone.
- The re-pin runs once no further request has come for 20 ms (at most
  100 ms late while they keep coming) rather than on the next turn, so it
  does not act on a transient estimate; so it is up to 20 ms later than
  before after each line the composer grows. With no row made, or on
  opening, it scrolls to the last row (anchor bottom) first, then 20 ms
  later to the end marker below its padding, unless a request came in
  between (which goes instead). Not otherwise: the last row stops 12 pt
  short of the end, and doing it on every composer line moved the rows
  12 pt for a frame each time. With none made after three such scrolls
  it stops trying until a row is made or you scroll.
- Opening a chat at its end asks for that re-pin by the last row after
  the scroll to the marker.
- A height change at the end while following, idle, with rows and none
  made, re-pins. Not in a thread's list, which reads from its top, nor
  while opening at a message asked for.

Offscreen (`check-app.sh`, dev profiles `bfx-owner` and `bfx-app` on a
local stack, a tribe of 200 rows: short and long texts with lists and
code, five sizes of image, tribe link cards, collapsed threads, boosts):
the estimate starts too tall (16 224 pt for about 9 000) and shrinks with
the offset clamped, as in Tom's log, but before the change rows were made
within milliseconds on all 7 opens: the blank did not reproduce. The
composer growing by Shift-Return (no text, nothing sent) showed the same
transient as Tom's 94acf4 (8 995 to 19 780 and back at each line), with
rows made throughout, before and after. After: 7 of 7 opens end at the
end with rows in view, the last-row scroll once per open, none during
the composer's growth, every step of which ends flush (below 0). Idle on
the chat for a minute: 0.0% with the log off; with it on, 0.0 to 0.4%
after one 13% sample 25 s in.

The log on adds `.scrollTargetLayout` and the visibility probe; Tom's
first reports were with it off, so the blank does not depend on it, and
the fix reads only the always-on count.

Independent review (agent, foreground), applied: the count kept as a set
of ids, so a doubled appear or disappear cannot switch the fix off; the
last-row scroll capped (a stack that never makes a row would otherwise be
scrolled every 40 ms); the wait capped at 100 ms; the second stage gives
way to a later request or a new last row; the blank re-pin not while
opening at a message asked for; the request counter moved out of
`@State`. A first version of the second-stage check compared against the
task's own request and left six of seven opens 12 pt short; it compares
against the latest request when the task ran. Not applied: dropping the
last-row scroll on opening (`made` empty covers a blank); kept so the
opening is placed by a row, as asked.

Confidence: moderate. It acts on the exact state Tom's log shows
(at the end, nothing made), but that state never persisted offscreen;
Tom's build with the log on says whether the last-row scroll draws it.

## Blank past the rows the stack placed (branch `fix/blank-timeline-past-rows`, 2026-10-14)

From Tom on main with #196: Evan's chat (134 rows, an image eight rows
from the end) opened blank until a large scroll; a small one left it blank.
Later Sphinx & Stak (199 rows) did the same. Not reproduced offscreen: a
seeded chat of Evan's shape (lengths, newlines, links, the image, filler
text, two dev profiles on a local stack) measures half his height (5 619
pt against 12 169: his rows span days, so headers and day dividers), and
its estimate never ran far enough. Found instead with the timeline log on
his build, after adding where each row laid out sits in the content.

What the logs show, Evan (20:50:31): opened at the end, the estimate swung
11 146, 6 249, 9 437, 10 499 pt; rows 125...133 laid out at 9 782...10 501
and in view; then the stack, having measured them taller than its
estimate, put its height at 12 624, keeping the rows where they were: 2 110
pt of height below the last row with no row in it. A re-pin to the end
marker went to 11 895, in that space (`visible NONE`); the estimate fell to
11 741, the offset clamped to 11 012, still 500 pt below the rows; the
#196 scroll to the last row landed at 10 999, the last row's estimated
place, not its real one (10 501). Nothing laid out in view, nothing
measured, so the estimate stayed: blank until a scroll by hand reached the
rows (about 500 pt up), when the stack measured them and its height fell
to 10 552. Sphinx & Stak: 25 098, 14 388, 43 515, 33 869 pt in 100 ms,
rows 183...188 in view, then the end (33 140): blank. In three of the
four logged blanks the jump to the end was a re-pin of the empty list
shown while the chat's messages load (`ConversationView` makes the list
again once they have), run after that list had been replaced
(`place: repin scrollTo bottom | rows=0`); in the fourth no re-pin of ours
logged one, so SwiftUI also moves the list there. So the stack's estimate
can run past its rows at the end of any chat, by more when the newest rows
measure far from its average, and any scroll by that estimate (the marker,
a row not laid out) can land past them.

Done means: a list following its end is never left past its rows; a re-pin
moves by where rows are laid out, never by the estimate when there are
any; the empty list's re-pins never move its replacement.

Changed, in `MessageList`:

- Each row reports where it is laid out in the content (one
  `onGeometryChange` per row, called on a layout, not while scrolling):
  `frames` while laid out, `placed` kept after.
- The re-pin, with rows laid out: if the newest row ends in view, nothing
  (past it is only estimate); if it is laid out, its bottom to the list's
  bottom; if not, half a list past the newest row laid out, where the
  stack lays out the rows after it, then again (at most 12 steps). By a
  `ScrollPosition` to a point; with none laid out (opening), as before.
- Rows laid out, none in view, while following and still: a re-pin.
- An empty list asks for no re-pin, and a list gone drops its re-pins and
  its opening scrolls (`ListTracking.gone`).
- The log: `laid out a...b at y...y` on geometry and visible lines, `last
  row at`, the new placements (`docs/testing.md`, "Timeline log").

Tried and dropped: every row of the newest 50 to 74 made always (a plain
stack under the lazy one), so the end is never estimated. No blank, but
550 ms to open a chat against 45 (debug build, same load, 10 opens each).

Tom's build, after: Sphinx & Stak still went past its rows once
(12:55:40.198, the jump with no re-pin of ours), then stepped down from row
188, 193, 197 and to the newest row's bottom, flush by .397 (about 40 ms
blank). Evan and Sphinx & Stak no longer stay blank for him. Offscreen (the
seeded chat, 10 opens per run): no blank, every open flush; first layout
47 and 50 ms against main's 40 and 45 at the same load; a message and an
image arriving at the bottom stay flush; opening at "New messages" blanks
for 20 to 130 ms on main and here alike, and recovers.

Independent review (agent), applied: the walk reads the rows as they are
now (`ListTracking.ids`), not those its task was asked with; every step,
the last too, asks again until the newest row ends in view, and a place
kept from an earlier layout is only stepped from; the steps start again on
a new newest row and after the jump to the end; the blank check only while
still (an animated scroll to the newest crosses that space) and not in a
thread. Checked after: 10 opens with the log off (snapshots: all at the
newest row; the log on adds scroll targets, which the new `ScrollPosition`
could follow), 10 with it on (flush, no blank). Not applied: the jump
button can show while the estimate is still past the newest row in view,
until the stack measures again.

Not done or not checked: an image loading at the bottom after it arrived
(images do not download in the check app); the agent chat
(`AgentMessageList`) is lazy and scrolls to its end marker the same way and
Tom has seen it blank; not logged, so next, on its own branch.

Confidence: the cause, high (measured on Tom's account); the fix, that the
re-pin no longer lands past the rows and steps back when something else
puts it there, shown once on his account and never failing offscreen,
where the blank did not reproduce.

## Hover cards and menus at their trigger (branch `fix/hover-card-anchor`, 2026-10-10)

Tom's report: in a tribe, after tapping and hovering several boost chips,
the boosts panel for Paul's message at the bottom of the timeline showed
up near the top, beside an earlier message of Evan's. The content was
right; the position was wrong.

Done means: every menu, panel and hover card opened from a `.menuAnchor`
(boost chips, a message's More, person cards, link cards' Join and Add,
the header's ••• and its panels, the sidebar header, the call menus)
opens beside its trigger wherever the list has scrolled and moves with
the trigger while the list moves. Menus and cards close when their
trigger leaves view; panels stay, pinned at the list's edge, and go only
with their row. Right-click menus are unchanged (a point).

What was found, on a new local dev profile with a seeded 90-message tribe
and nine boosted messages (windows kept off every screen, in-process
events only, snapshots drawn from Peel's own windows):

- The frame `onGeometryChange` kept was never stale in what could be
  driven: recorded and real frames (an AppKit probe behind each anchor)
  matched for every visible anchor (29 to 33) after opening at the end,
  at "New messages", after clip-view scrolls up and down, and when moving
  straight between chips with panels of the same and different heights.
  A trackpad scroll could not be driven: a wheel event handed to the
  scroll view in-process does not scroll it.
- A card or panel was placed once and never moved: with a person card
  open, the list moved 60 pt and the card stayed, 56 pt away from its
  name. Anything that moves the list under an open panel (a scroll, a
  re-pin, a new message while following, a composer resize) leaves it
  beside where the trigger was, which is what Tom saw.
- A hover card took the trigger's frame when the pointer arrived and
  showed 150 to 500 ms later there, wherever the trigger had gone since.

Built: `MenuAnchor` holds the AppKit view `.menuAnchor` puts behind its
view (no hits, draws nothing) and reads its frame on the screen when
asked, so a menu, panel or card is placed from where the trigger is when
it opens, not from a frame kept from an earlier layout. The presenter
takes the anchor (`show(_:at:)`, `showPanel`, `hoverCard`); menus open in
the anchor's own window (the host window before, which would misplace one
opened from inside a panel; none is today). `FloatingWindow` takes screen
rects only (the right-click catcher reports its click on the screen too)
and follows the anchor: it watches the clip view of the trigger's scroll
view (bounds for scrolling, frame for the list's height) and its
document's frame (a row above growing, rows measured again), and moves
with the trigger. Once the trigger is out of sight a menu is dismissed and
a card hidden; a panel stays at the list's edge, and goes only with its
row (`PopoverModifier`'s `onDisappear`). The observers go when the window
closes, hides or is freed. A hover card checks the trigger is still
visible when its delay ends. A message's hover bar stays while that row's
menu is open, since its More is what the menu follows.

Checked after, same profile and drive: the chip on message 88, then
Paul's chip straight after (panel above it, no room below), and back;
panel open while the list moved 40 pt (followed, still above the chip);
200 more until the chip left (panel closed); the top chip after scrolling
up, then the list moved down 100 (followed, 4 pt below the chip); a person
card while the list moved 60 (followed, 4 pt below); a card whose list
moved during its delay (shown at the name's new place); the header's •••
Details panel and the sidebar's connection card (beside their buttons, as
before). Not driven: a real trackpad scroll, the thread pane, link cards
and the composer growing under an open panel.

Independent review (before merge), applied: the message More menu closed
as soon as the list moved (the hover bar went while any menu was open,
taking the More button's anchor view with it); panels closed when their
trigger left view; content moving without the clip view (a row above
growing) was not watched; anchors went through SwiftUI's global
coordinates and back; the observers could outlive their window.
Rechecked hidden with `scripts/check-app.sh` (the hover bar shown by a
temporary hook in place of the pointer, cleared once the menu was open):
- More on message 86 stayed beside its button after the list moved 4 pt
  and 40 more, and closed when the row left the list (500 more).
- A person card closed when its name left the list.
- A boost panel followed its chip 200, 400 and 500 pt up to under the
  header. In this list the lazy stack tears a row down as soon as it
  leaves the visible area (its anchor view leaves the window in the same
  pass), so the panel went with the row, as on main, at 150 pt below and
  520 pt above; the pinned edge did not show in any run. A form with typed
  text in a row that leaves view still closes with it, as before.
- No document frame change came while a panel was open in these runs;
  every move was the clip view's.

Reviews (inline). Code review: a trigger that moved before the new
content reported its size placed the window at the old size (`size` now
reset on present); a right-click menu now opens on that row with its
hover bar showing (both menus share the row's source). Simplify: one
coordinate space, the screen, for anchors, clicks and floating windows.
Security: layout only, no input, storage, network or logging.

No unit test: the rule lives in `PeelApp`, which has no test target.

### The "1 new message" pill staying at the bottom (2026-10-11)

Tom: a notification for #hive, opened the chat, the new message was the
last row and fully in view, and the blue "1 new message" pill stayed.

What drives the pill: `MessageList`'s `seenUpTo`, set when the list leaves
the bottom (more than 24 pt from its end), and the count of unread messages
after it. Only a crossing back into the bottom, seen as `old` not at the
bottom and `new` at it, cleared it. Two ways that crossing never shows:
- The re-pin's early return skips the crossing code. The line that put
  `farFromBottom` back was added for this same skip, but it left `seenUpTo`
  alone.
- Reports are coalesced. In the offscreen runs, an action's `old` was not
  always the previous action's `new` (for example `old` 1476 pt after a
  report of 1505 pt). A return to the bottom can then arrive with `old`
  already at the bottom.
In both cases the list sits at the bottom with a stale `seenUpTo`, and the
pill counts every later incoming message, visible ones included, until you
scroll away and back.

Fix: at the bottom, `seenUpTo` is cleared on every report, before the
re-pin's early return, not only on a crossing. `following`, the
`chatListAtBottom` reset and the read-on-reach stay on the crossing, as
before. The scroll anchors (#134), "New messages" and opening at it are
unchanged.

Proven vs inferred:
- Proven by `scripts/check-app.sh` logs: reports are coalesced; after
  opening at "New messages" or at a notification's message, the list sits
  at its bottom with `following` false. In one Next Unread run the pill
  counted the new message while it was on screen ("1 new message", list
  more than 24 pt from its end), and openAtDivider's second pass happened to take
  it back.
- Not reproduced: the pill staying. Offscreen, animated scrolls do not
  finish (the phase stays `.animating`), and the local stack's tribes server
  kept losing messages to the CLTV error, so the full sequence could not be
  driven.
- Inferred and not fixed: after opening at "New messages" or at a focused
  message that is already at the bottom, `following` stays false. A row
  that grows later (a link card, an image) or a new message can leave the
  list short of its end with `dividerUnread` set, and the pill counts rows
  in view. A first attempt set `following` once `openAtDivider` ended at the
  end. It was dropped after review: a large backlog arriving would then
  scroll past the unread rows, and the check depended on timing.

Checked offscreen with `scripts/check-app.sh` on new development profiles
funded by the stack's Bank: a notification click, a sidebar select and
Next Unread (⌥⇧↓) into a chat with one new message, with Lounge open
first. None showed a stuck pill before or after the fix. Idle on the chat
for a minute: 0.0–0.2% CPU.

Driving it: a `{"notification": "<chat>"}` drive step clicks the
notification for the chat's newest message from someone else. Offscreen
mode now refuses `NSApplication.activate` for every caller, so nothing
brings the check app to the front.

Reviews (inline). Code review: the `following` change was dropped (above).
The activate guard moved from `openFromNotification` into `Offscreen.start`.
The drive steps share the chat lookup. The step is documented in AGENTS.md.
Simplify: the crossing's own `seenUpTo = nil` was redundant and is removed.
Security: no new input, storage, network or logging. The drive step runs
only in offscreen mode.

No unit test: the rule lives in `PeelApp`, which has no test target.
Extracting the scroll bookkeeping into PeelCore to test one line would
move the high-risk state machine for no proof of the view's ordering.

### Arrivals that move the list off its bottom (follow-up, 2026-10-11)

From the independent review of the change above. After opening from a
notification or a search, the list sits at its bottom with `following`
false. If "New messages" was marked afterwards (`dividerUnread`), an
arrival that pushed the list off the bottom made the pill count every
unread row since the divider, including rows that were on screen. If it
was not marked, the arrival itself went uncounted.

The bookkeeping now lives in `ListBottom` (PeelCore, tested):
- At the bottom, once the list is still after opening and not scrolling,
  everything down to the newest message has been in view: `seenAtBottom`.
  It is noted on every such report, when a scroll phase ends (no report
  comes while nothing moves), when the list has opened, and when a jump to
  a message ends.
- When the list leaves the bottom by itself (not by hand, and not on its
  way back down while following), only what came after `seenAtBottom`
  counts. By hand, or while following, the count is as before.
- Crossings are judged against the last one taken, not against a report's
  `old`, so `following = true`, the timeline-limit reset and read-on-reach
  fire even when reports were coalesced. The re-pin's "was at the bottom"
  test uses the same state.

Not taken from the review's suggestion: clearing `dividerUnread` on an
at-bottom report. Inserting the divider after "Mark unread" changes the
list's height, and the report that follows would have dropped the hold.
It was not needed: a leave by hand already clears it, and a leave by
itself now counts from `seenAtBottom`.

Checked offscreen (`scripts/check-app.sh`) on new development profiles:
- After a notification click, a long message arrived and moved the list
  off its bottom. The pill said "1 new message", counting only the arrival
  and not the unread message above it that was on screen.
- After a sidebar select at "New messages", the same arrival counted 1.
  Main's code would have counted 2 (the divider's row, which was on
  screen, and the arrival). That is read from the code, not observed: in
  the run on main the arrival did not move the list off its bottom.
- Next Unread: no pill. Idle on the chat for a minute: 0.0% CPU.

## Recent calls with a plain loop (2026-10-11, branch `idle/rows-once-per-message`, #138)

Found while measuring idle CPU (`04-money.md`, "Idle CPU"), first written
on 2026-10-09 with a second change: the conversations list rebuilding the
open chat's rows on every newest message. #158 fixed that one on main
(the rebuild now waits for a change of the contact's alias or photo, or
of whether the chat is a tribe), so the rebased branch keeps only this.

The header's recent calls (`refreshRecentCalls`) run on every rebuild of
the rows, and since #158 also when the rows come out the same. They
walked a chain of lazy collections, unspecialized, over every row under
12 hours old; a plain loop that stops at three calls gives the same
calls. Busy tribe on a local stack, about one message a second, debug
build through `scripts/check-app.sh`: `sample` over 25 seconds put 296
main-thread samples in `refreshRecentCalls` before and 35 after; CPU per
arriving message 152, 149, 148 ms before and 130, 143, 129 ms after
(alternating runs, load average near 60). Idle on the tribe for a minute
afterwards: 0.15%, the main thread waiting in `mach_msg`.

## The list's structure: thread close, width changes, coming back (branch `fix/list-structure`, 2026-10-14)

Layer 1 of the message-list review (`docs/reviews/2026-10-14-message-lists.md`),
the Mac half. From Tom: closing a thread jumped the chat, on a narrow
window and a wide one. The review confirmed both in code: on a narrow
window `SidePanelSplit` removed the chat column while the thread was open,
so closing it made a new `MessageList`, which opened afresh (hidden up to
400 ms, then at the newest or at a stale "New messages"); on a wide one the
close was animated, so every row wrapped again at each width on the way
and nothing held the row being read.

Done means: opening or closing a thread, on either width, leaves the chat
where it was (the row you were reading at the same place, or the bottom
flush); a chat come back to opens where you left it; the journeys of PR 1
(`scripts/journeys`) show it.

Changed:

- `SidePanelSplit` always makes the column. On a narrow window the panel
  covers it; the column fades under it and takes no clicks, VoiceOver or
  keys (`.disabled`; the composer reads `coveredByPanel`: the field gives
  up the keyboard and takes it back when shown again, if nothing else has
  it).
  The thread's, the web pane's and the agent memory's splits all go
  through it.
- The panel and its divider slide in an overlay over the column; the
  column changes width once, unanimated (`.transaction(value: isOpen)`):
  narrower once the panel has slid in (no empty strip beside it while it
  slides), wider as it starts to slide out, under it. Narrowing at once
  instead measured 1,203 and 12 pt on thread-scrolled-wide, 0 and 731 pt
  on thread-bottom-wide; after the slide, 48 pt in 4 frames and 71 pt in
  5, both runs. The split owns the slide: `ThreadPanel.opening` and
  `closing` (#273) now only run their closure, and the `withAnimation`
  around the web pane and the memory panel is gone. Closing the thread
  gives the keys back to the chat's composer (they were left on the
  window).
- A width change while scrolled up holds the row you were reading: the
  top row in view when the list last came to rest (`ListEnd.topRow`, never
  "New messages"' row or a replies line) goes back to where it was on
  screen, by its laid-out frame, or by its estimated place first when the
  new width left it unmade (`open(at:)`, at most three moves; a later
  width change, a drag, takes over). A width change no longer counts as
  reaching the bottom when it clamps the offset there. At the bottom the
  re-pin keeps it flush, now also on a width change. **Interim**: a
  timed, bounded retry on the lazy stack's estimates, to be deleted by the
  list controller (PR 4), not built on. The agent chat's list (beside its
  memory panel) has no such hold: PR 5, when it moves to the controller.
- The chat's list is made once, after its messages have loaded
  (`AppModel.loadedChat`, also set when the load fails, so the list shows
  empty under the notice), keyed by the chat: no empty list made and then
  replaced (`.id(messages.isEmpty ? nil : chat)` is gone), so none of its
  late tasks reach its replacement (F1, F14 in the history).
- `ListAnchor` in PeelUI: `.newest` or a row and its offset from the top,
  kept per chat and per thread (`AppModel.keep`, `anchor(of:)`), written
  when the list comes to rest (a scroll's end, opening, a jump, the newest
  reached), not per frame. A list made again opens at a message asked
  for, else "New messages" while it still marks new unread, else where it
  stood, else the newest. A row no longer loaded (it stood in a jump's
  window, since left) opens at the newest. `showNewest` writes `.newest`.
- "New messages" no longer decides where a list opens once the chat's list
  has stood at its newest this visit (`opensAtNewMessages`); it stays drawn
  until you leave or send, so nothing above you moves when it goes.
- Your own newest message takes a list to it, judged by the message (sent
  here, from another device, a payment or a boost alike), except in the
  chat for a reply in the thread open beside it: only the thread's list
  follows that.
- A scroll by hand that ends short of the bottom stops following, even
  when the move off the bottom came before its phase (it then counted as
  by itself, and the next re-pin or own send took the list back down).

Journeys: new ones for Tom's case (a tribe, bouncing between chats, a
thread closed in a tribe) and the thread paths, on a pair seeded with a
tribe (`seed.sh`: 300 tribe messages, 9 threads of 5 to 20 replies, long
messages and images; driver steps `reveal`, `note`, `"visible2"`,
`"from-threads"`, `open: threads`; `run.sh --tribe` and the tribe
signals). All 28 run twice on main (with the journeys) and on this
branch, `ls-me`/`ls-peer`, 2026-10-15. "Blank" there is mostly the list
hidden until placed (`revealLimit`), which this branch keeps.

| Journey | main (run 1; run 2) | this branch (run 1; run 2) |
|---|---|---|
| tribe-thread-close-narrow | 16; 15 blank, list made again, back 4,888 pt from the row | pass; pass |
| tribe-thread-close-wide | 8,226; 8,693 pt over ~600 frames, ends 6,455 pt off | 604 pt in 6; 5 frames, back on the row |
| bounce-tribe | 61; 59 blank, back at the newest | back on the row; 40; 74 blank |
| bounce-dm | 61; 61 blank, back at the newest | back on the row; 46; 51 blank |
| bounce-bank | 62; 60 blank, at the end | 47; 48 blank, at the end |
| bounce-arrival-scrolled | 22; 23 blank, back at the newest | back on the row; 29; 61 blank |
| bounce-arrival-bottom | 21; 23 blank, at the end | 23; 56 blank, at the end |
| tribe-reply-arrives-scrolled | pass; pass | pass; pass |
| thread-scrolled-narrow | 12; 42 blank, list made again | pass; pass |
| thread-bottom-narrow | 12; 42 blank | pass; pass |
| thread-scrolled-wide | 3,482; 3,382 pt over ~330 frames | 208 pt in 3; 1,752 in 11 frames, back on the row |
| thread-bottom-wide | 2,755; 2,438 pt | pass; pass |
| thread-send-scrolled | 886; 915 pt over ~536 frames | 62 pt in 5 (20 blank); pass |
| thread-hop | 3,477; 3,202 pt over ~500 frames | 1,216 in 97; 1,752 in 15 frames |
| thread-switch-chat | +40 pt; 377 blank, 921 pt off | -20; +40 pt (31; 23 blank); the thread is closed on return in both |
| escape-repeat | 92 pt over 551 frames; held | 493 pt over 544; 1,205 in 9 frames; keys end in the chat's composer (main: the window) |
| thread-from-threads | 15; 40 blank, at the end | 12; 46 blank, at the end |
| search-into-thread | no thread opened (both) | no thread opened (both): the journey's match needs a look |
| resize-scrolled | pass; 2,695 pt over 260 | 1,237 in 55; 1,216 in 92 frames (the drag) |
| return | 50; 50 blank, back at the newest | back on the row; 31; 34 blank |
| arrival-scrolled | 882; 860 pt | pass; pass |
| arrival-bottom | pass; pass | 60 blank; pass |
| jump, search-early | fail both (target outside the loaded rows) | same |
| open-read, open-unread, jump-old | 11–41 blank, right landing | 11–42 blank, right landing |

Not done: a live window drag still wobbles while it moves (the lazy
stack's estimate swings with every width) and lands back on the row once
it stops; a width change still shows a few frames at SwiftUI's offset
before the correction, where the review's same-pass correction needs the
list engine (PR 4). thread-hop and escape-repeat can still end off the row
when the stack's estimate swings during the hold's passes. The opening
blanks (hidden until placed) are unchanged. The iPhone is PR 3.

## The list controller and the Mac table (branch `feat/list-controller`, 2026-10-15)

PR 4 of the message-list review (`docs/reviews/2026-10-14-message-lists.md`,
"Layer 2"), on PR 2. Done means: the chat's and a thread's lists hold the
row you read through every change, open placed with no blank frame, follow
only by the latch, and load older history on the Mac; the journeys show it.

Built:

- `ChatListController` (PeelUI, `ChatList/`): the state machine T1–T27 of
  the design, engine-agnostic over `ChatListEngine` and `ListAnchorStore`
  (`AppModel`). Own sends are judged from the row's message; the following
  latch is set only by your own arrival, a scroll by hand ending at the
  newest, and the pill; while a scroll by hand moves the list it holds
  where the rows are (`placement` is `.keep`), for a resize as for any
  change the engine makes by itself. A jump says whether its message is
  here, waiting for a window (older than the first row) or not loaded;
  what to do then (its thread, or give up) is `AppModel.jumpMissed`, for
  every engine. 27 tests in `ChatListControllerTests`.
- `MessageTable` (PeelApp): the spike's engine made the only one. A
  non-flipped `NSTableView` of reused hosting cells, heights cached per row
  (a row is stale when new, changed, or at a new width, and only stale rows
  are measured), rows in view measured through their own cells before
  they are drawn, the rest in idle time (8 ms a turn, then nothing). Every
  change applies the controller's placement in the same pass. Updates are
  incremental (one `CollectionDifference`: rows inserted and removed,
  changed cells shown again), so a selection in an unchanged row survives.
  A cell reused for another row makes its views anew (`.id`), so a menu,
  card or panel the old row opened goes with them. 12 pt above and below;
  a short thread starts at the top; the pill reads the controller (its
  count from `ListBottom`); VoiceOver reads the rows top down; Page Up and
  Page Down scroll the chat's list.
- A row that resizes itself after the list is placed (an image's size
  arriving) holds what the controller holds, the row jumped to included,
  not only the rows on the screen; the cell laid out at another height
  than its row's is corrected in the scroll view's next layout pass,
  before anything is drawn, not on the next turn of the run loop.
- Follows, jumps and the pill animate with AppKit's own animation of the
  clip view on the screen (a far jump going to a view and a half short
  first), and snap off the screens, where there are no frames to animate on.
- Older history on the Mac: near the top, `loadOlder`; the page lands above
  with nothing on the screen moving.
- A trackpad's rubber band past either end is AppKit's: while the clip is
  past the content, or easing back after the gesture ends, the engine
  never sets its origin (it re-placed the rows in view each frame and
  clamped, pulling the list back under the fingers at the bottom), and the
  ease back is the same scroll by hand, not a new one; `overscroll-bottom`
  (a tribe and a direct chat, then a message that follows) and
  `overscroll-top` judge it with the driver's `overscroll` step.
  `overscroll-bottom` fails without the fix (the list never leaves its
  end: 0 of 80 pt); `overscroll-top` passes either way, since at the top
  the row across the edge is the table's padding row, so nothing was
  placed there, and it stays as a guard.
- The hover bar is one view the table engine owns, floating over the rows
  as Slack's does (in a row's cell, the row above drew over its top). One
  tracking area on the scroll view reports the pointer; the engine finds
  the row under it (`row(at:)`), puts the bar across that row's top-right
  edge, or inside the view at its top, and moves it with every report. It
  stays on the row whose menu it opened while that is open, hides while
  another menu is, and hides while the list moves (back once it is still,
  on the row then under the pointer). Rows read the hovered id from
  `ListHover` for their highlight and gutter time. Right-click on a row is
  unchanged: its menu sits on the row's content (`rowMenu`, an AppKit
  catcher over the text, quote or attachment), never the blank area to the
  right, so the dropped `contentShape` (only `onHover` used it) changes
  nothing there.
- Review follow-ups (2026-10-15): a placement asked for while a rubber band
  runs (an arrival, your own send, a jump) is no longer dropped: the
  controller's placement is put in place once the band is back in range
  (`overscroll-arrival`). `ListClipView` is installed only in the
  offscreen check. The scroll's end is AppKit's own where it gives one: the
  live-scroll notifications for a trackpad's gesture and its momentum, and
  the band back in range for its ease back; the 0.15 s and 0.3 s timers
  stay only as fallbacks for scrolls with no end signal (a plain mouse
  wheel, keys, the scroller's track, a still band).
- The jump pill sits at the bottom centre, above the composer, as Slack's
  "Jump to recent", clear of the newest row's Reply, Boost and More.
- `ListProbe` reads a `ListGeometry` report: the table's, and the agent
  list's `ListEnd`.
- `SidePanelSplit` narrows the column on the slide's own completion, not
  after a 0.2 s sleep, and only on the latest slide in's.

Deleted: `MessageList`'s lazy stack and everything holding it (its 15 state
flags, `BottomDistance`, the open sequence with its sleeps, both geometry
observers, the re-pin and its step loop, the reveal timer, `openAtDivider`,
`jumpToNewest`/`scrollToNewest`, `takeFocus`, `go(to:)`, `ListTracking`,
PR 2's `holdAcrossWidth`, `open(at:)`, `keepAnchor` and `ListEnd.topRow`),
735 lines of `MessageViews.swift`. `ListEnd` stays for the agent chat (PR 5).

Journeys: `older-history` is new (a flick into the top screen; the page
arrives; judged from the frame before the rows grow, `from=grow more=200`).
`search-into-thread` pressed Return before the matches came, which does
nothing (search-early's bug), so it never opened the thread on either
build; it now waits for them. A jump in a list too short to scroll passes
when the target is wholly in view. `late-image` (a jump to the message
under an image older than the newest 200; the image sizes itself once
placed, and the target must not move) and `thread-flicker`
(open, close, open again 60 ms apart inside one slide in; the chat holds
and narrows once, after the last slide) are new. A drive step can set
`"next"`, the pause after it (0.3 s otherwise).

Simplify (`/simplify` over the PR). Applied: stale rows in a set, not
whole-row compares per scroll frame; a running total for a thread's
fill; the probe's frames built only offscreen, in the same pass as the
rows in view; idle work returning at once when nothing is stale;
`anchorable` reused; `ChatRow.heldUUIDs` as the one list of what a jump
finds a row by; the model written only through the engine's `later`;
`ListDiff` down to `inserted`, from the engine's one difference;
`viewportWillResize`, `userExpanded` and `top(of:)` (no caller, no row
disclosure in the chat) removed; one `land(on:)`, one `remeasure`; the
flicker sequence written in its drive and the image jump folded into
`jump`. The menu patch for reused cells (`dismiss(anchoredIn:)`) is gone
for `.id` on the cell's root, measured on the long scroll at 1,000 rows
(`lj-big`, three runs of two 6,000 pt scrolls, a 16 ms step): frame p95
22.2 ms with `.id` against 21.8 without (p50 18.5 against 18.8; 3 frames
over 33 ms of 894 against none), and 22.3 before the simplify. Not applied: the remaining O(n) passes per row change and a
flags-only update path (optional, not on the scroll path); the
unreachable `.opening` case in `contentWillChange` (the switch must be
exhaustive; it says why); `openStarted` as a local (set in one update,
read in a later layout).

Run again after the review fixes and the simplify (2026-10-15), twice on
each build: this branch 30 of 31 both times, main 2 and 3.

| Journey | main (twice) | this branch (twice) |
|---|---|---|
| open-read, open-unread | 11; 30 blank frames | pass; pass |
| return, bounce-* (5) | 50–101 blank, wrong landings | pass; pass |
| arrival-scrolled, resize-scrolled | 876; 3,083 pt moved | pass; pass |
| thread-* (8), escape-repeat, tribe-thread-close-* | fail (moves, blanks; no probe where main's driver lacks a step; thread-bottom-wide passed once) | pass; pass |
| jump, jump-old | short of the target, blanks | pass; pass |
| older-history | never grew past 200 | pass; pass |
| late-image, thread-flicker | no probe (main's driver lacks the steps) | pass; pass |
| tribe-reply-arrives-scrolled, arrival-bottom | pass | pass; pass |
| search-early | fail | fail (the model: Return before matches) |

Open and resize at 200 and 1,000 rows (`lj-big`, two runs): placed 28–29
and 35–41 ms after the rows came (240–270 ms for the first list in a fresh
process), first frame shown 123 and 162–169 ms after the click, 0 blank
frames (the lazy stack: 430 and 520 ms, 30–34 blank). A resize pass 1.6
and 2.8–3.1 ms at the median, 7 ms at most; drag frames 20 ms at the
median, as the lazy stack's. Idle: 0% CPU after a minute on the chat.

Needs Tom's hands: hover cards, right-click menus and text selection in
the table's cells (sound in code: they anchor to AppKit views that follow
the table's scroll view), VoiceOver's order, and the feel of the follow and
jump animations.

### Connection control — 2026-10-15

Built the approved minimal Mac connection panel: one status line and one native
icon button, no heading, explanatory copy, footer or last-check timestamp. A nil
`Panel` title reuses the existing shell without its header. The native bolt
help is suppressed while the panel is open, with an explicit accessibility
label retained. The status keeps the retry countdown; errors remain available
to VoiceOver without adding visible copy.

`Engine.checkConnection()` reuses the keep-alive ping and its existing timeout
and reconnect path. `AppModel.checkConnection()` prevents duplicate requests,
checks online, and skips the retry delay offline. The action is disabled while
checking or connecting. The iPhone connection panel is unchanged.

Validation: `swift build`; full `swift test` (975 tests, one pre-existing known
IPv6 loopback issue); all five `Journeys/Reconnects` on an isolated loopback
stack. The new journey checks a healthy broker, a frozen connection, recovery,
and a closed engine. Offscreen app renders verified the compact panel, its
Escape key path, and the one-minute idle check (0.0% CPU, sampled for 10 s).
Independent correctness, simplicity/reuse and security review found no
blocking findings. Risk is high by the repository rules (Engine and Sidebar);
no money protocol, storage or credential behavior changed. Next: reviewer’s
look at the diff and renders before merge.

PR #291 conflict refresh: merged the latest main, keeping its Brain driver
commands and message-list journals alongside the connection panel commands
and journal. The two conflicts were documentation/comment additions; executable
connection changes merged unchanged. `swift build` passed against current main;
independent review found no lost changes or conflict markers.

## The thread panel sliding in around its rows (branch `fix/thread-panel-slide`, 2026-10-15)

Tom saw a thread's messages already in place when he opened it, the
panel's header and background then sliding in around them. The cause,
measured: `SidePanelSplit` slid the panel with `.transition(.move(edge:
.trailing))`, a drawn offset. AppKit views are placed by their frames
and ignore it, so the thread's table (and the divider's resize handle)
sat at the slide's end from its first frame while SwiftUI's chrome moved.
A probe frame by frame (the panel found where it is drawn, by a mark the
offscreen mode alone draws at its top left; the list's scroll view by its
frame): opening beside the tribe at 1180 pt, the panel drawn at 1,179,
1,030, 994 … 822, 819 pt over 0.2 s, the list at 820 pt and drawn in
every one of those frames. Closing, the same the other way: a removed
view is no longer laid out, so the rows stayed at 820 while the chrome
slid out to 1,111. `reveal()` and the order of insertion were not the
cause: the list was shown once placed, inside the panel, and only its
place was wrong.

The fix moves the panel by layout. Its slide in is a transition built on
an animatable `Layout` (`TrailingSlide`), so each frame is a layout pass
and everything in the panel, AppKit or SwiftUI, moves as one. Its slide
out keeps the panel in and slides the same layout back out, taking it out
at the animation's end; `SidePanelSplit` keeps the item it was opened for
(a thread, a memory, the web pane) until then, and `ThreadPanel` keeps
its rows as they were while open. The thread, the web pane and an agent
memory all slide this way. The column still changes width once: at the
end of the slide in, at the start of the slide out.

New journey `thread-open-slide` (open and close beside the tribe, then
over it at 760 pt): every frame the thread's list is drawn, the panel is
drawn and the list sits where it does in the panel at rest, within 1 pt.
On main it fails: apart by up to 360 pt in 17 frames beside, 498 pt in 18
frames covering. On this branch: 0 pt, 0 frames, both. The full set (39
checks) passed but for the known `search-early`; then the thread, close,
flicker, escape, resize and bounce journeys again after the slide out
and the review's changes.

2026-10-15: the sidebar's connection card fits its one line (`Panel` `fit`),
opens under the bolt and grows leftward (`PopoverEdge.trailing`), its right
edge in line with the bolt's, so it stays within the sidebar. The row ends
in a small (24) refresh 10 in from the card's edge, as a panel header's
close, under the bolt. Every other popover is placed as before. Checked
offscreen (connection snapshot): edges in line, card inside the sidebar.

2026-10-16: Return in a chat's search, pressed before the matches came,
did nothing: the field's key handler dropped it while the list was empty,
and nothing remembered it, so `search-early` failed on every build since
the list redesign began. Now `AppModel.searchReturn` decides, and
`ChatSearch` keeps the query Return was pressed for when the matches are
not yet for what is typed (debouncing or searching). When that query's
matches are found, the first is shown. Any other outcome drops it: a
newer query's matches, none, a failed search, or Escape and close (the
search is gone). With the matches in, Return goes to the selected one as
before. `ChatSearchTests` cover the waiting. On a fresh local stack,
`search-early`, `search-into-thread`, `jump`, `jump-old` and `open-read`
passed twice each. `search-into-thread` no longer works around the bug.

## A tribe that moved under a thread reply (branch `fix/tribe-thread-reply-hold`, 2026-10-16)

`thread-send-first-tribe` (scroll the tribe up, open a thread on the
second row in view, send three replies at once) failed `hold=chat` 10 of
10 on main. The thread is opened on the reading row itself, and a reply
takes that row away from its place: a message's thread folds into one
row at its newest reply once it has two (`Storage.tribeHidden`), and a
thread row already there re-sorts to the bottom on the first reply. The
engine applied the controller's placement in the same pass every time
(no late correction, no mode change); the placement was the problem. The
controller held a moved row (`has(id)`), so the list followed it to the
bottom (652–700 pt in 4 of 10 runs), or for a row gone held the row below
where it stood, so everything above slid down by the folded row's height
(22–424 pt in the other 6; the journey's checker, falling back to a row
a view above that had been measured again at the narrower width,
reported 2–454 pt).

Now the engine passes the rows that moved (`ListDiff.moved`, from the
difference it already makes for the table), and a reading row that moved
or went hands its place to the nearest row below that stayed, at the
same offset: what is above stays, what is below closes up (T12; with
none below, the nearest above stays where it was). `evaluate.py` judges
a reading row that left its place by the row that takes it.
Controller tests: a deleted reading row, one folded into its thread (real
tribe `ChatRow`s), one re-sorted to the bottom.

After: `thread-send-first-tribe` 10 of 10. `bounce-arrival-scrolled` was
6 of 10 before and 10 of 10 after, but its failures were another cause:
when the peer's post arrives and counts as unread before you return, the
tribe opens at "New messages" (T2, ahead of the kept row, T3, in
`ChatListController.appear`), at the newest. No run after the fix had the
post arrive in time.

Tom decided the order (2026-10-16): back to a chat left scrolled up (its
kept place a row), it opens at that row, the pill counting what came
below "New messages"; "New messages" opens a chat left at its newest, or
one with no kept place. A message asked for still wins over both.
`appear` now takes a kept row before the divider (`replaced()` never
took the divider). `bounce-arrival-scrolled` and `bounce-arrival-bottom`
now wait for the post to be counted unread before going back (the drive's
`unread` step), and the probe records the pill: scrolled up, back on the
reading row with "1 new message" (`pill=1`); at the bottom, at its end
with no pill.

All 50 journeys twice on a fresh stack: 49 pass each time, the known
`search-early` the only failure. `swift test`: 1,036 tests pass (the
known IPv6 loopback issue).

On main after #312 and #314, with the order above: `bounce-arrival-scrolled`
and `bounce-arrival-bottom` 10 of 10 each, `thread-send-first-tribe` 10
of 10, all 50 journeys pass once (`search-early` too, after #312), and
`swift test`'s 1,043 tests pass (the known IPv6 issue). The check app
would not launch after #314: `bundle-app.sh` now builds it without
Xcode's debug dylib, which the signing left unsigned. On a stack running
for over an hour the tribes server refused the peer's posts ("Upstream
node set CLTV to less than the CLTV set by the sender"); restarting its
mixer (`test-stack.sh mixer <dir> fund`) before each run cleared it.

## The last reply on a thread's row (2026-10-26)

A collapsed thread's row (Mac `ThreadSummaryLine`, iPhone `ThreadSummaryButton`) now also shows the newest reply's words under its reply count and "replied …" label: smaller, indented, with its sender's photo and name, two lines at most. `ThreadSummary.latest` already carried the message from `threadsSQL`'s `latestID` (one query for all rows), so no storage change. `Message.threadReplyPreview` (PeelCore) is the one string: text cut at 120 characters, else "Photo", "Video", "Voice message", "File", "Payment", "Payment request", "Call". Tested in `MessageTests`; the Apple UI was not built on this Linux pod.
