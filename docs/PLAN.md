# Peel plan

Last updated 2026-10-07.

## Why

The official Sphinx clients (iOS, Mac, Android) are old and heavy. Peel is a
from-scratch native client that connects to the same server, is
indistinguishable to colleagues at the protocol level, and could replace the
official apps if it turns out better. Mac first, iPhone second.

Only what other clients and the server can observe is fixed: the core's wire
protocol, the JSON shape of each message type, and the side services. Everything
else is designed from first principles. "Parity" means the same capabilities,
not the same screens.

## Scope (decided 2026-10-05)

In v1: onboarding (invite signup, mnemonic restore, name, PIN, photo); contacts
as the Mac app does them; payments (send in chat, pay invoice, request, boosts)
plus a new Receive screen; chat with tribes, attachments, threads and replies,
LiveKit calls; web apps; People and LSATs; paid messages and templates; six
languages. Later: AI Agent. Out: feeds and podcasts, Strut dictation, Hive
workspaces, Tor and relay-era code, Jitsi.

## Done

- Core contract implemented in `Engine` and verified end to end: registration,
  key exchange, text DMs both ways, offline catch-up, send confirmations. Tested
  between two accounts on a local test server, then between the throwaway
  account and Tom's real account on the production server (TLS verified, no
  certificate exceptions).
- Invite signup works against the production server.
- Storage: core state, settings, messages (upsert on uuid), contacts (names and
  photos from message senders), live queries for the UI.
- Mac app shell: onboarding, conversation list, conversation view with
  composer, connection status, reconnect with backoff. It launches and shows a
  window; the layout has not yet been checked by eye.
- Command-line harness with `init`, `signup`, `add`, `send`, `listen`,
  `contacts`, `whoami`.

## In progress

- Mac app: first real use on the throwaway account. Look at it, fix what reads
  wrong, then use it for a day.

## Next, in order

1. **Restore from mnemonic.** Connecting works, but a fresh install has no
   contacts or history. Port the restore sequence: `fetchFirstMsgsPerKey`,
   `getMsgsCounts`, `fetchMsgsBatch` paging, contact reconstruction from
   `ContactKeyRecord` (type 33) messages. Reference:
   `SphinxOnionManager+AccountRestoreExtension.swift` in `sphinx-mac-v2`.
2. **Long messages.** Text over ~869 bytes is split into chunks by the bindings
   layer (`sphinx-ffi/src/chunk.rs`). Confirm how `send` reports chunked
   messages (several tags) and how `handle` reassembles them, and handle both.
3. **Keychain.** Replace the mnemonic file with Keychain storage in the app. The
   CLI keeps the file for throwaway accounts.
4. **Read markers and mutes.** `getReads`, `read`, `getMutes`, `mute` on connect
   and on viewing a chat; unread counts in the sidebar.
5. **Tribes.** Join from a link, read, post, member list. Core calls:
   `joinTribe`, `listTribeMembers`, tribe management topic (already subscribed).
   Tribe messages carry a member as sender and the tribe as the chat; the
   message store needs a `chat` that is not the sender.
6. **Threads and replies.** `replyUuid` and `threadUuid` in the message JSON;
   quote rendering; threads list.
7. **Attachments.** Encrypt, upload to `memes.sphinx.chat`, `makeMediaToken`,
   send type 6 with `mediaToken`, `mediaKey`, `mediaType`; download and decrypt
   on receive. Reference: `SphinxOnionManager+ChatExtension.swift` and the Mac
   app's `Managers/Attachments`.
8. **Money.** Send sats in chat (type 5 and keysend), pay a BOLT11 invoice,
   request payment (`makeInvoice`), boosts (type 29), a Receive screen with QR
   and live paid confirmation, transaction history (`fetchPayments`). The async
   payment ping flow is already handled in `Engine`.
9. **Contacts and invites UI.** Add by contact info, share own QR, create
   invites (`makeInvite`), inbound requests.
10. **Profile, PIN, People and LSATs, web apps, localisation.**
11. **Calls** (LiveKit).
12. **iPhone target.** Push notifications are the open problem: the server keeps
    one push token per account and the hub only signs for the official bundle
    ID.

## Open questions

- Install Xcode on this Mac? Needed for a signed app bundle, entitlements,
  Keychain access groups, and the iPhone target.
- Build the Rust bindings from source (needs Rust 1.88.0 per `sphinx-rs`) or
  keep using the static library the Mac app ships?
- Repo hosting: local only so far.

## Accounts

- Throwaway account: profile `throwaway`, alias "Peel", created from Tom's
  invite on 2026-10-07. Its only contact is Tom's real account. Mnemonic at
  `~/Library/Application Support/Peel/dev/throwaway/mnemonic`.
- Production broker: `mqtt-broker.v2.sphinx.chat:8883`. Config endpoint:
  `https://config.config.sphinx.chat/api/config/bitcoin`.
