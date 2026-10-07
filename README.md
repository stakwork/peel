# Peel

A native Sphinx chat client, written from scratch on the shared Rust core.

## Layout

- `Sources/PeelCore` — the client engine: state store, broker connection, and the
  handler for what the core returns. No UI.
- `Sources/PeelApp` — the SwiftUI Mac app.
- `Sources/peel` — a command-line harness for PeelCore. It keeps the mnemonic in a
  plain file, so use it with throwaway accounts only.
- `Sources/Sphinxrs`, `Vendor/` — the core's Swift bindings and static library,
  produced by `scripts/build-ffi.sh` and not checked in.

## Build

Needs sibling checkouts of `sphinx-rs` and `sphinx-mac-v2` (the bindings and the
prebuilt library come from them).

```sh
./scripts/build-ffi.sh
swift build
```

## Try it

```sh
./scripts/run-app.sh --profile throwaway
```

Or from the command line:

```sh
.build/debug/peel signup <invite-code> --alias "My name"
.build/debug/peel whoami
.build/debug/peel add <pubkey_lsp_scid>
.build/debug/peel send <pubkey> hello
.build/debug/peel listen
```

Accounts live under `~/Library/Application Support/Peel/dev/<profile>`; pick one
with `--profile`.

See `AGENTS.md` for how the code is organised and `docs/PLAN.md` for what is done
and what comes next.
