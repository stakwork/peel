# Phase 13 — A worker's invite on the iPhone

Status (2026-11-22): **built; unit-tested; not run on a device.** The Swift was written on a Linux pod with no toolchain,
so it has not been compiled either: CI (`swift build --build-tests`, `swift test`, the Mac app's `xcodebuild`) is the
first compile. The live run is under UNTESTED.

Product owner's instruction: "make it the same as Android". This ports peel-android's phases 41 (worker onboarding), 46
(invite from the clipboard), 49 (the invite's page signs in) and 51 (a pasted invite) to the iPhone, and shares what is
shared with the Mac.

## The flow

Staff on a Stadeum (strut) choose "Invite a worker". The worker gets
`https://<strut>/public/join#action=i&d=…&c=…&a=<percent-encoded Tasks URL>`. Strut's join page (stakwork/strut
`src/public-join.ts`) opens Peel with the invite and, on the same tap, copies it to the clipboard, since nothing carries a
link across an install. Peel signs up with the invite, then opens the `a=` page (the employer's Tasks, `strut/worker`) as
the account, with no question.

## Decided: Peel's own scheme

Peel does **not** register `sphinx.chat`. The separate Sphinx iOS app (sphinx-ios-v2) registers it too, and iOS does not
guarantee which app opens a scheme two apps claim (Android pins the package in an `intent://` link; iOS cannot). Peel uses
`peel://join?<the invite query>`: `peel://join?action=i&d=…&c=…&a=…`, exactly Android's `sphinx.chat://?…` query.
`InviteLink.fromPeelLink` converts it to `sphinx.chat://?<same query>` and that is what the invite parsing reads, so the
core sees what it sees on Android. The scheme on the clipboard may be either (strut's page copies the `sphinx.chat://?…`
link, or the worker copies the https join link); both are taken.

**Strut's side:** the join page must open `peel://join?…` for an iPhone (it opens `intent://…sphinx.chat…` for Android).
That is stakwork/strut's change, not made here.

## Built

- **`InviteLink`** (`Sources/PeelCore/InviteLink.swift`, tested in `InviteLinkTests`, Android's `InviteLinkTest` cases):
  `fromPeelLink` (`peel://join?…` → `sphinx.chat://?…`; exactly one `action=i`, a non-empty `d=`; no path, user or
  fragment), `fromClipboard` (a whole `sphinx.chat://?action=i&…` link, or strut's join link `…/public/join[?lang=…]#action=i&…`:
  https only, no user info, the path exactly `/public/join`, a `sphinx.chat://?` after the `#` dropped; no whitespace, at most
  3000), `appOf` (the single `a=`, percent-decoded with `+` kept, held to `PublicAppLink.init(_:)`; none, two or invalid → nil, and
  the invite is read as before; sections read from after the first `?` or `#`, or the whole text).
- **The deeplink** (`PhoneRouter.open(peelLink:)`, host `join`): the invite is held as `pendingInvite` (memory only, never
  logged) for a device with no account; the app it names waits as `waitingLink` with `waitingLinkInvited`, dropped by
  `reset()` and never carried to another link. An account already here ignores the invite and opens the app (now if ready, else
  after the PIN). `openWaitingLink` runs when the phase becomes `.ready`, which after a signup is when the person has checked
  their words (`enterApp`), so the page opens once the account is ready. A tapped link wins over the clipboard.
  - One departure from "dropped on `reset()`": onboarding's own reset (`reset(keepingInvite: true)`, called when the phase turns
    `.onboarding`) keeps an invite link's waiting app and its invite, because on a cold launch by the link they arrive before
    that phase does and the reset would wipe them. Every other reset drops them.
- **The clipboard on first launch** (`PhoneRouter.takeClipboardInvite`, called when Peel first comes to the front and when the
  phase turns `.onboarding`): once per process, only with no account on the device and no invite in hand;
  `UIPasteboard.general.hasStrings` first, so an empty clipboard is never read and iOS shows no "Allow Paste" prompt; taken only
  through `InviteLink.fromClipboard`; then treated as a tapped link (invite and `a=`), and the pasteboard cleared if its
  `changeCount` has not moved. Never logged or stored. The invite step also has Apple's `PasteButton` (no "Allow Paste?" prompt), which fills the field through `InviteLink.fromClipboard`, else the trimmed text.
- **Onboarding fill-in** (`Onboarding.fillInInvite`): a pending invite takes the new-account path straight to the invite step,
  filled in; the person still taps Continue, names themself and sets a PIN. Continue also hands the invite step's text to
  `PhoneRouter.takeInviteApp(from:)`, so a pasted or scanned invite (the whole join link included, passed to the core as
  Android does) names its app too (Android phase 51).
- **No key choice when signing in** (`WalletHost.signIn`, shared with the Mac): a challenge offers exactly the key it names, so a
  root challenge offers the account's key alone; a domain challenge is unchanged. The connect sheets (iPhone, Mac) draw no
  picker for one key. This departs from strut's `specs/WALLET.md` "Signing a visitor in" step 5, as Android's phase 49 did.
- **The invite's page is granted sign-in** (`WalletHost.grantInvitePage`): when Peel opens the page an invite's `a=` named
  (`PhoneRouter` passes `invited: true` only for that link), a wallet connection for the page's origin that signs in with
  `.root` is written before the page loads (`AppModel.openingPublicApp`). Keyed `origin:<origin>`, `app` `/<?app=>`, title and
  place the host. An existing connection keeps its grant and gains the sign-in; one that already signs in is left alone; an
  expired one counts as none. A `peel://open` link or an open from Apps is never granted. Tested in `VisitorSignInTests`.
- **Opened public apps stay in Apps** (`Storage+PublicApps.swift`, migration v37 `publicApp(seller, app, url, origin,
  openedAt)`, one row per seller+app; `OpenedPublicApp`; `AppModel.openedApps`, `openingPublicApp`, `forgetOpenedApp`): every
  public page that comes on screen is kept, whichever way it came. The iPhone's Apps lists them with the workspace apps, after
  them as normal rows (last opened first, titled by the origin's connection or the host, caption host · app; their server's host
  is the source, so the filter menu offers it and the search finds them); a tap opens one through the router; long-press › "Remove from Apps" takes one off (its connection stays). Chats'
  Apps tab lists opened apps even without a Stadeum workspace. Disconnect in You › Connected apps forgets that origin's
  apps in the same write as the connection (`Storage.deleteWalletConnection`). Each opening also asks the seller for the app's title (`PublicAppLink.appTitle`, `GET <seller>/public/apps/<name>`; v38 `publicApp.title`, kept across openings) and renames an invite's host-titled connection with it, so a worker whose page never signs in again still sees "Tasks"; the row shows a connection's title unless it is just the host, else that title, else the host. Tested in `OpenedPublicAppsTests`.
- Strings: "Apps you opened", "Remove from Apps", and two notice phrases, in English and Spanish.

## An app opens inside Apps (2026-11-23)

A tester tapped "Done" at the top of Tasks expecting to finish the task: it closed the page and left them on the tab
underneath, with the photo unsent. The page sheet read as a browser (the host as its title, Reload, Done). Now an app
opened from Apps, a worker's invite or a `peel://open` link is pushed inside the Apps tab (`AppsRoute.org` / `.visit`,
`PhoneRouter.openInApps` / `show`), like any screen of Peel's: ‹ steps back through the page's own history, then to
the list; the title is the app's (`AppModel.openedAppTitle`, never the host; untitled until the seller names it); Reload
is in ⋯; the tab bar steps aside. Switching tabs keeps the page where it was. A link or a deliverable tapped in a chat
opens full screen over it (`fullScreenCover`, `orgPage`) with ✕ to close and Reload in ⋯; there is no more Done.
`router.publicPage` and its sheet are gone. The prototype this came from compared a browser sheet, full screen, a Tasks
tab and a native button in a chat; Apps being every app's home folded the last two into this.

Not yet: the edge swipe back (Peel draws its own ‹, which turns the system's swipe off), a native primary button the
app hands Peel (strut kit), and strut's Tasks page dropping its own header when Peel names the app.

## Not built

- The Mac does not keep opened apps or read `peel://join` (the Mac gets only the shared sign-in change).
- Strut's join page opening `peel://join` (above).
- `public_app` rows are not synced or backed up: a restore starts with none.
- `a=` lives in memory until signup: a Peel killed between the invite step and the end of signup loses it (the account and its
  invite are kept).
- A cold launch that reaches Peel by the link while the account is *locked* works like any waiting link (opens after the PIN);
  not separately tested.
- Not decided: an app-site association for an https link into Peel (a universal link would need strut's host to serve it).

## UNTESTED (needs a device)

On an iPhone with **no Peel**:

1. In Safari, open a fresh invite from strut/staff ("Invite a worker") on strut.stadeum.stakwork.ai.
2. Tap Get Peel (TestFlight: https://testflight.apple.com/join/mFsg7Gkb) and install.
3. Open Peel. iOS asks "Allow Paste": allow. The invite step is filled in (the clipboard is then empty).
4. Continue, name, PIN, check the words. Tasks opens (`strut/worker`) signed in, with only a toast, no sheet.
5. Tasks opens inside the Apps tab, titled "Tasks" (not the host), the tab bar hidden; ‹ goes back to Apps, which lists it;
   Disconnect in You › Connected apps removes it. ⋯ › Reload reloads. A Hive app link tapped in a chat opens full screen with ✕.

Then, with Peel installed, tap Open in Peel on a fresh invite (needs strut's join page to open `peel://join`): the invite step
is filled in; with an account already, the app opens signed in. Also check: "Don't Allow Paste" leaves the invite step empty
and the field accepts a pasted join link; an empty clipboard shows no prompt; a `peel://open` link to the same page asks
before signing in.
