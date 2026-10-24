# Peel Serve: Peel's engine on the brain (Peel Brain v2)

Last updated 2026-10-14. **A proposal for Tom's review; nothing is built.**
It follows [peel-brain.md](peel-brain.md) (v1: strut and the graph on a home
server, "Later: Peel's engine on the server") and the remote track of
[phases/07-iphone.md](phases/07-iphone.md) (the agent as a contact, B1 to
B5, and H1 "brain mode for a Mac mini"). Research read on 2026-10-14 from
Peel's `main`, `~/Documents/sphinx-swarm` and stakwork/strut#168.

## Goal

v1 moves strut and memory to an always-on box, but the agent still lives in
the Mac app. So with the Mac asleep:

- automations that read your chats or message you do not run;
- the agent cannot answer you;
- nothing can send you a result as a Sphinx message.

v2 puts Peel's engine on the brain as a third container, `peel-serve`. It
runs your Sphinx account (as another device of it), the agent's own account
(the agent as a contact) and the agent loop, all day. Your Mac and phone
stay full Sphinx clients: if the brain is down you can still chat.

```
brain = docker-compose
├── tailscale    Tailscale's image                                  v1
├── strut        ghcr.io/stakwork/strut (strut#168)                 v1
└── peel-serve   ghcr.io/stakwork/peel-serve, built from this repo  v2
                 ├── your account's engine  (another device of it)
                 ├── the agent's engine     (the agent as a contact)
                 └── the agent loop, the remote inbox, automations
```

## Is this the right shape?

| Option | Verdict |
|---|---|
| **A. `peel-serve`: Peel's Swift engine, headless, built for Linux** | **Chosen.** One engine on every host, as [agent-native.md](agent-native.md) asks: the same message conventions, storage and two-device behaviour the apps have and their tests cover. The port is contained (below) |
| B. Peel.app on a Mac mini as the brain (07-iphone H1) | Works with no port, and step 1 below gives it for free. But it is Mac-only: no Pi, PC or NAS, and nothing for Gonza. A step on the way, not the end |
| C. Swarm's `sphinx-bot` image (`sphinxlightning/sphinx-bot`, takes a `SEED`) | A headless Sphinx client that exists today, but a different engine: none of Peel's agent store, approval rules, tools or conventions. Two clients that drift apart. Worth reading for how it runs headless, not adopting |
| D. Move the engine to TypeScript or Rust | TypeScript on the server makes the devices thin readers and loses local-first. Rust under every app is the best end state but the biggest rewrite, and a Sphinx-team decision. Later, if ever |

**Inside the container, keep two engines, not one.** Your account and the
agent's are separate Sphinx accounts (07-iphone, "Why its own account, even
on an always-on server"). Agents as children of one account need a protocol
change, so that stays "Later" in that doc.

## The rules

1. **An account has exactly one agent host,** like it has exactly one strut.
   With `peel-serve` running, the Mac and phone do not run the agent loop
   themselves; they talk to the agent as a contact. Two hosts answering the
   same message is the double reply this avoids.
2. **strut never calls a device.** Automations are pulled (peel-brain.md,
   build step 3). On the brain, `peel-serve` is the always-on puller, so
   every automation runs on time. `peel-serve` shares the Tailscale
   container's network, as strut does, so it reaches strut on
   `127.0.0.1:3000` with no new port.
3. **Devices stay full clients.** `peel-serve` is one more device of your
   account, not a server the apps read from. Chat, payments and push work
   with the brain off.

## What runs in `peel-serve`

| Piece | Today | In `peel-serve` |
|---|---|---|
| Your account's engine | `Engine` in the app or `peel` CLI | The same `Engine`, connected all day; catches up like a second Mac |
| The agent's account | Not built (07-iphone B1) | A second `Engine`; its words derived from yours |
| The agent loop | `AgentSession`, hosted by the Mac app (`Sources/PeelApp/AppModel+Agent.swift`, `MacAgent`) | The same `AgentSession`, hosted headless |
| The remote inbox | Not built (B2 to B4) | Takes Talk and control messages from your devices, runs turns, replies |
| Automations | strut calls the app's `AutomationServer` on loopback | Pulls waiting runs from strut (build step 3) and runs them |
| Approvals | A sheet on the Mac | Sent to your devices as control messages (B4) |

## Keys: your devices are the key

`peel-serve` needs your twelve words, because the agent reads your chats and
sends as you behind the approval card. That is the trade for "it acts on my
chats while I sleep", and why the brain is hardware you own. The box also
holds your chat history, which is just as private.

**The rule: the box holds only ciphertext. The key that opens it lives in
the Keychain of your Mac and phone.** A stolen box, a pulled disk or a
leaked backup of `./data` opens nothing.

| Threat | What stops it |
|---|---|
| The box or its disk is taken (theft, repair, resale) | Words and chats are sealed; the unlock key is not on the box |
| A backup of `./data` leaks | The same: ciphertext only |
| Something else on the box (strut's workflows run code) | Separate volume, a key on every endpoint, a locked-down container |
| The handover is intercepted | Sealed end to end to `peel-serve`'s own key |
| `peel-serve` itself is compromised while unlocked | Not stopped: it holds your words in memory. Limited by little money in the account and approvals on the phone |

### The unlock key

- **At pairing**, Peel makes a random 32-byte unlock key and keeps it in
  the Keychain of each of your devices (`SecretStore`, behind Face ID or
  Touch ID like the PIN). It is never typed, so it needs no password
  stretching.
- **On the box**, `./data/peel` holds:
  - your words, sealed with the unlock key (ChaCha20-Poly1305);
  - both accounts' databases, encrypted with SQLCipher (GRDB supports it)
    under a key derived from the unlock key, so chats are sealed too;
  - downloaded media, sealed the same way.
- **The agent's words** are derived from yours in memory at each unlock
  (07-iphone, "One set of words"), so nothing more is stored.

### Locked and unlocked

- `peel-serve` **starts locked**: it holds ciphertext and does nothing else.
- **Any of your Peel apps that is open unlocks it**: Peel sees the brain
  locked (the Brain setting already checks the brain) and sends the unlock
  key. The words and database keys are then decrypted into memory only, and
  never written out in the clear.
- After a **reboot or power cut** the agent waits, locked, until you next
  open Peel, which shows "Brain locked" and unlocks with one tap or on its
  own. On an always-on box reboots are rare; that wait is the price of a
  stolen disk being useless.
- **Optional, for boxes with a TPM** (most PCs, some NAS boxes): the unlock
  key can also be sealed to that machine's TPM, so it unlocks itself after
  a reboot, on that machine only. A disk moved to another machine still
  opens nothing. A Raspberry Pi has no TPM and uses the default.

### The handover

`tailscale serve` ends https in the Tailscale container, and strut shares
that container's network, so https alone is not end to end.

- At setup, `peel-serve` makes its own key pair. Its fingerprint goes in
  the pairing link, so Peel knows it is talking to the real `peel-serve`.
- Peel seals the words, and later each unlock, to that key with HPKE
  (CryptoKit on the Mac and phone). Only `peel-serve` can open them.
- Each device registers its own key at pairing and signs what it sends, so
  `peel-serve` takes requests only from your devices.
- The words go once, after a confirmation in Peel. Never in a URL, a QR
  code, `.env` or a log.

### On the box

- **Its own volume:** `./data/peel`; strut never mounts it.
- **No open endpoint:** strut's workflows can reach `127.0.0.1`, so every
  `peel-serve` route needs a signed request or its key.
- **A locked-down container:** a non-root user, a read-only filesystem
  except `/data`, no shell, all capabilities dropped.

### If it goes wrong

- **Keep little money in the account.** The agent's work needs none:
  messages between you and the agent are free. A compromised, unlocked
  `peel-serve` can sign as you, and Peel's approval rules cannot stop
  someone who has the words.
- **Approvals happen on your phone,** a device the brain does not control.
- **"Stop running the agent on the brain"** in Peel wipes `./data/peel` and
  moves the agent loop back to the Mac. Your twelve words stay the only
  real backup: the box's copy can always be sent again.
- **Later:** keep the signing key off the box entirely, on a separate
  signing device (peel-brain.md, "Later").

## The Linux port

`PeelCore`, `AgentKit`, `PeelAgent` and the `peel` CLI build for Linux.
`PeelUI`, `PeelApp` and LiveKit do not need to.

| Where | Today | On Linux |
|---|---|---|
| The agent host | Inside the Mac app (`AppModel+Agent.swift`, about 500 lines, mixed with UI state) | A headless host in `PeelAgent` that the app and `peel serve` both use. The largest item |
| `Sphinxrs` | `Vendor/sphinxrsFFI.xcframework`, a Mac (and iOS) static library | `sphinx-ffi` built for `x86_64` and `aarch64` Linux from the commit `sphinxrs.lock` names, linked through a system-library or artifact-bundle target, pinned in the lock |
| `SecretStore`, `BiometricUnlock` | Keychain, `Security`, `CommonCrypto`, `CryptoKit` | A sealed file store opened by the unlock key ("Keys"); biometrics left out |
| `Storage`, `MediaStore` | Plain SQLite and files; the Mac relies on FileVault | SQLCipher and sealed media under keys from the unlock key, on the brain only |
| `MediaCrypto`, `MediaStore`, `AutomationsClient` | `CommonCrypto` (AES, PBKDF2) and `CryptoKit` | `swift-crypto` (`Crypto`, `_CryptoExtras`) |
| `AutomationServer` | `SecRandomCopyBytes` | `SystemRandomNumberGenerator`; the server itself goes once automations are pulled |
| `Transport` | MQTT over `NIOTransportServices` | MQTT over `NIOPosix` and `NIOSSL`, which `mqtt-nio` supports |
| `Engine`, `PeelError` | `Network` (`NWPathMonitor`) | No path monitor on Linux; the MQTT reconnect covers a server's network |
| `Media` | `AVFoundation` to check audio and video | The byte sniffing it already does, without the AVFoundation check |
| `URLSession` callers (six files) | Foundation | `FoundationNetworking` |
| `Package.swift` | Apple platforms, the xcframework | Per-platform conditions; LiveKit, `PeelUI` and `PeelApp` Apple-only |

GRDB, `Synchronization` and `Observation` (used by `AgentSession`) ship
with the Linux toolchain or build there; step 2 confirms it.

## The image

- `Dockerfile` in this repo: build in `swift:6` with the Linux
  `sphinx-ffi`, run `peel serve` in a slim image. Expect hundreds of MB, not
  strut's 2.8 GB.
- Published as `ghcr.io/stakwork/peel-serve` for amd64 and arm64 by a
  workflow copied from strut#168 (GitHub's own token, `latest` and the short
  sha). This is the Peel Docker image the 2026-10-14 notes asked about.
- `brain/docker-compose.yml` gains the service:

```yaml
  peel-serve:
    image: ${PEEL_IMAGE:-ghcr.io/stakwork/peel-serve:latest}
    network_mode: service:tailscale     # strut on 127.0.0.1:3000; no port opened
    restart: unless-stopped
    user: "1000:1000"
    read_only: true
    cap_drop: [ALL]
    security_opt: [no-new-privileges:true]
    environment:
      STRUT_URL: http://127.0.0.1:3000
      STRUT_API_KEY: ${STRUT_API_KEY:?run ./setup.sh first}
      # No unlock key here: it lives on your devices ("Keys").
    volumes:
      - ./data/peel:/data               # ciphertext only: sealed words, SQLCipher, media
```

## Build order

Steps 1 and 2 are independent and can run side by side once the
prerequisites are in.

0. **Prerequisites,** already planned elsewhere: the agent as a contact and
   the remote inbox (07-iphone B1, B2), and automations by pull
   (peel-brain.md, build step 3).
1. **`peel serve` on macOS.** The headless host out of the Mac app: open the
   profile, connect both engines, run the agent loop, the inbox and the
   automation puller, no UI. Peel.app uses the same host. This alone is
   07-iphone H1: a Mac mini can be the whole brain.
2. **The Linux build.** The port table above, and a CI job on Ubuntu that
   builds and runs `PeelCoreTests` and `AgentKitTests`.
3. **The image.** The `Dockerfile` and the publish workflow.
4. **The bundle and the keys.** `peel-serve` in `brain/`; its key pair and
   fingerprint in `setup.sh`'s pairing link; the unlock key in each
   device's Keychain; the sealed handover; locked and unlocked; SQLCipher
   for the brain's databases. TPM unlock after.
5. **The Brain setting.** "Run the agent on: This Mac / Home server". On
   Home server the Mac stops its own agent loop and its Agent chat talks to
   the agent contact.

## Done means

- With the Mac and phone off for a night, a scheduled automation that
  reads a tribe runs on time, and its result arrives on the phone as a
  Sphinx message in the morning.
- From the official Sphinx app, a message to the agent gets an answer while
  every Peel is closed.
- `peel-serve` runs on a Raspberry Pi 4 beside strut, and on Gonza's NAS.
- Turning the brain off loses nothing on the devices: chat and payments
  work, and the agent moves back to the Mac.
- A copy of `./data` taken from the box opens nothing without one of your
  devices. After a reboot the brain stays locked until Peel is opened.

## Open questions

1. Is handing the words over from the Mac the right first step, or should
   the box's setup page take them (typed or scanned) so a Mac is never
   needed? Either way the unlock key must stay off the box.
2. Should the phone unlock the brain on its own (a background refresh or a
   silent push), so a reboot overnight does not wait for you to open Peel?
3. Who builds `sphinx-ffi` for Linux: Peel's CI from the locked commit, or
   the Sphinx team beside the Mac and iOS libraries? Does `sphinx-bot`
   already link a Linux build?
4. Memory and CPU on a Pi 4 with strut and two engines: measure once step 2
   runs.
5. Does the agent's engine also need a stable push token, or is it enough
   that your devices get push for its replies as for any contact?
