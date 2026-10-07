# Phase 5 — Parity: contacts, profile, People, web apps, languages

Status: planned.

- Contacts UI: add by contact info or QR, share own QR and contact string,
  create invites with sats (`makeInvite`, `cancelInvite`), inbound requests.
- Profile: name, photo (upload to memes), PIN lock with timeout.
- People and LSATs: person profiles, external auth challenge
  (`SphinxOnionManager+PeopleExtension.swift`), LSAT list.
- Web apps: in-chat web apps in a WKWebView with an authorise prompt
  (`Scenes/Dashboard/WebApps` in the Mac app).
- Localisation: the six languages of the official app via String Catalogs.
- Settings sync between devices (the Mac app's `Data Sync Manager`), if still
  wanted once the iPhone exists.
