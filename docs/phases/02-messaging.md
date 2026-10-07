# Phase 2 — Safe accounts: Keychain, onboarding, restore

Status: core goal reached 2026-10-07 evening. Tom restored the throwaway's twelve words in the signed app with a PIN; the Keychain item exists, no mnemonic file does, and the engine-driven restore brought back the contact and history. What remains is listed under "Still open in this phase".

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
   payment must never be split (phase 4 refuses such notes); a history page
   made only of fragments of an unfinished message would end catch-up early
   (needs 100 fragments in a row, not seen).
7. **Read markers and mutes.** Done 2026-10-07 (branch
   `phase2/status-and-composer`). The engine asks for `getReads` and
   `getMutes` each time it comes online; the replies land in a new
   `chatState` table (migration v4: `lastRead` server index, `muteLevel`).
   A read marker only moves forward, and when the server's marker is behind
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
   Open: "mentions only" (level 1) has no UI until tribes; no mark-unread.
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

## Done criteria

- [x] An account created in the app has no `mnemonic` file anywhere.
- [x] A rebuilt app opens without a Keychain prompt (signed with Tom's identity).
- [x] A fresh profile restored from the throwaway's words shows the conversation
  with Tom and its history (CLI and app, 2026-10-07).
- [ ] Tom's real account runs in Peel alongside the official app with no loss.
