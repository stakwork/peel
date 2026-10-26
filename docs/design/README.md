# Peel design

Last updated 2026-10-08. The target layout and visual language for the Mac app.
Most of it is built: the sidebar, flat message rows, tribes, replies and
threads, attachments, Peel's menu, the Payments screen, the call card
and header call button (boards C1 and C2), and the call window, the
on-a-call bar and the switch confirm (C3 to C5), with screen share, click to
focus and keep on top, and call notifications. Not built yet: the gaps each section's notes list. The phase files say what is left. The source mock lives on the canvas "Peel layout directions"
(direction D); the screenshots below are taken from it.

The iPhone app's design is in [iphone.md](iphone.md).

![Dark theme](layout-dark.png)

![Light theme](layout-light.png)

## Decision

The layout follows Slack: tribes and direct messages in a sidebar, the
conversation in the middle, threads opening on the right. It replaces the
official app's tabbed chat list. Three other directions (a three-column mail
layout, a conversation with an inspector panel, an agent inbox home) were
mocked and rejected on 2026-10-07.

Colours and type are Sphinx's, because Peel is meant to replace the official
apps. The sidebar header is you (photo, name, balance), opening Account, since
option S2; the Peel logo shows only on the lock and welcome screens.

## Layout

Three regions, left to right. On a narrow window the thread panel closes first,
then the sidebar collapses; panels never overlay the conversation.

### Sidebar (260 pt)

Top to bottom:

1. **You, on top** (option S2, Tom, 2026-10-07). Your photo, your name,
   and the balance in sats under it. Clicking it opens the Account screen,
   as Account… (⌘,) does; no menu (Tom, 2026-10-12). On the right, Sphinx's connection
   bolt: green when connected, orange otherwise; clicking it shows the state,
   the retry countdown and the last connection error.
2. **Search.** One field over every conversation.
3. **Threads.** Threads you started or replied to that have new replies, with
   an unread count.
4. **Mentions.** Messages that mention you, across tribes. Its count
   takes in muted tribes' mentions too, so it agrees with the rows' gold
   counts; the Dock badge still leaves muted chats out.
5. **Payments.** Payment history: received, sent, boosts, invoices. The
   receive screen from the v1 scope lives here. Sats received while it is
   not open show as "+350" (the sum, in the green of received amounts) in
   the row's badge slot until it opens; the new rows then light once.
6. **Unread** (Tom, 2026-10-09: with 14 tribes and many DMs, a "1" on a
   DM below the fold was missed). Every chat with something unread, direct
   messages first, then tribes that mention you, then the other tribes,
   each newest first. A chat moves up into it while unread and leaves its
   own section. Muted chats stay out unless they mention you (then they
   count only those mentions, as a tribe set to mentions only does). The
   chat you open from it stays there until you open another, so it does
   not jump as it is read. While Peel is in the background nothing is
   marked read, so the open chat can move into Unread when a message
   arrives and back out when you return to it. No chevron, and no section at all when nothing
   is unread.
7. **Tribes.** The five most recent by last activity, then "Show all 14
   tribes" (every tribe, unread ones included; "Show fewer" once open).
   One row per tribe, led by the tribe's image or its initial on its own
   colour, both on a rounded square (people are round). Ends with "Join a
   tribe". The section collapses.
8. **Direct messages.** The five most recent, then "Show all 10 people".
   Ends with pending invites, "Add contact" and "Invite someone". The
   section collapses.

Tribes come before direct messages: Tom lives in tribes. Unread rows are
bold with a count, the count in the gold of a mention of you
(`mentionYouFill`) when they mention you; read rows are in the secondary
text colour. A direct message can show the gold count too, when a message
in it names you. The chat you have open always shows, in a trimmed or a
collapsed section alike. Each section's open or closed and shown-in-full
state is kept with the account (`Setting.sidebarLayout`, through
`Engine.sidebarLayout`), so it goes when the account is forgotten. The
search finds every chat, untrimmed, in closed sections too; while it is
on, the headers show no chevron, so a click cannot change the saved
layout. A header without a chevron (Unread, and every header while
searching) sits flush with the rows' icons; no room is kept for one. VoiceOver hears the headers as headings and "Show all 14 tribes" /
"Show fewer tribes". The sections are `ChatSections` in PeelCore. No
drag-and-drop ordering yet (later).

**Next unread:** Go › Next Unread Chat (⌥⇧↓) and Previous Unread Chat
(⌥⇧↑) open the next chat in Unread, going round, from anywhere in the
main window as ⌘F does (menu commands, guarded in the action by
`AppModel.takesCommands`, which ⌘F shares): only while the main window is
key, with no Peel menu or panel and no image viewer up, and not while
Peel is locked or due to lock. A menu key equivalent comes before any
view, so in every text field (the composer, the sidebar's search, a
chat's search, the forms) they open the next unread chat instead of the
text view's ⌥⇧↓ and ⌥⇧↑ (select to the paragraph's end or start), as in
Slack.
**Keys.** Clicking a row gives the sidebar the keyboard: Down and Up move a
soft highlight (the hover fill) through Apps and the apps under it,
Automations, Mentions, Payments, Threads (A–Z), then
the chats as shown (Unread, tribes, direct messages), skipping the section
headers, the "+" and "Show all" rows (reached by a click only), invites
and what a trimmed or collapsed section hides, and
stopping at the ends; it scrolls into view and VoiceOver reads
the row. Return opens the highlighted row as a click does, Escape clears it.
A chat opened this way leaves the cursor in the sidebar; typing (or ⌘V)
moves it to that chat's composer and the keys go there as typed, through
input methods and accents. Clicking the composer, a field or the web pane
ends it; the keys are never taken from a text field, a menu, a panel, the
image viewer or another window, nor while Peel is locked or due to lock. While the sidebar has focus Return never reaches
a pane's default button.
(The footer with your name and the Peel logo in the header are gone since
S2; the app's icon still shows on the lock and welcome screens.)

No tabs and no filter chips. Sorting inside each section: most recent first.
A chat opened another way (⌥⇧↓, a jump, a notification) scrolls into view
and the arrows go on from it.

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
  in the link colour, without the scheme, the host always whole and in its
  `xn--` form when international, and only the rest shortened in the middle
  when long; lines starting with "-" or "•" are a list with a hanging indent;
  `code` is monospaced on a soft fill, without its backticks, and ```
  fences are a code block.
  Quotes, attachments, thread summaries, Retry and the deleted placeholder
  sit in the row. Hovering lights the row and shows Reply, Boost (others'
  messages) and More at its top-right, over its top edge, as in Slack. Joins and leaves are a quiet
  centred line ("carol joined"). Someone who sent no name is "Someone"
  everywhere (rows, quotes, notes, mentions, notifications), with "?" as
  their initials: one owner, `Sender` (`People.sender(of:inTribe:)`, and
  `Sender(member:)` for a tribe member named by their own message).
  Payments and payment requests share the rows' chrome (`rowChrome`) and
  run header; cards in a chat are `Card(.inset)`.
- **Link cards:** the first tribe or contact link in a message gets a 320 pt
  card under the text, at one height whatever is known yet (lines
  reserved; soft bars while loading). A tribe: its image, name, two lines
  of description, then members, Private and the price to join, with Join
  (the Join form, filled in) or Open and "Joined" once a member; "Tribe on
  host" when it is listed elsewhere (never read from there) or could not
  be read (Try again); faded with no button once deleted. A contact: photo
  and name when already a contact (Open chat), else a quiet add glyph,
  "New contact", the short key and Add (the Add contact form, filled in).
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
- **Composer.** One rounded field ("Message #Tribe" or "Message Name")
  that holds everything (Tom, 2026-10-10: "the send button should be
  inside the input field"): the reply bar and the file tray at its top,
  the text, then a row under the text with the paperclip (and in a DM the
  bolt, which opens Send sats) at the left and a small send arrow at the
  right, not a "Send" button (Tom, 2026-10-07). The arrow is filled when
  there is something to send and muted otherwise. Attach, send sats and
  mention joined it with their phases; no control appears before it works.

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

Your own agent is one such contact; the workers behind it (Claude Code and
others) are not contacts. Its views (threads in the DM, approval cards,
Account › Agent) are in `agents.md`; the design is in
`../agent-architecture.md`.

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
  twelve words. "I've written them down" then asks for three of them, at
  random places, typed back; Peel opens once they match (finding N5,
  2026-10-11). A wrong word is named by its place, never shown.
- **The words checked** are a setting of the account (`wordsConfirmed`),
  never the words: set by that check, by the same check from Account's
  "Twelve words" row (after the PIN), or by a restore. Accounts from
  before it count as not checked.
  Forget on the lock screen says first that the account holds sats, when
  its last balance says so, and that without the words it and its sats
  cannot be brought back; otherwise "this account and any sats it holds".
  Never how many before the PIN, as a locked notification says only "Sats
  received", and never "no sats": the stored balance may be older than
  sats received since.
- **Restore:** twelve word fields (paste fills all twelve, suggestions as you
  type), a PIN, then a progress page: account, contacts, messages with a count,
  tribes. "Open Peel" works before history finishes. There is no name step:
  the name and photo come back from the account's own newest sent messages
  (contact chats), else stay empty until set in Profile.
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

## Words

Secondary text is the exception, not the default (Tom, 2026-10-13). A
label, its value and its control usually say enough; a helper line, a
switch's description, a header's subtitle or a caption under a row is
added only when someone would otherwise make a mistake: money moving or
held, something that cannot be undone, the twelve words, a state they
must act on, or an error. When one earns its place it is one short
sentence in everyday words: no "server", "offset", "Keychain", "macOS",
no edge cases, no account of how Peel works inside.

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
the panel together, the thread panel covers the chat, which stays as it
was under it. The panel slides in and out; the chat column changes width
once, never animated.

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
feedback"). Built in `Sources/PeelUI/CopyFeedback.swift` and `Sources/PeelApp/CopyButton.swift`; use it for any new
copy (the Payments screen's invoice and payment hash included), never a bare
`Clipboard.copy`:

- **A button:** `CopyButton("Copy invoice", text: invoice)`, or
  `CopyButton("Copy image") { model.copyImage(message) }` for anything else
  that copies (the closure returns whether it copied; no check when it did
  not). It takes the surrounding button style (`.peel(...)`);
  `iconOnly: true` draws the small hover icon button instead, with the title
  as its tooltip. `systemImage` defaults to `doc.on.doc`. After the click
  the icon becomes a check and the title "Copied" (a spring of about
  180 ms, no overshoot, scale and fade; leaving in 140 ms), held 1.5 s; another
  click starts the wait again. Both labels are laid out at once, so the button
  never changes width. Reduce Motion keeps only the cross-fade. The check is
  green on a bordered or plain button; on a filled one (`PeelButton`'s
  primary and destructive) it takes the button's own text colour, since green
  on the blue fill clashes (Tom, 2026-10-08). The filled variants say so
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
`UI/PeelButton.swift`, with the button style; `size: .mini` for the
small text buttons of a row); on a filled button the spinner is drawn light
against the fill. It needs a style SwiftUI draws (`PeelButton`, `.plain`),
so the popover forms' commit buttons (Look up, Join, Add, Create), the
payment forms' and the buttons of an inline confirm (Delete, Leave, Remove
from Peel) are `PeelButton`s; a member's Remove stays `.plain`, with the
mini spinner. Where one row has several buttons
that run (Approve and Decline, Remove photo and Save), only the clicked one
spins; the others are off. A spinner that stands for a status rather than a
click (restore progress, "Asking the tribes server…", "Paying…", a PIN being
checked under its field) stays where it is.

## Component library

The library lives in `Sources/PeelApp/UI/`, shadcn-style, built over
`Theme` alone. The review
[../reviews/2026-10-09-design-library.md](../reviews/2026-10-09-design-library.md)
inventories what was drawn by hand and planned the library in batches,
all fifteen now done (the tokens sweep, batch 14, last); its Progress
lists what was left for later. New UI uses the pieces that exist (`PeelButton`, `IconButton`, `Panel`,
`SectionHeader`, `Card`, `Callout`, `Badge`, `Chip`, `ListRow`, `FactList`, `EmptyState`, `FormKit`, `Controls`, `CopyButton`) and the tokens below, and adds no new variant.

Built so far:

- **Tokens** (batches 1 and 14, in `Theme.swift`). No layout number is
  written where a token says it:
  - `Theme.Radius`: `control` 7 (buttons, fields, a row's hover or
    selected fill, a menu's rows, the call window's name tags), `card` 9
    (every `Card` and `Callout`, file and audio cards, quotes and code
    blocks, pictures, a QR code's white tile, the call window's control
    bar), `panel` 12 (the popover, a menu, a hover card, a call tile).
    Chips, badges, the "Copied" pill and the jump button are capsules or
    circles. A box inside another takes the outer radius less the inset
    (the segmented choice's 5 inside its 7: `control - 2`).
  - `Theme.Space`: `xs` 4, `sm` 8, `md` 12, `lg` 16, `xl` 20, for padding
    and the gaps in stacks. Values off the grid (1–3, 5–7, 9, 10, 14, 18)
    stay as numbers where a layout was tuned by eye.
  - `Theme.AvatarSize`: `xs` 16 (inline, a thread's latest reply, the
    boost chip's faces), `sm` 20 (the sidebar's chats, search results,
    the composer's mentions, a fact's owner; the sidebar's icon column is
    this wide), `md` 24 (a panel's list:
    members, boosters; a call card's faces), `lg` 32 (beside a message, a
    header, Payments, Mentions, the Join and Add previews), `xl` 48 (the
    top of a details panel, a link card, a picture field in a form), `xxl`
    64 (your photo on the Account page). The call window's tiles size their
    own.
  - Type: the sizes are 10, 11, 12, 13, 14, 15, 16, 17 (a message's
    second heading), 20, 24 and 28 (no half points). `Text(…).muted()`
    (`Styles.swift`) is the muted line: 12 pt `secondaryText`, wrapping,
    for a note, a caption and the help under a control. A muted line held
    to one line (a row's detail, a preview) sets its own `lineLimit` and
    keeps the font and colour by hand.
  - Shadows: `popoverShadow` under a panel, `menuShadow` (black 25%)
    under a menu, a suggestion list and the jump button.
  - Words: counts go through `Formatting.count` ("1 member", "5
    replies", "99+ new messages"), times and dates through
    `Formatting.time` ("14:32"), `date` ("2 Oct 2026"), `dateAndTime`
    ("2 Oct, 14:32", the year when not this one), `moment` ("Monday 5 October 2026 at
    14:32:05", a payment's facts), `relative`, `when` and `expiry`.
  - `SettingDropdown` (`Controls.swift`): a setting chosen from a
    dropdown and saved at once, its help muted under it or what went
    wrong (the PIN timeout, notification text, payment confirmation).
- **Panel** (batches 4a and 4b). `Panel("Members", compact:, close:) { body } actions: { … } footer: { … }`
  in `UI/Panel.swift`, shadcn's `Card` in a popover, used by every
  popover: a 15 pt bold title, the panel's own actions and an
  `IconButton` close, the body, the footer. The actions may be left out,
  or the actions and the footer; a footer whose condition is false takes
  no room. 372 wide, or 320 with `compact` (a short form with no
  sections, or a short list); `fit` takes the content's own width.
  Radius `panel` 12 on `sidebar`, a `formEdge` hairline, `popoverShadow`
  on the box only (so the labels cast none). A click outside a field
  ends editing. It is the only box a popover has: the presenter adds
  none. `PanelHero` is the top of a details panel (the picture, the name
  in 16 bold, muted lines), shared by a contact's and a tribe's details.
  The placement rule:
  - A panel's own utility actions (the members panel's Copy link) go top
    right, beside the title, as icon buttons. Copy buttons that belong to
    a card in the body (a QR code's Copy link, Copy key) stay with it.
  - Navigation (Members, Edit tribe…) goes bottom left.
  - The commit (Save, Send, Join, Reconnect now) or the destructive
    action (Leave tribe, Remove contact…) goes bottom right, one of them,
    never both. A form with a commit keeps its destructive action as the
    last card of its body (Delete tribe).
  - Every panel has a title and a close button, the same box, and one of
    the two widths: 372 for the forms, Tribe details and a contact's
    Details; 320 for Join a tribe, Members, Boosts and the Account's
    Time zone. The connection card is the exception: it fits its one
    line, drops under the bolt and grows leftward (`PopoverEdge.trailing`),
    its right edge in line with the bolt's, so it stays within the sidebar
    and its small refresh button (10 in, as a header's close) sits under
    the click.
- **Section headers** (batch 10). `SectionHeader("Members")` in
  `UI/Section.swift`: 12 pt semibold in `secondaryText`, placed by its
  caller. Every heading over a group is one: a form's sections
  (`FormSection`), the Account's (`SettingsSection`), the Payments list's
  days, a panel's lists (Waiting for approval, Members, All time zones)
  and a label over a card's value (Public key). The sidebar's sections
  keep their own, 13 medium and collapsible.
- **Cards** (batch 10). `Card { … }` and `Card(.inset) { … }` in
  `UI/Card.swift`, shadcn's `Card`, at radius `Theme.Radius.card` 9;
  the content brings its own padding. `.raised` (the default) is `menu`
  with a `formEdge` hairline and `sectionShadow` in light: a switch row,
  `FormDestructiveSection`, the tribe's facts and share card, a contact's
  key, previews in Add contact, an invite and Join a tribe, the Account's
  sections and contact info, onboarding's restore rows. `.inset` is
  `quote` with a `divider` hairline, for cards in a chat: the call card,
  link cards, a payment request, a file or audio card, the sidebar's
  on-a-call bar.
  `menuBoxed` stays for menus, suggestion lists and the hover bar.
- **Callouts** (batch 10). `Callout` in `UI/Card.swift`, shadcn's
  `Alert`: an icon, the words, actions, and an optional dismiss, in a box
  at radius 9 with 12 by 10 of padding. The words are 12 pt
  `secondaryText` with monospaced digits, selectable: a bar's take three
  lines at most, or one with `oneLine` (cut in the middle, so a file name
  keeps its extension), and a note's wrap in full; a title above them
  is 13 semibold. With a title it is a note, its actions (a link) under
  the words; without one it is a bar, its actions and its ✕ (a `.sm`
  `IconButton`) at the end. Tones: `.neutral` (`panel`, `divider`; the
  icon carries any colour) and `.attention` (`attention` at 7% under a
  28% hairline, `.problem`'s icon by default: something blocks the next
  step, never red). Icons: `.problem` (amber `exclamationmark.circle`),
  `.progress` (the small spinner), `.symbol(name, colour)`.
  - A chat's notice and the window's: `Callout(detail:, icon: .problem, dismiss:)`.
  - A tribe you cannot post in: the words, the spinner while waiting,
    and Leave or Remove from Peel at the end.
  - Not enough sats and an expired invoice: `.attention` with a title
    and a link.
  - The web pane's download (under way, saved with Show in Finder, or
    failed): a bar in the strip along the pane's foot, under way and
    saved on one line.
- **Badges** (batch 11). `Badge("New")`, `Badge(count: 12)` in
  `UI/Badge.swift`, shadcn's `Badge`: a word or count in a circular
  capsule, 11 pt bold with monospaced digits, 6 by 1 of padding;
  `Badge.text` caps a count at "99+" (the jump pill's "N new messages"
  uses it too). Styles: `.default` (white on the accent: a sidebar row's
  unread count, "New" on a contact who added you), `.mention` (gold,
  `mentionYouText` on `mentionYouFill`: the row's chat mentions you;
  blue never does), `.success` (Payments' "+350", `confirmed` on 16% of
  it) and `.outline` (the day divider: 12 pt regular `secondaryText`
  inside a `divider` hairline, 10 by 2, no fill). The video's duration
  over its picture is not a badge and stays as it is.
- **Chips** (batch 11). `Chip` in `UI/Badge.swift`, shadcn's `Toggle` in
  a circular capsule: a fill and a hairline set by where it sits
  (`ChipStyle`, as `Card`'s are) and whether it is lit. `.field`, in a
  form or panel: `fieldFill` inside `inputBorder`, lit `selection` inside
  the accent at 60%. `.inset`, in a chat: `quote` inside `divider`, lit
  (yours) `boostMineFill` inside the accent at 25%. With an action it is
  a plain button whose hairline firms to `secondaryText` at 40% under the
  pointer. The label brings its own padding. `Chip("Bitcoin", selected:)`
  is a tribe's tag (12 medium, 24 tall, a tick while on) in the edit
  form, `Chip("Bitcoin")` the same shown in its details; a message's
  boosts are `Chip(.inset, lit: mine, action:)` around the bolt, the
  total and the faces.
- **List rows** (batch 12). `ListRow` in `UI/Rows.swift`, shadcn's
  `Item`: a start (avatar, tick), a title over an optional muted detail
  (13 pt `text` over 12 pt `secondaryText` unless the caller sets its
  own), and an end (a time, an amount, a row's own buttons; the end's
  text is `secondaryText` too); the title column takes what the end
  leaves and truncates, at least twice the spacing from the end. A time
  or an amount in the end is `.fixedSize()` so it never truncates; a
  row's buttons wrap first. On the selected fill the detail and the end
  are `selectionText` at 80%, the sidebar's pairing (`secondaryText`
  there is under 4.5:1). Sizes: `.sm` (8 apart, 8 by 4 of padding, 28
  tall at least: a time zone, a member, a booster; a search result 36)
  and `.md` (12 apart, 12 by 8: a payment, a mention). With an action it is a plain button: `hover` under the
  pointer and **`selection` when selected, the one selected fill** (the
  sidebar's, search results', a payment's), at radius 6; `tint` is a
  fill of the row's own when not selected (a payment just received,
  `confirmed` at 14%). Without an action it only lays out and never
  lights (members, boosters: their menu is a right click). A list of
  rows in a panel is outdented 8 so their text lines up with the
  panel's; its headings take the same 8 back. The sidebar's rows (its
  chats, Add contact, pending invites) keep `SidebarRowStyle`, 14 pt
  with their unread and keyboard states, on the same two fills; the
  menu's rows keep `MenuRow`.
- **Facts** (batch 12). `FactList { Fact("Owner") { … } }` in
  `UI/Rows.swift`, a description list on a `Card`: each `Fact` a muted
  13 pt name in a column (100 wide, 150 on the Account page with
  `labelWidth`), its value beside it and an optional action at the end
  (Edit, Copy), on the first line's baseline, 12 by 9 of padding, 36
  tall at least, a full-width hairline between facts. The action keeps
  its own width and the value wraps beside it; with under 96 left for
  the value, the action goes under it (`FactValueLayout`, one layout so
  an open confirm survives the move).
  `Fact("Amount", text: …, symbol:, tint:, monospaced:)` is a value in
  words, selectable and wrapping, with an icon; `tint` colours both
  (a payment's green Received, an invoice's amber Expired). Tribe
  details, a payment, Pay an invoice, a paid invoice in Receive and
  every Account section (`SettingsSection` is a `SectionHeader` over a
  `FactList`).
- **Empty states** (batch 13). `EmptyState("Threads you start or reply
  to show up here.")` in `UI/EmptyState.swift`, shadcn's `Empty`: what a
  screen, pane or list shows when it has nothing (or could not load it),
  centred in the room it is given. The words are `secondaryText`,
  centred and selectable (they may be a problem worth copying): 14 pt
  alone, or 13 under a `title` (15 semibold); actions go below, 10
  apart (the web pane's Try again, `.peel(.outline, size: .sm)`); 24 of
  padding. `.sm` is a list in a panel: 12 pt, 8 of padding (the
  Account's "No time zone matches."). The start screen ("Pick a
  conversation…", under the "Peel" header), Apps, Threads, Mentions, Payments
  and the web pane's failed page use it; a screen keeps its own
  `DetailHeader` above it.
- **Problem lines** (batch 7). Every failure the app shows goes through
  `PeelError.problem(error, couldNot:)` in `PeelCore`: the error's words
  as a sentence (a capital, unless the first word is a name such as a
  file name or host, and a full stop), after "Could not <action>." when
  the words alone would not say what failed: "Could not leave the
  tribe. The server could not be reached." A refusal under the button
  that caused it stands alone: "The balance is not enough for that." It
  takes words already in hand too (a reason a view was given, the
  engine's notices), and a sentence passes through unchanged. The colour
  is `secondaryText` or `attention`, never red. Never show
  `PeelError.readable` bare, and never write "Could not …: " by hand.
- **Composer** (batch 5). Its buttons sit inside the field: attach and
  the bolt are ghost `IconButton`s at the bottom left, send a `PeelButton`
  `.sm` square at the bottom right (`.primary`, or `.ghost` and disabled
  with nothing to send). Radius `Theme.Radius.control` plus the buttons'
  6 pt inset (13), `.continuous`, so its corners and theirs are concentric.
- **Keys** (batch 9). A key read before the views see it goes through a
  `KeyMonitor` (`PeelMenu.swift`) and names its code with `KeyCode`
  (`.escape`, `.return`, `.down`…), never a number. Escape has one
  written order, in `KeyMonitor`'s doc comment: a menu (its confirm, then
  its submenu, then the menu), a panel, the image viewer, the search bar
  while its field has the cursor, the sidebar's highlight, then the view
  with the keyboard (the composer's mention list, then its reply, then
  its thread; the web
  pane's address; the Payments pane; the call window's grid). Only the
  first that is open takes it, and the arrows and Return follow the same
  order. Monitors run in the order they started, not this one, so a new
  one defers to those above it itself (`MenuPresenter.takesKeys`: its
  own window, no menu or panel; `AppModel.viewer`). A ⌘ shortcut on a
  view (`.hiddenShortcut`: ⌘I, ⌥⌘A) works with the cursor in any text
  field, the composer included, as AppKit offers ⌘ keys to the window's
  views first; a key without ⌘ (End, the call window's Escape) reaches
  it only when the focused view does not take the key.

### Buttons (`PeelButton`)

shadcn's `Button`: one style with a variant and a size.

```swift
Button("Save") { … }.buttonStyle(.peel(.primary))
Button("Open") { … }.buttonStyle(.peel(.outline, size: .sm))
Button("Show in Finder") { … }.buttonStyle(.peel(.link))
Button("Pay") { … }.buttonStyle(.peel(.primary, fill: Theme.attention))   // armed
```

```
 primary    secondary   outline     ghost      destructive   link
[▓ Save ▓] [░ Copy ░]  [  Copy  ]   Copy      [▓ Leave ▓]   Show in Finder
```

| Variant | Looks | Use it for |
|---|---|---|
| `.primary` | `button` fill, `buttonText` | The one commit of a form or pane: Save, Send, Join, Create, Pay. One per footer. |
| `.secondary` | a quiet `hover` fill | A second action that should not read as the commit. |
| `.outline` | `fieldFill` with a 1 pt `inputBorder`, as the inputs | Everything else: Cancel, Done, Copy link, Members, Edit tribe…, Choose picture…, an inline confirm's trigger. The default choice. |
| `.ghost` | nothing until the pointer is over it | A quiet undo beside a commit (Revert). |
| `.destructive` | `destructive` fill | Only the second click of an in-place confirm (Delete, Leave, Remove). Never a first click. |
| `.link` | `link` text at regular weight, no box | A text action inside a line or a note (Make a new one, Show the payment). |

| Size | Height | Text | Padding | Where |
|---|---|---|---|---|
| `.sm` | 28 | 12 medium | 10 | chat cards, bars, headers |
| `.md` (default) | 32 | 13 medium | 12 | panels, forms, panes (the inputs' height) |
| `.lg` | 40 | 14 medium | 16 | onboarding |

- Every variant has its states: under the pointer (outline and ghost
  take `hover`; primary, secondary and destructive are a touch brighter;
  link underlines), pressed (those three darker, outline and ghost keep
  `hover`, link dimmer) and disabled (50% opacity, no hover). There is
  no focus styling yet: it comes in a later batch, checked with keyboard
  navigation on.
- Text is medium weight at every size, except `.link`, which is regular.
  A text action is always `.link`, in `link` blue (never `accent`); its
  size sets its text, `.sm` (12) beside a 12 pt line, `.md` (13) beside
  13.
- The radius is `Theme.Radius.control` for every variant and size.
- `fill` replaces a primary's colour: `attention` for a money button
  waiting for its second click (`PayButton`).
- A full-width button puts the frame on its label:
  `Text("Done").frame(maxWidth: .infinity)`.
- The spinner goes in the label (`buttonProgress`). A commit button stays
  on while it runs, keeping its fill under the spinner; its action ignores
  a second click.
- Where each lives: chat cards, bars and headers (a call card's Join,
  the image viewer's Reply, Mark all read, the Payments header) are
  `.sm`; panels and forms `.md`; onboarding `.lg`, its Back `.ghost`.
  The Payments header's buttons are `.outline`, `.secondary` while their
  pane is open.
- The call header's split Join is one outline box (`fieldFill`,
  `inputBorder`, `Theme.Radius.control`) holding a ghost `.sm` Join and a
  ghost `IconButton` chevron, split by a 1 pt `inputBorder` line.
- Still drawn by hand: the small text actions inside rows (a join
  request's Approve and Decline, a member's Remove, a pinned message's
  Unpin, a failed message's Retry and Cancel), which are muted or
  `accent` 11–12 pt text with a mini spinner, and `InlineConfirm`'s
  `.text` style that draws them. `ListRow` holds them in its end slot as
  they are; a text-action variant was left by the tokens sweep for
  Tom's call (muted or `link` blue, and its hover).

### Icon buttons (`IconButton`)

shadcn's `<Button variant="ghost" size="icon">`, in `UI/IconButton.swift`.
`HoverIconButton` and `HeaderButton` are gone: every icon button is one.

```swift
IconButton("xmark", help: "Close", action: close)
IconButton("magnifyingglass", help: "Search in chat (⌘F)", lit: open) { … }
IconButton("phone", help: "Start a call", working: starting) { … }
IconButton(help: title, action: copy) { CopyLabel(…) }        // any label
```

- `help` is the tooltip and the accessibility label, always.
- The icon is 13 pt, `secondaryText` at rest and `text` under the pointer,
  pressed or `lit`, on a `hover` fill at `Theme.Radius.control`. A label
  that sets its own colour keeps it (the connection bolt, the call
  window's pin, the copy check).
- `lit`: what it opened is open (a menu, the details, the search, the
  connection card). `MenuButton` is lit while its menu is open, so every
  More (•••) is.
- `working` puts the spinner in the icon's place (`buttonProgress`).
- Disabled is half opacity with no hover and never lit, as `PeelButton`; no call site
  dims it again.
- Variants: `.ghost` (default) and `.outline` (`fieldFill` and
  `inputBorder`, beside an outline button: the sidebar call bar's
  microphone). Sizes: `.md` 28 square (default; the height of a `.sm`
  `PeelButton`) and `.sm` 24 (the connection bolt, a notice's dismiss).
- Stay apart: the call window's control bar (its own `segment` and
  `pill`), controls drawn over a picture or video (the viewer's arrows,
  a video's full-screen button, the audio card's play), the jump to newest
  button, the composer's send (a `PeelButton` `.sm` square: `IconButton`
  has no primary variant) and the file tray's remove and "+". The
  composer's attach and bolt are ghost `IconButton`s, the bolt `lit`
  while Send sats is open.

## Forms (shadcn's conventions)

On 2026-10-09 Tom replaced direction A's row fields with shadcn's form
pattern, the web's standard for components, brought into SwiftUI. In a
row field the label sat on the left and the value on the right. Text
that sits on the right moves as you type, and it reads oddly. This
supersedes direction A's label-left, value-right rows for text inputs
(direction A, 2026-10-08: "Grouped, like System Settings"). Its
sections, its switches and its in-place confirms stay. The components
are in `Sources/PeelApp/FormKit.swift`.

- **A field is a `FormItem`.** The label sits above the field, then the
  input, then a line of help. A problem replaces that line of help.
- **Every input reads left, at the width of the form.** It is bordered
  at rest, as on the web, and nothing moves when you click in.
- **Sections stay a grouping.** Each is a heading (Basics, Pricing,
  Access) over its fields, stacked. They have no inset card rows.
  Pricing puts two fields to a line.
- **A switch keeps its label on the left and the switch on the right.**
  Nothing is typed there. Each switch row is a card of its own, as
  shadcn's switch-in-a-row is.
- **A click outside a field ends editing.** It can land on the form's
  background, a label or a heading. The caret goes and the field is at
  rest again (`endsEditingOnClick`). A click on another field moves the
  caret there, and a click on a field's padding or unit focuses that
  field. A button's click is the button's: as on the Mac, it does not
  take the keyboard.

The system applies to every form:

- Create a tribe and Edit tribe (`TribeSettingsForm`).
- Join a tribe, which keeps its compact popover with one field.
- Add contact, Invite someone and an invite's detail.
- Send or request sats.
- Receive and Pay an invoice, in their pane.
- Account. Its settings stay rows on cards (`SettingsSection` in
  `AccountView`), since they show what is set and nothing is typed in
  them. A field that opens there, Name, is a `FormItem`. The photo is a
  `PictureField` beside the name (see Components).
- Onboarding: the invite and the name. The PIN's and the twelve words'
  cells take the same chrome (`FieldChrome`).
- The sidebar's search, the time zone search and a paid attachment's
  price.

### Tokens

The tokens are in `Theme.swift`, with the rest of the palette. The
translucent ones use `Color(light:lightOpacity:dark:darkOpacity:)`.
Peel is dark only for now, and its floating windows are always dark. The
light values are kept for later, as the other light values are (see
Colour).

| Token | Dark | Light | For |
|---|---|---|---|
| `fieldFill` | white 5.5% | `#141E2D` 5% | inside a field, an outline button |
| `inputBorder` | white 15% | `#141E2D` 16% | a field's and an outline button's 1 pt border (shadcn's `input`) |
| `inputBorderHover` | white 26% | `#141E2D` 28% | the same border under the pointer |
| `formEdge` | white 7% | `#141E2D` 8% | the hairline around the popover and its cards |
| `focusRing` | `#618AFF` 28% | `#3F68E0` 22% | the 3 pt ring outside a focused field |
| `problemRing` | `#FFBC58` 20% | `#A86400` 16% | the 3 pt ring outside a field with a problem |
| `switchOff` | white 16% | `#141E2D` 16% | a switch that is off |
| `switchKnob` | `#F4F6F8` | `#FFFFFF` | a switch's knob |
| `popoverShadow` | black 50% | `#141E2D` 18% | the popover's shadow (radius 10, y 4) |
| `sectionShadow` | none | `#141E2D` 4% | lifts a card in light |

The surfaces are the existing tokens:

- the popover is `sidebar`;
- a card is `menu`;
- a focused field's border is `accent`;
- a problem's border and its text are `attention`, amber rather than
  shadcn's red, since nothing was lost;
- a destructive button is `destructive`.

### Components

- **The popover is a `Panel`** (see Component library): the title and close button, the sections, then `FormFooter` (the problem, then Cancel and the commit button).
- **`FormSection("Basics") { items }`.** Its heading is a `SectionHeader`, then its items 12 pt apart. It has no card.
- **`FormItem(label:helper:problem:) { field }`.**
  - The label is 13 pt medium. The field sits 6 pt under it, and the 12 pt help under that is in the secondary colour.
  - `problem` takes the help's place in `attention`.
  - Two items go side by side in an `HStack(alignment: .top)`, as Pricing's do.
- **`FormTextField(label:prompt:text:axis:problem:systemImage:monospaced:focusOnAppear:)`.**
  - The field is 32 tall, the width of the form, with 12 pt of padding and a corner radius of 7. Its text reads left.
  - `axis: .vertical` is a textarea of three to six lines, at least 64 tall.
  - `systemImage` puts an icon before the text (a search), `monospaced` is for an invoice, and `focusOnAppear` takes the keyboard (the time zone search).
  - The label is the field's accessibility name, and the prompt is its muted placeholder. With no prompt the field shows none, since the label above names it.
- **`FormNumberField(label:text:unit:prompt:problem:)`.**
  - It is the same input, with the unit inside the right edge in the secondary colour. The digits read left and are tabular.
  - The prompt is "0" unless given ("Free" for a price). It fills its column, and a caller that wants it smaller sets a frame (Boost amount, a paid attachment's price, 120).
  - `SatsField` is one that takes digits only.
- **`FieldChrome(focused:hovering:problem:)`.** Every field's states, as shadcn's input:
  - at rest, `fieldFill` with a 1 pt `inputBorder`;
  - under the pointer, `inputBorderHover`;
  - focused, an `accent` border with a 3 pt `focusRing` outside it;
  - with a problem, an `attention` border and `problemRing`, focused or not;
  - when disabled, at 50% opacity.
  It is also the chrome of the PIN's and the twelve words' cells.
- **`FormSwitchRow(label:detail:isOn:)` and `FormSwitchStyle`.**
  - The row is a `Card`, with the label and its description on the left and the switch on the right.
  - The switch is 30 by 18: `switchOff` when off, `button` when on, with a 14 pt knob.
  - The knob moves with a short spring (0.22 s).
  - VoiceOver reads it as a toggle.
- **Buttons** are `PeelButton` (see Component library): the form's buttons are `.md`, 32 tall as the inputs, outline unless they commit.
- **`endsEditingOnClick()`.** It goes on a form's container: the popover, the Receive and Pay pane, the Account page and onboarding. In a scroll view it goes on the content as well, since a click there never reaches a gesture outside it. A field's own click and a button's win over it.
- **`FormFooter`** lines its problem and buttons up on their text, so "Click again to confirm" hangs under a money button.
- **`PictureField(picture:upload:remove:uploading:label:)`.** A picture is picked, never typed: no link is shown, typed or copied (Tom, 2026-10-09).
  - The picture (an `Avatar`), then Choose picture… and Remove as outline buttons. A picture dropped on it goes the same way.
  - While it uploads, a spinner covers the picture and sits in Choose picture…; a failed upload says so under the row in `attention`.
  - `remove: .now` clears a form's draft (a tribe's image, kept on Save); `.confirmed` asks again in place (`InlineConfirm`), as the Account's photo does.
- **`FormDestructiveSection(trigger:prompt:explanation:confirm:action:)`.**
  - The destructive action is its own card at the end of the form, a full-width red row ("Delete tribe…", "Forget this account on this Mac…").
  - A click turns that row into the question ("Delete #hive for everyone?", or the explanation above the buttons) with Cancel and Delete. It is confirmed in place, never in a dialog.
- **`InlineConfirm(trigger:prompt:explanation:confirm:confirmKind:style:alignment:confirming:action:)`.** The one in-place confirm: the trigger, then the prompt with Cancel and the action, off while it runs.
  - `.buttons` (form buttons: Clear website data, Leave tribe, Cancel invite), `.text` (a row's text buttons: Remove a member, Discard, the lock screen's Forget), `.section` (`FormDestructiveSection`).
  - `confirmKind: .primary` for a second click that loses nothing (Copy words). `confirming` hands the state out, so the row can hide what stands beside it, or cancel it.
  - The buttons never shrink. The prompt sits beside them on one line when it fits, else above them, wrapping (`alignment` sets its side). A `confirming` binding is set back to false when the confirm goes away.

Renders of every form (at rest, focused, after a click outside, with a
problem and confirming), and Create a tribe beside a recreation of
shadcn's defaults, are kept outside the repo.

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
  the composer with the send arrow (inside the field since 2026-10-10). A banner at the bottom on
  development profiles says the twelve words are in a plain file.

Verified on the throwaway profile: messages both ways render, the layout holds
at the default window size. Not yet checked by hand: adding a contact through
the popover.

Not built, noticed in use:

- ~~No notification for incoming messages.~~ Local notifications and the
  Dock badge built on `phase3/notifications`; see `../phases/03-chat.md`,
  "Notifications".
- ~~Sidebar rows are buttons, not a `List`, so arrow keys do not move between
  conversations yet.~~ Down, Up, Return and Escape once a row is clicked
  (see "Sidebar", Keys).
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

**The header's right side (H1, Tom, 2026-10-08).** Two buttons: Call
(with its live "Join · N") and More (•••). A tribe's More holds, in
order: Tribe app and Second brain (each only when the tribe has one,
opening in the web pane, marked ↗; `Tribe.pages`, the one list and order
the details' buttons use too); Members, Details (⌘I, also from
anywhere in the chat), Copy tribe link and Notifications; then Edit
tribe… (owners) and Leave tribe (or Remove from Peel for a tribe you can
no longer post in), confirmed by a second click in the menu. A DM's More
is Details and Notifications. Notifications is a submenu opened in the
menu's place (‹ back, Left or Escape) with the sidebar's levels, the
current one beside it ("All"). Members, Details and Edit open below
More. The members panel keeps its own Copy link (top right, an icon) and
Leave (its footer). Every Leave (the menus, the members panel, the
details, the status bar's Remove from Peel) is offered by `Tribe.exit`,
worded by `Tribe.Exit` ("Leave tribe", then "Leave #tribe"; "Remove from
Peel", then "Remove #tribe") and run by `AppModel.leave`, whose failure
shows as the chat's notice.

**Tribe details (2026-10-09, branch `feat/tribe-details`).** In a tribe,
More's Details is "Tribe details" (⌘I); a click on the tribe's name or
icon opens the same panel in the same place, below More (a DM's name opens its details there too). It is a `Panel`, scrolling
under a fade above its footer: the image, name, public or private and
"Created 9 Oct 2026", the description, the tags as chips, a card of facts
(owner, members as "2 members" for the owner or "3 seen" for a member, price to join, per message, escrow; a dash until the
registry answers), Tribe app and Second brain as buttons into the web
pane, the link's QR with Copy link and Copy QR image, "How you appear in
#tribe" (a name whose helper shows the alias members will read, and a
`PictureField`; Save and Revert appear once something changed), and the
time zone switch. Its footer: Members, and Edit tribe… for the owner, on
the left; Leave tribe (or Remove from Peel) on the right for a member,
confirmed in place. Tags in the edit form are the same chips,
toggled, the selected ones in `selection` with a tick.

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

A link opens beside the chat, in a pane shaped like the Claude desktop
app's browser pane, without its tabs (decided 2026-10-08, restyled
2026-10-09; the decisions and what is left out are in
`../phases/05-parity.md`, "Web window"). Code:
`Sources/PeelApp/WebPane.swift`, with what may open in
`Sources/PeelCore/WebPage.swift`.

- **Where:** right of the detail column, 560 pt at first, dragged on its
  divider between 360 pt and what leaves the column 400 pt (remembered on
  this Mac; double-click for the standard width). On a window too narrow for
  both, the pane covers the column, which stays as it was under it. It stays
  open across chats, threads and Payments until closed: the toolbar's ×,
  or ⌘W while the page or the address field has the keyboard (⌘W
  elsewhere still closes the window). Closing it, or locking Peel, ends the
  page, media and all.
- **One page.** The next link replaces it; no tabs (Tom's choice,
  2026-10-09: add them only if people ask). `target=_blank` and
  `window.open` load in the same pane.
- **Toolbar** (60 pt, the chat header's height and rule): back, forward,
  reload (a cross while loading); the address field across the middle;
  then Open in default browser (an arrow out of a square), More (⋮: Copy
  link, Open in default browser, Clear website data, asked once more in
  place) and close (×). While loading, a 2 pt accent line grows along the
  rule.
- **Address field:** the boxed field of the forms (`FieldChrome`), "Type
  a URL" when there is no page. At rest it shows the lock (https with
  nothing insecure on the page) or "Not secure" in amber (attention, not
  red), then the full address with the host in full colour, as the address
  names it (an international name in its `xn--` form), the scheme and path
  quieter. The path gives way first, and a host too long for the field
  loses its start, so its real domain stays in view. The address changes
  when the next page arrives, not when it is asked for, so it always names
  what is on screen. A click selects the whole address to type over;
  Return loads it (`WebPage.typed`: an address gets https, or http for
  this machine; words are a DuckDuckGo search; any scheme but http and
  https is refused, saying so in the pane); Escape puts the address back.
- **Which links:** every http and https link SwiftUI opens below the main
  window (message links, which message markup makes only for https, and
  the header's Second brain and Tribe app). ⌘-click sends one to the
  default browser instead, from a message or inside the pane. Any other
  scheme keeps the system's handling. An address with a user name or
  password (`https://google.com@evil.example`) never opens in the pane.
  Links in floating panels (menus, popovers) still go to the browser: those
  windows do not take the main window's environment.
- **The header's More** (H1, tribes and DMs) starts with Browser (a globe:
  the pane as it is, or empty with the address field focused), then a
  tribe's second brain and app from the registry (`second_brain_url`,
  `app_url`), a brain and a grid, each only when present.
- **A failed load** shows "Couldn't open host", the system's reason and
  Try Again, centred on the pane's background.
- **Downloads** land in Downloads like a saved attachment (clean name,
  quarantined) and a bar at the pane's foot says "Saved name to Downloads"
  with Show in Finder; a failure says so in amber, never red.
- **HTML attachments** (2026-10-09) open in the pane like a link: a click
  on the file card, or its globe, downloads and decrypts the file, then
  shows it. It is someone else's page, so it is shown offline: a copy in its
  own temp folder that is the only file it may read, no script, a store
  that keeps nothing, and a content rule list that blocks every load but
  the file (images, styles, fonts, media, frames, pings, preconnects). The
  address field shows a page mark and the file's name, never a path; Copy
  link and Open in default browser are off. A web link clicked in it opens
  as a message's link does (⌘-click to the browser); any other navigation
  it asks for is refused. The copy is removed when the page closes or the
  next one replaces it. A paid one opens only once bought.
- **Website data:** one store per profile, so a Google or YouTube sign-in
  sticks for this account only. Account › Security › Website data, or the
  pane's More, clears it.

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
- **New contacts:** someone who added you shows "New" (`Badge("New")`, the
  unread count's look) in their row until their chat is read; a
  notification says "Added you as a contact". There is no request to
  accept: the core accepts at once, as in the official apps.
- **A contact's details** (More › Details, ⌘I, or a click on the name),
  a `Panel` like Tribe details: the picture, name, "Contact since" and
  their local time (`PanelHero`), their key with its QR, Copy key and Copy
  QR, the time zone switch, and Remove contact… in the footer, confirmed
  in place with what it deletes.

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
- **Account › Time zone** (T4): a row of Account's first section, "Time
  zone: Automatic · Europe/London (GMT+1)", or one chosen from a
  searchable Peel menu. No count of the chats it goes to and no note
  (removed 2026-10-13 as noise; see "Words").
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

Since v24 (phase 11, `../phases/11-preferences-sync.md`) the row below is
the chat's `timezone` preference, the file's item itself; the meanings
are unchanged.

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
  senders not asked yet. The query runs off the main thread; the rows are
  rebuilt when it answers. The rest of a run take their own
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
  menu's keys would swallow typing). The "Shared in" count was removed
  on 2026-10-13.
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

### Connection status (2026-10-15)

The Mac sidebar's bolt opens a headerless `Panel`: one status line and an
`IconButton` to check the server or reconnect now. A successful check returns to
Connected with no timestamp or extra copy. Busy actions are disabled; offline
keeps the retry countdown. The bolt's native tooltip is suppressed while the
panel is open. Escape, clicking outside, or pressing the bolt closes it.
