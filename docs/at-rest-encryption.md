# Data at rest: what is encrypted, what the PIN protects

Status: findings and a proposal, 2026-10-24. No code changed.

## Short answer

**No, Peel's data is not encrypted at rest by Peel.** `peel.sqlite`,
`agent.sqlite`, the attachment cache and strut's memory graph and agent
transcripts are plain files. Anything running as your macOS user can read
them with no key. The only encryption over them is FileVault, which helps
when the Mac is off or logged out, not against another process running
while you are logged in.

**The PIN protects your twelve words, not your data.** It seals the words
(and so the account's keys) in the Keychain, and it gates Peel's UI. The
database is opened in the clear once the PIN has loaded the words, and
it stays readable on disk whether Peel is locked, quit or running.

## What was checked

- `Storage.init` (`Sources/PeelCore/Storage.swift`) opens a GRDB
  `DatabasePool` with a default `Configuration`: no `prepareDatabase`,
  no key, system SQLite. Nothing in the repo mentions SQLCipher,
  `FileProtection` or `isExcludedFromBackup` (apart from the bridge's
  cache).
- On disk, `~/Library/Application Support/Peel/default/peel.sqlite` and
  `agent.sqlite` start with the bytes `SQLite format 3`. `sqlite3
  -readonly` lists their tables without a key.
- `Profile.storedBalanceMsat()` opens `peel.sqlite` read-only before
  the PIN, for the lock screen. The design already assumes the file is
  readable without the PIN.
- `AppModel.unlockedStorage` says it plainly: "locking leaves the engine
  open". The PIN timeout hides the UI. The database stays open.
- The one stated at-rest model is in `docs/phases/09b-inbox.md`: the
  Inbox cache "is in `peel.sqlite`, protected like the messages:
  FileVault, and the PIN in front of the UI." That is accurate. It just
  isn't written down anywhere central.
- FileVault is on, on this Mac (`fdesetup status`).

## File by file

| What | Where | At rest |
|---|---|---|
| Messages, contacts, tribes, payments, invoices, the FTS index (`messageText`), dictation History (text and `heard`), settings, core state (contacts and routes, not the seed) | `Peel/<account>/peel.sqlite` (+ `-wal`, `-shm`) | Plaintext SQLite, 0600 in a 0700 folder |
| Agent records and their FTS index | `Peel/<account>/agent.sqlite` | Plaintext SQLite, 0600 |
| Attachments | `Peel/<account>/media/cache` | **Stored decrypted** (`MediaStore`: "Decrypted attachments on disk"). The `file` command reports them as PNG and so on |
| Uploads waiting to go | `Peel/<account>/media/outbox` | Encrypted (RNCryptor, the attachment cipher) |
| Twelve words | Data-protection Keychain, `dev.peel`, `WhenUnlockedThisDeviceOnly`, app access group | **Encrypted**: sealed under the PIN (`PINBox`: PBKDF2 at 2.5M rounds, then AES-GCM) inside a Keychain item only Peel's team can read |
| Agent model key, strut key, brain, Hive credential | Keychain items | Encrypted (Keychain) |
| Strut's secrets (model key, bridge token) | `Peel/Strut/workspace/secrets.json` | Encrypted with `Profile.strutKey` |
| Strut's memory graph and workspace | `Peel/Strut/workspace/memory/graph.lbug`, `graph/graph.lbug` | Plaintext Ladybug files |
| Agent sessions | `Peel/Strut/workspace/sessions/*/messages.jsonl`, `turns.jsonl`, `system.md` | Plaintext JSON lines: full agent transcripts |
| Jobs, proposals, peers, dictation vocabulary | `Peel/Strut/workspace/{jobs,proposals,audio}/…`, `peers.json` | Plaintext JSON |
| Development profiles | `Peel/dev/<name>/` | Plaintext, and the words sit in a plain `mnemonic` file (by design, for the CLI harness) |

Also worth knowing:

- **Time Machine** backs up `~/Library/Application Support` unless it is
  excluded, so backups already hold plaintext copies of all of the above.
  Encrypting from now on doesn't reach those copies. Only an encrypted
  backup disk protects them.
- **App Store builds** run sandboxed (`Peel.AppStore.entitlements`), so
  their data lives in `~/Library/Containers/…`. Since macOS 14 the
  system asks before another app reads a sandboxed app's container. That
  is a real barrier, but only for those builds, and it is a consent
  prompt, not encryption. Debug builds and `scripts/run-app.sh`, which
  is what this Mac runs, are not sandboxed. Their data is in the plain
  Application Support path.
- **iOS** runs the same `Storage` code. The iOS target sets no
  data-protection entitlement, so files get the iOS default, Complete
  Until First User Authentication. That is real hardware-keyed
  encryption until the phone is first unlocked after a boot, and
  readable to the app (and to a forensic extraction of an unlocked
  phone) after that. Other apps can't read it because of the iOS
  sandbox.

## What the PIN guarantees today

1. Without the PIN, nobody can get the twelve words out of this Mac's
   Keychain, and so can't sign as you, spend, or restore the account
   elsewhere. The Keychain access group is the main barrier. The PIN adds
   a slow guess on top (about 0.4 s per try, so roughly 4.6 CPU-days for
   all 10⁶ PINs, much less on a GPU).
2. Peel's UI, notifications and the clipboard secret are hidden after
   the timeout and at launch.
3. Peel's own surfaces outside the main window, such as Dictation
   History, follow the lock (`unlockedStorage`).

It does **not** stop anything running as you from reading your
messages, payments, dictation, agent memory or attachments from disk,
whether Peel is locked, quit or running. That is exactly what the
`sqlite3` read did.

## Options

### A. SQLCipher, keyed from the account (recommended for the two databases)

Open both databases with SQLCipher and a 256-bit raw key.

- **Where the key comes from.** Derive it from the account seed, which
  `Account.load` already holds at the moment it opens `Storage`:
  `HKDF(seed, info: "peel.sqlite/v1")`, with a second `info` for
  `agent.sqlite`. Benefits:
  - no new Keychain item;
  - the PIN (or Face ID, which hands back the PIN) gates the data
    automatically, because the key exists only once the words are
    unsealed;
  - a PIN change needs no rekey;
  - "forget account" already deletes the data.

  The other choice is a random key in its own `WhenUnlockedThisDeviceOnly`
  Keychain item, sealed with `PINBox` like the words. It works, but it
  is one more secret to manage.
- **What it buys.** A copied or backed-up `peel.sqlite` is noise without
  the words. Once Peel is quit (or before first unlock at launch), the
  data on disk needs the Keychain item and the PIN, the same wall that
  guards the words. While Peel is running and unlocked, the key is only
  in Peel's memory. Another process can't read it from there: the
  hardened runtime blocks other processes from reading Peel's memory.
- **What it doesn't buy.** Data Peel has written elsewhere (media
  cache, strut files, old Time Machine copies) stays plaintext until it
  gets its own fix. The lock-timeout state keeps the database open, so
  a locked-but-running Peel still has the key in memory. Closing the
  engine on lock would fix that, but notifications would then need the
  PIN, so it is a separate decision.
- **Performance.** With a raw key (`PRAGMA key = "x'…'"`) SQLCipher skips
  its PBKDF2, so opening costs almost nothing. Page encryption (AES-256
  plus HMAC per page) typically adds around 5–15% to I/O-bound queries.
  The message list and FTS search are mostly memory-cached, so expect
  the cost to be hard to notice. Measure it on the universe tribe before
  and after.
- **Migration.** One-time, on the first unlock after the upgrade:
  `ATTACH 'peel.enc' AS enc KEY "x'…'"; SELECT sqlcipher_export('enc');`,
  then check it, swap the files and delete the plaintext file with its
  `-wal` and `-shm`. That takes about a second for today's 37 MB file.
  It must be crash-safe: keep the plaintext file until the encrypted one
  opens and passes `PRAGMA cipher_integrity_check`. APFS doesn't
  guarantee the old blocks are wiped, so the plaintext can survive in
  free space and snapshots for a while.
- **Engineering cost.** The real cost is the build, not the code.
  - GRDB's standard SPM product links the system SQLite. SQLCipher needs
    a SQLCipher-enabled GRDB build: Zetetic's SPM package with GRDB's
    SQLCipher support, a maintained fork, or a vendored amalgamation.
    Spike this first, and check that FTS5 is compiled in, because both
    databases use it.
  - It adds about 1–2 MB to the binary and touches both the Mac and iOS
    apps (same `Storage`).
  - `storedBalanceMsat` (balance on the lock screen) can no longer read
    the database before the PIN. Drop it, or keep that one number in a
    setting outside the database.
  - Development profiles keep working: their words are in a file, so
    their key is too.
  - Tests that open `Storage` directly need a key passed in.

### B. Data Protection classes (`FileProtectionType`)

- **On iOS** this is the native tool, and it's already partly there by
  default. Moving the databases to `.complete` would encrypt them
  whenever the phone is locked. But anything that runs while the phone
  is locked can't read them then: notification handling, background
  delivery. `.completeUnlessOpen` is the usual compromise for an open
  database. It costs little (an entitlement, or attributes when creating
  files), and the system migrates nothing.
- **On macOS** protection classes are tied to the login session, much
  like FileVault. They protect a powered-off or logged-out Mac. They do
  nothing against another process running as you while you are logged
  in, which is the case that matters here. They also don't make the PIN
  mean anything for the data.
- Verdict: worth doing on iOS later as defence in depth. It doesn't
  answer the question on the Mac.

### C. Document reliance on FileVault (and the sandbox)

- Write the model down: data at rest relies on FileVault and, for App
  Store builds, the sandbox container. The PIN guards the account keys
  and the UI. It costs nothing and is honest.
- It leaves the observed hole open. Any tool, script, compromised
  dependency or agent running as you can read every message and
  dictation. For a privacy-first app whose users run local agents
  alongside it, that is the threat that matters most.
- Do this now regardless, as the stated model until A lands.

## Recommendation

1. **Now:** adopt C as the written model (this doc), and say in the
   privacy copy that the PIN locks the app and the account keys, not the
   files.
2. **Next:** A for `peel.sqlite` and `agent.sqlite`, with the key derived
   from the seed. One PR: a spike to prove a SQLCipher GRDB build with
   FTS5 on both platforms, then the migration. This is what makes "the
   PIN protects my data" true.
3. **Then, in the same spirit:**
   - Keep `media/cache` encrypted on disk and decrypt on read. The
     attachment cipher (`MediaCrypto`) already exists, and the key can
     come from the same HKDF.
   - Have strut encrypt its workspace (graph files, `sessions/*.jsonl`,
     jobs) with a key the host hands it, the way `secrets.json` already
     works with `strutKey`. This is strut's contract to define ("strut is
     the brain"). It needs to find out whether Ladybug can encrypt its
     files, or whether strut has to wrap them.
   - On iOS, set `.completeUnlessOpen` on the profile directory.
4. Optionally exclude `Peel/` from Time Machine once A lands. The words
   and the server restore an account, and memory has its own encrypted
   backup. Until then, an encrypted backup disk is the only protection
   for those copies.
