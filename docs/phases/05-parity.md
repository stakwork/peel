# Phase 5 — Parity: contacts, in-app web window, self-hosted servers

## Status (2026-10-08)

**Built:** the Account screen (#10): name, photo by link (upload from this
Mac came with #13), contact QR, twelve words, PIN, forget. See "Account screen" below.
The web pane (branch `feat/web-pane`, in review): links and a tribe's apps
open beside the chat. See "Web window" below.

**Built (2026-10-08, `feat/contacts`):** contacts: adding by a scanned QR
picture or pasted code, invites with sats, new contacts who added you. See
"Contacts" below.

**Open:** nothing else in this phase before the v1 extras below.

**Moved to the v1 extras step** (`10-v1-extras.md`, after the polish pass),
with search and ⌘K, Markdown, voice messages and Giphy:
- Self-hosted servers with their own certificates: "Self-hosted servers" below.
- Settings sync between devices (the Mac app's `Data Sync Manager`). Tom,
  2026-10-08: Peel will need a preferences layer. What the official apps
  sync is in "Settings sync" below; the per-chat time zone switch is stored
  in the file's shape already (`../design/README.md`, "Time zones").

**Decided (2026-10-08):** web apps become a web window inside Peel. Out
of v1 (confirmed in the evening): People, LSATs, languages, feeds and
podcasts, Hive workspaces, the knowledge graph view and Jitsi ("Not in v1"
below).

## Contacts

Built 2026-10-08 (`feat/contacts`). Adding by contact info and your own QR
were already there (the sidebar's "Add contact", the Account screen).

**What the official apps do** (checked in `sphinx-mac-v2` and the core):
- `make_invite` is a keysend of the amount to this account's own server
  carrying a new 32-byte code (`AsyncPay::Invite`); the server keeps the
  sats, less `INVITE_PRICE` if it sets one, under the code. `new_invite` is
  the whole link (`sphinx.chat://?action=i&d=…&c=…`); the core keeps no
  record. The Mac app shows the code only once the funding payment's tag
  reports COMPLETE, and keeps the nickname and welcome message locally (the
  message is never sent anywhere). No minimum, no balance check in Swift.
- `cancel_invite` publishes the code; the mixer refunds the sats to the
  account and publishes the new balance. An invite already used gets no
  answer at all. Anyone holding the code can cancel it.
- Whoever signs up with an invite adds the inviter with the code in the key
  exchange's sender (`sender.code`, type 10); the Mac app matches it to the
  invite's placeholder contact.
- Someone adding you is accepted by the core at once (type 10 answered with
  11 when it carries the 3-sat price to meet): there is no pending request,
  no accept or decline in the core or the official app.
- The Mac app scans QR codes only at signup (camera); after that, contacts
  come by pasted contact info or a `share_contact` link.

**What Peel does:**
- **Add contact** (`ContactsViews.swift`, `Engine.addContact(code:)`): type
  or paste contact info, a `share_contact` link or an invite (its inviter is
  added; the invite itself is for a new account, so its code is never used
  and its sats stay in it); or read a QR code from a picture: dropped on the
  form (files, image data and the screenshot thumbnail's promised file, read
  as the composer reads drops), pasted, or chosen. Vision
  (`VNDetectBarcodesRequest`) reads it (`QRImage`, size- and pixel-limited);
  with several codes, the first that names someone. `ContactCode` is strict:
  two compressed keys and a channel id, `sphinx.chat://` links with no host
  or path and only those actions; a bare key, a tribe link, this account's
  own info are refused with the reason. Someone already a contact is not
  added again (their chat opens).
- **No camera** (decided here): the entitlement exists for calls, but a
  scanner needs a capture session, a preview and a first camera prompt that
  belongs to Tom's daily Peel too; a screenshot or photo of the phone does
  the same job on a Mac. Revisit for the iPhone.
- **Invites** (`Engine.makeInvite`, `cancelInvite`, `forgetInvite`; the
  `invite` table, migration v16): "Invite someone" under Direct messages:
  amount, nickname and message (only you see them). Balance and connection
  are checked first, then every invite is confirmed with its amount in
  place ("Invite 2,000 sats", click again), whatever the threshold, then
  `checkPayment` runs as for any payment. The form says the server may keep
  a fee (the production price is not known). The invite is written before
  its payment is published and shows its QR, Copy invite, Copy QR and Share
  once the server confirms. Pending invites sit under Direct messages; one
  opens its detail with Cancel invite, confirmed in place. A cancel counts
  once the balance rises by at most the invite's amount; with no answer it
  stays "cancelling", with Ask again and Remove from list (it may have been
  used). An invite is marked used when the key exchange that names its code
  arrives from its new account.
- **New contacts**: someone who adds you (type 10 from a verified sender,
  first seen, live or catching up, never in a restore) gets a "New" badge
  in the sidebar until their chat is read here, and one "Added you as a
  contact" notification (`Engine.Event.contactAdded`), quiet for their chat
  open in front of you and when muted. No accept or decline: the core has
  already accepted them.
- **CLI** (`Commands+Contacts.swift`): `add <code|picture>`, `scan
  <picture>`, `invite <sats> [--nickname --message] --yes`, `invites`,
  `invite-cancel <code>`.

**Verified (2026-10-08)** on a local stack (broker 2213, mixer 8193),
development profiles `kx-*`: Bob added Alice from a QR picture (CLI `add
<png>`), the key exchange completed both ways; Alice made a 3-sat invite
(refused without `--yes`), Carol signed up with it, had the sats and Alice
as a contact, and Alice's invite became used; a 4-sat invite cancelled and
the balance came back; Dave added Alice while the app was open and "New"
showed beside him. App screenshots, light and dark (rendered from a scratch
build, not committed): the sidebar with a pending invite and "New", Add
contact with a read code, the armed invite form, an invite's detail.

Not exercised by hand (no input automation): dropping or pasting a picture
in the app, the in-place confirms, Copy and Share, notifications.

**Review (2026-10-08):** `/code-review` (high), `/simplify` (four angles)
and `/security-review` ran. Fixed: a scanned code's problem shows at once;
a cancel never counts a rise it cannot be (unknown balance, more than the
invite) and no longer puts a maybe-refunded invite back to ready; a
publish that fails before sending marks the invite failed; balance and
connection are checked before asking to confirm; "New" clears with the
chat's read marker in the engine (`markRead`), not from the view; one
contact-info validator (`contactInfoParts` uses `ContactCode`); drops and
pastes go through `PasteboardFiles` (promised screenshots, JPEG and HEIC);
the shared `SatsField`, `BalanceLine`, `QRCodeTile`, `shortKey` and a
shared `capitalizedFirst`; the invite detail observes its own row.
Security review found nothing to fix.
Not applied, with reasons:
- `Storage.apply` returning one result struct instead of growing `inout`
  outputs (`received`, now `addedUs`): touches every caller; worth doing
  with the next output.
- One store of "records tracked by payment tag" (messages, invoices,
  invites) and one status write: invites follow the invoices' pattern; a
  shared one is a refactor of its own.
- One notification gate shared by messages, money and new contacts:
  `Notifier` already has two; folding three is a separate change.
- Sharing the dashed "unknown person" icon with Payments: different sizes
  and roles; revisit in the polish pass.
- Tribe invites (`tribe_host`/`tribe_pubkey` in the link): production's
  default tribe is empty, so the official app passes none in effect.

## Web window

Goal: a link or a tribe's app opens in a window inside Peel, not in the
browser, like the artifact pane in the Claude desktop app. That covers a URL
tapped in a message (today `LinkText` makes it a link and the system opens
the default browser) and a tribe's two web addresses, which the tribes
server's record carries as `app_url` and `second_brain_url` (the Mac app's
`tribeInfo.appUrl` / `secondBrainUrl`; it also keeps `feed_url`). Peel's
`TribeInfo` does not decode either yet; `TribeSettings.fields(over:)` sends
them back untouched on an edit.

What the official Mac app does (`Scenes/Dashboard/WebApps`): a WKWebView over
the chat, with back, forward, reload and "open in a new window". A tribe's
header has one button per address, the app and the second brain; a deep
link into a tribe uses the app URL, or the second brain URL when there is no
app URL. Pages talk to it
through a `sphinx` message handler (`WebAppHelper`): `AUTHORIZE` with a sats
budget, `KEYSEND`, `PAYMENT`, `SIGN`, `GETBUDGET`, the LSAT calls and more.

### Decisions (2026-10-08, defaults for Tom to change in review)

The open questions, answered; the look is in `../design/README.md`, "Web pane".

- **Where:** a pane beside the chat, resizable on a divider. It stays open
  across chats until closed (✕, or ⌘W while the page has the keyboard).
  One page, which the next link replaces; no tabs in v1 (kept on
  2026-10-09, "Browser look" below).
- **Which links:** every http and https link (message markup still makes
  links only of https, unchanged since #42), plus the tribe's `app_url`
  and `second_brain_url`. ⌘-click, or the pane's Open in Browser, sends a
  page to the default browser. Other schemes (mailto, `sphinx.chat://`)
  keep today's handling. `WebPage.address` decides: http or https, a
  host, and no user name or password.
- **Tribe apps:** `TribeInfo` decodes `app_url` and `second_brain_url`; the
  stored `Tribe` keeps them (v15, http or https only) from the join and the
  background registry refresh; an edit still sends back the record as the
  server had it, so `fields(over:)` round-trips them untouched. A header
  button for each one present.
- **No `sphinx` bridge in v1:** no message handlers, no injected scripts. No
  LSATs or in-page payments.
- **Storage:** one persistent `WKWebsiteDataStore(forIdentifier:)` per
  profile, its UUID in the profile folder (`web-store`), so sign-ins stick
  and profiles never share; never the default store (without a profile
  folder, a non-persistent one). Account › Security › Website data clears
  it; forgetting the account removes it.
- **Pages:** pop-ups load in the same pane. Downloads are written to a
  private temporary folder, then go into Downloads through
  `UserFiles.save` (clean name, quarantined). A page may not navigate the
  pane to file:, data: or blob: (top level), `sphinx.chat://` or any other app's
  scheme. Camera and microphone are denied. Media plays; sound starts only
  after a click, as in Safari. File inputs open the system's open panel.
  JavaScript alerts and confirms are not shown (no native dialogs).
  Locking Peel closes the pane.

### Built (2026-10-08, branch `feat/web-pane`)

- `PeelCore/WebPage.swift`: `address(_:)` for URLs and typed text, and
  `storeIdentifier(in:)`. `Tribe.appURL` / `secondBrainURL`, migration v15.
- `PeelApp/WebPane.swift`: the `WebPane` model (one `WKWebView`, made on
  open, dropped on close), its delegates, the toolbar, the split beside the
  detail column, the routing `OpenURLAction` and the tribe header buttons.
  `MainView`, `ConversationView`, `AppModel` and `AccountView` gain a line
  or a row each.
- Tests (`WebPageTests`): what routes to the pane and what does not, the
  store identifier per profile, `TribeInfo` decoding and the stored tribe,
  `fields(over:)` keeping the two addresses.
- Verified in the app on a development profile (offline, cached chats): the
  pane beside a tribe chat in light and dark on a normal site and from a
  tribe's app address; YouTube's watch page plays (checked muted). Not
  verified by hand: clicks (message link, ⌘-click, header buttons, ⌘W),
  a download, Clear website data, Google sign-in persisting across launches.
  A page in a window that is wholly hidden behind others does not paint
  until shown (WebKit's occlusion throttling); expected.
- Known: Google may refuse to sign in inside an embedded web view; Open in
  Browser is the way out. Peel does not change its user agent to hide that
  it is one.
- Review findings left as they are (code review, 2026-10-08):
  - A sign-in that opens a pop-up and waits for it through
    `window.opener` (some "Sign in with Google" buttons) cannot finish,
    since the pop-up replaces its opener in the one pane. Tom's call:
    one pane, no tabs. Open in Browser works for those.
  - The pane belongs to the app model, so a second main window (⌘N)
    would show the same web view in only one of them; Peel has one main
    window in practice. Closing the window closes the pane.
  - The split repeats the thread panel's room-and-divider arithmetic in
    `ConversationView`; sharing it waits until the files other branches
    are editing settle.
  - Forgetting the account clears the store's data, then asks WebKit to
    remove it; while a web content process still holds it the removal is
    refused and an empty folder stays under `~/Library/WebKit`. Only the
    app's Forget does this; a profile removed another way (a failed
    signup) leaves an empty store nobody ever signed into.
- `/security-review` (2026-10-08): `WKWebView.url` names a load's target
  before it commits, while the old page stays on screen and usable, so a
  page could start a load that hangs and wear another site's host and
  lock. The toolbar's address now changes only when the new page commits
  (or with no load under way, for a page's own history). Checked and
  fine: `user@host`, data:/blob:/file:/custom schemes, pop-ups, IDN
  (shown as `xn--`), downloads' names (`UserFiles.cleanName`), no bridge,
  each profile's own store and never the default one.
- `/simplify` (2026-10-08) applied: the page's state is one `Page` value
  written only on change (closing now resets all of it); one KVO helper;
  one store lookup; one download clean-up through `IncomingFiles.discard`;
  the failure bar is `NoticeBar`, Show in Finder is `showInFinder`; the
  link router is made once; the header buttons go through it; WebKit's own
  `WebKitErrorFrameLoadInterruptedByPolicyChange` instead of 102; the lock
  closes the pane by replacing the main view, so `AppModel` no longer does.
  Left: the split always sits in a `GeometryReader` (pulling the detail
  column out of it when the pane opens would make the chat again and lose
  its scroll); the divider writes its width on every drag tick, as the
  sidebar's and thread's do; Payments' 760 pt minimum is a constant until
  a detail column can publish its own; a finished download is copied into
  Downloads on the main thread (a clone on the same volume).

### Browser look (2026-10-09, branch `feat/browser-tabs`)

Tom's brief (2026-10-09, with a screenshot of the Claude desktop app's
browser pane): better icons and a URL field like Claude's. Tabs and a
browser per tribe were built first, then dropped the same day by Tom's
choice: keep one page until people ask for tabs (they can be added later).

- **Built:** the toolbar restyled: back, forward, reload or stop as arrows;
  an editable address field (`FieldChrome`) holding the lock or "Not
  secure" and the full address with the host emphasised, still the
  committed page's; Open in default browser as an arrow out of a square in
  place of Safari's compass; ⋮ with Copy link, Open in default browser and
  Clear website data; × to close. The header's More (tribes and DMs) gains
  Browser, which shows the pane as it is or empty with the field focused.
  Closing the pane still ends the page.
- **Typed addresses** (`WebPage.typed`): an explicit http or https address
  loads as written; a bare name (`example.com`, `bücher.de`, an IP) gets
  https, this machine (`localhost:3000`) http; words, or a name that does
  not read as a host, are a DuckDuckGo search (`+`, `&`, `=`, `#`
  escaped); any other scheme typed out (`javascript:`, `file:`, `data:`,
  `about:`, `mailto:`) is refused and the pane says so. DuckDuckGo because
  it keeps no search history tied to the person.
- **Skipped:** tabs, the layout toggle and the pointer tool from Claude's
  pane.
- **Left as it was:** one page that the next link replaces, pop-ups in the
  same pane, downloads (no ask before saving, Tom is undecided), the
  per-profile store, no bridge, camera and microphone denied.
- **Verified:** renders of the pane in dark and light (a page, the empty
  pane with the field focused, a page loading, "Not secure", the ⋮ menu
  open), from a scratch build driven into each state on a development
  profile copy, with a side-by-side against Tom's screenshot (not
  committed). `swift test`. Not exercised by hand (no input automation):
  typing into the field, ⌘W from the field, hover states, Clear website
  data from the menu.
- **Reviews (2026-10-09):** `/code-review`, `/simplify` and
  `/security-review` inline. Fixed: an explicit http(s) address with a
  space in its path loads rather than searching; a host too long for the
  field truncates at its start, keeping its real domain in view; a refused
  address names no host. Left: the ⋮ button repeats `MenuButton`'s few
  lines to turn its icon upright.

## Self-hosted servers

For people who run their own Sphinx server with a self-signed certificate.
macOS does not trust such a certificate, so Peel refuses to connect. The
official Mac app solves this by accepting any certificate
(`allowUntrustCACertificate`), which also accepts an attacker's. Peel will
not do that. Instead, the first time a server shows a certificate the system
does not trust, Peel shows its fingerprint and asks once whether to trust
it. Peel remembers that fingerprint for that server (a `Setting`) and
refuses to connect if it ever changes. The CLI's `--insecure` flag stays a
development tool. Ask Tomás whether self-hosting is indeed why the Mac app
accepts any certificate before building it.

## Settings sync: the official apps' `/preferences` file

Checked 2026-10-08 in `sphinx-mac-v2`, `Managers/Data Sync Manager/`
(`DataSyncManager.swift`, `DataSyncModels.swift`).

**Where it lives.** One file per account on the memes server:
`GET /preferences` and a multipart `POST /preferences` (fields `pubkey`,
the account's pubkey in base64url, and `file`), with the memes-server
bearer token (`API/API+AttachmentsExtension.swift:252-340`). A missing file
is answered `success: false` with a known error, which bootstraps a new one.

**Encryption.** RNCryptor v3 (`SymmetricEncryptionManager.encryptString`),
base64, with the password being the account's node secret key as hex:
`Sphinx.nodeKeys(net: "bitcoin", seed:)` from the mnemonic
(`SphinxOnionManager.getPersonalKeys`, `SphinxOnionManager.swift:1156`).
Only the account's own devices can read it; the memes server stores
ciphertext.

**Format.** `{"items":[{"key","identifier","date","value"}]}`, `date` in Unix
seconds as a string, values as strings or small objects of strings:

| key | identifier | value | controls |
|---|---|---|---|
| `tip_amount` | `"0"` | int | the default boost amount |
| `private_photo` | `"0"` | bool | the account's "private photo" flag |
| `timezone` | the chat's pubkey | `{timezone_enabled, timezone_identifier}` ("" = the device's zone) | sharing and the zone, per chat |
| `feed_status` | feed id | `{chat_pubkey, feed_url, subscribed, sats_per_minute, player_speed, item_id, feed_id}` | podcast subscription, streaming sats, speed, current episode |
| `feed_item_status` | `feedId-itemId` | `{duration, current_time}` | an episode's position |
| `chat_color` | the colour key | hex string | the colour given to a chat or sender |
| `pin_timeout` | `"0"` | int hours | the PIN re-lock time |
| `biometric_enabled` | `"0"` | bool | iOS only; the Mac ignores it |
| `ai_agent_config` | `"0"` | `"provider|apiKey|agentName"` | the in-app AI agent, **with its API key** |

**When.** A change is written to a local queue (`DataSync` rows) and a sync
runs 2 s later (debounced), and also when the app becomes active and at the
end of a restore (`AppDelegate.swift:489`,
`SphinxOnionManager+AccountRestoreExtension.swift:1053`). One sync: fetch
and decrypt the file (abort on any error or malformed JSON rather than
overwrite it), merge, apply what came from the server, upload the whole
file, and only then clear the queue.

**Conflicts.** Per `(key, identifier)`, the newer `date` wins, a local
change only if strictly newer, otherwise the server's
(`DataSyncManager.swift:243-263`); items only on the server are applied
locally. `chat_color` is first-one-wins: a local colour is added only if
the server has none for that key. Dates come from each device's clock, so
skew decides close races.

For Peel: read the whole file, keep the items it does not understand
untouched, and write it back merged; never upload a file it could not
decrypt. `ai_agent_config` holds a third-party API key, so Peel should
leave it alone and never log the file.

## Not in v1 (2026-10-08)

Confirmed by Tom on the evening of 2026-10-08, together with feeds and
podcasts, Hive workspaces, the knowledge graph view and Jitsi.

- **People:** a public profile and the bounty directory on the Sphinx
  people server (people.sphinx.chat), and signing in
  to outside sites by answering a challenge with the account key
  (`SphinxOnionManager+PeopleExtension.swift`, `API+PeopleExtension.swift`
  in the Mac app).
- **LSATs:** paid access tokens that web apps buy and reuse (the Mac app's
  LSAT list and the bridge's LSAT calls).
- **Languages:** the official Mac app's translations (Spanish, Filipino,
  Japanese and three kinds of Chinese) through String Catalogs; Peel stays
  in English for now.

## Journal

The build log, kept as written.

## Account screen

Opened from your row at the foot of the sidebar or with ⌘, (the app menu's
"Account…" replaces Settings). Follows the `Profile` board of the design
canvas, adapted: no Touch ID, devices or invite rows yet. Notifications
(permission and "Message text") came with `phase3/notifications`.

- **Name** (`Engine.setAlias`, trimmed, never empty; CLI `rename <name>`).
  How it reaches others, checked against the official Mac app
  (`ProfileViewController.updateProfile`): it only saves the owner's nickname
  locally. Names and photos are not core state and the server keeps no
  profile, so nothing is announced; the name travels as `myAlias` on every
  message sent from then on (and on a tribe join), and a contact's app
  takes the newest one it sees (`updateContactInfoFromMessage`). Messages
  already sent keep the old name. Peel does the same.
- **Photo** by https link (`Engine.setPhotoURL`, now trimmed); travels like
  the name as `myImg`. Seam for upload: the attachments work uploads a
  picture to the memes server and passes the URL it returns to the same
  call; nothing fakes an upload today. Shown through the shared
  `Avatar`/`PhotoCache` in the screen, the sidebar footer and the tribe
  member list.
- **Restore recovers the photo.** The official app keeps the account's own
  photo only in its local owner record (`UserContact.avatarUrl`; Data Sync
  carries tip amount, private photo and PIN timeout, not the photo). During
  a restore it fills an empty owner nickname/photo from the account's own
  sent messages, whose sender JSON carries `alias` and `photo_url`. Peel now
  does the same at the end of a restore: if no photo is set, it takes the
  photo of the newest own direct message (`Storage.newestOwnPhotoURL`; tribe
  messages left out, as the official app does). The name is not filled
  because Peel's restore always asks for one.
- **Contact info** with Copy and a QR code (CoreImage `qrCodeGenerator`);
  the old contact-info popover on the sidebar footer is gone.
- **Twelve words**: only after the PIN (`Profile.words(pin:)`, derived off
  the main thread), masked by default with Reveal/Mask, hidden again after
  30 s, when Peel leaves the front, or when the screen closes. Copy asks
  first in place; the copy is marked `org.nspasteboard.ConcealedType` and
  cleared after a minute unless something else was copied. Never logged.
  Development profiles have no PIN, so the words show without one.
- **Change PIN**: old → new → new again (`Profile.changePIN`, existing
  `SecretStore.changePIN`). A wrong old PIN starts again; nothing changes.
- **Ask for the PIN** (timeout) moved from the `pinTimeoutHours` default to
  the account's `Setting.pinTimeoutHours`; an account that never set it
  reads the old default, which is left in place (other profiles share it).
- **Balance** read only; **server** and connection state read only.
- **Forget this account on this Mac**: the lock screen's forget logic, now a
  shared `ForgetAccountControl`, confirmed in place with what is deleted and
  that the words are needed to come back.

Verified (2026-10-07):
- Local stack (broker 1927, mixer 8047), development profiles `ac-*`: a
  restore of `ac-alice` into a fresh `ac-alice3` came back with the photo of
  her newest message (`whoami` → `photo: https://example.com/alice-2.png`);
  `rename "  "` refused; `rename Alice Bee` then a send: Bob's contact row
  became "Alice Bee" with the new photo, his earlier message still shows
  "Alice".
- Keychain: a harness built from `SecretStore.swift` and `Profile.swift`,
  bundled as `dev.peel.mac` and signed by `scripts/sign-app.sh`, on the app
  profile `ac-kc1` only: words with the right PIN, wrong PIN refused, change
  with a wrong old PIN refused (old still works), short or non-digit new PIN
  refused, change works (old refused, new opens the same words), a
  development profile refuses a PIN change, delete leaves nothing.
- App: bundled with `bundle-app.sh` into the scratchpad and launched with
  `-profile ac-alice3`; the screen renders (identity, QR, account and
  security groups, forget control).

Not exercised by hand in the app (no input automation here): editing the
name or photo, the change-PIN steps on an app profile (the app only opens
`default` with a PIN, which is off limits), revealing, masking, copying and
auto-hiding the words, the timeout picker, ⌘, and forgetting from this
screen.

Review (2026-10-07): `/code-review` (high), `/simplify` and
`/security-review` ran on this branch. Fixed: copied words stay on this Mac
(`currentHostOnly`, no Universal Clipboard) and are cleared after a minute,
on lock, on quit and on forget; a PIN check still running when the words
are hidden cannot show them; Cancel is off while a PIN change runs; Return
in an empty photo field no longer removes the photo, and a save cannot run
twice; a failed forget starts the app over from what is left instead of a
main window with no engine; forget clears all per-account state in one
place; photo recovery is best effort (cannot stop a restore finishing) and
skips own records without sender details. The engine now emits
`.profile(alias:photoURL:)` from `setAlias`/`setPhotoURL` (so a restore's
photo or a future upload reaches the sidebar without a pull) and owns the
PIN timeout (`Engine.pinTimeoutHours`/`setPINTimeout`); `PIN.problem` is
the one wrong-PIN message; the QR uses one shared `CIContext`; the account
groups reuse `panelBoxed`, `SectionLabel` and `FormFooter`. Security review
found nothing to fix.
Not applied, with reasons:
- Taking the name and photo from this account's own messages sent by
  another device (the official app does this outside a restore): useful
  with both clients side by side, but an older echo could undo a newer
  local change; needs a "changed at" rule. Next step.
- Moving the words reveal session and the copy policy into `AppModel`: the
  words already clear on lock (the screen goes away), resign and forget;
  worth doing when another surface shows them.
- One shared inline editor for name and photo, and `GhostButtonStyle` folded
  into the onboarding button styles: different layouts and sizes; revisit
  if a third editor appears.
- Building `ForgetAccountControl` on `InlineConfirm`: it needs a long
  explanation, a problem line and alignment that `InlineConfirm` lacks.
- An index for `newestOwnPhotoURL`: it runs once per restore.
- A PIN attempt limit on the account screen: the lock screen has none
  either; the slow derivation is the only brake.
- Requiring the PIN to forget from the account screen: the lock screen can
  forget without it (for a lost PIN), so it would add no protection.
