# Phase 7 — iPhone

Status: planned.

- Same PeelCore and most views; an iOS target in the package plus an Xcode
  project for signing. Needs Xcode installed.
- The package declares iOS 17 (2026-10-07) and Mac-only calls are behind
  `#if os(macOS)`, but nothing builds for iOS yet: `Vendor/sphinxrsFFI.xcframework`
  has only a macOS slice. Add `ios-arm64` and `ios-arm64-simulator` slices in
  `scripts/build-ffi.sh` (build from `sphinx-rs` for `aarch64-apple-ios` and
  `aarch64-apple-ios-sim`; the official iOS lib has no arm64 simulator slice).
- The connection status lives in the Mac-only window subtitle; iPhone needs
  another place for it.
- Push notifications are the open problem: the mixer keeps one push token per
  account and sends through `hub.sphinx.chat`, which signs for the official
  bundle ID. Options: ship under the official bundle ID (migration path), or
  register a second app with the hub (server change). Until then, do not call
  `setPushToken` from Peel on a real account.
- Background fetch, notification service extension for decrypting the child
  index, Keychain access group shared with the Mac app.
