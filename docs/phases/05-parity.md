# Phase 5 — Parity: contacts, in-app web window, self-hosted servers

## Status (2026-10-08)

**Built:** the Account screen (#10): name, photo by link or upload, contact
QR, twelve words, PIN, forget. See "Account screen" below.

**Open**, in this order (Tom, 2026-10-08: after the cleanup and calls):
- Contacts UI: "Contacts" below.
- The in-app web window: "Web window" below.
- Self-hosted servers with their own certificates: "Self-hosted servers" below.
- Settings sync between devices, if still wanted once the iPhone exists.

**Decided (2026-10-08):** People, LSATs and languages are not in v1 ("Not
now" below); web apps become a web window inside Peel.

## Contacts

Add by contact info or QR, share your own QR and contact string, create
invites with sats (`makeInvite`, `cancelInvite`), inbound requests. Adding by
contact info and showing your QR exist (the sidebar's "Add contact", the
Account screen); scanning a QR, invites and inbound requests do not.

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
the chat, with back, forward, reload and "open in a new window"; the tribe's
app URL first, the second brain URL if there is no app URL. Pages talk to it
through a `sphinx` message handler (`WebAppHelper`): `AUTHORIZE` with a sats
budget, `KEYSEND`, `PAYMENT`, `SIGN`, `GETBUDGET`, the LSAT calls and more.

Open questions:
- A pane beside the chat, a sheet, or its own window? Does it stay open when
  you change chats?
- Which links open inside Peel: every https link, or only tribe apps, with
  everything else still going to the browser?
- Does Peel offer the `sphinx` bridge at all? Without it a page is just a
  page; with it, `AUTHORIZE` and `KEYSEND` need a budget that goes through
  `Engine.checkPayment`. The LSAT calls are part of LSATs, which are "Not now".
- What the window may reach: cookies and storage per tribe or shared, file
  downloads, pop-ups, and whether a page can ever navigate to a
  `sphinx.chat://` link.

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

## Not now (2026-10-08)

- **People:** a public profile on the Sphinx people server, and signing in
  to outside sites by answering a challenge with the account key
  (`SphinxOnionManager+PeopleExtension.swift`, `API+PeopleExtension.swift`
  in the Mac app).
- **LSATs:** paid access tokens that web apps buy and reuse (the Mac app's
  LSAT list and the bridge's LSAT calls).
- **Languages:** the official app's six languages through String Catalogs;
  Peel stays in English for now.

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
