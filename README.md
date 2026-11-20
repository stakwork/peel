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
- `Apps/` — the Mac and iPhone apps, one Xcode project (`Apps/Peel.xcodeproj`),
  and the SwiftUI they share (`Apps/Shared`).
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

## Localization

The apps are in English and Spanish (`es`). Text lives in String Catalogs:

- `Apps/Shared/Shared.xcstrings`: strings in shared code (`Apps/Shared`) and in
  every `Sources/` package (table `Shared`, so it does not clash with the app
  catalogs). Always name the table: `Text("x", tableName: "Shared")` or
  `String(localized: "x", table: "Shared")`. Both apps bundle it, and the
  packages read the app's bundle.
- `Apps/Mac/Peel/Localizable.xcstrings`: the Mac app
- `Apps/iOS/Peel/Localizable.xcstrings`: the iPhone app
- `Apps/Mac/Peel/InfoPlist.xcstrings`, `Apps/iOS/Peel/InfoPlist.xcstrings`:
  the permission descriptions (`NS*UsageDescription`)

**Add a language.** In Xcode, open a `.xcstrings`, click **+** and pick the
language (Project > Info > Localizations adds it to `knownRegions` in
`project.pbxproj`). By hand: add the locale code under each string's
`localizations` in the JSON, and the code to `knownRegions`.

**Add a string.** Use a literal where SwiftUI takes a `LocalizedStringKey`
(`Text("Save")`, `Button`, `Label`, `Toggle`, `navigationTitle`), and
`String(localized: "…")` anywhere else (a `String` property, an alert, an
AppKit title, a helper that takes a `String`). A ternary of literals in `Text(`
is a plain `String`: write `String(localized:)` on each branch. Build a
sentence as ONE interpolated string, never by `+`, so a translator can reorder
it; for a count use a plural variation (`%lld replies`, with `one` and `other`
in en and es) or `Formatting.count`. Keys with several placeholders use
positional specifiers in the values (`%1$@ … %2$@`). Never localize what is
compared, stored or sent.

**Building does not add the key.** `SWIFT_EMIT_LOC_STRINGS` is `NO`, so Xcode
does not extract keys: add the key and its `es` value to the catalog by hand
(the key is the literal with each `\(x)` as `%@` / `%lld`). Then run
`python3 scripts/check-localization.py`: it checks every catalog (valid JSON,
an `es` value for every key, matching placeholders, plural forms, no key with
leading or trailing space) and scans the Swift sources for localized literals
with no key or no table. `--hunt <files>` lists string literals that look
user-facing but are not localized yet.

**Test.** Edit the scheme, Options > App Language > Spanish, or launch with
`-AppleLanguages '(es)'`.

See `AGENTS.md` for how the code is organised, `docs/PLAN.md` for the
architecture, and `docs/phases/` for what is done and what comes next.
