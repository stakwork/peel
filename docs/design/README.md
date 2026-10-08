# Peel design

Last updated 2026-10-08. The target layout and visual language for the Mac app.
Most of it is built: the sidebar, flat message rows, tribes, replies and
threads, attachments, Peel's menu and the Payments screen. Not built yet: the
call button in the conversation header (phase 6) and the gaps each section's
notes list. The phase files say what is left. The source mock lives on the canvas "Peel layout directions"
(direction D); the screenshots below are taken from it.

![Dark theme](layout-dark.png)

![Light theme](layout-light.png)

## Decision

The layout follows Slack: tribes and direct messages in a sidebar, the
conversation in the middle, threads opening on the right. It replaces the
official app's tabbed chat list. Three other directions (a three-column mail
layout, a conversation with an inspector panel, an agent inbox home) were
mocked and rejected on 2026-10-07.

Colours and type are Sphinx's, because Peel is meant to replace the official
apps. The sidebar header is you (photo, name, balance) and Peel's menu since
option S2; the Peel logo shows only on the lock and welcome screens.

## Layout

Three regions, left to right. On a narrow window the thread panel closes first,
then the sidebar collapses; panels never overlay the conversation.

### Sidebar (260 pt)

Top to bottom:

1. **You, on top** (option S2, Tom, 2026-10-07: like a workspace
   switcher). Your photo, your name with a chevron, and the balance in sats
   under it. Clicking it opens Peel's menu: your name, short key and balance,
   then "Account…" (⌘,) and "Copy contact info". "Receive sats" and "Invite
   someone" join it when they are built. On the right, Sphinx's connection
   bolt: green when connected, orange otherwise; clicking it shows the state,
   the retry countdown and the last connection error.
2. **Search.** One field over every conversation.
3. **Threads.** Threads you started or replied to that have new replies, with
   an unread count.
4. **Mentions.** Messages that mention you, across tribes.
5. **Payments.** Payment history: received, sent, boosts, invoices. The
   receive screen from the v1 scope lives here.
6. **Tribes.** One row per tribe, prefixed `#`, like Slack channels. Unread
   tribes are bold. Ends with "Join a tribe". The section collapses.
7. **Direct messages.** One row per contact, unread ones bold with a count.
   Ends with "Add contact". The section collapses.
(The footer with your name and the Peel logo in the header are gone since
S2; the app's icon still shows on the lock and welcome screens.)

No tabs and no filter chips. Sorting inside each section: most recent first.

### Conversation (flexible)

- **Header.** The tribe name with `#` (or the contact's name), member count and
  description for a tribe, and three icon buttons: call, pinned messages,
  members.
- **Messages are flat rows** (Tom, 2026-10-07, readability option D, "try
  it out"; they replace the bubbles chosen earlier that day). No bubbles:
  the text sits on the background. Each run (one sender, a new run after
  five minutes, a new day, or anything that is not a message) starts with
  a 32 pt photo, the sender's name (13 semibold, `Theme.name`) and the time
  (12, secondary) once; the rest of the run sits under it, each message's
  time in the left gutter on hover. Your messages are left-aligned too, on a
  faint accent tint, with the green delivered bolt beside the time. Body
  text 14 pt with 3 pt line spacing (about 1.45), at most 560 pt wide
  (about 68 characters). Mentions are a soft chip (medium weight); links are
  in the link colour, without the scheme and shortened in the middle when
  long; lines starting with "-" or "•" are a list with a hanging indent.
  Quotes, attachments, thread summaries, Retry and the deleted placeholder
  sit in the row. Hovering lights the row and shows Reply, Boost (others'
  messages) and More at its top-right, over its top edge, as in Slack. Joins and leaves are a quiet
  centred line ("carol joined").
- **Day dividers** ("Today", "Yesterday", then dates).
- **New messages divider**: a blue line with "New messages" (12 semibold,
  accent) on the right, above the first incoming message that was unread
  when the chat was opened. The chat opens scrolled to it; it stays until
  you change chats or send.
- **Boosts** show as a chip under the message, as the official Mac app
  draws them (`NewMessageBoostView`): an orange bolt, the total ("1,210
  sats"), then the first three boosters' photos overlapping (24 pt, one
  per person in the order they boosted, initials when there is no photo)
  and "+N" for the other people (Tom, 2026-10-07). Tinted in the selection
  colour when one of them is yours; clicking it opens who boosted (avatars, names,
  amounts). There is no "+" chip: the bolt in the hover bar (Reply, Boost,
  More) boosts at once with your boost amount, as the official apps do:
  one tap, no panel and no confirmation of any kind (Tom, 2026-10-07); its
  tooltip and the menu's "Boost 100 sats" (B) name the boost amount only,
  never a tribe's price (the official apps' menu just says "Boost"; their
  chip, like Peel's, then totals what was sent, price included). That
  menu item is the only Boost in the menu (Tom, 2026-10-07: no "Boost…"
  panel; Account's "Boost amount" sets the amount). On others' messages
  only, and not on one you have already boosted: the bolt and the menu
  item go once you have a boost on it (the official apps keep offering
  Boost); a failed one shows Retry and Discard under the message instead
  (see `../phases/04-money.md`).
- **Payments** in a DM are a compact row: an orange bolt in a soft circle
  where the photo goes, "You sent **1,000 sats**" or "Bob sent you **1,000
  sats**", the time and delivery bolt, the note under it. A payment or
  boost waiting past 30 s reads "… waiting for the server…" (no Discard: it
  may have paid); one the server passed on but never settled "Payment not
  settled" / "Boost of 21 sats not settled", with no action; a failed one
  "Not sent · Retry · Discard".
- **Money panels.** Send sats (amount, note, balance) is a Peel panel. Money buttons use plain verbs (Tom,
  2026-10-07): idle "Boost", "Send", "Pay"; over the threshold (default
  100 sats) the first click turns the button orange with the amount
  ("Boost 150 sats", "Send 2,000 sats") and a quiet "Click again to
  confirm" beside or under it, never in the button; the second click sends
  exactly that. The same for Retry over the threshold and saving a large
  boost amount. Destructive menu items keep their own wording ("Delete for
  everyone").
- **Thread summary.** In a tribe, a thread of two or more collapses to one
  row: the original message, then up to three participants' avatars, "N
  replies" as a link (bold, with "N new", when unread) and "Last reply
  <sender> <time>". Clicking it opens the thread panel. DMs never collapse:
  replies show inline with their quote (Tom, 2026-10-07).
- **Composer.** A rounded text field ("Message #Tribe" or "Message Name")
  and a round send arrow beside it, not a "Send" button (Tom, 2026-10-07).
  Attach, send sats and mention join it with their phases; no control appears
  before it works. In a DM a round bolt beside the paperclip opens Send sats.

### Thread panel (360 pt)

Opens when you click a thread summary or "Reply in thread", and closes with
its close button.

- Header "Thread" with the tribe or contact name under it.
- The original message, a "N replies" divider, then the replies.
- A reply composer. No "Also send to #Tribe" checkbox (Tom, 2026-10-07): a
  thread reply stays in the thread.
- Escape stops replying, then closes the panel. On a window too narrow for
  both, the panel takes the conversation's place instead of covering it.

## Agents

An agent is a contact. It sits in Direct messages next to people, with no
separate section. Two differences:

- **Avatar shape.** Agents have rounded-square avatars with initials; people
  have round avatars.
- **An "AGENT" label** next to the name on its messages, so others in a tribe
  know they are talking to an agent. Kept on 2026-10-07.

Agent-specific views (budget, schedule, activity, approval cards) are not part
of this layout yet; see `../agent-native.md`.

## Profile and onboarding

Approved by Tom on 2026-10-07; mocks on the "Peel layout directions" canvas
(Profile, onboarding 1–5, restore 2b–3b).

- **Profile** is a full page in the detail column, opened from the sidebar
  footer. It holds your photo, name and short key; a "Your contact info" card
  with a QR code, Copy and Create invite; Account (name, balance, server,
  devices); Security (PIN, Touch ID, Show words behind PIN or Touch ID);
  Notifications; and "Remove this account from this Mac", the only red text.
- **New account:** Welcome (invite or restore), then four steps: invite,
  name and photo, a six-digit PIN with an optional Touch ID unlock, and the
  twelve words with an "I've written them down" check before Peel opens.
- **Restore:** twelve word fields (paste fills all twelve, suggestions as you
  type), then a progress page: account, contacts, messages with a count,
  tribes. "Open Peel" works before history finishes.
- **The PIN is required, as in the official apps** (Tom, 2026-10-07). The
  restore flow gets a PIN step too. How the PIN protects the words is a
  phase 2 decision; see `docs/phases/02-messaging.md`.

**Built 2026-10-07** (`OnboardingView.swift`, `LockView.swift`): both flows,
the PIN at launch for the app's own profile, the optional re-lock
(`defaults write dev.peel.mac pinTimeoutHours <hours>` until Profile has it),
"Paste twelve words", and restore progress from `Engine.Event.history`. Tom
ran the restore with the throwaway's words: contacts and conversation came
back, the words sit in the Keychain and no words file exists.

Not built: the photo picker (needs uploads to the media server), word
suggestions while typing, the Profile page.

Review notes left open:

- No limit on PIN attempts at the lock screen; the official app has none.
  Through the screen a full search takes about 4.6 days at 0.4 s per try.
- Re-locking after the timeout hides the window but keeps data in memory; the
  official app clears its context.
- If `Account.restore` fails after the words are saved, a retry reports that an
  account already exists until the app is relaunched.

## Colour

Tokens come from the official Mac app's colour catalog
(`sphinx-mac-v2/com.stakwork.sphinx.desktop/Colors.xcassets/SphinxNew`). The app
is dark only for now (Tom, 2026-10-07); the light values are kept in
`Theme.swift` for later.

| Role | Dark | Light | Sphinx token |
|---|---|---|---|
| Sidebar background | `#1A242E` | `#F2F3F5` | LightBG |
| Conversation background | `#151E27` | `#FFFFFF` | Body |
| Thread panel background | `#1A232D` | `#F7F8F9` | HeaderBG / ThreadOriginalMsg |
| Input background | `#13181D` | `#F2F3F5` | InputBG1 |
| Primary text | `#E3E7EC` | `#292C33` | PrimaryText, softened |
| Secondary text | `#97A3B4` | `#646C73` | SecondaryText, adjusted |
| Dividers | `#2C353D` | `#DCE0E3` | NewMessageIndicator / LightDivider |
| Quoted or summary block | `#1E2934` | `#F2F3F5` | ThreadOriginalMsg / ReceivedMsgBG |
| Accent (unread counts, links, selection) | `#618AFF` | `#618AFF` | PrimaryBlue |
| Filled buttons | `#618AFF` | `#3F68E0` | PrimaryBlue, adjusted |
| Your rows (tint) | accent at 6% | accent at 6% | — (bubbles retired) |
| Links, mention chip | `#8FB0FF`, `#2A3A5E` behind `#B4C8FF` | `#3F68E0`, `#DDE6FF` behind `#1E3D99` | — |
| Boost bolt | `#FFBC58` | `#FFBC58` | SphinxOrange |
| Online dot | `#49C998` | `#49C998` | PrimaryGreen |

Two deliberate departures from the Sphinx values, both for contrast (text
needs 4.5:1):

- Secondary text in dark mode is `#97A3B4`; Sphinx's `#6B7A8D` is too faint on
  navy.
- Filled buttons in light mode are `#3F68E0`; white text on `#618AFF` is too
  faint.

Colour is state, never decoration (Tom's `tom-ui` rules): blue marks unread,
selected and actionable; red only for destructive or blocking moments.

## Type

The system font, SF Pro (Tom, 2026-10-07: easier to read than the
official apps' Roboto, which is no longer bundled). Sizes: 16 pt for
conversation and panel titles, 14 pt for messages and sidebar rows, 13
semibold for names over runs, 12 pt for times and secondary lines. Times and
sats use tabular figures. Text in dark mode is `#E3E7EC`, not white; links
`#8FB0FF` (light `#3F68E0`); a mention chip `#2A3A5E` behind `#B4C8FF`
(light `#DDE6FF` behind `#1E3D99`). Secondary text stays `#97A3B4`, above
4.5:1 on the conversation background.

Panes: the sidebar (220–420 pt) and the thread panel (300–560 pt) resize by
dragging their dividers; a double-click puts the standard width back, and
the widths are remembered on this Mac. Below about 740 pt for the chat and
the panel together, the thread panel takes the chat's place.

## Motion

Restrained. The thread panel slides in from the right in about 200 ms with an
ease-out curve and leaves faster. Sidebar selection, hovers and keyboard
actions do not animate.

### Copy feedback

Every copy says it worked (Tom, 2026-10-07: "all copy buttons should have
feedback"). Built in `Sources/PeelApp/CopyFeedback.swift`; use it for any new
copy (the Payments screen's invoice and payment hash included), never a bare
`Clipboard.copy`:

- **A button:** `CopyButton("Copy invoice", text: invoice)`, or
  `CopyButton("Copy image") { model.copyImage(message) }` for anything else
  that copies (the closure returns whether it copied; no check when it did
  not). It takes the surrounding button style (`GhostButtonStyle`);
  `iconOnly: true` draws the small hover icon button instead, with the title
  as its tooltip. `systemImage` defaults to `doc.on.doc`. After the click
  the icon becomes a green check and the title "Copied" (a spring of about
  180 ms, no overshoot, scale and fade; leaving in 140 ms), held 1.5 s; another
  click starts the wait again. Both labels are laid out at once, so the button
  never changes width. Reduce Motion keeps only the cross-fade.
- **A button that copies in two steps** (the twelve words, after their
  warning): `CopyLabel("Copy", copiedAt: date)` as the label, setting
  `copiedAt` when the copy really happens.
- **A menu item:** `.copy("Copy tribe link", text: link, systemImage: "link")`,
  or `.copy(title) { ... }` (returning whether it copied). The menu closes
  on the click, so a small "Copied" pill with a green check fades in at the
  bottom centre of the main window and leaves after 1.5 s
  (`MenuPresenter.showToast`), also for a menu opened inside a panel.
  `.copyText` is one of these.
- The twelve words keep their warning, Peel-only concealed copy and
  one-minute clear; only the Copy button's label changed.
- VoiceOver hears "Copied" each time (`CopyFeedback.announce`).

## What the engine needs

Each part of the layout depends on something below the UI. Most of it exists
in the core or in the official apps' message conventions.

| UI part | Needs | Where it comes from |
|---|---|---|
| Tribes section | Join, list and read tribes | Core: `join_tribe`, `list_tribe_members`; phase 3 |
| Thread summary and panel | Group replies by thread | Message JSON `threadUuid` / `replyUuid`, as the official apps send them; phase 3 |
| Threads item | Threads you took part in with new replies | Peel's own query over stored messages |
| Mentions item | Messages that mention you | Peel parses `@alias` in stored messages; check how the official apps mark mentions |
| Payments item | Payment history | Core: `fetch_payments`; phase 4 |
| Boost chips | Boost totals per message | Boost messages reference the boosted message; phase 4 |
| Balance in header | Live balance | Core returns it with each call; available now |
| AGENT label | Know a contact is an agent | Not defined yet: needs a profile field or message convention, see `../agent-native.md` |

## Build order

The layout can be built before the features behind it, with empty states:

1. Sidebar structure with Direct messages working (what phase 1 already
   supports), Tribes, Threads, Mentions and Payments present but empty.
2. Flat message style and the composer.
3. Tribes, the thread panel and thread summaries with phase 3.
4. Payments, boosts and send-sats with phase 4.
5. Mentions once message storage can answer it.

## Status

**Steps 1 and 2: built (2026-10-07).**

- Dark Sphinx colours (`Sources/PeelApp/Theme.swift`); Roboto was bundled
  until the system font replaced it.
- Hidden title bar; the sidebar header carries the app icon, "Peel" and the
  balance (replaced by you and your menu with S2, see "Sidebar" above).
- Sidebar: search (filters the lists, held in `AppModel.searchQuery`), Threads,
  Mentions, Payments with empty states, Tribes with "No tribes yet", Direct
  messages, "Add contact" (a popover next to the row, through
  `Engine.addContact`), and a footer with your name that opens your contact
  info to copy.
- Delivery and reads (2026-10-07): the connection bolt in the header; a green
  bolt beside the time of a message the server confirmed; "Not delivered ·
  Retry · Discard" under a failed one; chat errors in a quiet bar above the
  composer, and errors that belong to no chat (the engine's own) in the same
  bar along the bottom of the window until dismissed; unread direct messages
  bold with a blue count, muted ones dimmed with a crossed-out bell (Mute / Unmute in the row's context menu). Times
  show under the last message of a run and beside any bubble on hover.
- Conversation: header with the name and short key, day dividers, bubbles,
  the composer with the round send arrow. A banner at the bottom on
  development profiles says the twelve words are in a plain file.

Verified on the throwaway profile: messages both ways render, the layout holds
at the default window size. Not yet checked by hand: adding a contact through
the popover.

Not built, noticed in use:

- ~~No notification for incoming messages.~~ Local notifications and the
  Dock badge built on `phase3/notifications`; see `../phases/03-chat.md`,
  "Notifications".
- Sidebar rows are buttons, not a `List`, so arrow keys do not move between
  conversations yet.
- The sidebar width is fixed at 260 pt and does not collapse; the window's
  minimum width (760 pt) keeps the conversation readable.

**Step 3, tribes: built (2026-10-07, branch `phase3/tribes`).** Tribes rows
show `#` or the tribe's image on a rounded square; "Join a tribe" opens a
popover beside the row (paste link, Look up shows name, description and
costs, then Join). The header shows the description and the price per
message; the people button opens a members popover with Copy link and Leave,
confirmed inline. No call or pinned-message buttons yet. Thread panel and
summaries are still to come.

**Tribes parity (2026-10-07, branch `phase3/tribes-parity`).** "Create a
tribe" under "Join a tribe" and an owner-only edit button in the tribe header
open one form (Delete confirmed inside it). Requests to join sit at the top
of the members popover and inline in the chat, with Approve and Decline;
Remove beside each member for the owner. A pinned message shows as a thin
bar under the header rather than a header button. When you cannot post
(waiting, declined, removed, deleted) a quiet bar replaces the composer.
Typing `@` offers aliases above the composer; the Mentions item lists
messages that mention you. Details in `../phases/03-chat.md`.

The rejected native-sidebar variant and the first Slack-skin build are kept in
the session scratchpad only; the mock canvas has all four mocked directions.

## Replies, threads, attachments and Peel's menu

Approved by Tom on 2026-10-07 (boards R1–R12 on the "Peel layout directions"
canvas), with these decisions over the boards:

- **One Reply** (Tom, later on 2026-10-07; "Reply in thread" is gone):
  the hover bar is Reply and More, beside the bubble (right of theirs, left
  of yours), top-aligned with it, never over its text. Reply opens the
  inline "Replying to…" bar, except for a message folded into a collapsed
  tribe thread, which is answered in that thread's panel. Threads emerge
  from replies, as in the official app (a reply joins or starts the
  parent's thread); the panel opens from "N replies" and the Threads list.
- **No "Copy link"**: Sphinx has no message links.
- **Peel's own menu** replaces every native context menu, pop-up button and
  picker: right-click (or Control-click) and the hover bar's More open it;
  arrows, Return and Escape work; it opens beside its trigger and flips at
  the window's edges; items that delete or leave are red and take two
  clicks: the first turns the row into bold red text with a trash icon
  ("Delete for everyone", "Click again") without closing the menu, the
  second acts; moving to another row or Escape puts it back. Confirms in
  panels and screens stay inline. Shortcuts shown in it really work (R reply, ⌘C copy). The Account
  screen's choices use the same menu as a dropdown, and the former popovers
  (connection, join and create tribe, add contact, tribe settings, members)
  are Peel panels in the same style. Menus and panels are their own small
  windows beside their trigger.
- **Delete** (red, "Delete for everyone?"): your own messages, and any in a
  tribe you own. A deleted message reads "This message has been deleted".
- **Message menu** (someone else's message): "Mark unread from here".
- **Sidebar row menu:** Mark as read (Mark as unread when nothing is
  unread and the chat has a message from them), the notification level with a check,
  Copy tribe link, Leave tribe. Direct messages have no Leave and no Delete
  chat (the engine cannot delete a conversation).
- **Threads list** covers direct messages (from a single reply) and tribes
  (two or more messages, as they collapse), newest first, with an
  unread dot and "Mark all read". Thread unread clears when its chat is
  opened (the server's read marker), as in the Mac app.
- **Quotes** show the sender and one line (an image's thumbnail or a file's
  type beside it); a parent that is not stored reads "Original message not
  available". Approvals and other membership messages are never quoted.
- **Images:** a grid of up to four with "+N", for one sender's consecutive
  images within about a minute. Images download when shown. A file's
  download button saves it straight into Downloads ("name (1).ext" when
  taken), then the card reads "Saved to Downloads · Show in Finder"; "Save
  as…" (choose where) is in the message's menu. Nothing is ever opened for
  you, and every file Peel writes for you is quarantined, so macOS checks it
  before it opens. Paid attachments: see "Payments" below.
- **Uploads:** a progress bar on the row ("Uploading · 2.1 of 3.4 MB"); a
  failed one reads "Not uploaded · Retry · Discard", like an undelivered
  message.
- **No emoji in previews:** an attachment without a caption reads "Image" or
  "File: name.pdf".
- **Pinned bar:** the one from tribes parity. Clicking it jumps to the message.
- **Jump to newest**: scrolled up more than a screen, a 36 pt round button
  (menu surface, down arrow) sits at the list's bottom-right above the
  composer, with an accent count of new messages that came in below; click,
  End or ⌘↓ (chat list, empty composer) scrolls to the newest. Fades in and out.
- **Jump to a message** (Mentions, notifications, Threads list, pinned bar,
  quotes): the chat (or thread panel) opens scrolled to it and the row is lit
  with the selection tint, which fades out over about 1.5 s. It wins over
  "New messages". A message deleted since opens the chat with "That message
  was deleted".
- **Mention suggestions** (after first use): above the composer, inside the
  window, in the menu's style, scrolling after seven.

**Built 2026-10-07 (branch `phase3/chat-ui`).** Details, what was verified
and what was not in `../phases/03-chat.md` ("Chat UI").

## Payments

Boards P1–P5 on the "Peel layout directions" canvas (row "Payments"), with
Tom's decisions of 2026-10-07:

- **The list** is plain, grouped Today / Yesterday / Earlier this week /
  Earlier, newest first, no balance, no tabs, no table chrome. Each row: the
  person's photo (a dashed ring with a bolt when nobody is known: an
  invoice, a keysend), their name, one line (the note, "Boost in #Tribe",
  a memo), the amount and the time in a right-aligned column. Amounts follow
  the banking apps: received "+500" in green, sent a plain "2,000" in the
  text colour, no arrows, no minus; the header says "Amounts in sats".
  Pending: grey, "Pending · 13:15". Failed: struck through, "Failed · 16:02".
  Never red. Older pages load as the list reaches its end.
- **Header:** "Payments" with Receive and Pay an invoice, small bordered
  buttons that stay lit while their pane is open.
- **The pane on the right** (360 pt, the thread panel's place; Escape or ✕
  closes): a payment's detail (what it was, the amount large, who, the note
  or the boosted message quoted, "Open in #Tribe", then Status, When,
  Amount in sats and msat, Routing fee and Ping when known, Payment hash with
  Copy); Receive (amount, required because the core cannot make an invoice
  the payer fills in; memo; QR with Copy invoice and Copy QR image; a
  countdown bar; then Paid with what arrived); Pay an invoice (paste, or drop
  it anywhere on the window; amount, to whom, memo, expiry; what stops it in
  an amber note; then Paying, then Paid with the fee).
- **Money buttons** everywhere: idle "Pay" / "Unlock" / "Send", on one
  line; over the threshold the first click arms it, orange, with "Click
  again to confirm" under it, and only the second pays. Where the amount
  already stands beside the button (a request card, a paid attachment's
  price, an invoice's amount) the armed button keeps just the verb; in a
  form whose amount is typed (boost, send) it names it ("Send 2,000
  sats").
- **Copy** gives a tick and "Copied" for a moment.
- **Requests in a DM:** the composer's bolt is "Send or request sats" with a
  Send | Request switch. A request is a 320 pt card in the flat row: who
  asked, the amount large, the memo, and Pay; then Paying, Paid, or Expired.
  A request whose invoice pays someone other than the person asking says so
  in amber above Pay.
- **Paid attachments:** someone else's, before buying, is a 320 pt card with
  a soft blurred veil (never the picture: nothing is fetched or decrypted
  first, and messages carry no preview), a lock, "Paid photo" (or video,
  file, message), the price and Unlock; then "Unlocking: waiting for Bob to
  send the key"; then the normal image or file. A refusal reads that the
  sats came back. Your own shows the attachment as usual with "For sale at
  200 sats · bought once" under it. Files waiting in the composer have a
  price field beside them ("Free" when empty).

**Built 2026-10-07 (branch `phase4/payments`).** Details, what was verified
and what was not in `../phases/04-money.md`.
