# Phase 11 — Preferences and their sync

## Status (2026-10-10)

**Planned, not built.** One `Preferences` layer in PeelCore owns every
user setting; the account-wide ones follow the account between its
devices through the official apps' encrypted preferences file on the
memes server. Tom, 2026-10-09: "look at the preferences and how
preferences sync … architect it correctly … cross-check with what is done
in the main Sphinx app, so we keep in sync, so both clients will work.
Equally, remember to build from first principles." Peel will run on more
than one Mac and later an iPhone, and the personal agent's settings
(budgets, permissions, connections) will be preferences too: designed for
here, not built.

Three PRs: (a) this file, (b) the layer and the migration onto it, (c) the
sync. Earlier notes: `05-parity.md`, "Settings sync" (2026-10-08), and
`../design/README.md`, "Time zones" (the per-chat switch, already stored in
the file's shape).

## Research: how the official apps sync settings

Read on 2026-10-10. Mac: `~/Documents/sphinx-mac-v2`, paths under
`com.stakwork.sphinx.desktop/`. iOS: `~/Documents/sphinx-ios-v2`, paths
under `sphinx/` (that checkout is from March 2026 and older than the Mac's).
Core: `~/Documents/sphinx` and `~/Documents/sphinx-rs`.

### Where it lives

- **Not in the core, the mixer or the broker.** The Rust core has no
  preferences, settings or key-value calls (`sphinx/sphinx/src/bindings/`;
  the nearest is `mute`, `details.rs:63`, a server-side per-chat level), and
  neither does the TypeScript reference client (`sphinx/wasm/test/auto`).
  Mute levels are already account-wide through the server; Peel reads them
  with the reads (`Engine.fetchReadsAndMutes`) and is not changed here.
- **One file per account on the memes server.** `GET /preferences` and a
  multipart `POST /preferences` with the fields `pubkey` (the account's
  pubkey, base64url without padding, `DataSyncManager.swift:767-787`) and
  `file` (filename `preferences`, `application/octet-stream`), both with
  the memes server's bearer token (`API/API+AttachmentsExtension.swift:252-345`).
  A missing file is answered `{"success": false, "error": "Preferences not
  found"}` (`:13`, `:283-289`); any other `success: false` is an error. A
  body that is not JSON is the file. The upload succeeds only on
  `success: true`.
- The memes server (`stakwork/sphinx-meme`, not in a local checkout;
  `~/Documents/sphinx/memes` is an S3 stub) answers that "not found" with
  a **404 for any storage read error**, not only a missing file
  (`router.go` `getPreferences`, `aws3.go`; found by the independent
  review, 2026-10-10). So "not found" does not prove there is no file: a
  client that starts a new one on it can wipe the real one. The official
  apps do exactly that (Mac, `DataSyncManager.swift:211-213`). Its size
  limit is unknown; neither client sets one.

### Encryption

End to end with the account's key; the memes server holds ciphertext.

- `DataSyncManager.swift:751-763`: `SymmetricEncryptionManager.encryptString`
  (`Managers/Encryption/SymmetricEncryptionManager.swift:16-37`): RNCryptor
  v3 with a password, then base64 (no line breaks). The body uploaded and
  downloaded is that base64 text.
- The password is the node secret key as 64 lowercase hex characters:
  `SphinxOnionManager.getPersonalKeys`
  (`Crypter/SphinxOnionManager/SphinxOnionManager.swift:1156-1165`) is
  `Sphinx.nodeKeys(net: "bitcoin", seed: mnemonicToSeed(mnemonic))`, always
  `"bitcoin"`; `sphinx-ffi/src/lib.rs:142-152` hex-encodes the secret;
  `derive/src/lib.rs:37-44` ignores the network (HKDF of the seed with
  `nodeid`). iOS is the same (`Crypter/SphinxOnionManager.swift:893-902`).
- RNCryptor v3 authenticates (HMAC-SHA256), so only a holder of the seed
  can write a file the apps accept. The memes server can withhold the
  file, delete it, or serve an older one; it cannot forge one.

### The format

`{"items": [{"key", "identifier", "date", "value"}]}`
(`Managers/Data Sync Manager/DataSyncModels.swift:27-122`):

- `key`, `identifier`, `date` are strings. `date` is Unix seconds, written
  `"%.0f"` (`:41`); read with `TimeInterval(dateString)`, and a date that
  does not parse counts as now (`:108-113`). `identifier` is `"0"` for an
  account-wide value.
- `value` is a string, or an object of strings for the three object kinds.
  Reading tries, in order (`:134-199`): `FeedStatus` (seven string fields),
  `FeedItemStatus` (`duration`, `current_time`), `TimezoneSetting`
  (`timezone_enabled`, or the legacy `timezoneEnabled`), a string, an int,
  a bool. Anything else (null, an array, a fraction, another object)
  throws.
- **Any item that fails to read makes the whole file unreadable**: Mac
  aborts the sync and never uploads (`DataSyncManager.swift:214-223`); the
  older iOS proceeds with an empty list and **overwrites the file with its
  own items** (`Managers/DataSyncManager/DataSyncManager.swift:185-198`).
  So every item Peel writes must read in both.
- **Strings are rewritten on every sync.** A string is turned into a bool
  if it is `true` or `false` in any case, into an int if `Int(s)` reads it,
  and into an int if `Double(s)` reads it and it has no `.`
  (`DataSyncModels.swift:155-180`); `toOriginalFormatJSON` writes them back
  as `"true"`, `"false"`, `String(int)` (`:34-96`). So `"007"` comes back
  as `"7"`, `"TRUE"` as `"true"`, `"1e3"` as `"1000"`, and `"inf"`, `"nan"`
  or `"1e30"` **crash the official app** (`Int(Double)` traps). Objects come
  back with only their known fields.
- Extra fields on an item or beside `items` are dropped by the official
  apps on their next upload. Unknown **keys** survive: the list is read
  whole, `restoreDataFrom` ignores keys it does not know (`:315`), and the
  whole list is uploaded again.

The keys (`DataSyncModels.swift:13-23`; iOS has the first six only):

| key | identifier | value | written by |
|---|---|---|---|
| `tip_amount` | `"0"` | int, **sats** (default 100, `CoreData/UserContact/UserContact+CoreDataClass.swift:26-35`) | Profile's "Default tip amount" (`Scenes/Profile/View Controllers/ProfileViewController.swift:350-353`); the AI agent (`Managers/AI Agent/AIAgentManager.swift:925`) |
| `private_photo` | `"0"` | bool | Profile (`:355-358`) |
| `timezone` | the chat's `ownerPubkey` (a contact's or tribe's pubkey) | `{"timezone_enabled": "true"\|"false", "timezone_identifier": ""\|IANA}` | the chat's switch and zone (`Scenes/Contacts/Custom View/TimezoneSharingView.swift:115-136`); a tribe alias change (`Scenes/Groups/View Controllers/GroupDetailsViewController.swift:233-247`) |
| `feed_status` | feed id | 7 string fields | podcasts |
| `feed_item_status` | `feedId-itemId` | `duration`, `current_time` | podcasts |
| `chat_color` | the colour key (`<pubkey or alias>-color`) | hex string | `syncChatColors`, every sync (`DataSyncManager.swift:482-509`) |
| `pin_timeout` | `"0"` | int hours: **0 = every time, 1–24, 25 = never** (`Configuration/Constants.swift:20`, `Scenes/Profile/Custom Views/PinTimeoutView.swift:36-59`, `Managers/Groups/GroupsPinManager.swift:22-33`) | Profile (`ProfileViewController.swift:365-368`) |
| `biometric_enabled` | `"0"` | bool | iOS; Mac ignores it (`DataSyncManager.swift:424-425`) |
| `ai_agent_config` | `"0"` | `"provider\|apiKey\|agentName"`, **a third-party API key** | `Scenes/Profile/View Controllers/SetupAIAgentViewController.swift:168` |

### When, and how conflicts resolve

- A change writes a local `DataSync` row (key, identifier, value, date =
  now) and schedules a sync 2 s later, debounced (`DataSyncManager.swift:137-173`).
  A sync also runs when the app becomes active (`AppDelegate.swift:489`)
  and after a restore (`SphinxOnionManager+AccountRestoreExtension.swift:1053`).
  One sync at a time (`:183-192`).
- One sync (`:183-310`): fetch and decrypt (abort if unavailable or
  unreadable; bootstrap an empty list only on the "not found" answer);
  for each local row, if the file has the item and the file's date is
  **strictly older**, the local value replaces it; otherwise the file's
  wins and is applied; a local row with no item is added. **Every file
  item with no local row is applied**: the file is the truth, local rows
  are only the pending edits. Then `chat_color` is first-one-wins: local
  colours the file lacks are added with date now. Upload the whole list
  (skipped if empty), and only after a successful upload delete the local
  rows.
- Dates come from each device's clock: last writer by clock wins, ties to
  the file, and clock skew decides close races.

### What Peel has today, mapped

| Peel setting | Stored | Official key | Decision |
|---|---|---|---|
| Boost amount (`boostAmountMsat`) | `setting`, msat | `tip_amount`, sats | **Synced** as `tip_amount` (whole sats; Peel's input is whole sats) |
| Time zone sharing per chat | `chatTimeZone` rows, already in the item's shape | `timezone` | **Synced** as `timezone` |
| Payment confirmation threshold (`paymentConfirmationMsat`) | `setting`, msat | none | **Synced**, Peel-only: `peel.payment_confirmation_msat` |
| The account's time zone (`timeZone`) | `setting`, IANA or "" | none (official zones are per chat or the device's) | **Synced**, Peel-only: `peel.time_zone` |
| PIN timeout (`pinTimeoutHours`) | `setting`, hours, 0 = only at launch | `pin_timeout` | **This device only**; see decision 4 |
| Notification text (`notificationText`) | `setting`, "0"/"1" | none | **This device only**; see decision 5 |
| Mute levels | `chatState`, from the server | none (the server keeps them) | Unchanged: already account-wide |
| Theme | none (Peel is always dark) | none | Nothing to sync |
| Tribes, memes and call servers | `setting` | none | Account configuration, not preferences: stay in `setting` |
| Pane widths, the notification offer | `UserDefaults` | none | Window state of this Mac: stay where they are |
| Name and photo | `setting` | none (travel on messages; restore recovers the photo) | Not preferences: unchanged |

Official keys Peel does not use (`private_photo`, `feed_status`,
`feed_item_status`, `chat_color`, `pin_timeout`, `biometric_enabled`,
`ai_agent_config`) and every key Peel does not know are kept exactly as the
file has them. Later, `chat_color` could give a contact the colour the
person sees on their phone (`PersonHue.swift` notes it); not in this phase.

## Architecture

### One owner: `Preferences`

`Sources/PeelCore/Preferences.swift`: the registry and the typed reads and
writes. Every user setting is a `Preference<Value>` with:

- `key`: the item's key in the file. An official key uses the official
  name and encoding exactly. A Peel-only key starts with `peel.`, which the
  official apps keep and ignore (unknown keys survive their syncs). A
  device-only key starts with `device.` and is never uploaded.
- `scope`: `.account` (synced) or `.device`.
- per chat or account-wide: the item's `identifier` is the chat's pubkey,
  or `"0"`.
- a codec between the Swift value and the item's value. Decoding is
  lenient (it reads what the official apps read); encoding writes only
  values the official apps read back unchanged.
- an apply policy: whether a value from the file is taken here given the
  one this device holds. Most take any newer value; one guarding money
  takes only a stricter one (decision 7), and a looser one waits until it
  is chosen on this device.

Storage (`preference` table, migration v23):

| column | meaning |
|---|---|
| `key`, `identifier` | the item's (primary key) |
| `value` | the item's value as JSON text, exactly as the file holds it |
| `updatedAt` | the item's date, seconds (REAL, as the official apps compare); 0 = never chosen on a synced device |

The table mirrors the file for the keys Peel knows, so a value read from
another device is kept as written (an official `pin_timeout` of 0 stays 0
even though Peel would not write it), and sync is a comparison of dates.
Engine getters and setters (`boostAmountMsat`, `setBoostAmount`,
`timeZoneSharing(in:)` and the rest) keep their signatures and go through
the layer; the app and the CLI are unchanged.

### Writing a value

`updatedAt = floor(max(now, previous updatedAt + 1))`: a change made on top
of a version always beats that version, even when the version came from a
device whose clock runs ahead. The official apps compare the same numbers,
so they agree.

Every encoded value is checked against the official reader before it is
stored (`Preferences.isOfficialFixedPoint`): a string must come back the
same through the official bool, int and double rules, and never be one
that traps; an object must be exactly the `timezone` shape with "true" or
"false". A value that fails is refused, not stored.

### Sync (`Engine+Preferences.swift`, PR c)

One sync: sign in to the memes server (the token attachments use), `GET
/preferences`, decrypt with the node key, read every item with the official
reader's rules. If the server is unavailable, the body does not decrypt,
or any item would not read in the official apps: stop, change nothing,
upload nothing.

**"Not found"** (a 404 or a 200 with that answer) is trusted only on a
device that has never seen the file. Once a file has decrypted here, or
an upload has succeeded, this device records it
(`device.preferences_file_seen`), and from then on "not found" is treated
as the server being unavailable: no change, no upload. A device that has
never seen one starts from an empty list, **bootstrapping**: it uploads
only rows chosen on it since the preferences layer arrived (dated after
`device.preferences_since`, which v23 records), never values from before.
So a storage error on the server can at worst make a new device write the
few things chosen on it since, and never makes a device that has synced
overwrite the real file.

Merge, per `(key, identifier)`, for keys in the registry with scope
`.account` only. When the file has the same key and identifier more than
once, the **last** copy is the file's value, as in the official apps
(which apply every file item in order, so the last wins):

1. Local date **strictly newer** than the file's: the local value replaces
   the item, every copy of it (`key`, `identifier`, `date` as a whole
   number of seconds, `value`).
2. Otherwise the file's value wins and is applied locally, if the codec
   reads it (an unreadable value is left in the file and ignored, as the
   official apps ignore it) and the key's apply policy takes it.
3. A file item with no local row: applied, likewise.
4. A local row with no item: added if it was chosen on a device
   (`updatedAt` > 0; when bootstrapping, after `device.preferences_since`).
   A row from before sync (0, from the migration) is added only under a
   `peel.` key, with date 0, so any real choice anywhere beats it, and
   never when bootstrapping.
5. Everything else in the file (other keys, extra fields, other top-level
   fields) is copied through as equal JSON values. They are re-serialised,
   so the text can differ: key order, and a number such as `1.0` written
   as `1`.

Applying is compare-and-set: each row is written only if the stored row
is still exactly what the merge read (the same value and date, or still
absent), so an edit made here while the sync was out is never lost, even
to another device's clock running ahead; it goes up on the next sync.
Upload only when something changed (the official apps upload every time;
Peel writes the shared file as little as it can). A failed upload changes
nothing locally: the rows keep their dates and go up with the next sync,
which waits for the next trigger (a change, a connect, the app coming to
the front); nothing retries on a timer. That is the offline queue: an
edit is a row with a newer date, and nothing else needs remembering.

`prefs-sync --dry-run` (CLI) fetches, decrypts and merges, then prints
which keys and identifiers would be applied here and which would go up,
without their values, and changes nothing.

Why this equals the official rule: the official apps compare a pending
edit's date with the file's and let the file win otherwise. Peel keeps the
dates of everything, not only pending edits, which gives the same answer
whenever a later write has a later date (an official app never uploads an
item older than the file's; it discards its own edit). It differs only
when the file goes back in time (a restored or replayed older file), where
Peel puts its newer values back instead of taking the old ones.

**When:** each time the engine comes online (that covers a restore, which
applies the account's preferences as soon as it connects), 2 s after a
local change (debounced), and when the app comes to the front (at most
once a minute). One at a time; a change during a sync runs another after
it. CLI: `prefs-sync`. After applying anything, the engine emits
`.preferencesChanged` and the app reads its settings again.

**Limits:** the downloaded body is capped at 5 MB, and a file over that is
neither read nor written. The file's contents are never logged and never
stored by Peel; only registry keys reach the database, so `ai_agent_config`
and its API key stay in memory for the length of one sync.

### Migration (v23) and Tom's real data

v23 creates `preference`, copies the old values in, and removes them from
`setting` and drops `chatTimeZone`, in one transaction:

| from | to | `updatedAt` |
|---|---|---|
| `setting.boostAmountMsat` (> 0) | `tip_amount`, whole sats as a string (at least 1) | 0 |
| the same | `device.boost_confirmed_msat` (it was confirmed when set here) | 0 |
| `setting.paymentConfirmationMsat` | `peel.payment_confirmation_msat` | 0 |
| `setting.timeZone` (not "") | `peel.time_zone` | 0 |
| `setting.pinTimeoutHours` | `device.pin_timeout_hours` | 0 |
| `setting.notificationText` | `device.notification_text`, "true"/"false" | 0 |
| `chatTimeZone` rows | `timezone`, the chat, `{"timezone_enabled", "timezone_identifier"}` | the row's `updatedAt` |
| (the time it runs) | `device.preferences_since` | 0 |

v23 follows v21 (#140) and v22 (#149, message resend dates), and assumes both.

**What Tom's first sync does.** Settings from before sync are dated 0, so
wherever the file has their key, the file wins: what he set in the
official app is applied, never overwritten (the confirmation threshold
only if it is stricter, decision 7). Where the file lacks an official key,
the value from before stays on this Mac and does not go up. The first
sync **uploads** in exactly these cases, and only once the file has
decrypted (a "not found" on his first sync uploads nothing from before
v23):

- a per-chat time zone row (the only old values with real dates, from
  when he flipped a switch in Peel since 2026-10-08) that is newer than
  the file's item for that chat, or that the file lacks: it goes up, as
  an edit made in the official app would;
- a Peel-only value from before (the threshold, the account's zone) that
  the file lacks: it goes up dated 0, so any real choice beats it; the
  official apps ignore `peel.` keys;
- anything he changes in Peel after updating.

`prefs-sync --dry-run` shows which keys these would be before anything is
written, on development profiles only. It is not offered for Tom's real
profile: the CLI never opens the app's profile (its words are in the
Keychain under the PIN, and a second process on the profile is refused),
and copying the real words into a development profile's plain file would
break the rule that those hold throwaway accounts only. If Tom wants the
check before his first sync, the way is an app-side dry run behind the
PIN (not built; small, the engine's `previewPreferences` does the work).

### The agent's settings, later

Budgets, permissions and connections slot in as registry entries, with no
change to storage or sync:

- Keys under `peel.agent.`, identifier the agent's pubkey (or
  `<agent pubkey>/<tool>`), values encoded as plain strings (a JSON object
  of settings goes in as a string, which the official reader leaves alone).
- What the agent **host** enforces (its budget, its permission gate) is
  not Tom's preference: the host is another account and cannot read Tom's
  file. Those limits live on the host and change by signed Sphinx messages
  (`../agent-architecture.md`). Tom's preferences hold what his own
  clients need: which contact is his agent, what the app shows and asks,
  the connections his devices hold.
- A preference that would loosen a gate on this device (a budget, a
  permission, a spending threshold) gets the stricter-only apply policy
  of decision 7, or is applied but held to a confirmation here, as the
  boost amount is (decision 3). The registry entry says which, so a new
  key cannot slip past it.

### Decisions

1. **Peel keeps every item's date**, not only pending edits: same result as
   the official rule, robust to an older file being served.
2. **Peel never uploads an unchanged file**, never a file it could not read,
   and never an item the official reader would rewrite or crash on.
3. **The boost amount syncs as `tip_amount`, but a one-tap boost over
   this device's threshold sends only an amount confirmed on this device**
   (`device.boost_confirmed_msat`, recorded when the amount is set here or
   a boost with it is confirmed). An amount over the threshold that came
   from the file makes the first one-tap boost ask, with the app's second
   click, before it sends (changed after the independent review; first
   planned as applied unconfirmed).
4. **The PIN timeout stays on each device.** The PIN is per device in Peel
   (it seals the words in this Mac's Keychain) and in the official apps;
   how long a device stays unlocked depends on the device (a desk or a
   pocket). The two scales also disagree: official 0 means "every time"
   and 25 "never", Peel's 0 means "only at launch" and it has no "never"
   (the words need the PIN). Any mapping would either weaken a phone's lock
   from the Mac or misreport. `pin_timeout` is kept in the file untouched.
5. **Notification text stays on each device**: what a notification shows
   is about who can see that screen.
6. **Forgetting a contact keeps its time zone item.** It is the account's
   synced state, on the other devices and in the file; re-adding the
   contact finds it again, as in the official apps.
7. **The confirmation threshold syncs, but is taken from the file only
   when it is stricter (lower) than this device's.** A higher one from
   another device is ignored here until it is chosen on this device; one
   chosen here goes up as usual. A device never asks for less
   confirmation because another one did.
8. **"Not found" is trusted once only** (see "Sync"): the memes server
   says it for any storage error, and the official apps' bootstrap on it
   can wipe the file.

## Verification plan

- Unit: the registry's encodings are fixed points of a port of the
  official reader (`DataSyncModels.swift:134-199`, `:34-96`); the merge's
  rules one by one (newer local, tie, older local, new local, file only,
  never-chosen rows, unknown keys untouched, the last duplicate read and
  every copy replaced, unreadable values ignored, unreadable files
  refused, apply policies, "not found" after a file was seen, bootstrapping,
  compare-and-set); the migration from a v22 database with every old
  setting; the one-tap boost held to a confirmation of a synced amount.
- Outside the repo, the official `DataSyncModels.swift` compiled as is,
  reading and rewriting a file Peel wrote: unchanged.
- Integration (local stack, the memes stub gains `/preferences`, and
  answers "not found" with a 404 as the real server does): two devices of
  one account, a change on one seen on the other; conflicting offline
  edits; an official-shaped file with unknown keys round-trips; a restore
  brings the settings back; a 404 after the file was seen uploads
  nothing.
- Unverifiable here: the official apps themselves syncing against the
  local stack, and the hosted memes server itself (its size limit).

## Journal

- 2026-10-10: research and this plan (PR a).
- 2026-10-10, after the independent review: "not found" trusted once
  (F1), the boost held to a confirmation here (F2), the threshold taken
  only when stricter (F5), compare-and-set applies (F4), the last
  duplicate, the dry run, and these docs corrected (F3, F6, F7).
