# Phase 2 — Restore, secrets and messaging basics

Status: next.

Goal: a fresh install can come back from twelve words, text works for any
length, the mnemonic is in the Keychain, and unread state behaves.

## Tasks, in order

1. **Restore from mnemonic.** Connecting works, but a fresh install has no
   contacts or history. Port the restore sequence: `getMsgsCounts`,
   `fetchFirstMsgsPerKey`, `fetchMsgsBatch` paging, contact reconstruction from
   `ContactKeyRecord` (type 33) messages, tribes from group-join messages.
   Reference: `SphinxOnionManager+AccountRestoreExtension.swift` in
   `sphinx-mac-v2`. Show progress in onboarding; it can take a while.
2. **Long messages.** Text over ~869 bytes is split into chunks by the
   bindings layer (`sphinx-rs/sphinx-ffi/src/chunk.rs`, message type 34).
   Confirm how `send` reports a chunked message (several tags) and how
   `handle` reassembles one, then make `Engine.sendText` and `Storage.record`
   handle both. Verify against the official app in both directions.
3. **Keychain.** Store the mnemonic in the Keychain from the app; keep the file
   store only for the CLI's throwaway profiles. Needs a signed bundle to avoid
   prompts on every rebuild, which means the Xcode question must be answered.
4. **Read markers and mutes.** `getReads` and `getMutes` on connect, `read` when
   a chat is viewed, `mute` from the sidebar; unread counts per conversation.
5. **Send failures.** Show "Not delivered" with a retry; surface core errors in
   the conversation rather than as a global notice.
6. **Typing-level polish.** Shift-Return for newline, paste handling, link
   detection in bubbles, timestamps on hover.

## Done criteria

- A new profile restored from the throwaway's twelve words shows the existing
  conversation with Tom and its history.
- A 3,000-character message round-trips with the official Mac app intact.
- The mnemonic file no longer exists for app-created accounts.
