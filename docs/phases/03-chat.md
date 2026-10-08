# Phase 3 — Tribes, threads and attachments

## Status (2026-10-08)

**Built and merged:** tribes and parity with the Mac app (#4, #7, #11, #20),
replies and threads (#8), attachments (#9), the chat UI and Peel's menu
(#13), notifications and the Dock badge (#18), mark as unread and jump to a
message (#23, in `02-messaging.md` item 7).

**Open:**
- Tribe parity leftovers (tags, app and second brain URLs, image upload, per-tribe alias, details page, directory, link QR): "Tribes", "Open".
- A production run of tribe create, edit, pin and delete on the throwaway: "Tribes", "Open".
- Clicking through what no session could exercise: "Chat UI", "Open".
- Notifying payments and boosts (`.moneyReceived`), a Reply action: "Notifications", "Open".

**Decided:** no auto-join of the invite's tribe; delete sends only
`delete_tribe`; one Reply, threads grow from replies, no Copy link; files
only from the account's own memes host, at most 100 MB, never opened for
you. Paid attachments came later, in phase 4.

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
| Copy link | Share | — | Done (no QR) |
| Create: name, description, image URL, price to join, price per message, escrow amount and time, private, unlisted | CreateTribeViewModel, `getNewGroupParams` | `create_tribe` (msat, millis) | Done: engine, CLI, app form |
| Create: tags, app URL, feed URL and type, second brain URL | same form | `create_tribe` | Open (kept untouched on edit) |
| Image upload (rather than a URL) | `uploadPublicImage` | memes server | Open (attachments task) |
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
| Per-tribe alias and photo | GroupDetails (local only) | — | Open |
| Tribe details page (created on, admin, member count) | GroupDetailsViewController | registry | Open (header shows description, price, private) |
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
(own join/leave now set membership); a joined link could set the account's
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
- From the parity table: tags, app and feed URLs, second brain URL; image
  upload; per-tribe alias and photo; a tribe details page; browsing the
  tribes directory; a QR code for the link.
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
one `SectionLabel`; `MentionsView` reuses `EmptyPlace` and observes only
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
- **Payments and boosts (hook ready, not shown yet).** Tom, 2026-10-07:
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
