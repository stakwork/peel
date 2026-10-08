# Peel design

Last updated 2026-10-08. The target layout and visual language for the Mac app.
Most of it is built: the sidebar, flat message rows, tribes, replies and
threads, attachments, Peel's menu, the Payments screen, the call card
and header call button (boards C1 and C2), and the call window, the
on-a-call bar and the switch confirm (C3 to C5), with screen share, click to
focus and keep on top, and call notifications. Not built yet: the gaps each section's notes list. The phase files say what is left. The source mock lives on the canvas "Peel layout directions"
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
   receive screen from the v1 scope lives here. Sats received while it is
   not open show as "+350" (the sum, in the green of received amounts) in
   the row's badge slot until it opens; the new rows then light once.
6. **Tribes.** One row per tribe, led by the tribe's image or its initial on
   its own colour, both on a rounded square (people are round). Unread
   tribes are bold. Ends with "Join a tribe". The section collapses.
7. **Direct messages.** One row per contact, unread ones bold with a count.
   Ends with "Add contact". The section collapses.
(The footer with your name and the Peel logo in the header are gone since
S2; the app's icon still shows on the lock and welcome screens.)

No tabs and no filter chips. Sorting inside each section: most recent first.

### Conversation (flexible)

- **Header.** The tribe's icon and name (or the contact's), member count and
  description for a tribe, and three icon buttons: call, pinned messages,
  members.
- **Messages are flat rows** (Tom, 2026-10-07, readability option D, "try
  it out"; they replace the bubbles chosen earlier that day). No bubbles:
  the text sits on the background. Each run (one sender, a new run after
  five minutes, a new day, or anything that is not a message) starts with
  a 32 pt photo, the sender's name (13 semibold, in their colour) and the time
  (12, secondary) once; the rest of the run sits under it, each message's
  time in the left gutter on hover, level with its first line. Runs are
  12 pt apart; the messages inside one are 5 pt apart, more than the 3 pt
  between a message's own lines (Tom, 2026-10-08: in #hive two messages
  in a run read as one wrapped message). Your messages are left-aligned too, on a
  faint accent tint, with the green delivered bolt beside the time. Body
  text 14 pt with 3 pt line spacing (about 1.45), at most 560 pt wide
  (about 68 characters). Mentions are a soft chip (medium weight); links are
  in the link colour, without the scheme and shortened in the middle when
  long; lines starting with "-" or "•" are a list with a hanging indent;
  `code` is monospaced on a soft fill, without its backticks, and ```
  fences are a code block.
  Quotes, attachments, thread summaries, Retry and the deleted placeholder
  sit in the row. Hovering lights the row and shows Reply, Boost (others'
  messages) and More at its top-right, over its top edge, as in Slack. Joins and leaves are a quiet
  centred line ("carol joined").
- **Day dividers** ("Today", "Yesterday", then dates).
- **New messages divider**: a blue line with "New messages" (12 semibold,
  accent) on the right, above the first incoming message that was unread
  when the chat was opened. The chat opens scrolled to it; it stays until
  you change chats or send.
- **Following the newest.** Sending always scrolls to the newest. Someone
  else's message is followed only when you are at the bottom; scrolled up,
  you stay put and a blue "N new messages" pill with a down arrow sits at
  the bottom-right (a round arrow when far up with nothing new). Clicking
  it, End or Command-Down goes to the newest and clears it.
- **Boosts** show as a chip under the message, as the official Mac app
  draws them (`NewMessageBoostView`): Sphinx's orange bolt (`attention`,
  every chip, yours too; faded to half while your boost waits for the
  server; Tom, 2026-10-08: orange, never grey), the total ("1,210
  sats"), then the first three boosters' photos overlapping (one
  per person in the order they boosted) and "+N" for the other people
  (Tom, 2026-10-07). Quiet, like Slack's reactions (Tom, 2026-10-08: the
  chip shouted louder than the message): 11 pt text, 16 pt photos (their
  initial on their colour when there is no photo), about 20 pt
  tall, on the soft `quote` fill inside a divider hairline (so it keeps
  its edge on your tinted rows), firmer under the pointer. One of yours
  among them, once the server has it, tints the chip faintly
  (`boostMineFill`, the accent at 12%, with a faint accent hairline) and
  puts the total in the accent tuned for 4.5:1 (`boostMineText`); no
  bright border and no orange fill. Clicking
  it opens who boosted (avatars, names, amounts). There is no "+" chip: the bolt in the hover bar (Reply, Boost,
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
| Mention of you or @all | `#F2C744` at 22% behind `#FFE08A` | `#FBE7A6` behind `#5C4300` | — |
| Names and initials | per person, see below | per person | — |
| Money bolt (payment rows, Send sats, boost chips) | `#FFBC58` | `#A86400` | SphinxOrange, deeper in light |
| Boost chip | `quote` fill; yours `#1E2B41` behind `#8FB0FF` | `quote` fill; yours `#ECF1FF` behind `#1E3D99` | — |
| Online dot | `#49C998` | `#49C998` | PrimaryGreen |

Three deliberate departures from the Sphinx values, all for contrast (text
needs 4.5:1, icons 3:1):

- Secondary text in dark mode is `#97A3B4`; Sphinx's `#6B7A8D` is too faint on
  navy.
- Filled buttons in light mode are `#3F68E0`; white text on `#618AFF` is too
  faint.
- Orange in light mode is a deeper amber, `#A86400` (Tom, 2026-10-08):
  `#FFBC58` is about 1.5:1 on the light chip fills and payment rows; the
  amber is over 3:1 on every light fill it sits on and 4.5:1 on white.

Colour is state, never decoration (Tom's `tom-ui` rules): blue marks unread,
selected and actionable; red only for destructive or blocking moments.

### Colour (direction D)

Approved by Tom on 2026-10-08 (boards K4, K5 and K5b on the canvas). Each
person has a colour on their initials avatar and their name, so a run, a
quote or a booster reads at a glance. Eight hues, no blues (links,
mentions, unread) and no ambers (money, the @you chip):

| Hue | Name, dark | Name, light | Avatar fill, both themes |
|---|---|---|---|
| coral | `#FF9079` | `#A83825` | `#BA4A36` |
| lime | `#A2C854` | `#507000` | `#587900` |
| green | `#6AD18A` | `#007938` | `#007F3D` |
| teal | `#55CEC0` | `#00776B` | `#007C70` |
| cyan | `#57C8E6` | `#00718D` | `#007893` |
| violet | `#BAA4FF` | `#674EB0` | `#765DC1` |
| orchid | `#E196F3` | `#874197` | `#9951A9` |
| pink | `#FF8CBC` | `#A13567` | `#B44778` |

- **Which hue:** FNV-1a (32-bit) over the official apps' colour key, mod 8
  (`PersonHue` in PeelCore). The key is `<alias>-color` for a tribe
  member and `<pubkey>-color` for a contact and for you, everywhere, as
  sphinx-mac-v2 keys it (`ChatHelper.getSenderColorFor`). A synced
  `chat_color` can later map to its nearest hue in `PersonHue(colourKey:)`;
  nothing is synced yet. The app asks only `AppModel.myHue` and `hue(…)`.
- **Where:** run headers and their avatars, quotes and the reply bar,
  thread cards and participants, boost chips and the boosters panel, the
  members panel and @ suggestions, the Mentions list, the image viewer,
  sidebar direct messages and you at the top, the Account photo, and the
  Payments counterpart (list, detail, quoted message). A tribe without an
  image takes its initial on the same palette, keyed by the tribe's key,
  on its rounded square. Photos stay photos;
  only initials get the fill (white, at every size down to 16 pt; a
  person's two letters for two words from 18 pt, a tribe's always one).
  Notifications carry no avatars.
- **A mention of you, or @all,** is a gold chip (semibold):
  `mentionYouFill` / `mentionYouText`, `#FBE7A6` behind `#5C4300` in
  light, and in dark `#F2C744` at 22% behind `#FFE08A` (final, Tom,
  2026-10-08). No row tint and no left bar. "You" is what the mention
  scan reads: your name as tribes get it, or the aliases the tribe echoed
  back on your messages, which the engine keeps (`Engine.echoedOwnAliases`,
  `ownMentionAliases`). @all is gold too but,
  as before, is not counted in Mentions.
- **Unchanged:** other mentions stay the blue chip; boosts, money, the
  balance, badges, the New messages line, "N replies", the jump pill and
  your rows' tint keep their colours.

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

### Sats received

Built 2026-10-08 (`MoneyArrivals.swift`); Tom's feedback on the first
build: nothing in the header may move or wrap.

- **Header balance:** rolls up digit by digit (`numericText`, about 0.7 s,
  tabular figures) only when a received payment explains the rise; the
  line keeps the larger number's width from the start, so nothing
  jiggles. The connection bolt glows green for a moment. A first balance,
  a restore, a fall, or sats no payment explains just change.
- **Payments row:** "+350" in the badge slot, green text on a soft green
  capsule, popping in with a 0.3 s scale and fade (no overshoot), rolling
  to "+420" as more comes, cleared when Payments opens; the matching rows
  light green and fade over 1.5 s, as a jump to a message does.
- Payments within 0.7 s of each other (up to 3 s) are one arrival: one
  roll, one notification ("+350 sats · 3 payments").
- **Reduce Motion:** no roll and no pop; the number and the badge just
  appear.

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
  the icon becomes a check and the title "Copied" (a spring of about
  180 ms, no overshoot, scale and fade; leaving in 140 ms), held 1.5 s; another
  click starts the wait again. Both labels are laid out at once, so the button
  never changes width. Reduce Motion keeps only the cross-fade. The check is
  green on a bordered or plain button; on a filled one (`GhostButtonStyle(prominent:)`,
  `PrimaryButtonStyle`) it takes the button's own text colour, since green
  on the blue fill clashes (Tom, 2026-10-08). The filled styles say so
  through `\.filledButton`.
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

### A button while it works

The spinner goes inside the button that was clicked, in its label's place,
never beside it (Tom, 2026-10-08: "we've discussed before this shouldn't
happen"; the onboarding Next button did this first). The label stays laid
out, hidden, so the button keeps its width and nothing next to it moves.
Use `Text("Save").buttonProgress(working)` as the label (in
`ButtonStyles.swift`, with the button styles; `size: .mini` for the
small text buttons of a row); on a filled button the spinner is drawn light
against the fill. It needs a style SwiftUI draws (`GhostButtonStyle`,
`PrimaryButtonStyle`, `.plain`), so the popover forms' commit buttons (Look
up, Join, Add, Create) are `GhostButtonStyle(prominent: true)` like the
payment forms', and so are the buttons of an inline confirm (Delete,
Leave, Remove from Peel; a member's Remove stays `.plain`, with the mini
spinner). Where one row has several buttons
that run (Approve and Decline, Remove photo and Save), only the clicked one
spins; the others are off. A spinner that stands for a status rather than a
click (restore progress, "Asking the tribes server…", "Paying…", a PIN being
checked under its field) stays where it is.

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
- **Videos** are sized like an image: the poster frame (a second in) with a
  play button and the length; a plain tile with a camera until the frame
  is ready. Up to 25 MB they download as they show; a larger one is a tile
  with "Video · 38.3 MB" and Load. A click plays it in place with AVKit's
  controls (play, pause, scrub, volume); one plays at a time, and it pauses
  when its row scrolls away or the chat changes. The corner button (on
  hover) or a double-click opens it in the image viewer, which carries on
  where the row was, with Download (then Show in Finder) and Save as…;
  Space plays and pauses, Escape closes and pauses. Nothing plays by itself.
- **Audio** is a 300 pt card: a round play button, a scrubber and
  "0:12 / 1:05". The same 25 MB rule; a larger one loads on its first play.
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
  the banking apps: received "+500" in green, sent "−2,000" in the text
  colour with a true minus (U+2212; Tom, 2026-10-08, replacing
  "no minus"), the same in the detail's large amount; no arrows; the header
  says "Amounts in sats".
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
  in amber above Pay; an invoice their server or ours made for them (as
  `request_invoice` requests are) pays them.
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

## Web pane

A link opens beside the chat, like the artifact pane in the Claude desktop
app (decided 2026-10-08; the decisions and what is left out are in
`../phases/05-parity.md`, "Web window"). Code: `Sources/PeelApp/WebPane.swift`,
with what may open in `Sources/PeelCore/WebPage.swift`.

- **Where:** right of the detail column, 560 pt at first, dragged on its
  divider between 360 pt and what leaves the column 400 pt (remembered on
  this Mac; double-click for the standard width). On a window too narrow for
  both, the pane takes the column's place rather than covering it. It stays
  open across chats, threads and Payments until closed: the toolbar's close
  button, or ⌘W while the page has the keyboard (⌘W elsewhere still closes
  the window). Locking Peel closes it, media and all.
- **One page.** The next link replaces it; no tabs. `target=_blank` and
  `window.open` load in the same pane.
- **Toolbar** (60 pt, the chat header's height and rule): back, forward,
  reload (a cross while loading); then the host in 14 pt semibold, as the
  address names it (an international name in its `xn--` form), with the
  page's own title under it in 12 pt secondary. The host comes first so a
  page cannot pass itself off as another; the title is the page's to choose.
  A small lock before the host for https with nothing insecure on the page,
  otherwise "Not secure" in amber (attention, not red: nothing is broken).
  The host changes when the next page arrives, not when it is asked for,
  so the address always names what is on screen. The full address is the
  tooltip. On the right: Open in Browser, Copy Link
  (the usual tick), and close. While loading, a 2 pt accent line grows along
  the toolbar's rule.
- **Which links:** every http and https link SwiftUI opens below the main
  window (message links, which message markup makes only for https, and
  the tribe header's buttons). ⌘-click sends one to the default browser
  instead, from a message or inside the pane. Any other scheme keeps the
  system's handling. An address with a user name or password
  (`https://google.com@evil.example`) never opens in the pane. Links in
  floating panels (menus, popovers) still go to the browser: those windows
  do not take the main window's environment.
- **A tribe's apps:** its `app_url` and `second_brain_url` from the
  registry become header buttons, a grid for the app and a brain for the
  second brain, before the call button; each only when present.
- **A failed load** shows "Couldn't open host", the system's reason and
  Try Again, centred on the pane's background.
- **Downloads** land in Downloads like a saved attachment (clean name,
  quarantined) and a bar at the pane's foot says "Saved name to Downloads"
  with Show in Finder; a failure says so in amber, never red.
- **Website data:** one store per profile, so a Google or YouTube sign-in
  sticks for this account only. Account › Security › Website data clears it
  with the usual inline confirm.

## Contacts

Built 2026-10-08 (`ContactsViews.swift`); details in
`../phases/05-parity.md`, "Contacts".

- **Direct messages ends** with pending invites (a dashed envelope ring,
  the nickname, the amount in the time column; "Sending…" or
  "Cancelling…" while they are), then "Add contact" and "Invite someone",
  each a popover beside its row.
- **Add contact:** one field (contact info, invite or Sphinx link), a
  dashed drop zone ("Drop a picture of their QR code here", Paste, Choose
  picture…; it lights blue while a drag is over the form), who the code adds
  (avatar, name or short key, and for an invite that its sats stay in it),
  an optional name, Add. Why a code adds nobody shows quietly in the
  footer, never red. No camera.
- **Invite someone:** amount (the shared sats field), nickname and message
  ("only you see it"), a line that the sats leave now and the server may
  keep a fee, the balance, and the money button: "Invite", then orange
  "Invite 2,000 sats" with "Click again to confirm", always.
- **An invite:** the QR tile (the Account screen's, shared), nickname,
  amount, when it was made and its state, the private message; Copy invite,
  Copy QR, Share; Cancel invite confirmed in place.
- **New contacts:** someone who added you shows "New" (accent capsule, the
  unread badge's shape) in their row until their chat is read; a
  notification says "Added you as a contact". There is no request to
  accept: the core accepts at once, as in the official apps.

## Time zones

Researched and designed 2026-10-08, second pass after Tom's review the same
day. Boards T1–T6 and T3a–T3c on the "Peel layout directions" canvas (row
"Time zones"). **Engine built** (plan steps 1–3, `Sources/PeelCore/TimeZones.swift`,
migration v14) and **the UI** (steps 4–5, `Sources/PeelApp/TimeZoneViews.swift`
and Account's "Time zone" group); sync (step 6) later. What was built and
where it differs from the plan: "Built (steps 1–3)" and "Built (steps 4–5)"
at the end of this section.

The official apps let each person share their time zone, and show the other
side's local time in a DM header and on tribe messages. Peel keeps their
wire format exactly and changes how the time shows: quietly, once per run
at most, never as a second timestamp on every message.

### What the official apps do (checked 2026-10-08)

Mac from the local `sphinx-mac-v2` checkout (14 commits behind
`origin/master`, none touching time zones; paths below are under
`com.stakwork.sphinx.desktop/`). iOS and Android from `origin/master` of
`stakwork/sphinx-ios-v2` (54e2e98) and `stakwork/sphinx-android-v2`.

**On the wire.** The time zone rides inside each message's JSON, in a field
`metadata` whose value is itself a JSON *string*:

```json
{"content":"hi","metadata":"{\"tz\":\"GMT+1\"}"}
```

- The core declares `metadata: Option<String>`
  (`sphinx/sphinx/src/msg/mod.rs:211`), so an object there makes `send`
  fail to parse. Nothing in the core (`sphinx/src/bindings` included) reads
  it; it is carried as is, through tribes too. There is no time zone on
  contacts, in contact info, in invites or in the core's state.
- The value is a **GMT offset at the moment of sending**, not an IANA name:
  `GMT+1`, `GMT-5`, `GMT+5:30`, `GMT+0` (`Extensions/TimeZone.swift:12`,
  `gmtOffsetAbbreviation()`, from `secondsFromGMT(for: Date())`, so summer
  time is included). iOS is the same (`sphinx/Extensions/TimeZone.swift`).
  Android uses `rawOffset` (`wrapper_common/DateTime.kt`, `getGmtOffset`),
  which ignores summer time: an Android phone in London sends `GMT+0` in
  July.
- Built in `Chat.getMetaDataJsonStringValue`
  (`CoreData/Chat/Chat+CoreDataClass.swift:1273-1290`; iOS 1282-1298) and
  added by `formatMsg` to whatever it formats
  (`Crypter/SphinxOnionManager/SphinxOnionManager+ChatExtension.swift:123`).
- **When it is sent.** Mac and iOS send it when the chat's switch is on and
  the zone changed since the last send (`timezoneEnabled &&
  timezoneUpdated`), *or* when `forceIncludeTimezone` is set
  (`Chat+CoreDataClass.swift:1278`). That is true when none of your loaded
  messages in the chat carries a time zone
  (`NewChatTableDataSource+ResultsControllerExtension.swift:1095-1098`,
  passed at `NewChatViewModel+SendMessageExtension.swift:72`). Your own DM
  messages never get one (`SphinxOnionManager+ChatExtension.swift:603-605`
  sets it only in public tribes, 1521-1527 only on the chat for others'), so
  **in a DM Mac and iOS send it on every message, and the force skips the
  share switch**: turning sharing off in a DM does not stop it. In a tribe
  the same force applies whenever your loaded messages lack one. Android
  sends only when enabled and changed (`SphinxRepository.kt`, the
  `metadata` in the send path, about line 5944): once per change.
- A change of the computer's zone marks every automatic chat as changed, so
  the next message carries the new offset (`Chat.processTimezoneChanges`,
  `Chat+CoreDataClass.swift:1175-1198`).
- **Receiving.** `metadata.tz` is parsed into `GenericIncomingMessage.tz`
  (`SphinxOnionManager+StructsAndHelpersExtension.swift:266-275`). In a DM
  it is stored on the chat (`chat.remoteTimezoneIdentifier`, the latest
  wins); in a tribe on each message (`message.remoteTimezoneIdentifier`)
  (`SphinxOnionManager+ChatExtension.swift:1521-1527`). Per member, by
  alias: the latest value among the loaded messages of the last three
  months (`Chat+CoreDataClass.swift:477-545`), and for anyone without one
  the newest stored value of any age
  (`TransactionMessageQueriesExtension.swift:941-975`). Android splits it the
  same way (`SphinxRepository.kt`, about lines 3240 and 3310).
- Readers accept an offset or an IANA name:
  `TimeZone(abbreviation:) ?? TimeZone(identifier:)` on Mac and iOS,
  `TimeZone.getTimeZone` on Android (`DateTime.getLocalTimeFor`). Checked
  with Foundation on this Mac: `GMT+1`, `GMT+5:30` and `Europe/London` all
  resolve. Nothing is ever sent to say "stopped sharing": a receiver keeps
  the last value for good.

**Setting it.** Per chat, not per account: a contact's or tribe's details
have a "share time zone" switch and a zone picker whose first entry is "Use
Computer Settings" (`Scenes/Contacts/Custom View/TimezoneSharingView.swift:38`,
then `TimeZone.knownTimeZoneIdentifiers`). Default on and automatic
(`timezoneEnabled` defaults to `YES` in the Core Data model, and the
one-time migration `Chat.resetTimezones`,
`Chat+CoreDataClass.swift:1200-1209`, turned it on for every chat). The choice is
synced between your devices through the encrypted preferences file on the
memes server (`DataSyncManager.saveTimezoneFor`, key `timezone`, identifier
the chat's pubkey, value `{"timezone_enabled":"true","timezone_identifier":""}`,
`Managers/Data Sync Manager/DataSyncModels.swift:55-59`; uploaded to
`/preferences`, `API/API+AttachmentsExtension.swift:308`; read back at
258). Profile shows the
computer's zone, read-only (`Scenes/Profile/View Controllers/ProfileViewController.swift:438-445`).

**Showing it.**

- DM header: their time now and the zone's abbreviation, "02:05 PM GMT+1",
  set when the chat opens (`Scenes/Dashboard/Chat/Custom Views/Chat View/ChatHeaderView.swift:264-279`).
- Every message in a tribe: "02:05 PM  /  03:05 PM GMT+2" in the row's
  header (`MessageTableCellState.swift:210-225`,
  `StatusHeaderView.swift:119-126`), and on a thread's original message
  (`MessageTableCellState.swift:893-908`).
- The tribe member list shows each member's raw value, "GMT+1"
  (`GroupContactListItem.swift:73-75`).

**What Peel does today.** Nothing: `Engine.sendText` and the other senders
build bodies without `metadata` (`Sources/PeelCore/Engine.swift:698`), and
`BodyFields` does not read it (`Sources/PeelCore/Message.swift:294`). The
raw body of every incoming message is kept (the `body` column), so the time
zones already received can be recovered from history.

### Decision (Tom, 2026-10-08)

Boards T1, T2, T3a, T4 and T6. Tom's review of the first boards: T1 yes
without the late-hours hint (dropped); the local time and offset in the DM
header and at the top of the profile; T2 and T4 yes; the sender's local
time on each run, but not T3's chip. Then his answers to the open
questions, the same day:

1. **Sharing is on by default** in direct messages and private tribes,
   as in the official apps (reversed by Tom on 2026-10-08: "match
   Sphinx"; it was first decided off, since sharing says where you are).
   A chat with no `chatTimeZone` row shares; turning a chat's switch off
   writes its row with `enabled` false. Public tribes are unchanged:
   never, and no switch.
2. **Public tribes: never shared**, whatever the switch says, and they get
   no switch. A tribe is public unless it is private (`Tribe.isPrivate`,
   stored per tribe, `Storage+Migrations.swift:88`, set from the tribes server's
   `private` field, `Tribe.swift:290`; Sphinx's "private" means the owner
   approves each member). An unlisted tribe that anyone with the link can
   join is public; Peel does not store `unlisted` and does not need it.
   **Decided by the stored record, not asked at each send** (Tom,
   2026-10-08: "sends must stay instant and in order"; his rule is only
   "never in public tribes"). The first build asked the tribe's registry
   before every send to a private tribe, which with sharing on by default
   made every such send wait a round trip (up to 30–60 s on a registry
   that hangs) and let two quick messages go out of order. Now a send reads
   `Tribe.isPrivate` as stored, and a tribe its owner makes public stops
   receiving the offset once Peel has refreshed its record (Privacy, below).
3. **One switch per chat, as the official apps have it:** each DM and each
   private tribe has its own "Share my time zone" switch in that chat's info,
   on by default (T6). The zone itself (automatic or chosen) is set once,
   in Account (T4). Stored per chat on this Mac now; synced with the official
   apps through the `/preferences` file later (plan step 6).
4. **Sent on every message** in a chat where the switch is on.
5. **You still see their time** when yours is hidden.
6. **T3a:** the sender's local time on each run, always visible.
7. **Word form, not glyph** (Tom, 2026-10-08, reversing the first answer of
   a clock glyph and "14:05"): the run label reads "14:05 local"; its
   accessibility label and tooltip keep the full words ("14:05 local time
   for Lena Okafor"). No glyph in the DM header either.
8. Reporting the official apps' DM switch bug upstream is still open.

What that gives:

- **DM header and profile top, one line** (T1). Under the contact's name,
  in secondary text: "02:14 local time · 6 h ahead", no clock. The same
  line sits under the name at the top of the contact's profile. Only when
  their offset differs from yours. It moves on with the minute. The words
  stay here, unlike the run label: the line carries the offset as well and
  has the room.
- **Hover card** (T2): photo, name, short key, then a clock and "**14:05**
  local time · 6 h behind", with the offset they sent under it.
- **The sender's local time on each run** (T3a). In the run header, after
  your time: "Lena Okafor  20:05 · 14:05 local" (word form, decision 7).
  Rules:
  - the run header only, never on a continuation message;
  - only when the sender's offset differs from yours; your own runs never;
    anyone who sends no offset never;
  - always visible, in a tertiary colour, `#808D9E` (5:1 on the
    conversation background, 4.7:1 on the thread panel), 12 pt, tabular
    figures, so the times do not jitter run to run;
  - the accessibility label is "14:05 local time for Lena Okafor", and
    hovering the label shows a tooltip with the words and the offset
    ("00:37 local time for Priya Nair · GMT+5:30");
  - the time *they had when they wrote it*: the offset on the run's first
    message, else their latest one if it is within 90 days of that message,
    else nothing;
  - in DMs as well as tribes, public ones included: what others send is
    shown wherever it arrives; only what *you* send is limited;
  - narrow widths (the thread panel, 360 pt, or a narrow window): the label
    stays while the header fits on one line; when it would wrap it drops
    out, and the tooltip and hover card still carry it.
- **No second timestamp on messages.** Hovering any message's time shows
  a tooltip with both: "20:02 your time · 02:02 for Evan".
- **The per-chat switch** (T6), in the chat's info panel, under the
  contact's or tribe's name: "Share my time zone with Evan" (in a tribe:
  "with #Name"), on unless turned off; under it "Sends your offset, GMT+1, with each message
  you send here. Turning it off stops sending; Evan keeps the last one you
  sent." A public tribe's panel has no switch, only the line "Your time zone
  is never sent in public tribes."
- **Account › Time zone** (T4): "Time zone: Automatic · Europe/London
  (GMT+1)", or one chosen from a searchable Peel menu, and "Shared in",
  which counts the chats you share with ("12 chats · as GMT+1" or "No
  chats"): every direct message and private tribe except those turned
  off, with "Never in public tribes" in its note.
- **No account-wide "new chats share" setting.** Every new chat shares,
  as in the official apps, whose file has no such key, so it would never
  sync. Turning it off per chat is one click in the chat's info.
- **When they don't share,** or nothing has come for 90 days: nothing at
  all, no "unknown" anywhere. The hover card leaves the line out.

**Always visible or on hover?** Always visible (T3a), for four reasons:

1. The point is noticing what you were not looking for: that Priya wrote at
   00:37, so her "before I sleep" is tonight, not tomorrow. On hover you
   only learn it if you already suspected it.
2. Hover already exists: the tooltip on every message time (T1) and the
   hover card (T2). A third hover would repeat them.
3. Hover is invisible to keyboard and VoiceOver users unless built twice,
   and a trackpad hover over a scrolling list flickers.
4. It is cheap where it is shown: one quiet run header, and in a busy
   global tribe the runs that carry it are exactly the ones whose senders
   are elsewhere. A tribe of one city shows nothing at all.

Kept on the canvas, not chosen: **T3b** (on hover only; fails reasons 1 to
3), **T3c** (the first run of the day per sender; a missing label then
means nothing), **T3** (the first, outlined chip, which read as a control),
and the hover card alone. Board T5 shows the edge cases: a contact who
shares nothing and an agent. The late-hours hint is dropped.

### Stored per chat, in the file's shape

So that sync can slot in without changing what anything means, Peel keeps
one row per chat with exactly the fields of the official apps' `timezone`
item (`DataSyncModels.swift:55-59`, `TimezoneSetting` at 435-459):

| Peel column | File field | Meaning |
|---|---|---|
| `chat` (primary key) | item `identifier` | the contact's or tribe's pubkey |
| `enabled` | `timezone_enabled` ("true"/"false") | share in this chat; no row means on |
| `identifier` (null) | `timezone_identifier` ("" when null) | a zone for this chat only; null means "the account's zone" |
| `updatedAt` (seconds) | item `date` | for last-writer-wins |

Peel's UI only ever writes `enabled` and leaves `identifier` null, so the
chat uses the zone from Account. A zone set for one chat on the phone
(the official apps allow it) is kept and used for that chat, and its info
panel says "Uses Asia/Bangkok, set on another device". The zone sent is
`identifier ?? account zone ?? this Mac's zone`. A public tribe's row is
kept if one arrives but never makes Peel send.

**No row means on**, as in the official apps: their chat's
`timezoneEnabled` defaults to `YES` in the Core Data model, a preferences
file with no `timezone` item for a chat leaves it there
(`DataSyncManager.restoreDataFrom`, `DataSyncManager.swift:332-338`, which
also keeps the chat's value when the item's value is unreadable), and
`TimezoneSharingView` writes an item only when the switch or zone changes
(`TimezoneSharingView.swift:115-136`). So Peel needs no migration and
writes no rows for chats nobody touched; turning a chat off writes
`enabled` false with `updatedAt` now, which maps onto the file's item
(`timezone_enabled` "false", `date` the same seconds).

### Conventions on the wire

- **Send** what the official apps send, `"metadata": "{\"tz\":\"GMT+1\"}"`:
  the offset of the chosen zone at the moment of sending, from
  `secondsFromGMT(for: now)` (summer time included, like Mac and iOS). Added
  in one place, `Engine.deliver`, to text messages and attachments
  (payment notes included) in a DM or private tribe whose switch is on,
  never in a public tribe; not to deletes, boosts or membership messages. On every such message, not only after a change, so a
  receiver always holds a current offset and a summer-time change never
  leaves them an hour out. About 25 bytes, which `wouldBeSplit` must count
  for payment notes. A retry re-sends the stored body, with the offset of
  the first try.
- **Never an IANA name.** All three apps would read one, but a city says
  more than an offset, and the offset is what they send.
- **Read** `metadata.tz` on any incoming message, with Peel's own small
  parser: `GMT`, `UTC`, `GMT±H` and `GMT±H:MM` (hours 0–14) as fixed
  offsets, and IANA names (a `/` in them) through
  `TimeZone(identifier:)`. Not `TimeZone(abbreviation:)` as Mac does: it
  also takes `EST` or `BST` and turns them into a city with summer time
  (`EST` comes out as America/New_York, at −4 in October), which nobody
  sends but would show wrong. Anything else, or a `metadata` that is not a
  string holding a JSON object, is ignored and never costs the message its
  other fields.
- **Keep** the latest value per sender with when it came: per contact in a
  DM, per member key in a tribe (the sender key Peel stores with each
  message; the official apps key by alias, which a member can change).
  Older than 90 days counts as unknown.

### Privacy

- An offset narrows where you are to a band of longitude, and together with
  when you write it says when you sleep. Peel shares it by default anyway,
  to match the official apps (decision 1): everyone you DM and every member
  of a private tribe you post in gets it until you turn that chat off. It
  is per chat, and never in public tribes. In a private tribe it goes to every member the
  owner has let in, and the tribe server reads tribe messages to forward
  them (it works out mentions from them, `sphinx/tribes/src/incoming.rs`),
  so its operator sees the offset too; the switch's note names the
  members and the tribe's server.
- **A private tribe made public** keeps getting the offset until Peel next
  reads its registry record (decision 2): a member learns of the change
  only there. The records are read on every connection (app start, wake,
  reconnect) and when a tribe is first seen; there is no timer, so on a Mac
  that stays connected the record can be hours old. A send that carries the
  offset to a private tribe whose last read record was asked for more than
  five minutes ago (`Engine.tribeRecheck`) reads it again in the
  background; the send itself goes by the record it has. So after an owner
  makes a tribe public, the messages that can still carry the offset are:
  any sent within five minutes of the last read, the first one after that
  (it starts the read), and any sent while the read is on its way (normally
  well under a second; at worst the request's 30–60 s timeout, after a full
  refresh already running). A registry
  that does not answer leaves the stored record as it is, and the next send
  asks again: unlike the first build, no answer is not "public".
- Turning sharing off cannot recall what was sent: the wire has no "off".
  The switch's note says so.
- The official Mac and iOS apps send the offset in DMs even with the chat's
  switch off (the `forceIncludeTimezone` path above), and they share in
  public tribes. Peel defaults to on as they do, but honours its switch on
  every message and never sends in a public tribe.
- Once synced (plan step 6), a switch turned on in the official app on the
  phone turns on in Peel too, but Peel still never sends in a public tribe.
- An agent's host often runs in UTC on a server. With sharing on by
  default an agent account sends its host's offset like any other account
  unless its owner gives it a zone or turns its chats off (open question 3).

### Agents

- The time zone is engine state, not view state: each `Engine` holds the
  per-chat switches and the chosen zone of its account (no `UserDefaults` global,
  so many accounts can live in one process) and exposes
  `localTime(of:)`: their offset, when it was seen, and the difference from
  yours. The hover card and an agent's tools call the same operation.
- An agent working for its owner can then say "It is 02:11 for Evan now.
  15:00 tomorrow in Evan's time is 09:00 for you. Shall I ask for that?"
  (board T5, Tweaks: Agent), later as a choice card, behind the same
  permission gate as sending.
- An agent's hover card shows a local time only if the agent sends one;
  with sharing on by default, one with no zone of its own sends its host's
  offset.

### Plan (after the cleanup)

1. Engine: parse `metadata.tz` into a new `senderTZ` column on `message`,
   with a migration that backfills it from stored bodies
   (`json_extract(json_extract(body, '$.metadata'), '$.tz')`, like the
   `threadUUID` backfill in `Storage.swift`, but only where
   `json_type(body, '$.metadata') = 'text'` and that text is itself valid
   JSON: `metadata` is whatever the sender wrote, and one malformed value
   must not fail the migration; the stored string then goes through the
   same parser as live messages), and queries for each message's offset and
   the latest per chat and sender within 90 days. Tests for the parser and
   the backfill.
2. Engine: a `chatTimeZone` table in the file's shape (above), with a
   migration; the account's zone (automatic or an IANA name) in the
   settings table; `Engine.setTimeZoneSharing(_:in:)` and
   `Engine.setTimeZone(_:)`. `deliver` adds `metadata` unless the chat's
   row says off, when the chat is a contact or a private tribe; `wouldBeSplit`
   counts it. Tests: public tribes never, private tribes and DMs unless
   turned off (first planned as off by default; see decision 1).
3. Verify on the local test server, then with the throwaway account against
   the official Mac app: Peel's offset shows in its DM header and on its
   tribe rows, the Mac's shows in Peel, and nothing reaches a public tribe.
4. App: the hover card (wanted for names anyway), the DM header and profile
   line, the glyph on run headers (with the one-line rule at narrow
   widths), the tooltips, and the per-chat switch in the chat's info (T6).
5. App: the "Time zone" group in Account (T4) with the searchable zone menu
   and the "Others see" summary. CLI: `whoami` prints the zone; `contacts`
   prints each contact's local time and whether you share with them.
6. **Later, with the preferences layer** (see `../phases/05-parity.md`,
   "Settings sync between devices"): read and write the official apps'
   `/preferences` file so each chat's switch round-trips with the phone.
   What it needs: the file's JSON format (the `timezone` item: identifier
   the chat's pubkey, value `timezone_enabled` and `timezone_identifier`);
   RNCryptor v3 with the account's node secret key as the password (Peel
   already has RNCryptor for attachments); and a memes-server token, which
   Peel already gets for media. The whole file has to be merged and
   uploaded back, since it carries the other settings too.

### Built (steps 1–3, 2026-10-08)

- **Wire.** `Engine.deliver` sets `metadata` to `{"tz":"GMT+1"}` in what it
  hands the core, from `offsetShared(in:type:)`, for text, attachments and
  payments (`TimeZoneOffset.carriedBy`) unless the chat's row says off (no
  row is on) and when the chat is a person the core holds or a tribe stored
  as private. Nothing is asked over the network on the way out, so a send is
  never held up and sends go in the order they were made. Taken out of the
  body otherwise. Payment requests (type 2) do not carry it; the plan named
  only text, attachments and payment notes.
- **Keeping the record fresh** (2026-10-08, replacing the first build's
  registry request before each send to a private tribe, decision 2).
  `refreshTribes` reads every joined tribe's record on each connection and
  when the core reports a new tribe. After a send that carried the offset
  to a tribe (so a private one), `deliver` calls `recheckIfStale`: when the
  tribe's last read record was asked for more than `tribeRecheck` (five
  minutes) ago in this session, it queues that tribe (`tribesToRecheck`)
  for the same background refresh, which then reads only the queued
  tribes; the send goes on without waiting. One refresh runs at a time, so
  answers are saved in the order they were asked for, and `disconnect`
  cancels it as before. `saveRecords` notes when each answer was asked for
  (`tribeReadAt`); a failed read notes nothing, so the next send queues it
  again. In memory only: a new session starts with the refresh on connect.
  A tribe the registry marks deleted keeps its stored flag (the current
  tribes server answers a deleted tribe with an error, so the flag is
  rarely seen); nobody is left there to read the offset but the tribe's
  server, which saw the tribe's messages before.
- **A payment note that fits only without the offset** goes without it,
  rather than the payment being refused as too long.
- **A retry follows the switch as it is now**, not the first try's offset as
  the conventions above said: the body is rewritten on the way out, so a
  message first sent while sharing was on, retried after it was turned off or
  after the tribe went public, goes without it. The stored row keeps the body
  it was first written with (an attachment's never has the offset); only the
  wire copy changes.
- **Reading.** `message.senderTZ` is a generated column (v14): the `tz` of a
  `metadata` string holding a JSON object, at most 64 characters, **as
  sent**, worked out from `body` by guards that run in order, so a
  malformed value gives NULL and stored history has it with no backfill. A
  delete empties the body and so clears it. `TimeZoneOffset.zone(_:)` parses
  it when read (`Message.senderTimeZone`). Zone names must contain `/` and
  only `A–Z a–z 0–9 / _ - +`, with no `..`, before `TimeZone(identifier:)`
  sees them (the system's `knownTimeZoneIdentifiers` is incomplete: it lacks
  `Asia/Kolkata`).
- **Per member, by alias**, not by key: a tribes server strips members' keys
  from what it forwards (`contact_pubkey`, `tribes/src/forward.rs`), so the
  sender key the conventions above mention does not exist on tribe messages.
  Aliases are unique within a tribe, as for mentions and deletes.
- **Storage (v14).** The generated `senderTZ` with a partial index on
  `(chat, timestamp) WHERE senderTZ IS NOT NULL AND fromMe = 0`;
  `chatTimeZone` (chat, enabled, identifier, updatedAt) as in the table
  above. The account's zone is `Setting.timeZone` ("" = automatic).
- **Engine API.** `setTimeZoneSharing(_:in:)` (refuses turning it on in a
  public tribe or for a key that is neither a contact nor a tribe),
  `timeZoneSharing(in:)` (the switch), `offsetShared(in:)` (what goes out
  there now, nil when off or in a public tribe), `setTimeZone(_:)`,
  `chosenTimeZone()`, `timeZone(for:)` (the chat's zone, else the account's,
  else this Mac's) and `localTime(of:member:at:)`: their zone, the value
  sent, when, and the difference from yours, from the newest readable offset
  within 90 days.
- **CLI.** `local-time <pubkey> [alias]`, `share-timezone <pubkey> [yes|no]`;
  `messages` shows `[tz …]` on rows that carry one.
- **Verified on the local stack** (two development profiles): nothing sent
  with the switch off; `GMT+5:30` (TZ=Asia/Kolkata) and `GMT+1` in a direct
  message and a payment note once on, parsed on the other side; turning it on
  in a public tribe refused, and (with the first build, which asked the
  registry at each send) a private tribe made public stopped getting it with
  the next message, the owner's and a member's alike; a private tribe carried both ways
  (`GMT+1`, `GMT-4`) through the tribes server; each side saw the other's
  local time with its own switch off. Not done: against the official Mac app
  with the throwaway account (step 3's second half).
- **The registry at send time, dropped** (2026-10-08, decision 2). The
  first build asked a private tribe's registry before every send, so a tribe
  made public stopped getting the offset with the very next message. With
  sharing on by default that held every send to a private tribe for one
  HTTPS round trip (30–60 s on a registry that hangs) and let a later
  message overtake an earlier one. The stored record and `recheckIfStale`
  replace it; the cost is the window under Privacy.
- **Existing installs** have no rows for chats nobody touched, so every
  such DM and private tribe starts sharing with its next message, as the
  reversed decision intends. The engine shipped in #47 the same day, with
  no switch in the UI yet. The default-on change's `/security-review` found
  nothing at confidence 8 or above: every send still goes through
  `offsetShared`, a tribe needs its stored flag (then also a fresh registry
  answer; since dropped, decision 2), and a key that is not a tribe needs a
  core contact, so no row meaning on cannot reach a public tribe or a
  stranger.
  `ChatTimeZone.identifier` and `updatedAt` stay although only sync
  (step 6) will write them: the table keeps the file's shape. A retry's
  stored row keeps its first body (above).
- **`/security-review`:** no finding at confidence 8 or above. Checked: every
  send goes through `offsetShared`, and `metadata` is set or removed (so a
  retry, an attachment or a payment never keeps an offset the rules no longer
  allow); a tribe needs its stored flag (and, until decision 2 changed, a
  fresh registry answer); new SQL is bound or constant; the v14 column's
  guards run in order. Hardened from a near-miss: a zone name may not start
  with `/`.
- **Reviews of the stored-record change** (2026-10-08). `/code-review`
  applied: a slow single-tribe read could save an old "private" over a
  newer "public", a cancelled or failed read held off the next one for five
  minutes, the recheck ran for sends that carried no offset, and the reads
  were not cancelled on disconnect. `/simplify` then folded the single-tribe
  read into `refreshTribes` (one refresh at a time, so answers save in order).
  Not applied: a deleted private tribe keeps its flag (Built, above); no
  offline guard on the recheck (an offline send is not published, and the
  refresh on reconnect reads every tribe); the first message after a quiet
  spell goes by the old record (the accepted window, Privacy).
  `/security-review`: no finding at confidence 8 or above. Checked: every
  `deliver` path (text, attachment, payment, boost, invoice, retry) goes
  through `offsetShared`, which needs a stored private tribe or a core
  contact, so a stored public tribe or a stranger never gets it; the
  refresh only reads stored tribes' own hosts; a missing `private` field
  stores public.

### Built (steps 4–5, 2026-10-08)

- **Run label** (T3a, word form): `RunHeader` shows "· 14:05 local" in
  `Theme.tertiaryText` (`#808D9E` dark, `#6B737C` light), 12 pt, tabular
  figures, from `ChatRow.senderZone`. `AppModel.withSenderZones` sets it once
  per rows rebuild: the run's first message's own offset, else one storage
  sender's newest earlier on the page, else one storage query for the
  page, one answer per sender at their first such run
  (`Storage.senderTimeZones`: the newest offset at or before it and within
  90 days, by alias in a tribe; the newest readable of its five newest),
  kept for the open chat (`senderZoneCache`) so a rebuild asks only for
  senders not asked yet. It runs on the main actor with the rows rebuild. The rest of a run take their own
  offset or the run's, for the time tooltip. Compared at the message's
  moment, so a summer-time change is right, with **this Mac's zone**, the one
  every time on screen is in: a zone chosen in Account is what you send, not
  what you see (the same for the DM header's "6 h ahead"). Dropped by a
  `ViewThatFits` when the header would not fit on one line.
- **Time tooltip:** a run header's time, and a continuation's gutter time,
  read "20:02 your time · 02:02 for Evan" when the offsets differ; otherwise
  the full date as before.
- **DM header and details** (T1): `DirectHeader`, a minute `TimelineView`
  over `localTimeLine`, refetched when a new message arrives. "The top of
  the profile" is the DM's details panel: the header's new info button
  (`ChatInfoPanel`, a `peelPopover`), photo, name, short key and the same
  line. Tribes get the same button.
- **Hover card** (T2): `PersonCard` on a run's name and avatar, in a third
  `FloatingWindow` of `MenuPresenter` that never takes the keyboard
  (`takesKey` false, `hide()`); it shows after 0.5 s at rest, moves
  between triggers in 0.15 s, goes 0.2 s after the pointer leaves the
  trigger and the card, and never over an open menu or panel (opening one
  hides it). Photo, name, a contact's short key, then "**14:05** local time
  · 6 h behind" (or "same as yours") and "GMT-5 · sent 2 min ago". Not on
  your own messages, nor a tribe member without an alias. No Message or
  Copy key buttons yet.
- **Per-chat switch** (T6), in the details panel: a switch "Share my time
  zone with Evan" (or "#Name"), on unless turned off, with the default-on
  note ("Sends your offset, GMT+1, with each message you send here[, to every
  member and the tribe's server]. Turning it off stops sending; Evan keeps
  the last one you sent."); "Uses Asia/Bangkok, set on another device." when
  the chat's row has its own zone. A public tribe: "Your time zone is never
  sent in public tribes." and no switch.
- **Account › Time zone** (T4): the zone (Automatic · this Mac's, or a chosen
  name) opening a searchable `ZonePicker` panel (a `peelPopover`, since the
  menu's keys would swallow typing); "Shared in" counts the chats
  `offsetShared` says go out ("2 chats · as GMT+1" or "No chats").
- **Verified** on the local stack with three development profiles (London,
  TZ=America/Chicago, TZ=Asia/Kolkata): run labels in a private tribe and a
  DM, the fallback for a message sent with sharing off, the thread panel,
  the hover card, the DM header, the details panel of a DM, a private and a
  public tribe, and Account with the picker open. Not driven by hand (no
  pointer events from the session): hover timing and the switch's click.
- **Review findings not applied** (kept to the UI and one storage query, as
  briefed): an engine operation for a chat's whole time zone status and for
  the "Shared in" count (the details panel makes four reads and Account
  loops `offsetShared` per chat); the page's sender zone query off the main
  actor; one notion of "yours" in PeelCore (`LocalTime.difference` is still
  against the account's zone, the app's against this Mac's); reusing the
  menu's private `MenuRow` and `TribeViews`' `ToggleLabel`; a layered
  dismiss path in `MenuPresenter` shared by menu, panel and card.
- **Not done here:** the CLI half of step 5 (`whoami` printing the zone,
  `contacts` with local times); agents (no agent flag exists yet, so "never
  on agents" has nothing to key on).

### Open questions for Tom

1. **Report the Mac and iOS DM switch bug upstream?** (Their switch does not
   stop the offset in DMs.)
2. **Private tribes:** the switch is offered there (decision 3). Should a
   private tribe's note name how many members will see it?
3. **Agents, now that sharing is on by default:** should an agent account
   (often on a UTC server) start with sharing off, or with no offset until
   its owner gives it a zone? Peel has no agent accounts yet; today one
   would share its host's offset.
