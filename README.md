# Peel

Peel is a private assistant that lives with you, remembers what you tell it,
runs errands within limits you set, and answers to you alone. It is also a
native Sphinx chat client, written from scratch on the shared Rust core.

## Guiding principles

1. **Privacy is a human right.**
2. **Personal agents will be a powerful helper to humans.**
3. **They must be controlled fully by the single human.**
4. **Security and backups apply the lessons of bitcoin self-custody. Losing
   data or a security fault is not allowed.**

What these mean for the person using Peel, and what they ask of the system,
are in [docs/VISION.md](docs/VISION.md). Read it before changing what Peel
does.

## Layout

- `Sources/PeelCore` — the client engine: state store, broker connection, and the
  handler for what the core returns. No UI.
- `Sources/PeelApp` — the SwiftUI Mac app.
- `Sources/peel` — a command-line harness for PeelCore. It keeps the mnemonic in a
  plain file, so use it with throwaway accounts only.
- `Sources/Sphinxrs`, `Vendor/` — the core's Swift bindings and static library,
  produced by `scripts/build-ffi.sh` and not checked in.

## Build

Needs macOS 15 or later and Xcode 27 or later (Swift 6.4).

```sh
./scripts/build-ffi.sh
swift build
swift test --filter PeelCoreTests
```

`build-ffi.sh` downloads the Sphinx core Peel links: the prebuilt Rust library,
its Swift bindings and header from the
[sphinx-rs](https://github.com/stakwork/sphinx-rs) release pinned in
`Vendor/sphinxrs.lock`, and checks each file's hash. Run it again whenever
the lock changes.

## Run the app

The app keeps the account's words in the Keychain, which needs it signed with
an Apple Development certificate. A free Apple ID is enough:

1. In Xcode > Settings > Accounts, add your Apple ID. Select its team, choose
   Manage Certificates, and add an Apple Development certificate.
2. Build, sign and open it (installed in `~/Applications`):

   ```sh
   ./scripts/run-app.sh -profile throwaway
   ```

`-profile` keeps a separate account per name; leave it out to use the app's
main account. A free team's provisioning profile lasts 7 days, after which the
app won't launch: run `./scripts/run-app.sh` again to re-sign it. If you have
several Apple Development certificates, set `PEEL_SIGN_IDENTITY` to the one to
use.

A bundle ID belongs to one team, so the app is signed as `dev.peel.mac.<your
team ID>`; set `PEEL_BUNDLE_ID` to choose another.

Or from the command line:

```sh
.build/debug/peel --profile alice signup - --alias "My name"   # paste the invite link on stdin
.build/debug/peel --profile alice whoami
.build/debug/peel --profile alice add <pubkey_lsp_scid>
.build/debug/peel --profile alice send <pubkey> hello
.build/debug/peel --profile alice listen
```

Accounts live under `~/Library/Application Support/Peel/dev/<profile>`; pick one
with `--profile` (required; `default` is reserved for the app's own account).

See `AGENTS.md` for how the code is organised, `docs/PLAN.md` for the
architecture, and `docs/phases/` for what is done and what comes next.
