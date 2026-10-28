# On-device crash and memory diagnostics

## Status (2026-10-25)

**Built, first slice, Mac and iPhone.** Peel notes what went wrong on this
device and shows it to the person who owns it. Nothing is uploaded: no
MetricKit, no DiagnosticReports, no Sentry, Crashlytics or Bugsnag, no
automatic export. The redacted record reaches the person's agent only when it
reads it (the Mac's record: the iPhone's is read only on the iPhone), and
another workspace (Jamie, through a Stadeum peer) only as a summary the agent
writes, sent on the card a call to a workspace shows. The card is the only
gate on what goes: once the person picks "Always allow" for that workspace,
no card shows and the summary's size and wording rest on the prompt alone.

Built: `Sources/PeelDiagnostics` (no UI), the notice and "Show record" sheet
on both apps, the error and action wiring in `AppModel`, the strut's stderr
tail on the Mac, and the `diagnostics.latest` device request (the agent's
`sphinx/diagnostics` read, below).
Frames are named on the device at crash time in Debug builds only
(PLCrashReporter's symbol table and Objective-C strategies, `.all`), which
keep their symbols (`scripts/run-app.sh` makes one); release builds do not
symbolicate, so their frames are addresses.
Not built: any other way to send, share or export a record; a Swift runtime
error's message ("Index out of range") is not captured, only its signal.
Checked on a Mac: a real crash, the record shown after relaunch (#381); a
Force Test Crash read by the agent and sent to a workspace's assistant on the
card.

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
  On iOS most runs end this way, so `killedBackground` there is normal
  (suspension or jetsam; willTerminate is rarely delivered). A launch the
  system makes in the background is marked background from the start.
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

The agent reads it with `sphinx/diagnostics` (device request
`diagnostics.latest`, `DeviceReads`, the chat's agent only, not an
automation): how the last run ended, then the newest record, however old (its
date says when), redacted with the account's names at the time of the read
(`DiagnosticsNames`; no names read, no answer) and cut by `compact()` to the
crashed thread's top 25 frames without registers, the images they are in,
the last 15 events and the exception's words shortened; or the ring when no
record is kept. It is framed as chat data (never instructions) within its
character budget. It is a read, so no card; the record goes to the agent's
model like a chat read. Asked to tell a workspace, the agent sends a short
summary (`Orchestrator.diagnosticsPrompt`) through `strut/run-workflow`,
which the Mac shows on its "Send this to …?" card unless the person always
allows that workspace.

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
that target alone (the whole package needs the Apple frameworks). On a Mac:
Force Test Crash with no debugger, relaunch, read the record (compiled and
checked for #381).

## Journal

- 2026-10-25: first slice written. Unchecked on Apple platforms.
- 2026-10-25: the remaining notices wired, kind only: `AgentSession.notice`
  (AgentKit now depends on PeelDiagnostics; key read `other`, rules and chat
  reads `database`), the tribe forms' save problems (`saveProblem`, by the
  error's kind) and the Mac's and iPhone's refused-file notices (`refused`,
  since their words name files).
- 2026-10-25: the agent reads the record (`diagnostics.latest`,
  `sphinx/diagnostics`): redacted with the account's names, trimmed to fit a
  device answer (the whole record was 164 KB against 32 KB), framed as chat
  data; Debug builds name frames at crash time. First run end to end: the
  agent read a Force Test Crash and, asked, sent a summary to the stakwork
  workspace's assistant on the card, which filed it as an issue (closed:
  stakwork/peel#383). Learned: told only to "send" to a workspace, the agent
  picked `sphinx/send` to a tribe sharing the workspace's name; the prompt
  now names `strut/run-workflow`, and the same belongs in strut's peer line.
  Left for later: names the redactor does not know (tribe members, the
  person's per-tribe aliases); a Swift runtime error's message; a Report
  button (only internal users have a workspace to report to).
