# Phase 1 — Core and account

Status: done; the Mac app is in its first daily-use trial.

## Done

- `Engine` implements the core contract and is verified end to end:
  registration, key exchange, text DMs both ways, offline catch-up, send
  confirmations, async-payment pings. Tested between two accounts on a local
  test server, then between the throwaway account and Tom's real account on the
  production server (TLS verified, no certificate exceptions).
- Invite signup works on the production server (`peel signup`, and the app's
  onboarding screen, which also accepts twelve words).
- `Storage`: core state, settings, messages with upsert on uuid, contacts with
  names and photos taken from message senders, live queries for the UI.
- `Transport`: signed MQTT login, TLS on and verified by default (plaintext
  only for an explicit `mqtt://` scheme or a loopback host).
- Reviewed on 2026-10-07 (simplify: reuse, simplification, efficiency,
  altitude; plus an independent security read). Applied: one transaction per
  core call, engine-owned reconnect and registration wait, `Account` as the
  single open/signup/restore path, profile lock, sender identity resolved from
  the topic's child index, message upsert that cannot cross conversations,
  `msgsTotal`-driven history paging, persisted unique clock, library hash lock.
- Mac app shell: onboarding, conversation list, conversation view with
  composer, connection status, reconnect with backoff. App icon compiled from
  `Assets/AppIcon.icon`, so macOS 26 masks it itself instead of putting it on
  a white plate.
- CLI harness: `init`, `signup`, `add`, `send`, `listen`, `contacts`, `whoami`.

## Learned

- `send` returns only a tag and uuid; Peel writes its own outgoing row before
  publishing. The server then echoes the message to all of the account's
  devices and the row is filled in from the echo.
- Pings (someone paid you while you were offline) can arrive before the
  account is registered; they are held until registration completes.
- The official Mac app accepts any TLS certificate, stores core state in
  UserDefaults and uses a new device ID per connection. Peel verifies
  certificates, keeps state in SQLite and uses one stable device ID per install.
- The Rust library prints debug lines to stdout (`[handle-trace]`,
  `CONTACT KEY ...`). Harmless, but filter them when reading CLI output.
- Review findings deliberately not applied: folding the three schema
  migrations into one (the throwaway database already carries them); replacing
  the inbound stream with mqtt-nio's `createPublishListener` (not `Sendable`
  across the actor boundary); the `AsyncImage` cache and day-boundary
  precomputation (not worth it at this size).
- Open hardening: history (`batch`) messages cannot be tied to the decrypting
  key from the client side, so a contact could file a history message under
  another known contact's name. The clean fix is one field in the core's batch
  result (`key_idx`); until then history never renames contacts.

## In progress

- Daily use of the Mac app on the throwaway account. The window has not yet
  been checked by eye from an agent session (no screen-capture permission), so
  expect layout fixes: spacing, bubble widths, sidebar footer, dark mode.

## Not covered by this phase

- Restore of contacts and history for a fresh install (phase 2).
- Long messages over ~869 bytes (phase 2).
- Keychain storage of the mnemonic (phase 2).
- Unit tests. The codec and engine were verified by running real sessions;
  tests should follow once Xcode (or a confirmed `swift test` setup) exists.
