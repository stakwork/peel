# Phase 1 — Core and account

## Status (2026-10-08)

**Built:** the engine and the core contract, invite signup, storage,
transport with verified TLS, the Mac app shell and the CLI. Tom uses Peel
daily on his real account (since 2026-10-07, phase 2); unit tests exist
(`Tests/PeelCoreTests`).

**Open:** history messages cannot be tied to the key that decrypted them,
so history never renames contacts; the fix is a `key_idx` in the core's
batch result ("Learned", last item).

**Decided:** one transaction per core call; certificates verified, one
stable device ID per install, state in SQLite (not the Mac app's ways).

## Journal

The build log, kept as written.

Status on 2026-10-07: done; the Mac app is in its first daily-use trial.

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
- (2026-10-11, bug hunt N2) The mixer redeems an invite and credits the
  new account before it answers the register, and a register it already
  knows is answered `already_registered`. So a signup whose reply is lost
  or late no longer deletes the profile: only when no register can have
  gone (`Engine.inviteMayBeRedeemed`). The invite is kept
  (`Setting.invite`) until the registration is confirmed, and every
  connect until then registers with its code. Such an account opens on
  the words step with a line saying the server has not confirmed it.
- (2026-10-11, N2 review) Once the account is online, during the signup
  or on a later connect, the engine adds the inviter as the first contact
  in the background (`Engine.addInviterIfPending`). The invite is
  forgotten as that key exchange starts, so it goes at most once; it is
  kept for the next connection only when nothing of it left
  (`notConnected`), and any other failure is reported. Signup no longer
  adds the inviter itself, so it no longer throws once the account
  exists. It used to when that add failed: the app stayed on the PIN
  step, trying again failed with "an account is already stored here",
  and the words were never shown.
- Review findings not applied (N2):
  - A refused register (an invite used or cancelled, on a mixer with
    `INVITE_PRICE` above 0) gets no answer at all: the mixer at `caa76a1`
    logs "failed to route" and replies nothing. Peel cannot tell it from a
    lost reply or a mixer that is down, so it keeps the account and asks
    again on each connect, and the words step says what a wait that never
    ends may mean. Deleting on a timeout is what lost funded accounts.
  - No register again on a timer while connected and unconfirmed: a timer
    could not tell a refusal from an outage either, and would add timing
    to the connection loop. A reconnect or a relaunch asks again.
  - The local stack leaves `INVITE_PRICE` unset (0), so no register is
    ever refused there and no journey covers that case.
  - Not seen in the app: an offscreen drive cannot reach the words step
    (onboarding's first buttons have no shortcut, its steps are view
    state, and the signup would need a deafened stack).
  - An unconfirmed account's connection still reads Connected (the
    sidebar bolt) while nothing works. A "registration pending" state
    would have to be read by every view that shows the connection; the
    state is rare, and Tom should decide whether it earns that.
  - Never deleting once the words are saved (every connect now registers
    with the stored invite, so even a register that never left would
    recover) would put an unreachable server on the words step rather
    than an error: a product call, left as it was.
  - The words step reads `myContactInfo == nil` as "not confirmed", as
    the Account screen does: the core sets the contact info in the reply
    that registers, committed with it before `connect` returns.
  - Signup keeps `registered ||` beside the flag: a registered account is
    never deleted, whatever the flag says.
  - The deafened journey ends on the tribe topic's subscribe timeout
    (20 s, its acknowledgement is lost too), not the 30 s registration
    wait. Closing the connection after the register instead would be the
    cut-short case the unit test already covers.

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
