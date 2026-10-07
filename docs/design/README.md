# Peel design

Last updated 2026-10-07. The target layout and visual language for the Mac app.
Nothing here is built yet beyond the current shell; phase files say when each
part lands. The source mock lives on the canvas "Peel layout directions"
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
apps. The Peel logo stays in the sidebar header for now so Tom can tell the
two apps apart.

## Layout

Three regions, left to right. On a narrow window the thread panel closes first,
then the sidebar collapses; panels never overlay the conversation.

### Sidebar (260 pt)

Top to bottom:

1. **Header.** Peel logo, "Peel", and the wallet balance in sats under it. A
   compose button on the right starts a new direct message.
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
8. **Footer.** Your avatar, your name and the connection state ("Connected",
   "Connecting", "Offline").

No tabs and no filter chips. Sorting inside each section: most recent first.

### Conversation (flexible)

- **Header.** The tribe name with `#` (or the contact's name), member count and
  description for a tribe, and three icon buttons: call, pinned messages,
  members.
- **Messages are flat, Slack style, not bubbles.** Avatar, name, time, text.
  Consecutive messages from the same person within a few minutes collapse
  under one name.
- **Day dividers** ("Today", "Yesterday", then dates).
- **Boosts** show as a chip under the message: a bolt and the total sats. A
  "+" chip next to it boosts.
- **Thread summary** under a message that has replies: the repliers' avatars,
  "N replies" as a link, and "Last reply HH:MM". Clicking it opens the thread
  panel.
- **Composer.** A text field ("Message #Tribe" or "Message Name") with a
  toolbar: attach, send sats, mention, and Send.

### Thread panel (360 pt)

Opens when you click a thread summary or "Reply in thread", and closes with
its close button.

- Header "Thread" with the tribe or contact name under it.
- The original message, a "N replies" divider, then the replies.
- A reply composer with an "Also send to #Tribe" checkbox, as in Slack.

## Agents

An agent is a contact. It sits in Direct messages next to people, with no
separate section. Two differences:

- **Avatar shape.** Agents have rounded-square avatars with initials; people
  have round avatars.
- **An "AGENT" label** next to the name on its messages, so others in a tribe
  know they are talking to an agent. Kept on 2026-10-07.

Agent-specific views (budget, schedule, activity, approval cards) are not part
of this layout yet; see `../agent-native.md`.

## Colour

Tokens come from the official Mac app's colour catalog
(`sphinx-mac-v2/com.stakwork.sphinx.desktop/Colors.xcassets/SphinxNew`). Dark is
the default; light follows the system setting.

| Role | Dark | Light | Sphinx token |
|---|---|---|---|
| Sidebar background | `#1A242E` | `#F2F3F5` | LightBG |
| Conversation background | `#151E27` | `#FFFFFF` | Body |
| Thread panel background | `#1A232D` | `#F7F8F9` | HeaderBG / ThreadOriginalMsg |
| Input background | `#13181D` | `#F2F3F5` | InputBG1 |
| Primary text | `#FFFFFF` | `#292C33` | PrimaryText |
| Secondary text | `#97A3B4` | `#646C73` | SecondaryText, adjusted |
| Dividers | `#2C353D` | `#DCE0E3` | NewMessageIndicator / LightDivider |
| Quoted or summary block | `#1E2934` | `#F2F3F5` | ThreadOriginalMsg / ReceivedMsgBG |
| Accent (unread counts, links, selection) | `#618AFF` | `#618AFF` | PrimaryBlue |
| Filled buttons | `#618AFF` | `#3F68E0` | PrimaryBlue, adjusted |
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

Roboto, as the official apps use, at 400, 500 and 700. Sizes: 16 pt for
conversation and panel titles, 14 pt for messages and sidebar rows, 12 pt for
times and secondary lines. Times and sats use tabular figures.

## Motion

Restrained. The thread panel slides in from the right in about 200 ms with an
ease-out curve and leaves faster. Sidebar selection, hovers and keyboard
actions do not animate.

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
