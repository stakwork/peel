# Phase 6 — Calls

Status: planned. LiveKit only; Jitsi links open in the browser.

- Call links arrive as type 32 messages; start and join from a chat.
- LiveKit Swift SDK, room token from the existing API
  (`API+LiveKitExtension.swift` in the Mac app), participants socket.
- Mac: a call window with mute, camera, screen share. iPhone later needs
  CallKit and VoIP push, which depend on the push question in phase 7.
