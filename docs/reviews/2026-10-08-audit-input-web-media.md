# Audit B: untrusted input, the web pane and media, 2026-10-08

Part B of three of the phase 8 security audit (`docs/phases/08-audit.md`,
item 6). Scope: everything a stranger can send or show Peel, the web pane,
and attachments.

Line numbers are on `origin/main` at `2a945d7` (#83) unless a line says
"now", which means this branch.

## Verdict

The code was not vibe built where it matters most. Each parser that stands
between a stranger and money, keys or the file system was written to refuse
by default:

- call links, contact codes, tribe links and invoices;
- media tokens and the attachment cipher;
- file names and downloads;
- what the web pane may open.

Each of those parsers names its threat in a comment, and most already had
tests. I found no way to:

- move money without a click;
- read or write a file outside Peel's folders;
- run code;
- reach this machine or its network through a fetch;
- get Peel to open a file.

What I did find is the kind of thing a fast build misses:

- **One real denial of service.** One long message could freeze Peel for
  seconds to minutes. The message-markup parser was quadratic in four
  places, and it runs on the main thread for every notification and every
  redraw of the row. Any tribe member could send such a message. **Fixed.**
- **One real spoof.** A long or look-alike link could hide its real host
  in the message text. **Fixed.**
- **Two places where a page or a sender can cost you resources without a
  click:**
  - web pane downloads;
  - images that download whole, up to 100 MB.

  Both are left, with the fix described below.
- **A handful of small hardening gaps.** Four are fixed here; the rest are
  written down below.

## Method

- **Reading.** I read every file in scope from top to bottom:
  - `MessageMarkup`, `TimeZones`, `Call`, `Contacts`, `QRImage`, `Tribe`,
    `Invoice`, `Message` (body fields), `Media`, `MediaCrypto`,
    `MemesServer`, `MediaStore`, `Files`, `IncomingFiles`, `Web`, `WebPage`;
  - `Engine+Attachments`;
  - `WebPane`, `ConversationView` (`LinkText`), `AttachmentViews`,
    `MediaViews`, `ChatModel` (downloads, `ImageCache`), `Clipboard`.
- **Probing Foundation.** I checked how `URL`, `URLComponents` and
  `NSDataDetector` treat:
  - full-width characters;
  - IDN look-alikes;
  - bidirectional overrides;
  - `user@host`;
  - IPv6.
- **Timing the parsers.** I timed the parsers on 64 KB adversarial
  messages, in a debug build. The core reassembles up to 65,535 fragments
  of about 500 bytes into one message (`total_chunks: u16`,
  `sphinx-ffi/src/chunk.rs`), so a long message is a real input.
- **New tests.** All are in `Tests/PeelCoreTests/AuditInputTests.swift`:
  - seeded random inputs (SplitMix64, so a failure repeats);
  - huge inputs;
  - hand-picked adversarial inputs for every parser;
  - a differential test of the new span parser against the old algorithm;
  - time bounds on the inputs that used to be quadratic.

Verdicts: **holds**, **weak** (works, but a gap someone could use), or
**vulnerable** (a concrete exploit, given).

## Threats

### 1. Untrusted input

| # | Threat | Evidence | Verdict |
|---|---|---|---|
| 1.1 | A long message freezes the app (CPU) | `MessageMarkup.swift:103-113` scanned every remaining line for each unclosed fence. `:160` scanned every link for each code span; `:167` every code for each link; `:169-171` every span for each mention. These run on the main actor: `MessageViews.swift:953,983`, and `Message.preview` (`Message.swift:238`) for each notification (`Notifier.swift:295`). | **Vulnerable, fixed.** At 64 KB (debug build), 21,000 `@a ` took 37.8 s; 12,800 `` ```x `` lines took 24.9 s; mixed mentions, code and links took 9.0 s. Now each takes under 0.2 s together. |
| 1.2 | A link whose text differs from where it goes | `LinkText.display` (`ConversationView.swift:567-574`) cut any link over 56 characters in the middle, host included. It showed an international host in Unicode. | **Vulnerable, fixed.** Exploit 1: `https://accounts.google.com.session-verify.attacker.example/…` read `accounts.google.com.session-ver…`. Exploit 2: `https://аpple.com/login` (Cyrillic а) read `аpple.com/login` and opened `xn--pple-43d.com`. The web pane's toolbar showed the real host; ⌘-click went straight to the browser. |
| 1.3 | `https://real@evil` style links | `NSDataDetector` already leaves these out; `WebPage.address` refuses them. | Holds; now also refused in `MessageMarkup.spans`. |
| 1.4 | Bidirectional overrides in message text or names | Message text and aliases are shown as sent. A link cannot contain U+202E (`URL` refuses it). | **Weak.** A name or caption can render reversed. See finding 10. |
| 1.5 | `metadata.tz` | Read by a guarded SQL column (`Storage+Migrations.swift:228-234`), at most 64 bytes. `TimeZoneOffset.zone` (`TimeZones.swift:33-49`) takes `GMT±H[:MM]` up to 14 h, or an IANA name of ASCII letters, digits and `/_-+`, with no `..` and no leading `/`. | Holds. Fuzzed. |
| 1.6 | The `peel` metadata key | No such key exists on `main`: no code reads or writes one. | Not applicable. |
| 1.7 | Call links | `CallLink.init?(link:server:)` (`Call.swift:99-119`) requires all of these: the account's own server, scheme, host and port; no user or fragment; `/rooms/sphinx.call.<1-128 safe chars>`; known query keys once each, with token-charset values. `url` is rebuilt from the parts (`:144-158`). | Holds. Fuzzed: 4,000 random links, and every one read is https on the call server under `/rooms/`. |
| 1.8 | Contact codes, invites and QR codes | `ContactCode.read` (`Contacts.swift:20-31`) is strict: three-part contact info, `sphinx.chat://` with three known actions, and the core's invite parser. `QRImage` (`QRImage.swift:11-24`) refuses files over 40 MB and decodes at most 4096 px. | Holds. **Weak:** `isPubkey` (`Tribe.swift:434`) used `Character.isHexDigit`, which accepts full-width digits (since fixed on main by #80). **Weak (fixed):** a 100 MB paste was trimmed and counted before the length check. |
| 1.9 | Deep links | Peel declares no URL scheme (`scripts/bundle-app.sh` has no `CFBundleURLTypes`) and has no `onOpenURL`. Nothing from outside can trigger an action. | Holds. |
| 1.10 | Tribe links and registry JSON | `TribeLink` needs a key and a plain host. `TribeInfo.fetch` (`Tribe.swift:312-316`) refuses a record for another pubkey. `Web.get` caps it at 1 MB, public https only. Prices saturate (`:81-84`); app URLs pass `WebPage.address` (`:352-353`). | Holds. **Weak (fixed):** `isPlainHost` (`:242-244`) accepted any Unicode letter or digit, which `URL` maps onto ASCII (`１２７.０.０.１` becomes `127.0.0.1`). `Web.isPublic` still caught that case, because it reads the mapped host. The memes and call server base URLs did not. |
| 1.11 | BOLT11 invoices and payment requests | `Invoice.init` (`Invoice.swift:24-27`) caps the length at 4096 and parses in the core. The amount and hash always come from the invoice, never from the JSON. | Holds. Fuzzed. |
| 1.12 | Attachment file names | From the server: `MemesServer.fileName(fromDisposition:)` (`MemesServer.swift:265-273`) keeps only the last path component, with no control characters, no `:` and no leading dot. When saved: `UserFiles.cleanName` (`Files.swift:85-92`). | Holds for traversal and hidden files. **Weak (fixed):** names were cut to 200 characters, which can be up to 800 bytes (APFS takes 255). The cut also dropped or changed the extension, so `x….app<…>.pdf` could save as `.app`. |
| 1.13 | MIME types | `AttachmentKind.verified` (`Media.swift:35-46`) believes the declared type only when the bytes match: an image must decode; video and audio must start with a container signature; a PDF must start with `%PDF-`. Anything else is a plain file that nothing renders or opens. | Holds. |
| 1.14 | Actions without the user | Automatic actions are limited to these: answering a paid purchase with its key (`Engine+Attachments.swift:259-278`, checks the amount), the core's key exchange, photo fetches, and image downloads. None moves money. | Holds, but see 3.3 and finding 7. |

### 2. The web pane

| # | Threat | Evidence | Verdict |
|---|---|---|---|
| 2.1 | URL spoofing in the toolbar | `sync` (`WebPane.swift:184-194`) moves the address only once a load commits, or when nothing is loading. The host is shown as `URL.host` (`xn--` form), truncated at the head (`:531-534`). | Holds. |
| 2.2 | `file:`, `data:`, `blob:`, `javascript:`, custom schemes | `decidePolicyFor` (`:204-226`): http/https only with no `user@`; `data:`/`blob:` only in subframes; everything else cancelled, so no app is launched. `javascript:` URLs run inside the page's own origin. | Holds. |
| 2.3 | Pop-ups | `javaScriptCanOpenWindowsAutomatically = false` (`:158`). `createWebViewWith` (`:261-269`) loads a user-made pop-up in the one pane, through the same policy. | Holds. |
| 2.4 | Downloads and quarantine | Downloads go to Peel's temp folder, then `UserFiles.save` saves them into Downloads with a clean name and quarantine (`:305-327`, `Files.swift:94-112`). | **Weak.** Nothing asks first, and nothing caps the size (`:205`, `:228-232`). A page can drop files into Downloads with no click. See finding 3. |
| 2.5 | Data store isolation | One `WKWebsiteDataStore(forIdentifier:)` per profile, its UUID in the profile folder (`WebPage.swift:29-40`, `WebPane.swift:156`). Without a profile, `.nonPersistent()`. Never the default store. | Holds. |
| 2.6 | Camera and microphone | `decideMediaCapturePermissionsFor` returns `.deny` (`:272-277`). There is no location usage key, so geolocation is refused by the system. | Holds. |
| 2.7 | A JS bridge | No `WKScriptMessageHandler`, user script or `evaluateJavaScript` anywhere in `Sources`. | Holds. |
| 2.8 | Native dialogs and clickjacking over Peel | No `runJavaScriptAlertPanel` and the like, so `alert`/`confirm`/`prompt` show nothing. Element full screen is not enabled (WebKit's default is off). The page draws only inside its pane, below Peel's toolbar. | Holds. A page can of course draw a fake Peel inside the pane. |
| 2.9 | A page that crashes its process | `webViewWebContentProcessDidTerminate` reloaded at once (`:256-258`), forever. | **Weak (fixed):** now it reloads once a minute at most, otherwise it shows the problem. |
| 2.10 | Links routed out of the pane | `linkAction` (`:57-63`): a non-web scheme gets `.systemAction`. Message links are https only (`MessageMarkup`), and tribe app URLs pass `WebPage.address`. | Holds. |

### 3. Media

| # | Threat | Evidence | Verdict |
|---|---|---|---|
| 3.1 | `MediaCrypto` decryption | `decrypt` (`MediaCrypto.swift:45-56`) checks the version and length, then the HMAC (CryptoKit, constant time) before AES. A wrong key or a tampered byte is refused. | Holds. Every truncation, every bit flip and 200 random blobs are refused in tests. |
| 3.2 | The memes server and its token | A download goes only to this account's memes server (`Engine+Attachments.swift:174, 234`). The bearer token is dropped on a redirect to another host, and only https (or loopback) is followed (`MemesServer.swift:61-70`). The token is kept in memory only. | Holds. The media token is appended to the path as-is (`:251`), but the host is already fixed there. |
| 3.3 | Size limits (`upTo` / `tooLarge`) | `Transfer` refuses an over-limit `Content-Length` and stops mid-stream past the limit (`MemesServer.swift:133-150`). `upTo` holds videos and audio over 25 MB (`ChatModel.swift:464-467`). | **Weak.** Images have no `upTo`: `ImageTile` downloads whole (`AttachmentViews.swift:155`), up to `attachmentLimit` = 100 MB. Sign-in replies are unbounded (`MemesServer.swift:282-286`, own server only). |
| 3.4 | AVFoundation on untrusted files | `MediaInfo.asset` (`Media.swift:240-247`) overrides the MIME type from the signature. AVFoundation parses only files that downloaded and matched a container signature. | Weak by nature: AVFoundation parses in process. That is the same exposure as any Mac app that shows video. |
| 3.5 | The image cache | `ImageDecoding.thumbnail` decodes at most the drawn size (640 px in chat, 4096 in the viewer, 256 for photos). `ImageCache` is an `NSCache` capped at 200 MB. | Holds against decompression bombs. |
| 3.6 | Cache paths | Files are named by `SHA256(muid + key)` (`MediaStore.swift:18-21`). A muid cannot name a path, and cannot read someone else's file without the key. | Holds. |
| 3.7 | Save paths and quarantine | `UserFiles.save` and `copy` (`Files.swift:56-81`) quarantine every file, or remove it if it cannot be marked. Peel never opens a file. | Holds. |
| 3.8 | Clipboard copies | `copyImage` (`Clipboard.swift:57-60`) decodes the whole picture with `NSImage` and writes its TIFF. | **Weak.** A small file of huge dimensions takes gigabytes on Copy Image. It needs a click. |
| 3.9 | Pasted images | `IncomingFiles.png(fromTIFF:)` (`IncomingFiles.swift:95-107`) decodes in full, but only from the person's own clipboard and only up to 100 MB. | Weak, low. |
| 3.10 | Photos from anyone | `Web.photo` (`Web.swift:55-64`) accepts public https only, up to 2 MB, decoded at 256 px. | Holds for safety. **Weak for privacy:** see finding 7. |

## Findings, ranked

1. **Markup parsing was quadratic. (High; vulnerable; fixed.)**
   - The attack: a member of any tribe (or any contact) sends one long
     message. The core joins type-34 fragments into one, so tens of
     kilobytes cost a few hundred sats at most.
   - The effect: every member's Peel freezes. It parses the message for
     the notification preview and again on every redraw of the row, all
     on the main thread. At 64 KB of `@a ` that took 38 s per parse in a
     debug build. A release build is faster but still in seconds, repeated.
   - Fix: see 1.1. A differential test checks the new parser against the
     old one on 3,000 seeded inputs.
2. **Link labels could hide the host. (Medium; vulnerable; fixed.)**
   - The attack: a phishing link whose shown text names another site (see
     1.2).
   - Fix: `MessageMarkup.linkLabel` always shows the whole host, as `URL`
     names it (`xn--`). Only the path and query are shortened.
3. **Web pane downloads need no consent and have no cap. (Medium; weak;
   left.)**
   - The attack: any page the person opens, or a frame inside it, can
     trigger `<a download>` or answer with `Content-Disposition:
     attachment`. Files then land in `~/Downloads`, as many and as large
     as it likes. Quarantine keeps Gatekeeper in the loop; nothing stops
     the clutter or a full disk.
   - Fix:
     - keep WebKit writing to the temp folder;
     - cap each download (say 2 GB) in `decideDestinationUsing`, using
       `response.expectedContentLength`, and cancel past it in progress;
     - turn the download bar into a question ("Save `name` from `host`?
       Save / Discard") before `UserFiles.save`.
   - Not done here: it changes the pane's UI, and Tom should see it first.
4. **Images download whole, up to 100 MB. (Medium-low; weak; left.)**
   - The attack: anyone in a chat sends an attachment declared `image/*`
     that points at a large file on the memes server. Every member's Peel
     fetches it as soon as the row shows. Peak memory is about twice the
     size (the sealed bytes and the plain bytes), and several such tiles
     download at once.
   - Fix:
     - apply `Engine.autoDownloadLimit` to images in `autoDownload`;
     - have `ImageTile` call that instead of `download(message)`;
     - give `ImageTile` the held state that `VideoTile` has (a size and a
       click to load).
   - Not done here: it is a UI change.
5. **Full-width hex and Unicode hosts. (Low; weak; fixed.)**
   - `TribeLink.isPlainHost` is now ASCII only (`isPubkey` was fixed by #80).
6. **Saved file names. (Low; weak; fixed.)**
   - `cleanName` now cuts at 200 UTF-8 bytes and keeps the extension.
   - A single huge character (a letter under hundreds of accents) becomes
     `file.ext`, never a bare `.ext`.
7. **Photos are fetched from anyone's host. (Low; weak; left.)**
   - The attack: a tribe member sets `photo_url` to their own server and
     learns each member's IP address and when they are online.
   - This is how every Sphinx client works.
   - Fix (a product call): fetch photos of non-contacts only when their
     profile is opened, or proxy them through the memes server.
8. **A page that crashes its process reloaded forever. (Low; weak;
   fixed.)**
9. **Copy Image decodes in full. (Low; weak; left.)**
   - Fix: in `Clipboard.copyImage`, read the pixel size with
     `CGImageSourceCopyPropertiesAtIndex` and refuse anything over about
     100 megapixels. Better still, put the file's own bytes on the
     pasteboard under its UTType.
10. **Names and captions keep bidirectional controls. (Low; weak; left.)**
    - An alias such as `Tom\u{202E}…` renders reversed.
    - Fix: strip format characters (`withoutControlCharacters`, which
      covers Cc and Cf) from aliases and invite names where the engine
      reads them (`SenderInfo`, `Engine.parseInvite`).
    - The download bar's "Downloading `name`" (`WebPane.swift:594`) shows
      the server's raw name. The name saved is clean.
11. **Memes sign-in replies are unbounded. (Low; weak; left.)**
    - Only this account's own memes server can send them.
    - Fix: `challenge` and `verify` go through `Transfer` with a 64 KB
      limit.

For the core team, not Peel: `handle_chunks` reassembles up to 65,535
fragments per message. A cap on the reassembled size (say 256 KB) would
bound every client, not only Peel.

## Fixed in this PR

- **`Sources/PeelCore/MessageMarkup.swift`.**
  - `blocks`: the line that closes each fence is found once, from the end
    (`closers`).
  - `spans`: the link, code and mention overlap checks each walk forward
    once (`outside`).
  - Links with a user name are no longer links.
  - New `linkLabel(_:url:limit:)`.
- **`Sources/PeelApp/ConversationView.swift`.** `LinkText` uses
  `MessageMarkup.linkLabel`. Its own `display` and `longLink` are gone.
- **`Sources/PeelCore/Tribe.swift`.** `TribeLink.isPlainHost` is ASCII only.
- **`Sources/PeelCore/Contacts.swift`.** `ContactCode.read` refuses
  anything over 12,000 bytes before trimming it.
- **`Sources/PeelCore/Files.swift`.** `UserFiles.cleanName` cuts by bytes,
  keeps the extension, and never leaves an empty stem.
- **`Sources/PeelApp/WebPane.swift`.** A crashed page is reloaded at most
  once a minute.
- **`Tests/PeelCoreTests/AuditInputTests.swift`.** 27 tests, many
  parameterised: markup (differential, random, time-bounded), link labels,
  codes and hosts, call links, time zones, invoices, media tokens, server
  file names, saved names, the cipher, container sniffing, QR codes, and
  pane and fetch addresses.
- **Docs.** `docs/design/README.md` (how links read) and `AGENTS.md` (the
  test list).

`swift test`: 417 tests pass (one known issue, unchanged).

Not checked in the running app:

- the pane's crash limit;
- the new link labels.

Both are small, and the labels are covered by unit tests.

## What's left

| Finding | Why not here | Size |
|---|---|---|
| 3. Download consent and cap | UI change in the pane | S–M |
| 4. Images held over 25 MB | UI change in `ImageTile` | S |
| 7. Photo fetches leak IP to senders | Product decision | M |
| 9. Copy Image size guard | Small; listed for batch 12 (media) of the second review | XS |
| 10. Strip bidi controls from names | Touches message intake (part A's area) | S |
| 11. Bounded memes sign-in replies | Batch 10 (network helpers) moves `Transfer` anyway | XS |
| Core: cap reassembled message size | `sphinx-rs` | S |
