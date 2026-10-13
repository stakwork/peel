# Phase 2 — Safe accounts: Keychain, onboarding, restore

## Status (2026-10-08)

**Built and merged:** signing with the Personal Team (re-sign weekly), the
words sealed under a six-digit PIN in the data-protection Keychain,
onboarding, the engine-driven restore, Tom's real account in the `default`
profile; then long messages, read markers, mutes and mark unread, send
failures, the composer, contacts the other side started surviving a
restore, and `run-app.sh` quitting Peel first ("Still open in this phase",
items 0 and 6–11, all done). Item 12, sends across a dropped connection
(resend on reconnect, a keep-alive that notices, network changes), is
built on its branch. Item 13, the twelve words checked (finding N5), is
built on its branch.

**Open:**
- Signing up with a fresh invite in the app (proven only from the CLI): "Tasks, in order", item 3.
- Running the real account beside the official app with no loss, Tom's check: "Done criteria".
- Bringing a running Peel forward when its profile is locked: "Still open in this phase", item 11.

**Decided:** the PIN is required; an app profile never writes the words to
a file; the Keychain item is this-device-only, so a new Mac needs the
twelve words; never `setPushToken`; no session touches `default`.

## Journal

The build log, kept as written.

Status on 2026-10-07: core goal reached that evening. Tom restored the throwaway's twelve words in the signed app with a PIN; the Keychain item exists, no mnemonic file does, and the engine-driven restore brought back the contact and history. What remains is listed under "Still open in this phase".

Goal: Peel can hold a real account safely. The twelve words live in the
Keychain, a new account can be created from an invite, and an existing account
can be brought back from its twelve words with its contacts and history. The
restore is the point of this phase; the Keychain is what makes it allowed.

## Rules for this phase

- No real account touches Peel until tasks 1, 2 and 4 are done and task 4 has
  been proven on the throwaway's own words.
- The app never writes a mnemonic to a file. The plain file store stays for
  the CLI and its throwaway profiles only. Until task 2 lands, the app's
  onboarding refuses twelve words outright (`AppModel.join`); task 4 removes
  that refusal.
- Never call `setPushToken`. A real account restored into Peel is one more
  device on that account; the server keeps a single push token per account and
  registering ours would take notifications away from the official app.

## Tasks, in order

1. **A stable signing identity.** Done for local use (2026-10-07): Tom's
   Apple Development certificate (personal team ID T3M78XC3UV) plus Apple's WWDR
   G3 intermediate in the login keychain; `scripts/sign-app.sh` signs the
   bundle with it, hardened runtime on. No Xcode project yet: it is not needed
   for local signing, only later for TestFlight and the iPhone target.
   Original brief: Keychain items are tied to the signed app,
   so an ad-hoc signature that changes on every build is useless. Add an Xcode
   project that builds the package's `PeelApp` target with the Apple
   Development identity, a fixed bundle ID (`dev.peel.mac` or whatever Tom
   prefers) and a hardened runtime. Keep `swift build` and `scripts/run-app.sh`
   working for the CLI and quick checks, but the app ships from Xcode from now
   on. Update `AGENTS.md` and the README.
2. **Keychain storage with a PIN.** Done and verified in the signed app
   (2026-10-07: Tom restored the throwaway's words into the app's own profile;
   the Keychain item exists and no mnemonic file does). Tom decided a
   six-digit PIN is required, as in the official apps. `SecretStore` with
   `KeychainSecretStore` (app profiles, `Application Support/Peel/<name>`;
   the words are sealed under a key derived from the PIN with
   PBKDF2-HMAC-SHA256, 2.5M iterations and a random salt, then AES-256-GCM;
   versioned blob in a generic-password item) and `FileSecretStore`
   (development profiles under `Peel/dev/<name>`, CLI only, no PIN).
   `Profile(name:kind:)` picks the store and exposes `requiresPIN`; the app
   uses `.development` only when launched with `-profile`. The PIN lives only
   in memory; timeout and re-asking are the app's job.
   Honest limits, from the security review: a six-digit PIN at ~0.4 s per
   guess falls to an offline search in minutes on a GPU and hours on a laptop
   if someone gets the sealed blob out of the Keychain. The Keychain is the
   real wall; the PIN stops a passer-by at an unlocked Mac. Since "Still open"
   item 0 the item is in the data-protection Keychain, not the login keychain
   file.

3. **Onboarding.** Done in the app (2026-10-07): welcome → invite link or
   twelve words → name → PIN → confirm PIN → the words shown once (new
   account) or restore progress (existing account); PIN lock at launch with a
   timeout setting; "forget this account on this Mac" on the lock screen; a
   banner when a development profile's words are in a file. The new-account
   path has not yet been exercised with a fresh invite in the app (signup is
   proven from the CLI); do that with the next invite.
4. **Restore from twelve words.** Done. `Account.restore` marks the account
   (`needsRestore`) and the engine runs the plan itself the moment it is
   online: `getMsgsCounts`, then one message per contact key
   (`fetchFirstMsgsPerKey` paging, from which the core recreates each
   contact), then every message from index 0 to the server's highest. Runs
   queue behind one another, a dropped connection resumes the page in flight,
   a page that never comes fails the run after 30 s, and the app observes
   progress through `.history`, `.historyDone`, `.historyFailed`. Names come
   with the messages: the core recovers each sender from the message
   signature, so a sender can only name themself, and contact records are
   honoured only when signed by this account. Verified 2026-10-07 from the CLI
   into a fresh profile (contact, name, all messages) and by Tom in the app.
   The app shows the progress and offers "forget this account" on the lock
   screen.

5. **Real-account checklist**, done by Tom, not an agent: Keychain in place
   (done), restore proven on the throwaway in the app (done), CLI closed (the
   profile lock enforces one process), official app still installed. Restore
   the real account, then use both clients side by side for a few days before
   relying on Peel. Done 2026-10-07: Tom restored his real account into the
   app's `default` profile after tribes and the data-protection Keychain
   landed; history came back complete. From here `default` is off limits to
   every session (see AGENTS.md Rules), and the CLI refuses it.

## Still open in this phase

0. **Data-protection keychain.** Done 2026-10-07 (branch
   `phase2/data-protection-keychain`). The words now live in the
   data-protection Keychain (`kSecUseDataProtectionKeychain`), access group
   `T3M78XC3UV.dev.peel.mac`, `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`,
   not synchronizable; `PINBox` sealing is unchanged. Being ThisDeviceOnly,
   the item is wrapped by a key tied to this Mac and is not carried by Time
   Machine, iCloud Keychain or a migration to another Mac: a new Mac needs
   the twelve words (stated, not tested).
   Migration: on unlock with the right PIN, an item still in the login
   Keychain is copied over, read back and compared byte for byte, and only
   then deleted. If any step fails the old item stays and the unlock shows
   the error. A wrong PIN moves nothing. Forget deletes from both keychains;
   a save is refused while an old item exists.
   Signing: a free Personal Team is enough. Spike, 2026-10-07:

   | Approach | Launches | `SecItemAdd` |
   |---|---|---|
   | Hand-built bundle, Apple Development identity, no entitlements | yes | -34018 (missing entitlement) |
   | Same, with `keychain-access-groups` entitlements, no profile | killed at launch (SIGKILL) | — |
   | Minimal Xcode project, automatic signing, `xcodebuild -allowProvisioningUpdates` | yes | 0; read and delete 0 |
   | Hand-built bundle + entitlements + the profile Xcode fetched, embedded | yes (direct and via `open`) | 0; read and delete 0 |
   | Item written under profile 1, read by a build with a newly fetched profile 2 | yes | read 0, same value |

   Xcode was already signed in; it fetched "Mac Team Provisioning Profile:
   <bundle id>" with no prompt. The profile's `TimeToLive` is 7 and its
   expiry 7 days after creation; it grants `keychain-access-groups`
   `T3M78XC3UV.*` and lists this Mac only. Not tested (it would need the
   clock moved): launching with an expired profile. macOS is expected to
   refuse the launch, and the item, owned by the access group, is read again
   by any build re-signed with a fresh profile, as the last row shows.
   `scripts/sign-app.sh` now embeds the profile and entitlements and fetches
   a fresh profile through `scripts/provision` when the current one has under
   two days left; `scripts/bundle-app.sh` builds a signed bundle without
   installing it. Weekly re-signing is in `AGENTS.md` ("Signing and the
   weekly re-sign"): run `./scripts/run-app.sh` at least once a week.
   Verified with a harness built from `SecretStore.swift` and `Profile.swift`,
   bundled as `dev.peel.mac` and signed by `sign-app.sh`, on `kc-*` profiles
   only: create, unlock, wrong PIN refused, change PIN (old refused, new
   works), duplicate save refused, restore from words, delete (both keychains
   empty); item attributes `pdmn=aku`, `sync=0`, access group as above.
   Migration: a profile created by a harness built from `origin/main`
   (login keychain) unlocked with the new build: wrong PIN moved nothing;
   right PIN left one data-protection item and nothing in the login keychain
   (`security find-generic-password -s dev.peel` lists only `default`). A
   build without the profile failed the move with the entitlement error and
   kept the login item; the provisioned build then moved it. The signed app
   itself launches (run on a development profile; the `default` profile was
   not touched). Not exercised by hand in the app: the lock screen showing a
   migration error, and Tom's own first unlock, which performs the move.

   Review (2026-10-07): `/code-review`, `/simplify` and `/security-review`
   ran on this branch. Fixed: the login keychain is read only while no
   data-protection item exists, so a locked or broken login keychain cannot
   block unlock after the move, and a failed removal of the old copy errors
   once and then unlocks from the new copy; `save` checks both keychains
   before the slow seal; `PEEL_SIGN_IDENTITY=-` signs ad hoc again; the
   provisioning stub builds with `-target` (no shared scheme needed). Signing
   now takes the profile and entitlements from the stub app Xcode signed
   (single source of truth, checked against the app ID, certificate and a
   two-day margin) instead of scanning Xcode's profile folder; the stub has
   no `get-task-allow`. Renewal checked by forcing it: the old profile was
   set aside, Xcode issued a new one, and a build signed with it read the
   `kc-*` items. Security review found nothing to fix.
   Not applied, with reasons:
   - Moving the item at launch without the PIN: the brief was "on unlock",
     and opening it first means only a blob that decrypts gets moved.
   - Dropping the read-back after `SecItemAdd`: the brief asked for it; one
     query, once per account.
   - `hasMnemonic` cannot tell a build without the entitlement from "no
     account" (the data-protection read returns not-found, not -34018), so
     such a build would show onboarding. Only an ad hoc build hits this
     (an expired profile stops the launch instead); `sign-app.sh` warns.
   - A real Xcode project for the app (Xcode would bundle, sign and renew
     itself): bigger than this item; the stub covers the profile.

6. **Long messages.** Done (checked in the code 2026-10-07, branch
   `phase4/boosts-payments`; Tom sees them display correctly). The vendored
   library includes `sphinx-ffi/src/chunk.rs`: `send` splits any JSON over
   about 569 bytes minus the alias and photo URL into type 34 fragments,
   publishes them all and returns one `msgs[0]` whose uuid is the chunk id
   and whose tag is the last fragment's, so Peel's row, its status and the
   echo all match. `handle`, `fetchMsgsBatch` and the other fetches buffer
   fragments in core state (`chunkbuf_*`, 300 s timeout) and hand back one
   reassembled message with the original type, the chunk id as uuid and the
   last fragment's index; in a tribe our own long message comes back under
   the same chunk id and merges into its row. Nothing to build. Caveats:
   every fragment carries the send's full amount, so in a tribe a long
   message pays the price once per fragment (as the official apps do) and a
   payment must never be split (phase 4 refuses such notes). A history page
   made only of fragments of an unfinished message no longer ends catch-up
   early: the cursor moves by the indices the server sent (item 13).
7. **Read markers and mutes.** Done 2026-10-07 (branch
   `phase2/status-and-composer`). The engine asks for `getReads` and
   `getMutes` each time it comes online; the replies land in a new
   `chatState` table (migration v4: `lastRead` server index, `muteLevel`).
   (Superseded by "Mark unread and the read-marker fix" below.) A read marker only moves forward, and when the server's marker is behind
   ours (read while offline) the engine sends `read` again.
   `Engine.markRead(chat)` runs when a chat is shown with the window in front
   and whenever a message lands in the open chat; `Engine.setMute(chat,
   level:)` from the sidebar's context menu (Mute / Unmute; level 2 or 0).
   Unread = incoming text messages past the marker (`Storage.readStates()`);
   the sidebar shows them bold with a blue count, muted chats dimmed with a
   crossed-out bell and no count. The mixer does not push read changes from
   other devices, so they show only on the next connect.
   Verified on the local stack: unread 1 → `read` → 0; `mute 2`; local
   markers wiped, reconnect, both came back from the server.
   After a restore the engine asks again once history is in, because the
   core drops markers for contacts it has not rebuilt yet (verified: a
   restored profile came back read and muted).
   Open: "mentions only" (level 1) has no UI until tribes.

   **Mark unread and the read-marker fix** (2026-10-07, branch
   `phase3/unread`, migration v12). The rules above ("a marker only moves
   forward", "send `read` again when the server is behind") broke mark
   unread on the official apps: the mixer stores whatever index it is sent,
   lower too (`mixer/src/handler.rs` READ, `db/read.rs`), and the official
   apps apply the server's markers as truth (`Chat.updateMessageReadStatus`),
   but Peel ignored a lower one and pushed its own higher marker back on the
   next `getreads`. Now:
   - `chatState.readPending` marks a marker moved here and not yet sent.
     Markers in a `getreads` reply replace ours, lower ones included, except
     where ours is pending; the engine then publishes only the pending ones
     and clears the flag once sent (`Storage.readSent`, only if the marker
     has not moved again). A chat whose `read` was published after the
     `getreads` request went out is skipped when its reply is applied
     (`Engine.readsSentSinceGetReads`): the mixer handles each request in its
     own task, so the reply may predate the marker.
   - `Engine.markRead` still only moves forward (the server's marker may be
     past what is stored here); offline it stays pending.
   - `Engine.markUnread(chat, fromServerIndex:)` sets the marker to the
     index − 1 (unread counts `serverIndex > lastRead`); `markUnread(chat)`
     uses the newest incoming message, so the chat counts one, as the
     official apps' chat-level "Mark as Unread" (`setReadLevel(previousMsg)`).
   - Sending: the mixer moves the marker to the sent message
     (`send.rs` 318–320), so a delivered send marks the chat read locally
     too, not pending (`Storage.readBySending`).
   - Threads have no marker of their own: a thread's unread is its chat's
     marker, so marking unread from a thread message marks the chat.
   - CLI: `read` and `mark-unread <pubkey> [server index]` run offline too
     (the marker waits as pending); `unread` prints the marker.
   App: "Mark unread from here" in an incoming message's menu, "Mark as
   unread" in a sidebar row's menu (when the chat has an incoming message
   and nothing unread). After a manual unread in the open chat it is not
   marked read again until you leave it, scroll back to its bottom or send.
   A "New messages" divider (blue) goes above the first incoming message
   past the marker the chat had when it was opened (captured before marking
   it read); the chat opens scrolled to it, else at the bottom. It stays
   until you change chats or send; a manual unread moves it. The thread
   panel uses the same captured marker. "Incoming" is what counts as unread
   (`Storage.countsAsUnreadSQL`, from the boosts branch): someone else's
   text, attachment or payment, or their boost on your message; with only
   new boosts, the divider goes above the first boosted message of yours.
   Chat-level "Mark as unread" uses the newest such message.
   Verified on the local stack (`ur-*` profiles, Alice on two devices
   restored from the same words, Bob): device 2 marks unread from #7 →
   device 1 reconnects, shows 3 unread at marker 6, and device 2 reconnecting
   again still reads 6 (nothing pushed back); device 2 reads with the broker
   down (marker 9, pending) → broker back → reconnect publishes it, pending
   clears, device 1 picks up 9; with 3 unread, Alice sends → local marker
   read at once, device 2 picks up the server's 10. Bundled app on
   `ur-alice`: the divider, the message menu and the sidebar menu
   (screenshots in the session). Not exercised by hand: clicking the menu
   items in the app, the hold on the open chat and its release at the bottom.

   **Reads across clients** (2026-10-12, `fix/read-sync`). Tom: a chat
   read on the iPhone reads in Peel, one read in Peel stays unread in
   Sphinx. Found: the mixer stores a `read` (inclusive server index, as
   Peel and the official apps send it) and pushes nothing to the other
   devices but a badge count to the one push token; each client asks with
   `getreads`/`getmutes`. The official apps ask on every coming to the
   front (Mac `applicationWillBecomeActive` → `reconnectToServer` →
   `startNewMsgsSync` and `refreshUnreadStatus`; iOS
   `applicationWillEnterForeground`, pull to refresh, after each history
   page); Peel asked only once per connection. And Peel sent `read` for the
   open chat only when its own unread count was above 0, which leaves out
   joins, leaves, other members' boosts and blank messages; the server's
   badge and the official apps count every message past the marker, so a
   tribe whose newest messages were such stayed unread there.
   Now: `ChatReadState.isBehind` (someone else's message past the marker,
   of any type; our own need none, the server moves the marker to each we
   send) gates marking the open chat read instead of `unread > 0`
   (`readStates` now also re-emits on an uncounted message, which is what
   triggers it); `Engine.refreshReadsAndMutes` asks again each time the
   app comes to the front, unless an ask is still unanswered (30 s), and
   before the open chat is marked read, so that `read` goes after the ask
   and `readsSentSinceGetReads` keeps the answer off it. Mutes have the
   same guard now (`mutesSetSinceGetMutes`). Both sets empty only on an
   ask with none outstanding, so a late answer to an earlier ask cannot
   lower a marker sent since. Journey `Reads.markersAndMutesAcrossDevices`.
   Review, not applied: the sidebar's and thread rows' "Mark as read" still
   show only with Peel's unread (offering it on a chat Peel shows read would
   confuse; opening the chat now reads it); no floor between answered asks
   (one getReads and getMutes per activation, as the official Mac app);
   activation's mark read waits behind the ask's publish (local, short);
   the gate itself lives in `AppModel` and is covered by the storage test
   of `isBehind`, not by a journey; no unit test of the mute guard (needs
   the core).
   Left: nothing is live while both apps stay in front (the server has no
   push for it); a delivered notification on the iPhone is not taken
   away by a read in Peel (the server sends only the badge count).

   **Jump to a message** (same branch). `AppModel.focus(on:inThread:)` opens
   a message's chat scrolled to it (anchor centre) and lights the row (the
   selection tint, held 0.4 s, then fading out over 1.5 s); the quote click
   already did this in `MessageList.go(to:)`, which both now share. Used by
   the Mentions list, a notification click (the notification carries the
   message id; a summary notification its first new message), the Threads
   list (the thread panel, at the first new reply when some are new) and the
   pinned bar (click anywhere but Unpin). A message folded into a collapsed
   thread opens that thread's panel and lights it there. One older than the
   newest 200 is loaded with everything after it
   (`Storage.timelineLimit(reaching:)`, counted once when you jump, then
   `timeline(in:limit:)`: the limit grows to reach it, plus 20 older ones;
   not when the message already has a row, a collapsed thread's included); one deleted since opens the chat with "That message was
   deleted". It takes precedence over the "New messages" position.
   Verified in the bundled app on `ur-alice` (220 messages, the target the
   8th, outside the newest 200): the longer timeline loaded, the list
   scrolled to it and the row lit and faded (screenshots). Found while
   verifying: the list showing before the reload took the target, did not
   find it and gave up; the anchor is now set before `focus`, and a list
   gives up only on a target within what it has loaded. Scrolling from the
   new list's `onAppear` was undone by its initial bottom anchor; it waits
   0.1 s. Not exercised by hand: Mentions, a notification click, the Threads
   list and the pinned bar (each only calls `focus(on:)`; no tribe on this
   stack), and a deleted target. Known limit: for a very old target the
   timeline holds everything after it (no gap), and the lazy list can land
   the row near the top rather than the centre.

   Review (`/code-review` high, `/simplify`, `/security-review`). Fixed: a
   pending read now gives way to a server marker at or past it (pending is
   `read` or `unread`; only an unread is sent whatever the server holds);
   mark read/unread need a core contact, so nothing stays pending for good;
   reaching the bottom ends the hold only when scrolled by hand (not by a
   new message's auto-scroll) and only in the chat's list; a mark unread
   that returns after leaving and coming back does nothing; scrolling to
   "New messages" targets its row's id (it shares the row's view); a failed
   local write after a delivered send no longer fails the send; one
   `markUnread(_:fromServerIndex:)`; shared `highestServerIndex` query;
   fewer row rebuilds. Security review: no findings. Not applied, with reasons:
   - Markers moved ahead of the server by an older build (read offline, then
     upgraded before reconnecting) are replaced by the server's on first
     connect: marking them all pending in the migration would push them over
     any unread made on the official apps, the bug this fixes.
   - Keeping a marker pending until a `getReads` reply confirms it, instead
     of `readsSentSinceGetReads`: a reply cannot be told apart from one sent
     before the marker, so another device's later change would be pushed
     back; the per-request set is the narrower rule.
   - A send racing a mark unread (`readBySending` overrides the pending
     unread locally): rare; the next `getReads` brings the server's marker.
   - "Mark unread from here" on a message past a lower marker moves the
     marker forward (earlier messages become read): intended, as Slack's.
   - The sidebar menu's `newestIncomingIndex` query on the main actor: one
     indexed query when the menu opens; folding it into `readStates` would
     add a subquery per chat on every change.
   - Sharing one view between the day and "New messages" dividers, and one
     upsert helper for the three `chatState` writes: different shapes and
     rules; small.

   Rebased onto the boosts branch (v11 before this v12). The hover bar is
   Reply, Boost, More; the message menu has "Boost…" and "Mark unread from
   here"; payment rows take the divider and the jump highlight.
   Second `/code-review` (high, the jump and the rebase). Fixed: jumping to a
   thread's original already on screen (the pinned bar) no longer reloads
   everything since it; the reach-back count runs once per jump, not on
   every change; a list judged how far back it was loaded by a collapsed
   thread's original instead of its row's time; the Threads list opens at
   the first new reply, not the newest; leaving "Mark unread" and the
   divider happens only once a send has gone, and boosts and payments do it
   too; `markRead` moves the local marker again for a chat without a core
   contact (it is sent once there is one); a failed storage read no longer
   says "That message was deleted"; "Mark unread from here" on a run of
   images starts at its first image. Not applied, with reasons:
   - `readsSentSinceGetReads` filters every commit's markers, not only the
     `getreads` reply: only that reply carries markers (`handler.rs`
     GET_READS sets `last_read`), and the set clears with each request.
   - The 0.1 s wait before scrolling to a focused message on a new list: a
     list slower to lay out could still land at the bottom; a retry until
     the row is visible needs scroll-position tracking the list lacks.
   - Resending a failed message does not end "Mark unread" in the app (the
     engine still marks the chat read): rare.

   **Jump to newest** (same branch). Scrolled up more than a screen from
   the bottom, a conversation or thread panel shows a round button with a
   down arrow at its bottom-right, over the list above the composer
   (`menuBoxed`, fading in and out); new messages that arrive below meanwhile
   no longer pull the list down (your own still do) and are counted on it
   in an accent badge, by the same rule as "New messages" (others' text,
   attachments and payments). Click, End or Command-Down scrolls smoothly to
   the newest, and in the chat counts as reaching the bottom (ends a "Mark
   unread" hold, reads the chat). Verified in the bundled app on `ur-alice`:
   jumped to an old message, Bob sent three, the button read "3"
   (screenshot). Not exercised by hand: the click and the shortcuts.
   The shortcuts are on the chat's list only, and only while its composer
   is empty (End and Command-Down move the cursor in a draft). Opened at
   "New messages" more than a screen up, the count starts with the unread
   below it. `/code-review` (high) on this: fixed collapsed threads (follow
   and count by their newest reply), shortcuts clashing between the chat
   and the thread panel, the count reset by a resize, a missing count when
   opened at the divider; one `Message.countsAsUnread(after:)` for the
   divider and the count. Not applied: whether the list's bottom anchor for
   size changes still nudges the reading position when a tall row arrives
   below (not seen; needs a hand check).

   Rebased onto main with #22 (relative times), #24 (one-tap boost) and #25
   (copy feedback): the hover bar is Reply, the one-tap Boost bolt, More;
   the message menu has Reply, "Boost 100 sats" (B), "Boost…", the copy
   items with the Copied pill, "Mark unread from here". A one-tap boost
   ends a "Mark unread" hold like any send. `/simplify` and
   `/security-review` on the jump work (security: no findings). Applied:
   the jump button's badge is `UnreadBadge`; it reads the draft itself (typing
   no longer redraws the list); the grown timeline drops back to the newest
   200 once the chat's list is at its bottom; one page-size clamp; the
   thread opens through `openThread(of:)`; `firstUnreadReply` uses
   `countsAsUnreadSQL` (boosts excluded: they have no row to open at); one
   loop for the two shortcuts. `/code-review` (low) on the merge: fixed a
   jump into a chat not open losing its longer timeline as the chat opened.
   Not applied: an "initial scroll target" in place of the 0.1 s wait,
   anchored timeline windows instead of a growing limit, one open-chat state
   struct for the four per-chat fields, `.onKeyPress` for the shortcuts, a
   shared flash modifier for message and payment rows, and taking the
   focus reads off the main actor: each is a broader change than this item.

   Re-checked after the rebase on a fresh local stack: chat-level
   `mark-unread` → 1 unread, the bundled app shows "New messages" above the
   newest of Bob's messages, and a jump to an earlier message lights its row
   and fades out over about 1.2 s while the divider stays.
8. **Send failures.** Done 2026-10-07. A sent message shows a green bolt by
   its time once the server confirms it (`COMPLETE`, as the official apps),
   fades while pending, and shows "Not delivered · Retry · Discard" when it
   failed or has waited over 30 s unconfirmed (the official apps' rule,
   `Message.isRetryable`). A publish that fails marks the row failed instead
   of leaving it pending. `Engine.resend(messageID:)` sends the same body
   again; the core gives each send a new uuid and tag, so the same row takes
   them over (`Storage.Commit.resend`) and the server's echo matches it: no
   second row. `Engine.discard(messageID:)` deletes an undelivered row
   locally (Discard asks once, in place). Errors that belong to a chat (a
   refused send, a message that could not be read) arrive as
   `Event.conversationError` and show above that chat's composer; the rest
   stay `coreError`. The connection is a bolt in the sidebar header: green
   connected, orange otherwise (orange while connecting too, decided
   2026-10-07); click for the state, a live retry countdown,
   the last connection error and "Reconnect now" (`Engine.reconnectNow`).
   Verified on the local stack from the CLI: send → delivered; broker
   stopped → send → failed; broker back → resend → same row id.
   Accepted for now (2026-10-07): a retry of a message that was in fact
   delivered (pending past 30 s but the server did get it) arrives twice for
   the recipient; the official apps share this.
9. **Composer polish.** Done 2026-10-07. The composer is a text view
   (`ComposerField`): Return sends, Shift-Return or Option-Return adds a line,
   paste is plain text only, smart quotes and dashes are off, it grows to
   eight lines. https links in bubbles are clickable (others stay text). The
   time shows under the last message of a run (same side, under five
   minutes apart) and beside any bubble on hover, without moving the layout;
   the full date is in the bubble's tooltip.

   Checked for items 7–9 so far: everything protocol-level on the local
   stack from the CLI (`messages`, `resend`, `discard`, `unread`, `read`,
   `mute` commands added for this); the sidebar rows, bubbles, bolts,
   undelivered actions and notice bar in an offscreen render. Not yet
   exercised by hand in the running app: typing in the composer (Return,
   Shift-Return, paste), hover times, clicking a link, the context menu,
   the connection popover and its countdown, Discard's confirmation, and
   marking read when the window comes to the front.

   Review (2026-10-07): `/code-review`, `/simplify` and `/security-review`
   ran on this branch. Fixed: an empty read map from the server (the core
   leaves `lastRead` out) now still pushes local markers, reconciled only in
   reply to `getreads`, so it cannot loop; the resend UPDATE checks chat,
   `fromMe`, type and pending/failed itself; unread counts use a new
   `message(chat, serverIndex)` index (migration v5) per conversation instead
   of scanning the message table; `connect()` clears the reconnect task; the
   connection popover shows the last connect error, not any notice; the
   composer leaves input-method text alone, Cmd-Return sends again, and iOS
   falls back to a `TextField`; one sidebar row view; pending rows redraw once
   at the timeout. Security review found nothing to fix.
   Not applied, with reasons:
   - Retry or Discard on a message pending past 30 s that the server did in
     fact get: Discard's row comes back with the next history fetch, and
     Retry leaves the original's late echo or history copy as a second local
     row. Accepted with the recipient-side duplicate above; the fix is an
     engine sweep that marks pending sends failed only when the server says
     so, which the protocol does not offer.
   - Moving pending to failed in storage after the timeout (so only `failed`
     is retryable): changes what the CLI and storage show; the view and
     engine both use `Message.isRetryable`, one rule.
   - Folding unread and mute into the `conversations()` query: worth doing,
     but it reshapes `Conversation` and the sidebar; the indexed per-chat
     query removes the cost that mattered.
   - Resend as "insert new row + delete old": keeping the same row keeps its
     place and id in the open chat; the guarded UPDATE is enough.
   - Showing a failed send only by its row (no banner): the banner carries
     the transport error text, which the row does not.
   - Caching link detection or day/run flags per message: the bubble is now
     its own view, so hover no longer redoes it; measure before caching more.
10. **Restore: contacts started by the other side.** Fixed 2026-10-07
   (branch `fix/restore-contacts`). Symptom: Gus adds Fay, Fay's Peel
   answers, Fay restores her words into a new profile and Gus is gone, until
   either side sends a message on the contact's key.
   Cause (Peel): a restore rebuilds contacts from the first message on each
   child key (`fetchFirstMsgsPerKey`). For the answering side that is its own
   contact record (type 33), which the core sends to the new child key in
   the same result that registers the key (`handle_msg.rs` `ContactKey` →
   `send.rs` `add_contact_inner` → `handler.rs`
   `push_contact_key_record_msg`, on `sendself`). The mixer handles every
   request in its own task (`mixer/src/mqtt.rs` `spawn_router`), so the
   `sendself` peeled before `register` had written the key
   (`send.rs` `unwrap_onion`: `get_scid_for_pubkey` fails, the onion goes
   to "a peer" and fails) and `spawn_send_thread` drops a `sendself`
   failure without a status. Peel published register and the rest back to
   back; the Mac app waits 0.25 s after a register and 0.5 s more before
   the topics (`SphinxOnionManager+HandleStateExtension.swift`
   `handleRegisterTopic`, `handleTopicsToPush`), and the reference client
   waits for the async payment before the topics (`wasm/test/auto/main.ts`
   `handle_rr`). The adding side lost its first record the same way but
   sends a second one on the confirmation, so only the answering side lost
   the contact.
   Fix: `Engine.complete` publishes settle and register, waits 0.75 s when
   the register is for a new child key (`newChildIdx`: add contact, answer,
   tribe join), then publishes the rest on the current transport
   (`Engine.publishPlan`, unit tested).
   Verified on the local stack (`rs-*` profiles): before, Fay restored with
   no contacts and the server held only Gus's key exchange for her; after,
   Fay (answer only) and Erin (answer, then a DM) restore with the contact
   ready, and the adding side keeps both records. Still a timing margin, as
   in the official app; the robust fix is the mixer finishing `register`
   before later requests from the same client (not changed here).
   Accounts that answered a key exchange in Peel before this fix have no
   record on the server for that contact; a restore brings it back only once
   either side has sent a message on the contact's key.
   Review (`/code-review`, `/security-review`): fixed a cancelled wait
   skipping the rest and a reconnect during the wait publishing on the old
   transport. Not applied, with reasons:
   - Waiting for the register reply instead of a fixed time: the reply comes
     through the same serial inbound loop the wait runs in (answering a key
     exchange happens inside `receive`), so it needs the rest moved to its
     own task; worth doing with the mixer fix, not for this.
   - The wait holds the inbound loop for 0.75 s per new key: rare (a key
     exchange or join), and the official app waits as long.
   - Waiting between the async payment and the topics as well (the Mac app
     waits for the payment's tag): a separate race, not seen to lose
     anything on the local stack.
   - Re-sending contact records for contacts already answered: the core has
     no call that makes a lone type 33; needs a core change.
   Simplify pass: the two publish loops now share `Engine.publish`, and the
   comment in `complete` points at `publishPlan`. Not applied:
   - A per-key publish gate (a "register settles at" deadline checked by
     every publish): the engine actor is free during the wait, so another
     `run` or `send` (a DM to the new contact, a second key exchange) can
     publish before the register lands. Rare (a send within 0.75 s of
     answering); the gate belongs with waiting for the register reply.
   - Shortening this entry's cause trace: the citations are what make the
     timing margin checkable against the core and the Mac app.
11. **`run-app.sh` quits the installed Peel first.** Done 2026-10-07. Before
   replacing `~/Applications/Peel.app` the script sends a quit Apple Event
   (`NSRunningApplication.terminate`) to this user's processes running that
   exact binary (escaped, anchored pattern), so `willTerminate` still clears
   the clipboard and delivered notifications; if one is still running after
   10 s it stops with an error and replaces nothing. Checked with `sh -n` and
   the block run against a dummy bundle in a temporary directory, never the
   installed app. Review, not applied:
   - It quits every installed instance whatever its profile: the bundle is
     replaced under all of them anyway.
   - Copies running from `.build/Peel.app` or `swift run` are not quit; only
     the installed copy is the script's concern.
   - No SIGKILL after the timeout: an error is safer than killing a process
     mid-write.
   - The deeper fix, the app handling a held profile lock (bring the running
     instance forward instead of showing onboarding), is a separate change.

12. **Sends across a dropped connection.** Done 2026-10-10. Asked by Tom
   on a train: "I came from disconnected to connected. It auto-retries my
   msgs, right?" It did not, and Retry on a flaky link seemed to do
   nothing. What was found:
   - mqtt-nio's own keep-alive never notices a dead connection: its ping
     waits for the answer with no timeout (`MQTTClient.Configuration.timeout`
     was nil) and a failed ping does not close the channel. A connection
     whose network had gone stayed "Connected" (green bolt) until the OS
     gave up on the socket, minutes later. A connect to a dead network
     likewise waited for its CONNACK for good.
   - So Retry on such a connection published into the dead socket: the
     write succeeded locally, the row went back to pending with no error,
     and 30 s later offered Retry again. That is "Retry didn't work".
   - Nothing resent on reconnect: a message sent offline failed at once
     (`commitAndPublish` → `.none` → `notConnected`) and stayed failed.

   Built:
   - **Keep-alive that notices.** The client's own ping is off; the engine
     pings every 15 s (`Engine.keepAliveInterval`, the same MQTT keep-alive
     as before) and a ping with no answer, and nothing else heard, within
     5 s (`pingTimeout`, `Transport.answersPing`) closes the connection and
     reconnects at once (`connectionAnswers`). ACK waits (CONNACK, SUBACK)
     time out after 20 s.
   - **Network changes.** While the engine keeps connected (`start`), it
     follows `NWPathMonitor`: each path change (Wi-Fi to 4G, offline to
     online) pings at once if connected, or skips the reconnect's backoff
     if offline and the path is usable. Event-driven; nothing polls at idle
     beyond the keep-alive.
   - **Retry checks the connection first.** On a connection, Retry pings
     before anything else; one that no longer answers is refused as
     `connectionDropped` ("the connection had stopped answering;
     reconnecting now"), shown above the composer as before. Then
     `resend`'s checks (the tribe price, `checkPayment`) run with nothing
     waiting between them and the send's commit. With no connection the
     checks still run, then `notConnected`. Nothing is committed when
     refused.
   - **Recent sends go again on reconnect** (`Engine.resendRecent`, after
     `cameOnline`, only on the connection it ran for): oldest first, through
     `resend`'s checks, each message of ours that is failed or unconfirmed
     past 30 s, first sent at most an hour ago (`Message.autoResendWindow`,
     from `firstSentAt`, v22, kept when a resend moves `timestamp`), never
     in a tribe, and `Message.isAutoResendable`: text, an attachment
     already uploaded and not for sale, or a payment request, carrying no
     sats. Never a payment, boost, purchase, tribe join, paid attachment or
     tribe message (it pays the tribe's price): those may have paid and
     wait for Retry.
   - **The double-send gate.** `checkPendingSends` asks the server
     (`getTags`) about the tag of every candidate, failed ones too, since a
     send can be marked failed here after it left (`.unknown`, "the
     connection went after sending"). Only a row whose tag was asked about
     and that the server's records do not name, whatever their status
     (PENDING included), goes again; a failed row with no tag never left
     and goes. With no reply within 10 s, or if coming online failed before
     the question, nothing with a tag goes. The mixer records a send only
     once it has finished, so a pending one goes only once first sent over
     two minutes ago (`Message.inFlightLimit`): a text to a contact on
     another server may still be in flight, unrecorded, past 30 s. Replies
     merge into what was heard. The decision is one pure function
     (`Engine.autoResends`), unit-tested, a PENDING record included, which
     the local stack cannot produce.
   - **Once, stored.** A reconnect's resend sets `autoResentAt` (v22) in the
     same commit, so a message is sent again by itself at most once, across
     relaunches; one that fails again stays failed with Retry, and nothing
     new is shown beyond its row.
   - **Backoff and settling.** A connection that fails its ping within 60 s
     of coming up counts as another failed attempt (2, 4, 8 … 30 s) rather
     than reconnecting at once; network changes act once the path has
     settled for 1 s.

   Verified: `AutoResendTests` (the rule, the first-send window, the
   stored mark, the candidates query and its tribe exclusion);
   `ReconnectJourneys` on the local stack, with the wire tap taken down
   or frozen (`scripts/test-stack.sh tap`): a text sent while down is
   delivered once with no action, a payment sent while down stays failed
   and Bob's balance does not move, a two-hour-old failed text is not
   resent and Retry after the reconnect sends it; a frozen tap is noticed
   by the keep-alive within 15 + 5 s and Retry on it is refused as
   `connectionDropped` within the ping timeout; a text the server got but
   that is marked failed here is named by the server's records and not
   sent again; a message the reconnect sent, failed again with no tag, is
   not sent again after a relaunch. Idle: `peel listen` (keep-alive and
   network watch running) on the local stack stayed at 0.0% CPU over a
   minute, 0.01 s of CPU in all.

   Not done, with reasons:
   - A send still pending but under 30 s old when the connection comes
     back is not resent: it may still be on its way; it offers Retry at 30 s.
   - A failed tribe message is never resent by itself, though one that
     failed with nothing published paid nothing: the row does not record
     how far its publish got.
   - A text the server records as PENDING is not mapped to `.unsettled`:
     storage lets only a payment be unsettled, and the gate already holds
     such a row back; it keeps Retry.
   - A resent message moves to the bottom with the time of the resend, as
     Retry always has. Keeping its place would mean keeping the old time
     against the server's echo (which carries the resend's time, and is
     what the recipient and other devices see); for Tom to decide.

   Review (2026-10-10): `/code-review`, `/simplify` and `/security-review`
   ran inline. Fixed: a connection that dropped while coming online left
   the reconnect loop finished and the engine offline (the loop now goes
   again); per-connection work (keep-alive, the resend sweep, the records
   gate) now ends in `connectionClosed` too; path updates count only when
   the status or the interfaces change, so cost or VPN flags never cut the
   backoff short; the candidates query leaves out rows with sats before
   its limit. An independent review then found the gate weaker than
   claimed (an absent flag counted as an answer; failed rows were never
   asked about; "once" lived in memory and the hour restarted with each
   resend); fixed as above, with the ping before the checks, tribes left
   out twice over, the sweep tied to its connection, and the backoff and
   settling. Not applied:
   - A failed send waits for the records too (up to 10 s, usually under
     one): it may have left, and the sweep keeps oldest first.
   - A network change while `connecting` waits for that attempt (now at
     most the 20 s ACK timeout): cancelling a connect half-way would run
     two at once.
   - A ping whose answer is lost lingers until the client's 20 s timeout;
     at most two overlap.
   - On thaw a frozen tap (like a real link that comes back) may still
     deliver the copy written into it, so that journey checks delivery,
     not a single copy: the accepted Retry duplicate of item 8.

13. **History gaps** (bug hunt N4, 2026-10-11, branch `fix/history-gaps`).
   A catch-up asked for everything above the newest stored message, and
   the cursor lived only in memory. A live message stored during a
   catch-up raised that index, so a quit, a 30 s stall or a page the core
   could not read left the messages below it unfetched for good. Pages
   carry no request ID either, so the same page twice (a reconnect asks for
   the page in flight again) ended the run, and a restore with it.
   - Where history stands is kept in the `setting` table
     (`Setting.historyFrom`, `HistoryCursor.from`): every message below it
     has been handled, written in the same transaction as what moves it.
     Every catch-up starts there.
   - A messages page that starts no further than it moves it (a restore's
     contacts pages skip messages), by the indices in the page's own frame
     (`StateCodec.onions`), the ones the core could not read included.
   - A live message moves it when its index (from its topic) is the next
     one; one above a gap is held in memory until the gap fills. So a
     catch-up fetches again only what came live above a gap that a quit or
     a stall left, not everything since the last one.
   - A page the core refuses whole (one malformed chunk fails the whole
     call in sphinx-ffi's `handle_chunks`, and any contact or tribe member
     can send one) is read again without the messages it refuses, found
     by halves (`Engine.readablePart`, `readable`); a core error names
     their indices. History moves past the whole page.
   - A page behind the cursor (a duplicate or a stale reply) is ignored and
     the watchdog keeps waiting for the page asked for. An empty page still
     ends the run.
   - Where history stands is read when the engine is made, before any
     connection can store a live message: a profile from before starts
     after its newest message stored, or dropped from a left tribe
     (`Setting.droppedIndex`, read only then), as it did.

   Review (2026-10-12): an independent review, `/code-review`, `/simplify`
   and `/security-review`. The first version had a regression: one message
   the core cannot read (a malformed chunk, which any contact or tribe
   member can send) failed its whole page, so the index never moved past
   it and every catch-up stopped there for good, where before the next
   live message moved the start past it. Closed by reading the page again
   without what the core refuses (`readablePart`). Also fixed:
   - A catch-up fetched again everything that came live since the last
     one, which brought back Retry's first copy as a second row, a
     discarded send, a tribe removed from Peel, and notifications for
     unread messages; now it fetches only what came live above a gap.
   - The start for a profile from before was read at the first catch-up,
     after live messages on that connection could already be stored; it is
     read when the engine is made.
   - The journey passed without testing anything when the catch-up ended
     before the live message landed, as it did in four runs of four here.
     It now waits for the server to hold every message, sends the live one
     as soon as Alice is back, and requires the catch-up to be cut short.
   - The engine tests could crash the test process on a failure (no
     disconnect); they share `withTestEngine` and `registeredStorage` with
     `ConnectionDropTests`.
   - Each page is read once (`Engine.arrived`, both the amounts and the
     indices), not twice.

   The security review found nothing. Not applied, with reasons:
   - Matching each page to its request (`req_id`). A duplicate of a
     restore's last contacts page that lands after its messages run began
     at 0, or a page meant for another Mac with the same device ID, is
     still taken as a messages page, and moves the index past messages
     never fetched. The mixer echoes a `req_id` in the reply topic, but the
     core never sets one, so Peel would edit the core's request. Before
     this change the same page skipped those messages too. For Tom: it
     changes what Peel sends the server, and production's mixer version is
     unknown (bug hunt N6).
   - A tribe removed from Peel, or a request to join asked again, can still
     come back when a catch-up after a quit or a stall fetches its own join,
     or the rejection, again. That is now only what came live above a gap.
     Skipping membership for stored messages was tried and dropped: a leave
     is never stored (the tribe is left when it lands), so leave then
     rejoin fetched again would hide a tribe the person is in, and drop its
     messages. The fix is the index each tribe was hidden at: a column and
     a migration.
   - A live message the core refuses does not move the index. The next
     catch-up asks for it again and reads it as history, or leaves it out
     like any refused page message. Until then the live messages after it
     wait in memory, and a relaunch fetches them again.
   - The cursor moves in `commit`, and the next page is asked for at the
     end of `followUp`. A follow-up that throws first (a `pingDone` on a
     connection that just went) leaves the run with no request and no
     watchdog until the next connection asks again.
   - What the core refuses only for the moment (a payment against a stale
     block height), or drops for a sender not yet known, is moved past for
     good. So did the old start above the newest stored message. A restore
     still fetches everything from the first, which keeps phase 3's "must
     stay re-fetchable" for restores.
   - Seeding the index in a migration, not in `Engine.init`: the guarantee
     is the same (before any connection), and migration numbers are
     contended across open branches (v22 to v24).
   - One helper for "Alice and Bob as contacts" shared with the payments
     journeys' `pair()`, and one recorder of test writes shared with
     `ConnectionDropTests`: outside this change.

14. **The twelve words checked (finding N5).** Built 2026-10-11 (branch
   `fix/words-backup`). The words step's checkbox lived in view state:
   nothing recorded, or tested, that the words were written down, and
   every way of losing the Keychain item (Forget after a lost PIN, a new
   Mac, a change of signing team) then lost the account
   (`../reviews/2026-10-11-bug-hunt.md`, N5).

   Built:
   - **Stored, never the words.** `Setting.wordsConfirmed`, "1" or "0".
     `Account.open` writes "1" for a restore (all twelve were typed) and
     "0" for a new account. An account from before has no row and counts
     as not checked: Tom's `default` shows the reminder until he checks
     his words once.
   - **The check is the engine's.** `Engine.wordsToCheck()` picks three
     places at random; `confirmWords(_:mnemonic:)` refuses words whose
     seed is not this account's (`Engine.seed(of:)`, the one derivation
     `init` uses too), needs three answers, and stores "1" only when every
     answer is the word at its place (any case, stray spaces). A mismatch
     throws `wrongWords(positions:)`, which names places, never a word,
     and stores nothing.
   - **Onboarding.** "I've written them down" leads to "Check what you
     wrote": three numbered boxes (`WordCheck`, `WordCheckGrid`), then
     "Open Peel" once they match. Back returns to the words, never before
     them.
   - **Account.** The Twelve words row says whether the written copy is
     checked; while it is not, Check words asks for the PIN as Show words
     does, then shows three boxes. The words are read but never shown.
   - **The reminder.** While the account holds sats and is unchecked, a
     neutral `Callout` at the foot of the sidebar, "Check your twelve
     words", whose link opens the check on Account (not shown beside it).
   - **Forget on the lock screen** says first that the account holds sats
     when its balance says so (the open account's, or before the PIN the
     one last stored, read-only: `Profile.storedBalanceMsat`), then that
     without the words it and its sats cannot be brought back. Never how
     many before the PIN, as a locked notification says only "Sats
     received", and never "no sats": a stored balance can predate sats
     received since.
   - **Driver.** `{"open": "check-words"}`, what the reminder's link does.

   Tests: `WordsConfirmationTests` (which accounts start checked, the
   right words kept across a reopen, wrong words named by place with
   nothing stored, another account's words refused), `StorageTests`'
   balance read with no writer open, and the words check inside
   `AuditSecretsTests`' scan of the profile's files (S14). With the two
   writes removed, the restore row and `rightWordsConfirmAndAreKept`
   fail; with places ignored, the wrong-words test fails.

   Review (2026-10-11): an independent review, `/code-review`, `/simplify`
   and `/security-review`. Fixed: the branch no longer built on `main`
   (#184 removed `cardBoxed`; the problem lines moved to
   `PeelError.problem`); the lock screen named the balance before the PIN;
   `confirmingForget` and the driver's `lock` and `forget` steps existed
   only for the drive; a check finishing after Cancel left its problem
   under the closed row; the reminder hand-drew a card where `Callout`
   exists, and its balance redrew the whole sidebar; two wordings of a
   wrong word; the balance test read beside an open writer, not as at
   launch; the wrong-words test passed a check that ignores places; the
   lock screen said "no sats" from a stored balance that can predate sats
   received.
   `/simplify` then folded the places and answers into `WordCheck`, the
   grid's two parameters into `places`, the typed box's look into
   `wordBox`, the database's file name into `Storage.exists(in:)`. The
   app check then crashed on the first successful check from Account: the
   box being edited read its answer once more after the row had dropped
   the check (a nil one there; emptied arrays before). A check is now
   never nil or emptied, only replaced, so every box always has its
   answer. `/security-review`: no finding at confidence 8 or above. Not
   applied:
   - The check is required to open Peel at onboarding, with no skip, as
     the checkbox was; a quit there leaves the account unchecked, and the
     reminder then asks.
   - While a check is open on Account the words stay in view state with
     no 30-second limit: they are never drawn, and they go on Cancel,
     success, leaving the screen, Peel leaving the front or the lock. A
     limit would cut short someone fetching their paper, and would not
     take them out of memory (Swift strings are never zeroed; the seed
     stays all session, S20).
   - A wrong-words problem stays until the next try, as the PIN's does.
   - The words pasted into a check box are not cleared from the clipboard
     (S19 covers the restore boxes): nothing offers a paste there, and
     twelve words in one box never match.
   - The scroll to the words row waits 100 ms for the screen's layout, as
     the PIN field waits 150 ms for focus.
   - `WordCheck` stays in the app: it is what is being typed; the engine
     takes answers by place, as the CLI or an agent would pass them.
   - Read-only `Storage` still creates and sets 0700 on the folder;
     `Storage.exists(in:)` keeps it from being called without a database.

## Done criteria

- [x] An account created in the app has no `mnemonic` file anywhere.
- [x] A rebuilt app opens without a Keychain prompt (signed with Tom's identity).
- [x] A fresh profile restored from the throwaway's words shows the conversation
  with Tom and its history (CLI and app, 2026-10-07).
- [ ] Tom's real account runs in Peel alongside the official app with no loss.
