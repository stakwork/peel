# Audit C: network, calls and privacy on the wire, 2026-10-08

Part C of the phase 8 security audit (`docs/phases/08-audit.md`, item 6).
Scope: `origin/main` at `2a945d7` (#83). Line numbers are on this branch.

I read the MQTT transport, the server and host settings, `Web`, the memes
server client, the tribes registry client, `CallServer`, `CallLink`, the
watched calls, screen sharing, the call session, the notifier's call path,
time zones and the read and push paths in the core. No production request
was made. The only local traffic was one mutation check: with the tribe-link
fix taken out, the new test made Peel connect to `127.0.0.1:9` (nothing
listens there), which proved the finding. Then the fix went back in.

## Verdict

The network code is not vibe-built. Someone thought about each boundary.
The protections hold:

- **TLS everywhere off this Mac.** MQTT checks certificates in full, and
  only the CLI's `--insecure` can turn that off. The app bundle has no ATS
  exceptions.
- **Every web request goes through an ephemeral session.** Redirects are
  checked. Photos and registry records come only from public https hosts.
- **Call links are parsed, not substring-matched.** They are checked
  against the configured call server's exact host and port, with a strict
  room name and only known query keys.
- **Tickets and presence go only to the configured server.** The media
  server allowlist uses exact hosts and fails closed.
- **The LiveKit token never reaches storage, logs or the CLI.**
- **Nothing calls `setPushToken`.**
- **The time zone never goes to a public tribe.**

The existing tests already pinned most of this, and they test the right
things.

I found three real holes, all small, and fixed them in this PR:

- **An invite could turn TLS off for the broker connection.** This was
  the only finding with medium severity.
- **A tribe link could make Peel fetch from a service on this Mac.**
- **The memes server could redirect Peel onto plain http on this Mac.**

What is left is low severity. Most of it is the protocol's own privacy
cost: the call server, photo hosts and tribe hosts learn your IP and what
you look at. The official apps have the same cost. One open item is worth
doing before the team sees the code: a tribe's "private" flag comes from
whichever host its join link named. A hostile host could therefore make
Peel send your time zone to a public tribe.

## Threats

Verdicts:

- **holds**: no way through that I could find.
- **weak**: a gap with a limited or conditional effect.
- **vulnerable**: an exploit exists. Each one is marked fixed or open.

### 1. Transport and servers

| # | Threat | Evidence | Verdict |
|---|---|---|---|
| 1.1 | MQTT accepts a forged certificate | `Transport.swift:72-74` uses `.fullVerification` unless `allowUntrustedCertificate`. The app always calls `engine.start()` with the default false (`AppModel.swift:888`). The flag exists only in the CLI, per run (`PeelCommand.swift:188`), and is never stored. | holds |
| 1.2 | Plaintext MQTT to a remote host by default | Without a scheme, only the exact names `127.0.0.1`, `localhost` and `::1` go plaintext (`Transport.swift:29`, `:49`). Look-alike names keep TLS: `localhost.example.com`, `127.0.0.2`, `LOCALHOST`, `127.0.0.1.nip.io` (`AuditTransportTests.onlyExactLoopbackSkipsTLS`). | holds |
| 1.3 | A server someone else names turns TLS off | The core returns an invite's `lsp_host` exactly as the inviter wrote it (`sphinx/src/bindings/invite.rs:177`). `Account.signup` parsed it with `ServerAddress.init`, so `mqtt://<real broker>:1883` meant a plaintext login. Anyone on the path then saw the signed login timestamp (replayable within the broker's window), the xpub client ID and every topic. Restoring from the public config had the same path. | **vulnerable, fixed**: `ServerAddress.named` (`Transport.swift:40`), used at `Account.swift:38` and `:94` |
| 1.4 | A production profile downgrades to plain HTTP (memes, call or tribes host) | `TribeLink.baseURL` picks http only for the exact loopback names (`Tribe.swift:248-256`). The call and memes hosts are set only by CLI flags (`PeelCommand.swift:206`). There is no ATS exception in the bundle (`bundle-app.sh:26-45`). | holds |
| 1.5 | A tribe link points Peel at a service on this Mac | `sphinx.chat://?action=tribeV2&…&host=127.0.0.1:<port>` made the Join form `GET http://127.0.0.1:<port>/tribes/<pubkey>`, whatever the account's server. It took a paste or a scanned QR code, and the path was fixed. Confirmed by the mutation check above. | **vulnerable (low), fixed**: refused unless the account's own server is on this Mac (`Engine+Tribes.swift:17`) |
| 1.6 | `Web` helpers (#42) | Sessions are ephemeral, with no URL cache or cookies (`Web.swift:12-20`). Redirects go only to public https hosts (`:36-38`). `isPublic` refuses IP literals in every spelling, credentials, and names only a local network resolves (`:71-84`; `WebTests`). A public name that resolves to a private address is not caught (`:69`). Https-only limits that: a local service would fail the TLS name check. | holds; DNS case weak |
| 1.7 | Bearer tokens leak | **Memes token:** kept in memory only (`Engine+Attachments.swift:301-311`). It is dropped when a redirect leaves the host or port (`MemesServer.swift:67-69`). **LiveKit token:** kept in memory only. Its `description` and `Mirror` leave it out (`CallServer.swift:18-23`). The CLI prints only its size (`Commands+Calls.swift:27`). A `URLError`, whose text holds the ticket URL and Hive key, is replaced by `.unreachable` (`CallServer.swift:132-135`). **LiveKit's own logs:** set to `.warning` (`PeelApp.swift:16`). I did not check what LiveKit logs at warning level. | holds; LiveKit logging unverified |
| 1.8 | The memes server redirects onto this network | The redirect policy allowed `http://127.0.0.1/…` from the production memes server, without the bearer token. That is a blind GET to a local service, chosen by the memes server's operator. | **weak, fixed**: plain http on this Mac is followed only from a memes server on this Mac (`MemesServer.swift:62-66`) |
| 1.9 | Attachments are fetched from or bought on a host a message names | Downloads and purchases need the media token's host to equal the configured memes host (`Engine+Attachments.swift:174`, `:234`). | holds |
| 1.10 | A media token rewrites the download path | The token is pasted into the URL unchecked (`MemesServer.swift:252`). The host cannot change, but `…/file/<a>/../<b>` reaches other GET routes on the memes server with the bearer token attached. | weak, open (finding 5) |
| 1.11 | `setPushToken` gets called | Nothing outside the generated bindings names it (`AuditPrivacyTests.nothingCallsSetPushToken` scans `Sources/`). | holds |

### 2. Calls

| # | Threat | Evidence | Verdict |
|---|---|---|---|
| 2.1 | The ticket request leaks or asks for too much | The session follows no redirect and keeps no cache (`CallServer.swift:74`). Every value is strictly percent-encoded, and `isHost` is never sent (`:144-153`). The only metadata is the photo URL: no pubkey (`:157-161`; `AuditCallTests.ticketMetadataIsThePhotoAlone`). | holds |
| 2.2 | A message steers the ticket or presence to another server | `callConnection` refuses a link that is not on the configured server, before any request (`Engine+Calls.swift:58-61`; `AuditCallTests.ticketsAndPresenceOnlyFromTheConfiguredServer`). A subscribe is sent only for a valid room name (`CallServer.swift:241`). | holds |
| 2.3 | `mediaHosts` admits another LiveKit tenant | The list is exact hosts and is empty today (`CallServer.swift:114`). `wss` is required; `ws` is allowed only on a loopback call server (`:181-195`). It fails closed: if the production server names a separate LiveKit host, Peel refuses it until that host is recorded. | holds |
| 2.4 | `CallLink` accepts other hosts, Jitsi or a lookalike | Links are parsed with `URLComponents`. The host and port must match exactly, with no credentials and no fragment; the room must match `^sphinx\.call\.[A-Za-z0-9._-]{1,128}$`; only three query keys are kept (`Call.swift:99-119`, `:172-181`). The existing `CallTests.swift:43-66` cover Jitsi, `@` tricks, ports, `%2e` and path injection. | holds |
| 2.5 | Hive links | They are joined with their `callKey` or `hiveToken`, but only on the configured server. Peel never makes one (`Call.swift:134-140`; `AuditCallTests.hiveLinksAreJoinOnlyOnTheCallServer`, `newLinksCarryNoKeys`). | holds |
| 2.6 | The presence feed injects names or photos | Names are stripped of control characters and capped. Identities with a control character are refused. Avatars are kept only when they are public https (`CallServer.swift:429-442`). | holds |
| 2.7 | Background watching (#83) over-subscribes or outlives a lock | It watches at most 8 calls, plus the header's 2 and the cards on screen. Only valid links on the configured server count. It stops when `phase` leaves `.ready` (`CallViews.swift:67-96`, `AppModel.swift:44`). But Peel locks only when it comes to the front (`AppModel.swift:405-410`). Past the PIN timeout, a Peel in the background keeps watching. | weak, open (finding 6) |
| 2.8 | A poster learns who watches their room | No. The feed lists participants, not subscribers. Only the call server sees watchers. | holds |
| 2.9 | Paid tribes charge a call its price | A call message pays only the 3-sat floor (`Tribe.swift:70-72`; `CallTests.aCallInAPaidTribePaysOnlyTheFloor`). | holds |
| 2.10 | A screen share shows Peel's windows (#70) | The picker excludes Peel's bundle and can't be changed from the menu bar (`CallScreenShare.swift:50-52`). A display share sets `sharingType = .none` on every window, again after each event (`:225-249`). A window opened mid-share might show for one frame before the next event. Notification banners are drawn by macOS, not Peel. I did not check whether they appear in a share. | holds; banners unverified |
| 2.11 | The picker lifetime | The picker is active only while Peel asks (`:54-62`). An answer that comes after the call ended is dropped (`CallSession.swift:295`). If a call ends with the picker open and the next call opens it again, the first wait is overwritten and never resumed (`CallScreenShare.swift:134-139`). That is a suspended task, not an exposure. | weak, open (finding 8) |
| 2.12 | Sharing outlives the call | Capture stops on `.lost` (`CallSession.swift:456`), on leave (`:200`) and when macOS ends it (`:324`). | holds |
| 2.13 | Entitlements | Only `device.audio-input` and `device.camera`, under hardened runtime (`Provision.entitlements`, `sign-app.sh:43`). There is no library-validation opt-out and no screen-capture entitlement: the picker needs none. | holds |
| 2.14 | Call notifications (#74) | Only someone else's call, at most 10 minutes old, valid on the server, and allowed by the chat's mute level. Locked, they say nothing (`Call.swift:70-74`, `Notifier.swift:156-164`, `:305-310`). Calls skip the summary, so a member who posts many calls makes many banners. Muting is the remedy. | holds |

### 3. Privacy on the wire

| # | Threat | Evidence | Verdict |
|---|---|---|---|
| 3.1 | The time zone reaches a public tribe | `offsetShared` sends it only to a contact the core holds a key for, or to a tribe whose stored record says private (`TimeZones.swift:229-230`). `deliver` asks every time (`Engine+Messages.swift:190`). A tribe with no stored record gets none (`AuditPrivacyTests.aTribeWithNoStoredRecordGetsNoOffset`). The existing `TimeZoneTests` cover public tribes, strangers, the switch and types. | holds |
| 3.2 | `isPrivate` goes stale | The record is refreshed on connect, and rechecked after a send that carried the offset when the last read is older than 5 minutes (`Engine+Tribes.swift:510`, `Engine.swift:75`). The first message after a tribe goes public can still carry it. | weak, by design |
| 3.3 | A host lies about `isPrivate` | The record comes from the host the join link named (`Engine+Tribes.swift:45-55`, `Tribe.swift:354`), and the refresh keeps asking that host. Someone hosting a fake registry for a real public tribe sends a link with their host; the record says `private: true`, and Peel shares your zone with every member. It needs you to join from that link. | **weak, fixed** 2026-10-09 (finding 4) |
| 3.4 | Read receipts reach contacts | `Sphinxrs.read` publishes only to the account's own broker topic (`sphinx/src/bindings/details.rs:6-41`). Contacts never see it. | holds |
| 3.5 | Presence subscriptions | The call server sees your IP and up to about 10 rooms you watch (2.7). No one else does. | weak, inherent |
| 3.6 | Contacts or tribes leak to third parties | No request carries your contact or tribe list. Each host learns only its own part, with your IP: <ul><li>each tribe's host, on every connect (`Engine+Tribes.swift:462`);</li><li>a photo's host, when you see the photo (`Web.swift:55`);</li><li>the call server, which gets your alias and photo URL in the ticket query string.</li></ul> The official apps have the same cost. | weak, inherent (finding 7) |

## Findings, ranked

1. **An invite or the config could turn MQTT TLS off** (1.3). Medium.
   Fixed: `ServerAddress.named` refuses plaintext off this Mac for any
   address Peel did not get from the person. The CLI's `--server
   mqtt://…` still works for local stacks.
2. **A tribe link could make Peel fetch from this Mac** (1.5). Low.
   Fixed: the lookup is refused unless the account itself is on a local
   server.
3. **The memes server could redirect Peel onto plain http on this Mac**
   (1.8). Low. Fixed.
4. **A tribe's privacy comes from whatever host its link names** (3.3).
   Low to medium: it leaks the time zone to a public tribe. Open. *Fix:*
   when the account's own tribes host (`tribeHost`) lists the tribe, take
   `private` from there; when the two hosts disagree, treat the tribe as
   public. That is about 15 lines in `joinTribe` and `refreshTribes`,
   plus a test. I left it because it changes where the registry is read,
   and that needs Tom's call.

   **Decided and fixed (Tom, 2026-10-09):** `isPrivate` is taken only
   from the account's own configured tribes host (`tribeHost`). A record
   read from any other host, or with no tribes host recorded, leaves the
   tribe public, so the time zone is never sent there; nothing extra is
   fetched to compare. `Tribe.update(from:trustingPrivacy:)` takes the
   flag only when `Engine.isOwnTribeHost` says the record's host is the
   account's own (exact `host[:port]`, any case), on joining and on every
   registry refresh. The time zone decision is unchanged: `offsetShared`
   reads the stored `Tribe.isPrivate`, kept fresh by the refresh on
   connect and the background recheck (#52). Joining still asks to join
   (`MemberRequest`, pending) as the link's host says, so a private tribe
   on another server can still be joined; only the time zone waits for
   the account's own host. Owned tribes keep the flag their own tribes
   server reports. Migration v18 clears the flag on joined tribes stored
   from another host before this. Tests:
   `TimeZoneSharingTests.onlyTheOwnTribesHostMakesATribePrivate`,
   `MigrationTests.privateFlagsFromOtherHostsAreCleared`.
5. **The media token is not checked before it goes into the download
   path** (1.10). Low. Open. *Fix:* accept a token only when it is made of
   base64 or base64url characters and dots, and contains no `..`. The
   meta part may be standard base64 with `/`, so the check needs real
   tokens from the throwaway account first. That is why it is not in this
   PR.
6. **Presence watching continues past the PIN timeout while Peel is in
   the background** (2.7). Low. Open. *Fix:* a timer at `unlockedAt +
   timeout` that calls `stopWatchingCalls`, or lock on the timer rather
   than on coming to the front.
7. **Hosts named by others learn your IP and when you look** (3.6).
   Low, and the protocol's own cost. Open. *Options:* fetch photos only
   from the memes server's host by default, or add a "don't load photos
   from other hosts" setting.
8. **Loose ends to verify:**
   - the picker's overwritten wait (2.11): keep one wait and cancel the
     old one;
   - whether notification banners appear in a display share (2.10): test
     on a real share, and if they do, hide message text while sharing;
   - what LiveKit logs at `.warning` (1.7): grep the SDK for its connect
     URL.

Seen in passing, outside this part: a tribe that raises its price per
message is paid the new price on the next message, with no prompt. The
header shows the price (`ConversationView.swift:150`), but `deliver` reads
the stored record (`Engine+Messages.swift:196`). That belongs to the money
audit.

## Fixed in this PR

- `ServerAddress.named` (`Transport.swift`), used by `Account.signup` and
  `Account.restore`.
- A tribe link naming this Mac is refused unless the account's server is
  on this Mac (`Engine+Tribes.swift`). `TribeLink.isLoopback` is shared
  with `baseURL` (`Tribe.swift`).
- The memes server's redirect policy (`MemesServer.swift`). It is now
  internal, so the tests can reach it.
- `Tests/PeelCoreTests/AuditNetworkTests.swift`: 15 tests in three
  suites (transport, calls and privacy).
- `AGENTS.md`: the TLS rule and the test list.

`swift test`: 365 tests pass. The one known issue is the existing IPv6
`ServerAddress` case.

## Left

Findings 5–8 above, each with the fix it needs. None blocks Tom's own use.
Finding 4 was decided and fixed on 2026-10-09 (see above).
