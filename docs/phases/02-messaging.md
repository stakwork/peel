# Phase 2 — Safe accounts: Keychain, onboarding, restore

Status: in progress. Xcode is installed and an Apple Development certificate exists (2026-10-07).

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
2. **Keychain storage.** Done in code, untested until task 1 gives the app a
   signed identity: `SecretStore` with `KeychainSecretStore` (app profiles,
   `Application Support/Peel/<name>`) and `FileSecretStore` (development
   profiles under `Peel/dev/<name>`, CLI only). `Profile(name:kind:)` picks
   the store; the app uses `.development` only when launched with `-profile`.
   Original brief: a `SecretStore` with two implementations: Keychain
   (`kSecClassGenericPassword`, service `dev.peel`, account = profile name,
   `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, not synced to iCloud) for
   the app, and the existing file for the CLI. App profiles move to
   `Application Support/Peel/<name>`; dev profiles stay under `Peel/dev/<name>`
   and the app opens one only when launched with `-profile`, showing a banner
   that says the words are in a file. `Account` takes the store; `Profile`
   stops knowing about mnemonics. Verify: create an account in the app, confirm
   no `mnemonic` file exists and the item is in Keychain Access, relaunch after
   a rebuild without a prompt.
3. **Onboarding: new account.** One field already accepts an invite link.
   Finish the flow: name, then a screen that shows the twelve words once with a
   "written down" confirmation, then the conversation list. Verify with a fresh
   invite on the throwaway path. Signup already works end to end from the CLI.
4. **Restore from twelve words.** Engine side done (`Engine.restore()`):
   `getMsgsCounts`, then one message per contact key (`fetchFirstMsgsPerKey`
   paging; the core recreates each contact, and the account's own
   `ContactKeyRecord`s, which the core only honours when signed by this
   account, supply names and photos), then whatever messages are still
   missing. Verified 2026-10-07: the throwaway's words restored into a fresh
   CLI profile reproduced the contact, its name and all messages. Still to do:
   the app's onboarding path (`AppModel.join` refuses twelve words until the
   Keychain is live) with a progress view driven by `.history` events.
   Original brief: after connecting, rebuild what a fresh install lacks. Port the sequence from the Mac app's
   `SphinxOnionManager+AccountRestoreExtension.swift`:
   `getMsgsCounts` → `fetchFirstMsgsPerKey` (one message per contact key, from
   which the core reconstructs each contact; `ContactKeyRecord`, type 33,
   carries the full contact info and name) → `fetchMsgsBatch` paging for
   history (`msgsTotal` already drives paging in `Engine`) → tribes from
   group-join messages (left to phase 3). Show progress in onboarding; a busy
   account takes a while. Names and photos for restored contacts come from
   those messages; see the open hardening note in phase 1 about history
   messages and sender trust.
   Verify by restoring the throwaway's own words into a fresh profile and
   comparing contacts and messages with the original database.
5. **Real-account checklist**, done by Tom, not an agent: Keychain in place,
   restore proven on the throwaway, CLI closed (the profile lock enforces one
   process), official app still installed. Restore the real account, then use
   both clients side by side for a few days before relying on Peel.

## After the account is safe

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

- An account created in the app has no `mnemonic` file anywhere.
- A rebuilt app opens without a Keychain prompt.
- A fresh profile restored from the throwaway's words shows the conversation
  with Tom and its history.
- Tom's real account runs in Peel alongside the official app with no loss.
