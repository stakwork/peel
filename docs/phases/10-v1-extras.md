# Phase 10 — v1 extras: search, Markdown, voice messages, Giphy

## Status (2026-10-08)

**Added to v1 by Tom on 2026-10-08 (evening).** Nothing is built. These
come after calls, the file splits, contacts and the web window, the
remaining cleanup and a polish pass (`../PLAN.md`, "Phases"). They are
listed in the order Tom gave for the phase: search and ⌘K, Markdown, voice,
Giphy. The same step also carries payment templates (`04-money.md`),
preferences sync and self-hosted certificates (`05-parity.md`).

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

## 2. Markdown

**Goal:** render bold, italic, strikethrough, quotes, headings, ordered and
unordered lists, and `[text](url)` links. Inline code and fences are already
built (#41).

**Built today:** `MessageMarkup` (PeelCore) reads paragraphs, "- ", "• " and
"* " items, fenced code, inline code, https links and mentions. Everything
else shows as typed.

**The official Mac app** renders every text message through
`Scenes/Dashboard/Workspaces/MarkdownRenderer.swift`. What it covers, and
how it differs from Peel's code rules, is recorded in `03-chat.md`
("Inline code and following the newest", "Markup"). Peel keeps its own
code rules, and the new syntax extends `MessageMarkup`. That keeps the
iPhone app and `Message.preview` (`MessageMarkup.plainText`) on one reader.

**Open:** a `[text](url)` link hides its address, so the link's host
should show on hover or beside the text. Only https stays clickable, as
today. Task lists and horizontal rules are in the official renderer but
not in Tom's list.

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
