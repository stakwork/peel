# Phase 3 — Tribes, threads and attachments

Status: tribes built and reviewed on branch `phase3/tribes`, rebased onto
the status branch (2026-10-07); tribes parity with the Mac app built on
`phase3/tribes-parity` (on top of it); threads and attachments planned.

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
| Mentions: `@` autocomplete from aliases heard in 3 months | `aliasesAndPics`, `getAtMention` | — (plain `content`) | Done |
| Mentions: highlighted in messages | `\B@[^\s]+` | — | Done (bold) |
| Mentions: which messages mention me | `content.contains("@alias ")` | server `detect_mentions` (exact word) | Done, as the server reads them |
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
  mention as the server does: `@alias` as a whole word, exact case.
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
- Mentions flagged before v7 (or from history the engine had already stored)
  are not back-filled; nor is a mention of the alias the tribes server
  made unique for us (`name_2`).
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

- `replyUuid` and `threadUuid` in the message JSON; quote rendering; a threads
  list per chat. Reference: `formatMsg` in `SphinxOnionManager+ChatExtension.swift`.

## Attachments

- Encrypt with a random key, upload to `memes.sphinx.chat` (auth by signed
  challenge), `makeMediaToken` (or `makeMediaTokenWithPrice`), send type 6 with
  `mediaToken`, `mediaKey`, `mediaKeyForSelf`, `mediaType`. Download and decrypt
  on receive; thumbnails; file, image, audio, video.
- Reference: `SphinxOnionManager+ChatExtension.swift`, the Mac app's
  `Managers/Attachments` and `Managers/S3 Uploader`.
