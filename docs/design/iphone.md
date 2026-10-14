# Peel on iPhone

Last updated 2026-10-14. The design for the iPhone app, agreed by Tom on
2026-10-14 from the board "Peel iPhone"
(https://claude.ai/artifact/PWonJ4bK6FXiCr7dpmrLBm, ten artboards at 390 by
844, dark). Nothing here is built. The plan and the build order are in
[../phases/07-iphone.md](../phases/07-iphone.md); the Mac's layout, colours
and components are in [README.md](README.md), the agent's screens in
[agents.md](agents.md). Where this file is silent, the Mac's rules hold.

**The spec wins over the board.** Some artboards drifted from the
decisions below; build to this file, not the drawing:

- The Thread sheet's composer lacks attach (+), and shows Send filled while
  empty (it should show the mic until something is typed).
- The agent DM's composer lacks attach (+).
- The approval card says "NEEDS YOU", draws Deny as an outline button and
  "Always allow" without its target. Build the Mac's card: Deny quiet,
  "Always allow for <target>".
- Unread puts a tribe first; the Mac's order is direct messages first.
- Chats, not connected, puts the capsule in a row above the title and
  drops the Automations, Threads and Mentions rows and the section
  chevrons; it is Chats with the bolt in the title capsule.
- Colours off the palette: the agent's avatar is orange (orange is a
  state; use its `PersonHue` fill), names are not the direction D hues, and
  thread participants are rounded squares (people are round).
- Your message's time on the tinted row is `#808D9E` (4.46:1); use
  `secondaryText`. The green bolt beside it is not part of the design.
- The You photo is 84 pt; build it at 64 pt.

The phone is the Mac's layout as a stack: the sidebar becomes the Chats
list, a chat pushes in, a thread opens as a sheet. Colour still means
state. iOS 26's Liquid Glass is the chrome, never the content.

## Decisions

All by Tom, 2026-10-14.

1. **Tabs: Chats, Payments, You**, plus the system's separate search tab
   (the search role). No Agent tab and no Activity tab.
2. **The agent is a DM**, not a tab. Its row sits in Direct messages with
   the AGENT label, and shows an orange count when it needs you.
3. **Chats opens with three sidebar-style rows**: Automations, Threads,
   Mentions (rows, not tiles). Then Unread, Tribes and Direct messages, in
   the Mac's order and with its trimming. No profile header on Chats.
4. **Chats' title bar** is the large title "Chats" with one glass capsule
   holding the connection bolt, always: green (`confirmed`) when connected,
   orange when not. Tapping it always opens the connection panel. There
   is no New message button (Tom, 2026-10-14, superseding "New message,
   and the bolt only when not connected"): people are added and tribes
   joined from the ends of their sections, as on the Mac.
5. **Threads and Mentions push their own lists.**
6. **A thread is a sheet**: large detent, a grabber, and it keeps the
   draft. No "Also send to channel".
7. **The composer** is a glass capsule. Attach (+) sits outside it, on the
   left. Inside: the mic while the field is empty, Send (filled blue) once
   something is typed. The send-sats bolt shows only in DMs, as on the Mac.
8. **The agent DM's header** shows the brain's status ("Mac asleep since
   08:15" after a grey hollow dot; a green dot when awake). A message sent
   while the brain sleeps is grey with a clock and "Queued until your Mac
   wakes". The approval card has Allow once / Always allow / Deny at 44 pt
   and is otherwise the Mac's card. A job's result opens its files in the
   app, never as raw links.
9. **Automations** is a screen pushed from the Chats row, grouped Upcoming,
   Recurring and Done as on the Mac.
10. **Payments**: large title, the balance, Receive (left, outline) and
    Send (right, filled), the history by day. Received amounts are green.
11. **You** has your 30 pt photo as its tab icon, with an accent ring when
    selected. The screen: photo, name and balance; Agent (Peel, the brain's
    status, the model); Account (twelve words, Change PIN, boost amount,
    server); then Forget this account, the only red, with no "Danger"
    header.
12. **Lock**: the PIN keypad, Face ID, and "Forgot your PIN?".
13. **Not connected**: an orange bolt in the title capsule and "Reconnecting
    in N s" under the title. The bolt opens a panel beside it with the
    state, the countdown, the last error and Reconnect now. Connected, the
    same panel says so (Tom, 2026-10-14).
14. **Liquid Glass only on floating chrome**: the tab bar, search, toolbar
    capsules and the composer, through the system's `.glassEffect`.
    Neighbouring toolbar buttons share one capsule. The scroll-edge effect
    sits under bars, and content scrolls under the glass. Never glass on
    content. Reduce Transparency is the system's job.
15. **Colours are the Mac's `Theme` tokens.** Sphinx blue `#618AFF` for
    unread and primary; gold for a mention of you; orange for waiting on
    you and not connected; green for confirmed; red only for destructive.
    The tab badge is blue, not iOS red. Grey text on a raised or tinted
    surface uses `#97A3B4` (`secondaryText`), since `#808D9E`
    (`tertiaryText`) falls under 4.5:1 there.
16. **iOS patterns** from the iOS review are accepted: see "iOS patterns"
    below.
17. **People and tribes as on the Mac** (Tom, 2026-10-14): Add contact
    (scan with the camera, paste, or a photo of a code), Invite someone
    with sats and the pending invites, contact details, Join a tribe (by
    its link or QR code, the price shown), Create a tribe, and a tribe's
    details and members, each the Mac's behaviour over PeelUI.

## Navigation map

```
Lock (full screen, before anything)

Tab bar (glass): Chats · Payments · You      Search (separate glass button, search role)

Chats  (NavigationStack, large title)
├─ title capsule: bolt (green or orange) → connection panel, beside the bolt
├─ Automations  → push Automations
├─ Threads      → push Threads list (to design) → push conversation + thread sheet
├─ Mentions     → push Mentions list (to design) → push conversation at the message
├─ a tribe row  → push Conversation (tab bar hidden)
│                  ├─ thread summary / Reply in thread → Thread sheet
│                  ├─ More › details → push Tribe details → push Members
│                  │                    └─ Edit tribe (owner) → sheet
│                  └─ call → call (to design)
├─ a person row → push DM (as Conversation, with the send-sats bolt)
│                  └─ More › details → push Details
├─ Join a tribe, Create a tribe (end of Tribes) → sheet
├─ a pending invite, Add contact, Invite someone (end of DMs) → sheet
└─ the agent row → push Agent DM

Payments  (NavigationStack, large title)
├─ Receive → sheet (to design)
├─ Send    → sheet (to design)
└─ a row   → payment detail (to design)

You  (NavigationStack)
├─ Agent: Peel → agent details (to design)
├─ Twelve words → push
├─ Change PIN → push
├─ Boost amount, Server → push or inline picker (to design)
└─ Forget this account → confirm in place

Search → results across chats (to design)
```

A notification opens its chat at the message; a thread reply opens the
chat with the thread sheet over it. Back always returns to the list it
came from.

## Screens

Sizes are the board's at the default text size (Large); every one scales
with Dynamic Type.

### 1. Chats

- **Title row.** The large title "Chats" (34 bold) and, on its right, one
  glass capsule (44 pt) with the connection bolt: green when connected,
  orange when not (screen 9). Its label says the state, so colour is not
  the only signal. A tap opens the connection panel beside it, connected
  or not. No New message (Tom, 2026-10-14). The large title collapses
  into the bar on scroll.
- **Rows at the top**, sidebar-style (a 19 pt icon in a 30 pt column, then
  the name): Automations, Threads (blue count of threads with new
  replies), Mentions (count as on the Mac). Bold when they have something
  new, in `secondaryText` when not. Each pushes its own screen.
- **Unread.** As on the Mac: direct messages first, then tribes that
  mention you, then other tribes, newest first; muted chats only when they
  mention you; no section when nothing is unread; no chevron. A chat
  opened from Unread stays there until you open another.
- **Tribes.** The five most recent, then "Show all 14 tribes" (blue, 14);
  "Show fewer" once open; ends with "Join a tribe" and "Create a tribe"
  (a "+" in the avatars' column, `secondaryText`), each a sheet. The
  header collapses the section (a chevron after the title). The section
  is there with no tribes, for its actions.
- **Direct messages.** The five most recent, then "Show all 10 people";
  pending invites (the Mac's dashed envelope ring, the nickname, the
  amount where a count goes), "Add contact" and "Invite someone" at the
  end, each a sheet. Someone who added you shows "New" until their chat
  is read, as on the Mac: the core accepts them at once, so there is no
  request to answer. The agent sits here like a person (see "Chat row").
- **Add contact** (sheet): their code typed or pasted, scanned with the
  camera, or read from a photo of their QR code; who it adds; an
  optional name; Add, which pays the 5-sat key exchange through the
  touch-safe confirm. Why a code adds nobody shows quietly, never red.
- **Invite someone** (sheet): the amount, a nickname and message only you
  see, and Invite, always confirmed with its amount; then the invite.
- **An invite** (sheet): its amount and state, the QR code with Copy
  invite, Share and Share QR once the server holds its sats, your
  message, and Cancel invite confirmed in place.
- **Join a tribe** (sheet): the link typed, pasted, scanned or read from a
  photo, looked up at once when it arrives whole; the tribe's image,
  name, description and "Joining costs 10 sats · 3 sats a message"; Join
  through the touch-safe confirm.
- **Create a tribe**, and **Edit tribe** from its details: the Mac's form
  (Basics with the image and tags, Pricing, Access), Delete confirmed in
  place.
- The open, closed and shown-in-full state of each section is the Mac's
  `Setting.sidebarLayout`, shared through the engine.
- **Pull to refresh** reconnects if needed and runs a catch-up.
- **Swipe actions** on chat rows: leading Mark read / Mark unread; trailing
  Mute and Pin.
- The tab bar floats over the list; the list scrolls under it.

### 2. Conversation

- **Header.** A glass back button on the left; the chat's name (16 bold)
  and a second line (a tribe's member count; a person's local time or
  status) centred; on the right one glass capsule with Call and More.
  More holds pinned messages, members and the chat's info. The tab bar is
  hidden inside a conversation.
- **Messages are the Mac's flat rows**: a 32 pt photo, the name in the
  person's hue (direction D) and the time once per run; the rest of the
  run under it. Your messages are left-aligned on the accent tint. The
  text is Markdown through the shared renderer (see "Components").
- **The day** sits on a hairline as an outline badge ("Today").
- **New messages** is the Mac's blue line with its label.
- **Boost chips** under a message: the orange bolt and the total, on
  `quote`, yours on `boostMineFill`.
- **A thread summary** under its root: the participants' photos (round
  for people), "4 replies" in `link` blue and "Last reply 10:02". Tapping
  it opens the Thread sheet.
- **A mention of you** is the gold chip; other mentions the blue chip.
- **"N new messages" pill** floats above the composer when new messages
  arrive below the fold; tapping it scrolls to the first.
- The composer floats at the bottom (see "Composer").

### 3. Thread (sheet)

- A sheet at the large detent with a grabber, over the conversation
  (which dims and steps back, as iOS does). Swipe down or the glass close
  button dismisses it.
- **Header.** "Thread" (17 bold) and the chat's name under it; a glass
  close button on the right; a hairline under the header.
- The root message, a "4 replies" label on a hairline, then the replies
  as flat rows.
- **Composer**: the same composer, placeholder "Reply". No "Also send to
  channel" (the Mac's rule, Tom, 2026-10-07).
- **The draft is kept** when the sheet is dismissed and comes back when it
  reopens, per thread, as the Mac keeps drafts.

### 4. Agent (a DM)

- **Header.** Back; the agent's 36 pt rounded-square avatar; "Peel" with
  the AGENT label; under it the brain's status: a grey hollow dot and "Mac
  asleep since 08:15", or a green dot and "Mac awake". A glass More button
  on the right opens the agent's details (to design).
- **Messages** in the conversation's rows. Markdown always rendered.
- **Queued.** A message sent while the brain sleeps shows grey, with a
  clock and "Queued until your Mac wakes" beside its time. It turns
  normal when the brain acknowledges it.
- **Job result card.** A green check, "Job done · Friday Night Chef · 6
  min" in `secondaryText`, the result in Markdown, then one outline button
  per file ("Shopping list"). A file opens in the app's own viewer, never
  as a raw link.
- **Approval card.** The Mac's `AgentApprovalCard`: an attention callout
  (orange hairline), what will happen, the exact content inset, then
  Allow once (primary), Always allow for its target (outline, only when
  the action may be always allowed) and Deny (quiet). Each button is 44 pt
  tall. Once answered it collapses to one line with the outcome, as on the
  Mac. No red: nothing is lost by declining.
- **The row in Chats** keeps an orange count while any card waits on you.
- **Composer**: the same composer, placeholder "Ask Peel"; the send-sats
  bolt is not shown (messages to your agent are free).
- The cards depend on the remote track (B1 to B4 in the phase file). Until
  then the agent DM is a plain DM.

### 5. Automations

- Pushed from the Chats row. A glass back button, the centred title
  "Automations", and a glass "+" for a new automation.
- Under the title, one line: "Run by your home Mac · last heard from 2
  min ago" (what the brain last reported, and when).
- **Upcoming** (one-offs not yet run), **Recurring**, **Done** (one-offs
  that ran; "Missed" for one that could not run), as the Mac groups them.
- Each row: the name (16 semibold), the schedule and next run, and for a
  recurring one the last run's outcome. A paused or finished one is in
  `secondaryText`.
- Tapping a row opens it (to design). Pull to refresh asks the brain for
  status. Waits on the remote track (B3).

### 6. Payments

- The large title "Payments", then "Balance" and the amount (40 bold,
  tabular figures) with "sats".
- **Receive** (left, outline) and **Send** (right, filled), 48 pt tall,
  side by side.
- **History by day** ("Today", "Yesterday", then dates), each day a
  section header. A row: the money bolt on a soft orange circle, who or
  what ("Boost · # Sphinx Builders", "Invoice paid"), a note under it, and
  on the right the amount over the time, both tabular. Received is green
  with "+"; sent is plain text with "−". A pending request is grey with a
  clock icon and "Waiting · expires in 2 days".
- Pull to refresh. A success haptic when a payment lands while open.

### 7. You

- **Tab icon.** Your photo at 30 pt; when selected, a 2 pt accent ring
  outside a 2 pt background gap.
- **Top.** Your photo at 64 pt (centred; the board's 84 pt is drift, 64 is
  the Mac's largest photo), your name (22 bold), the balance in
  sats under it.
- **Agent** group: Peel (its avatar, and the brain's status on the right:
  green "Home Mac awake" or grey "Mac asleep"), then Model.
- **Account** group: Twelve words, Change PIN (both push), Boost amount
  and Server (value on the right).
- **Forget this account** in its own group, in `destructive` red, with no
  header. Confirmed in place, never a system alert.
- Groups are `quote` cells with `divider` hairlines, radius 12; group
  headers are section headers.

### 8. Lock

- The Peel icon, "Enter your PIN" (20 bold), six dots (filled as digits
  go in), a 3 by 4 keypad of 78 pt round keys, Face ID bottom left and
  Delete bottom right, and "Forgot your PIN?" as a link at the bottom.
- What a wrong PIN does and where "Forgot your PIN?" leads are the
  Mac's `LockView`. No red.

### 9. Chats, not connected

- The title capsule holds the orange bolt (green once connected).
- Under the large title, one line in orange: "Reconnecting in 8 s".
- Tapping the bolt opens a panel beside it (not a sheet, not a centred
  alert): an orange bolt and "Not connected", one sentence ("Trying again
  in 8 s. Your messages are here; new ones arrive once Peel reconnects."),
  the last error in `secondaryText`, and Reconnect now (filled). The
  panel is the Mac's `ConnectionCard`.
- The rest of Chats stays as it is; nothing greys out.
- Connected, the panel has the green bolt, "Connected" and the server,
  and no Reconnect now (there is nothing to start).

### 11. Details (Tom, 2026-10-14)

Pushed over the conversation from its More menu
(`PhoneRouter.openDetails`); Back returns to it.

- **A contact**: their photo (64 pt), name, "Contact since" and their
  local time; their public key with its QR code, Copy key, Share and
  Share QR; the time zone switch; Remove contact, confirmed in place with
  what it deletes, back to Chats once done.
- **A tribe**: its image, name, "Public tribe · Created 3 Oct 2026",
  description and tags; a card of Owner, To join, Each message and
  Escrow; Members with the count (pushes the list); the tribe link with
  its QR code; how you appear in it (name and photo, Save); the time
  zone switch in a private tribe; Edit tribe for its owner; and Leave
  tribe (or Remove from Peel), confirmed in place.
- **Members**: photos and names in their colours. The owner gets the
  tribes server's list: requests to join first with Decline and Approve,
  and Remove on a member by swiping, confirmed in place. Anyone else
  sees who has posted, "Seen in #tribe".

### 10. Composer, keyboard up

- The composer rides on the keyboard. The keyboard dismisses
  interactively by dragging the messages down.
- Typing "@" opens the mention list above the composer: a `menu` panel,
  radius 14, one 44 pt row per person (photo, name, @alias), the
  highlighted one on `selection`. Tap to insert. The typed mention shows
  in `link` blue.
- Once there is text, the mic becomes Send: a 32 pt filled accent circle
  with an up arrow, in a 44 pt target.

## Components

Each phone piece maps to a Mac piece and its tokens. Reuse the shared
piece where it is plain SwiftUI; write a phone version only where the Mac's
is AppKit.

| Phone piece | Mac equivalent | Tokens and notes |
|---|---|---|
| Chat row | `SidebarRowStyle` rows in `Sidebar.swift` | 30 pt avatar (`Avatar`; tribes rounded square, people round), name 16 regular. Read: `secondaryText`; unread: `text`, semibold. Minimum 44 pt tall, no fixed height. Horizontal padding 20. Swipe actions |
| Top rows (Automations, Threads, Mentions) | Sidebar's Threads, Mentions rows | Same row, an SF Symbol in the avatar's column |
| Section header | `SectionHeader` | 13 semibold, `tertiaryText` on the background (5:1); `secondaryText` on a raised surface. Chevron after the title when it collapses. A VoiceOver heading |
| Count badge | `Badge(count:)` | Capsule, min 22 pt. Default: `accent` behind `buttonText`. `.mention`: gold. A new `.attention` style (orange `attention` behind `buttonText`) for the agent waiting on you, shared with the Mac |
| Tab badge | Dock badge | `accent`, not iOS red. The Chats count, by the Dock badge's rules |
| Glass capsule | `IconButton` | A new helper over `.glassEffect` in a `GlassEffectContainer`; 44 pt tall, each button 44 to 46 pt wide; neighbours share one capsule |
| Composer | `ComposerView`, `ComposerField` (`NSTextView`) | A `UITextView` wrapper with the Mac composer's behaviour (mentions, drafts, paste). Glass capsule, min 44 pt, grows to about six lines then scrolls |
| Send button | The composer's send | 32 pt `button` circle, `buttonText` arrow, 44 pt target |
| Message row | `MessageRow` in `MessageViews.swift` | 32 pt photo, name 14 semibold in `PersonHue.name`, time 12 `tertiaryText`, body 15. Your rows: accent at 6 to 8%; times on them use `secondaryText` |
| Markdown | `MessageText` over `MessageMarkup` | One renderer for both platforms (F1 moves it off AppKit). Never raw Markdown |
| Mention chips | Same | `mentionFill`/`mentionText`; you: `mentionYouFill`/`mentionYouText` |
| Boost chip | `Chip` | `quote` fill, orange bolt; yours `boostMineFill`/`boostMineText` |
| Job result card | `Card` | `quote` fill, `divider` hairline, radius 12; file buttons `PeelButton(.outline)` at 44 pt |
| Approval card | `AgentApprovalCard` (`Callout(.attention)`) | As the Mac; buttons `.primary`, `.outline`, `.ghost` at 44 pt |
| Connection panel | `ConnectionCard`, `ConnectionBolt` | `menu` fill, radius 18, beside the bolt; Reconnect now `.primary` |
| Grouped cells (You) | `FactList`, `Fact` | `quote` cells, `divider` hairlines, radius 12 |
| Payment row | `PaymentRows.swift` | Bolt on `attention` at 14%; received `confirmed`; amounts and times tabular |
| Buttons | `PeelButton` | Primary filled `button`; outline `fieldFill` with `inputBorder`; all 44 pt tall at least |
| Avatars | `Avatar`, `PersonHue` | Initials on `PersonHue.avatarFill`; the agent's rounded square on its own hue, never orange (orange is a state) |

Type follows the Mac (SF Pro), mapped to Dynamic Type through
`Font.system(size:weight:relativeTo:)` or the matching text style: large
titles `.largeTitle`, screen titles `.headline`, rows and messages `.body`,
names `.subheadline`, times and secondary lines `.footnote`/`.caption`.
Times and sats use tabular figures.

## Liquid Glass

- Glass only on floating chrome: the tab bar and the search button, the
  title and toolbar capsules, back and close buttons, the composer, and
  later the on-a-call bar.
- Use the system's `.glassEffect`; group neighbours in a
  `GlassEffectContainer` so they share one capsule and morph together.
- Content (rows, messages, cards, the connection panel's body) is never
  glass. The connection panel and the mention list are opaque `menu`
  panels.
- Content scrolls under the glass. Bars use the scroll-edge effect, not a
  hand-made gradient.
- Reduce Transparency, Increase Contrast and Reduce Motion are left to the
  system's glass.

## iOS patterns

Accepted from the iOS review (Tom, 2026-10-14):

- **Swipe actions** on chat rows: leading Mark read / Mark unread;
  trailing Mute and Pin.
- **Long-press a message** for its context menu: Reply in thread, Boost
  <amount> (the boost amount from You), Copy, Copy link, and Delete for
  your own. Delete is the only red item.
- **Swipe right on a message** to reply in its thread.
- **Large titles** on Chats and Payments, collapsing on scroll.
- **The tab bar hides** inside a conversation and its pushes.
- **Pull to refresh**: on Chats (reconnect if needed, then catch up) and
  Payments.
- **Haptics**: light on a boost; success when a payment is sent or lands.
  Nothing else.
- **Interactive keyboard dismissal** in conversations and threads.
- **"N new messages" pill** over the composer.
- **Deep links** from notifications to the message, or to the thread
  sheet over its chat.
- **Dynamic Type everywhere.** No fixed row heights; rows grow with the
  text. At accessibility sizes the counts and times wrap below the name
  rather than clip.
- **44 pt targets** for every control, including card buttons, the
  composer's buttons and section headers that collapse.

## Accessibility

- Every glass button has a label (Back, the bolt's state: Connected,
  Connecting or Offline, Search, Call, More, Attach, Record a voice
  message, Send).
- Section headers and screen titles are headings.
- One VoiceOver element per message: the sender, the time, the text, then
  boosts and replies ("1,200 sats boosted", "4 replies"). Its actions are
  custom actions: Reply in thread, Boost, Copy, Copy link, Delete for
  your own, Open thread.
- A chat row reads its name, then "3 unread, mentions you", "waiting on
  you" or "muted"; swipe actions are also custom actions.
- The approval card reads "Waiting on you:" and the action, then its
  buttons in order.
- The PIN dots read "2 of 6 digits entered".
- Contrast: text 4.5:1 and icons 3:1 on whatever they sit on, glass
  included. `tertiaryText` only on the background and the sheet's panel;
  `secondaryText` on `quote`, `menu` and tinted rows.
- Colour is never the only signal: the queued message has its clock and
  words, the bolt has its label and the line under the title.

## To design

Not on the board yet. Each needs drawing before it is built:

- **Send flows**: Send (pay an invoice, pay a person, scan), Receive
  (amount, invoice, QR), the send-sats sheet from a DM.
- **Search results** across chats, people and messages.
- **Threads and Mentions lists.**
- **Message states**: sending, failed (orange, retry), deleted, edited,
  paid and locked attachments, voice messages, images and files.
- **Empty states**: no chats, no unread, no payments, no automations, no
  agent yet.
- **Pinned messages and mute** in a chat's details (contact and tribe
  details are built: screen 11).
- **Calls**: incoming, in call, the on-a-call bar.
- **The agent's details page.**
- **Onboarding**: restore from the twelve words, create, set a PIN.
- **Light appearance.** The app is dark only for now, as on the Mac.
