# Phase 5 — Parity: contacts, profile, People, web apps, languages

Status: in progress. Account screen built; the rest planned.

- Contacts UI: add by contact info or QR, share own QR and contact string,
  create invites with sats (`makeInvite`, `cancelInvite`), inbound requests.
- Profile: done 2026-10-07 as the **Account screen** (branch
  `phase5/account-screen`); photo upload from this Mac waits for attachments.
  See "Account screen" below.
- People and LSATs: person profiles, external auth challenge
  (`SphinxOnionManager+PeopleExtension.swift`), LSAT list.
- Web apps: in-chat web apps in a WKWebView with an authorise prompt
  (`Scenes/Dashboard/WebApps` in the Mac app).
- Self-hosted servers with their own certificates: the official Mac app accepts
  any TLS certificate (`allowUntrustCACertificate`), most likely so self-hosted
  swarms with self-signed certificates work. Peel verifies by default and must
  not go back to "any certificate". Instead, trust on first use: when a server
  presents a certificate the system does not trust, show its fingerprint and
  let the person accept it once; store the fingerprint per server
  (`Setting`), and refuse to connect if it ever changes. The CLI's `--insecure`
  flag stays a development tool. Ask Tomás whether that is indeed the reason
  before building it.
- Localisation: the six languages of the official app via String Catalogs.
- Settings sync between devices (the Mac app's `Data Sync Manager`). Tom,
  2026-10-08: Peel will need a preferences layer. What the official apps
  sync is below; the per-chat time zone switch is stored in the file's shape
  already (`../design/README.md`, "Time zones").

### Settings sync: the official apps' `/preferences` file

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
