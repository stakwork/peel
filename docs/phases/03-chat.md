# Phase 3 — Tribes, threads and attachments

Status: planned.

## Tribes

- Join from a `sphinx.chat://` tribe link or the default tribe in an invite;
  leave; member list. Core: `joinTribe`, `listTribeMembers`, the tribe
  management topic (already subscribed in `Engine.connect`).
- Tribe messages carry a member as `sender` and the tribe as the chat.
  `Storage.record` currently assumes the chat is the sender; it needs the
  tribe's pubkey (from the message's routing / `sent_to` / core contact of
  type tribe). Check `handle_msg.rs` for how the core marks tribe messages.
- Mentions, price per message and escrow amounts (`amtMsat` on send, see the
  Mac app's `sendMessage`), admin actions later.

## Threads and replies

- `replyUuid` and `threadUuid` in the message JSON; quote rendering; a threads
  list per chat. Reference: `formatMsg` in `SphinxOnionManager+ChatExtension.swift`.

## Attachments

- Encrypt with a random key, upload to `memes.sphinx.chat` (auth by signed
  challenge), `makeMediaToken` (or `makeMediaTokenWithPrice`), send type 6 with
  `mediaToken`, `mediaKey`, `mediaKeyForSelf`, `mediaType`. Download and decrypt
  on receive; thumbnails; file, image, audio, video.
- Reference: `SphinxOnionManager+ChatExtension.swift`, the Mac app's
  `Managers/Attachments` and `Managers/S3 Uploader`.
