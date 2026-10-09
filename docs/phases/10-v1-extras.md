# Phase 10 — v1 extras: search, Markdown, voice messages, Giphy

## Status (2026-10-08)

**Added to v1 by Tom on 2026-10-08 (evening); reordered the same night.**
Markdown (item 2) is built (2026-10-09), and search in a chat (item 1,
first half) the same day, pulled ahead of the agent by the parity sweep;
the rest is not. It was pulled forward: it comes after the
cleanup and the polish pass, before the personal agent (phase 9), because
agent replies are Markdown. The rest (search and ⌘K, voice, Giphy, and the
payment templates of `04-money.md`, preferences sync and self-hosted
certificates of `05-parity.md`) comes after the personal agent
(`../PLAN.md`, "Phases").

Each item below records what the official Mac app does, read from
`sphinx-mac-v2` at `706e6f07` (2026-10-02). Paths are under
`com.stakwork.sphinx.desktop/`. Peel copies only what others can observe:
the message bodies and the media types. The screens are designed here.

## 1. Search

**Goal:** search the messages of the open chat, and a ⌘K command palette
that searches the whole app: messages in every chat, people and tribes.

**The official Mac app** has only the in-chat half:
- `NewChatViewController+SearchMessagesExtension.swift` switches the chat
  into a search mode. `NewChatTableDataSource+SearchMessagesExtension.swift`
  does the matching.
- A term needs at least 3 characters. Shorter terms show "Search term must
  be longer than 3 characters" and clear the results.
- The match is a case-insensitive substring of the message text. Bot HTML,
  payments, invoices and deleted messages are skipped. Matching rows
  highlight the term.
- It searches only the messages already loaded. When you step to the oldest
  match, it loads another page and searches again after a second.
- The first match shown is the one nearest the current scroll position.
- `ChatSearchResultsBar.swift` replaces the composer with a bar showing
  "n" and the match count, a spinner while it searches, and up and down
  arrows. Each arrow is disabled for half a second after a click.
- Across chats, the dashboard's search field filters the chat list by chat
  or contact name only (`ContactsService.updateChatListWith(term:)`). No
  message search covers more than one chat, and there is no command palette.

**For Peel:** every message is already in the account's SQLite file, so a
search can cover the whole stored history in one query instead of paging.
An engine operation should do the search so that the CLI and an agent host
get it too. Open: whether to use SQLite FTS5 or `LIKE`; how to rank
results; whether text inside code and quotes counts; what ⌘K offers besides
search (actions such as "Start call" or "Pay invoice").

**Search in a chat: done (branch `feat/chat-search`, 2026-10-09).** Tom
approved the in-chat half before the agent; ⌘K stays for after it.
- Storage (v19): `messageText`, an FTS5 table over `message.content` with
  the `trigram` tokenizer, so any part of a word matches, ignoring case.
  The migration reads the SQLite library's version: from 3.45 the index
  also ignores accents (`remove_diacritics 1`; "cafe" finds "café"), and
  from 3.44 it deletes for good (`secure-delete`), so a message deleted for
  everyone leaves no trace of its text in the index's pages. macOS 26 has
  3.51; an older library gets the plain index (macOS 15 may ship 3.43,
  without either). External content: the text stays in `message`, and
  triggers on insert, update (of type or content, when either changed) and
  delete keep the index in step. Only text and attachment captions (types
  0 and 6) are indexed; the migration back-fills the rows stored before.
  Payment notes, requests and call links are not searched, as in the
  official app. A database with this index cannot be written by an older
  SQLite without the option (Python's 3.42, say).
- `MessageQuery` reads what is typed: words match on their own, in any
  order, and all must; text in double quotes is one phrase (an unclosed
  quote runs to the end); `from:ann` or `from:"ann lee"` keeps messages
  whose sender's name, as it came with the message, contains it (case
  aside), with words or alone. Words and phrases under three characters
  are left out (the trigram index finds nothing shorter; "3 or more
  characters" when nothing is left). NULs are dropped (FTS5 ends a query
  string at one).
- `Storage.searchMessages(_:in:limit:)`: messages, newest first, in one
  chat or (with nil, for ⌘K later) every chat; not deleted, with words.
  The only FTS5 syntax is Peel's own: each term one quoted string, quotes
  doubled, joined by AND, bound as a parameter; the `from:` name is a
  bound LIKE pattern with `%`, `_` and `\` escaped. At most 1,000 matches
  ("1,000+"). Nothing leaves the Mac. A term in every message of a
  250,000-message database (50,000 in the chat) takes about 0.25 s, off
  the main actor; a rarer one a few milliseconds.
- App (`ChatSearch.swift`): ⌘F (Edit › Find…), or the magnifying glass
  left of Call in both chat headers, opens a bar under the header: the
  field, "12 matches" or "3 of 12", newer and older, close (Escape, or the
  button again). Under it, the matches as Slack lists them: avatar, name,
  a line around the first match with the words lit, a thread mark, and
  the time; five and a half rows tall, scrolling, the selected one lit
  and kept in view. Typing searches after 200 ms and lists the matches,
  none selected; with the cursor still in the field, ↓ selects the first
  and then the next, ↑ goes back, and Return goes to the selected match
  (the first when none is). A click or the chevrons go to a match at once.
  Escape or close puts the cursor back in the composer. Each step goes
  through `focus(on:inThread:)`, the jump quotes and notifications use: the
  timeline grows to reach an old message, and a message inside a thread
  opens its thread panel there, the cursor staying in the search. The
  words are lit (`Theme.searchMatch`) in the chat's rendered text, threads
  and code blocks too, ignoring case and accents as the index does; the
  step's row flashes as a jump does. Changing chats closes the search.
- Rendered on a new development account seeded with local rows (dark
  and light; the bar, the list, a thread match, `from:`, an accent).
- ⌘F fix (2026-10-09, Tom: "it defaulted to the left sidebar search",
  then "nothing works" after closing). Seen on a seeded offline profile
  with synthetic keys: closing the bar (Escape or ×) left the window
  itself with the keys, so typing went nowhere and Tab went to the
  sidebar's search, the window's first field; and once, as the bar
  opened, the sidebar's search took the cursor instead of the bar's
  field, and what was typed filtered the sidebar. ⌘F was a hidden button
  in the chat header, there only while that header was. Now ⌘F is Edit ›
  Find… (`AppModel.find`): the open chat's search from anywhere in the
  window, or, with no chat open (Threads, Mentions, Payments, the
  account), the sidebar's search, which filters the lists. The bar's
  field takes the cursor once it is in the window (`.task`, not
  `onAppear`), and closing puts the cursor back in the composer. A menu
  command does not follow `@Observable` state, so `find` checks the
  phase itself rather than `.disabled` (Account… shows the same: it
  stays disabled). Arrows (Tom: "you can't press the down key"): ↓ was
  "newer" and the newest match was already selected, so it did nothing
  until a click.
- Not built: results refreshing while new messages arrive (search again by
  typing), a search in the thread panel alone, the CLI command, `from:me`
  for your own messages in a DM. The words are lit in every message shown,
  matched or not (a message with only one of two words lights it). Lit in
  rendered text, so a search for Markdown marks (`**bold**`) finds the
  message but lights nothing.

## 2. Markdown

**Pulled forward (2026-10-08 night):** built before the personal agent,
ahead of the rest of this phase.

**Goal:** render bold, italic, strikethrough, quotes, headings, ordered and
unordered lists, and `[text](url)` links. Inline code and fences are already
built (#41).

**Before:** `MessageMarkup` (PeelCore) read paragraphs, "- ", "• " and
"* " items, fenced code, inline code, https links and mentions. Everything
else showed as typed.

**The official Mac app** renders every text message through
`Scenes/Dashboard/Workspaces/MarkdownRenderer.swift`. What it covers, and
how it differs from Peel's code rules, is recorded in `03-chat.md`
("Inline code and following the newest", "Markup"). Peel keeps its own
code rules, and the new syntax extends `MessageMarkup`. That keeps the
iPhone app and `Message.preview` (`MessageMarkup.plainText`) on one reader.

**Done (branch `feat/markdown`, 2026-10-09).** `MessageMarkup` gained:
- Blocks: `# ` to `###### ` headings, `>` quotes (lines in a row are one
  quote), `1. ` / `1) ` numbered items (the number as typed). Lists stay one
  level: an indented item is an item.
- `inlines(_:)`: the spans plus emphasis, `**`/`__` bold, `*`/`_` italic,
  `~~` strikethrough, nested in any order. Marks pair by CommonMark's
  flanking rules ("a * b", "snake_case" and an unclosed "**" stay as
  typed), each kind of mark on its own stack, so a message is read once
  whatever it nests. Marks are never read inside a span: code shows as
  typed.
- `[text](url)` (`Span.Kind.namedLink`): opens only when the detector reads
  the whole address as an https link, the same rule as a typed-out link;
  `http:`, `javascript:`, `file:`, `user@host` and the rest stay as typed.
  The text shows in the link colour with its host beside it, "docs
  (github.com)", in the `xn--` form `linkLabel` uses and isolated left to
  right so a direction override in the text cannot turn it around. A click
  opens the web pane, as any link.
- Emphasis marks at the end of a link or mention are not theirs:
  `**https://a.co**` was the link "a.co**".
- `plainText` (previews, notifications) drops every mark; a named link is
  its text; a numbered item keeps its number.

`MessageText` draws headings at 20/17/15 pt semibold, a quote behind a
bar, numbered items like bullets; `LinkText` sets emphasis as
presentation intents, so it scales with the heading's size. Tested in
`MessageMarkupTests`; the long adversarial inputs of `AuditMarkupTests`
cover emphasis, named links, quotes and headings.

Not built, as typed: task lists, tables, horizontal rules, nested lists,
backslash escapes, markup inside a named link's text.

## 3. Voice messages

**Goal:** record and send audio from the composer, and play it inline in
the timeline.

**The official Mac app** (`Helpers/Audio/AudioRecorderHelper.swift`):
- It records with `AVAudioRecorder` to `recording.wav`: linear PCM, mono,
  44.1 kHz. It asks for the microphone through `AVCaptureDevice`.
- It sends the file as an ordinary attachment (type 6) on the memes server,
  named `audio.wav` with media type `audio/wav`
  (`AttachmentObject.getFileAndMime`).
- When reading, only a media type containing `audio/wav` plays as audio
  (`TransactionMessage.getMediaType`). The duration comes from the file,
  not the message.

**Built today:** Peel already reads any `audio` media type as
`AttachmentKind.audio` and checks the bytes (`AttachmentKind.verified`).
Its preview says "Audio"; since `feat/video-attachments` (2026-10-08) the
timeline plays it in a compact card (see `03-chat.md`, "Video and audio
playback"), and playback pauses when you change chats. LiveKit
(phase 6) already adds the microphone usage string and entitlement.

**Open:** send WAV for compatibility, which is about 5 MB a minute,
against the 100 MB attachment limit. Check what iOS and Android send and
play before choosing anything else. Also open: a waveform or a plain
progress bar, and whether playback continues when you change chats.

## 4. Giphy

**Goal:** pick a GIF in the composer and send it, as the official app
does. About 38 of its Swift files mention Giphy: `Helpers/Giphy/GiphyHelper.swift`,
`API/API+GiphyExtension.swift`, the search view in `Scenes/Dashboard/Chat/Custom Views/Giphy Search/`,
and the cells and checks in the message views.

**Wire format:**
- A GIF is a **type 0 text message**, not an attachment. Nothing is
  uploaded to the memes server.
- Its `content` is `giphy::` followed by base64 of a JSON object
  `{"id", "url", "aspect_ratio", "text"}`. `aspect_ratio` is written as a
  string, and `text` is the caption (`GiphyHelper.getMessageStringFrom`).
- The receiver loads the GIF from `url` on Giphy's CDN, using the 200 px
  wide variant (`giphy.gif` replaced by `200.gif`).
- "Recent" lists your own last 50 sent `giphy::` messages
  (`TransactionMessage.getRecentGiphyMessages`).

**API key:**
- The picker calls `api.giphy.com/v1/{gifs|stickers}/{search|trending}`
  with `api_key`, `limit=30`, `offset`, and a `random_id` that is a random
  32-character string kept in `UserDefaults`.
- The key is `Config.giphyApiKey`. `Config.swift` is gitignored, and the
  repo has only `Config.template.swift` with a placeholder. Peel needs its
  own Giphy key, kept out of the repo in the same way.

**Today in Peel:** a received GIF shows as `giphy::` and a base64 string.
Reading the format is needed even before the picker exists.

**Open:** whether a received GIF loads automatically. Each load is a
request to Giphy's CDN, which the photo fetch rules from #42 (public https,
ephemeral session) would cover. Also open: whether to offer stickers.
