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
   Honest limits, from the security review: the item is in the file-based
   login keychain, so `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` is not
   in effect there (it is backed up and migrated with the keychain file), and
   a six-digit PIN at ~0.4 s per guess falls to an offline search in minutes
   on a GPU and hours on a laptop if someone has the keychain file and the
   login password. The Keychain's binding to the signed app plus the login
   password are the real wall; the PIN stops a passer-by at an unlocked Mac.
   Next step when an Xcode project with a provisioning profile exists: move
   to the data-protection keychain (`kSecUseDataProtectionKeychain`), which
   wraps items in hardware and keeps them out of backups.

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
   relying on Peel. Tribes are phase 3, so until then Peel shows DMs only.

## Still open in this phase

0. **Data-protection keychain.** The item is in the file-based login keychain
   (see task 2). Moving it to the data-protection keychain needs a bundle with
   an application identifier, i.e. an Xcode project with a provisioning
   profile. Decided 2026-10-07: this lands before the real account moves over.


6. **Long messages.** Text over ~869 bytes is split by the bindings layer
   (`sphinx-rs/sphinx-ffi/src/chunk.rs`, type 34). Confirm how `send` reports a
   chunked message and how `handle` reassembles one; handle both. Verify with
   the official Mac app in both directions.
7. **Read markers and mutes.** `getReads` and `getMutes` on connect, `read`
   when a chat is viewed, `mute` from the sidebar; unread counts.
8. **Send failures.** "Not delivered" with a retry; core errors shown in the
   conversation, not as a global notice.
9. **Composer polish.** Shift-Return for a newline, paste handling, link
   detection, timestamps on hover.

## Done criteria

- [x] An account created in the app has no `mnemonic` file anywhere.
- [x] A rebuilt app opens without a Keychain prompt (signed with Tom's identity).
- [x] A fresh profile restored from the throwaway's words shows the conversation
  with Tom and its history (CLI and app, 2026-10-07).
- [ ] Tom's real account runs in Peel alongside the official app with no loss.
