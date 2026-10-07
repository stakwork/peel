# Phase 5 — Parity: contacts, profile, People, web apps, languages

Status: planned.

- Contacts UI: add by contact info or QR, share own QR and contact string,
  create invites with sats (`makeInvite`, `cancelInvite`), inbound requests.
- Profile: name, photo (upload to memes), PIN lock with timeout.
- People and LSATs: person profiles, external auth challenge
  (`SphinxOnionManager+PeopleExtension.swift`), LSAT list.
- Web apps: in-chat web apps in a WKWebView with an authorise prompt
  (`Scenes/Dashboard/WebApps` in the Mac app).
- Self-hosted servers with their own certificates: the official Mac app accepts
  any TLS certificate (`allowUntrustCACertificate`), most likely so self-hosted
  swarms with self-signed certificates work. Peel verifies by default and must
  not go back to "any certificate". Instead, trust on first use: when a server
  presents a certificate the system does not trust, show its fingerprint and
  let the person accept it once; store the fingerprint per server
  (`Setting`), and refuse to connect if it ever changes. The CLI's `--insecure`
  flag stays a development tool. Ask Tomás whether that is indeed the reason
  before building it.
- Localisation: the six languages of the official app via String Catalogs.
- Settings sync between devices (the Mac app's `Data Sync Manager`), if still
  wanted once the iPhone exists.
