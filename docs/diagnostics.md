# On-device crash and memory diagnostics

## Status (2026-10-25)

**Built, first slice, Mac and iPhone.** The record only: Peel notes what went
wrong on this device, and shows it to the person who owns it. Nothing leaves
the device: no upload, no MetricKit, no DiagnosticReports, no Sentry,
Crashlytics or Bugsnag, no automatic export, no Jamie or Hive round trip.

Built: `Sources/PeelDiagnostics` (no UI), the notice and "Show record" sheet
on both apps, the error and action wiring in `AppModel`, the strut's stderr
tail on the Mac.
Not built: any way to send, share or export a record; the `diagnostics.latest`
device request (named in `DeviceReads.swift`'s comment, not in its switch).
Not checked: a build for macOS or iOS (written on Linux; see "Verify on a
Mac").

## The guarantee

Two things, and only these:

1. **The event ring holds no free text.** `DiagnosticEvent` has no `String`
   field: only enums and numbers (kind, error kind, last action, footprint,
   available memory, pressure level, previous run, exit reason and status,
   time, count). No error message, name, path, amount or key can be stored,
   however a caller is written. The live `os.Logger` mirror (subsystem
   `dev.peel.mac`) logs enum names only.
2. **A crash record is redacted on a best-effort basis before it is shown,
   copied or handed on.** The raw report stays in a private folder and no
   public function returns it. Redaction keeps structure (stacks, image
   UUIDs, load addresses, registers) and scrubs every free-text field by
   rule. Rules catch what Peel knows to look for; they are not a proof.

## What is recorded

- **Crash reports**: PLCrashReporter 1.12.2, one instance, no upload, no
  callbacks, no custom data. Threads with frames and registers, binary
  images (uuid, base, size), exception name and reason, signal, process
  info, machine model, app and OS version, time. Mach handler in release,
  BSD in debug. Off while a debugger is attached (`P_TRACED`), because it
  would take the debugger's signals: **test a crash without one.** The
  report is moved from the library's folder into `Diagnostics/raw` and the
  library's copy purged.
- **How the last run ended** (`PreviousRun`): a marker file, `running` from
  launch, `clean` on normal termination (the Mac's and the phone's
  willTerminate), with the last known state (in front or not, from the Mac's
  active/resign and the phone's scene phase). Next launch: a report means
  `crashed`; `running` and in front means `killedForeground`; `running` and
  in the background means `killedBackground`, the system's doing, not
  announced.
- **The event ring** (`events.ring`, JSON lines, about 256 KiB or 2000
  events, rotated to the newest half, identical consecutive events counted):
  every error that becomes a notice, through `PeelError.noted` and
  `Diagnostics.note(error:)`, with what the person had just asked for
  (`tribeJoin`, `send`, `sync`, `launch`, `other`); memory samples
  (`phys_footprint`, every 60 s in front, skipped when within 5% of the last;
  `os_proc_available_memory` on iOS); memory pressure (the Mac's dispatch
  source; the phone's warning notification); launches; the previous run;
  the strut's exits.
- **The strut's exit** (Mac): reason and status in the ring, its last 2 KiB
  of stderr, redacted, in `Diagnostics/strut-stderr-tail.txt`. Its argv and
  environment are never logged.

Where: `Application Support/Peel/Diagnostics` on the Mac,
`Application Support/Diagnostics` in the iPhone app's container. Owner-only,
excluded from backup, iOS file protection `completeUntilFirstUserAuthentication`.

## What is redacted

`Redactor(allow:knownNames:)`. Home paths (`/Users/<name>`, the app
container's UUID path) become `~`; hostnames, `.local` names, UUIDs that are
not binary images' and serials become `[device]`; amounts and bolt11
invoices `[amount]`; recovery-phrase runs, long hex or base64, `xprv`, `sk-`
tokens, bech32 `[key]`; quoted strings and text after `message:`, `text:`,
`name:`, `alias:`, `content:`, `body:` become `[text]`; contact names (built
from the contact list when redacting, never stored) `[contact]`. The tribe's
name and public key survive (`allow`, swapped for placeholders first).
Code-like symbols, addresses, PCs and image UUIDs are never scrubbed; fields
that are identifiers by nature (versions, model, signal) are kept only in
that alphabet.

## Reading it

`Diagnostics.previousRun()`, `latestRedactedReport(allow:knownNames:)`,
`recentEvents(limit:)`, `snapshot()`. The next launch after a crash or a kill
in front shows a notice (Mac: under the detail column; iPhone: top of Chats)
with "Show record": a sheet with the redacted text, Copy and Delete (removes
raw and redacted). Debug builds have "Force Test Crash" (Mac: Debug menu;
iPhone: You tab); launch from Finder or the Home Screen, not Xcode's Run.

## Library choice

PLCrashReporter, not KSCrash 2.6.0: KSCrash always writes the crashed
thread's raw stack words, the NSException's name, userInfo and reason, and a
device hash from `identifierForVendor` and the executable path, none of it
switchable. PLCrashReporter's report has threads, frames and registers,
images, the exception's name and reason, signal, process and machine info,
and no stack bytes, heap strings or device ids. It has no clean-exit marker,
so Peel writes its own.

## Verify on a Mac

The pure logic (ring, marker, redactor, store, tail buffer) builds and tests
on Linux: `swift test --filter PeelDiagnosticsTests` in a package holding
that target alone (the whole package needs the Apple frameworks). Not yet
compiled: `PendingReport.swift` and `CrashRecorder.swift` against
PLCrashReporter's Swift API (`enableAndReturnError`, the report's
properties), `MemoryProbe` (`task_info`, `sysctl`, `os_proc_available_memory`),
the app and strut changes, and whether `@_exported import PeelDiagnostics`
from PeelUI links the library into both apps without a project change. Then:
Force Test Crash with no debugger, relaunch, read the record.

## Journal

- 2026-10-25: first slice written. Unchecked on Apple platforms. Not
  applied: `AgentSession.notice` (AgentKit has no PeelDiagnostics
  dependency; its notices are about the key and rule stores), the forms'
  own problem lines (`TribeForms`, the Account's panes), which are not
  notices.
