# Jamie in tribes from Peel

Status: Peel's side built 2026-10-29. It waits for Hive's routes to be
switched on (`JAMIE_SERVICE_TOKEN`, `JAMIE_SPHINX_PUBKEY`) and for Jamie's
account to run. Not yet checked in the running app.

A tribe's owner links the tribe to one of the orgs Peel is paired with
(Stadeum). From then on anyone in the tribe can write `@jamie …`, and
Jamie, that org's orchestrator, answers in the tribe with its
deliverables. The turns run as the owner.

- The design is Hive's `docs/plans/jamie-in-tribes.md`.
- Hive's routes are stakwork/hive#5667.
- Jamie is one ordinary Sphinx account in every linked tribe, run by
  stakwork/sphinx `wasm/daemon` (#401).
- The twin of this file is `hive-calls.md`: a call with Jamie in it.

## What the owner does

1. Opens the tribe's details. A **Jamie** row is there for its owner only
   (`AppModel.offersJamie`: the owner, still in it, on a tribes server Hive
   can name).
2. Picks one of their orgs, or **No Jamie**. When the tribe has no Jamie
   yet and its app or second brain is on one of their orgs, **Add Jamie
   from Acme** links it in one tap.
3. In a private tribe, Jamie asks to join a few seconds later. Peel
   approves it without asking.

With no pairing, or a revoked one, the row starts Hive's pairing (Connect
Stadeum) and shows the code in place.

Everyone else in the tribe only types `@jamie`.

## Hive

Every route takes `Authorization: Bearer hivedev_…`, the device credential
(`HiveLink.credential`).

| Route | Answer |
|---|---|
| `GET /api/strut-devices/tribes` | `{ jamie: { pubkey, alias }, tribes: [{ pubkey, host, name, workspace, org, createdAt }] }` |
| `POST /api/strut-devices/tribes` with `{ workspace, tribe: { pubkey, host, name } }` | `{ jamie, tribe }` |
| `DELETE /api/strut-devices/tribes/<pubkey>` | `{ unlinked: true }`, or 404 when the person has no such link |

`workspace` is a `HivePeer.id`, the org's central workspace.

What Peel says when Hive refuses:

| Hive answers | Peel says |
|---|---|
| 503 | "Jamie isn't switched on in Stadeum yet." |
| 409 | "Someone else already linked this tribe to an org." |
| 401 (a revoked device, or a Hive without the routes) | "Stadeum didn't accept this device for Jamie. If it was disconnected in Stadeum, connect it again." |
| any other error, 403 included | "Stadeum could not add Jamie: <Hive's error>." |
| 200 that names a key that is not one, or another tribe | "Stadeum's answer about Jamie could not be read." |

The picker puts "Could not add Jamie." (or "remove") in front of these.

## Peel

**The Hive client** (`Sources/PeelCore/Hive.swift`), beside `startCall`:
`HiveClient.jamieLinks`, `linkTribe` and `unlinkTribe`, with
`JamieAccount`, `JamieLink` and `JamieLinks`.
- Keys are kept in lower case.
- A listed link Peel could not use is left out: a key that is not one, or
  a workspace id strut would not take.
- A DELETE Hive answers 404 is unlinked already, from the person's other
  device.

**Stadeum** (`Sources/PeelUI/Stadeum.swift`) keeps what Hive last said:
- `jamieLinks`, read by `readJamieLinks`. It is read each time a tribe's
  details open and each time an approval needs it, so the person's Mac and
  iPhone show the same pick. It is never kept on disk.
- `setJamie(_:for:)` links or unlinks.
- `jamiePick(of:)` is the picked peer id, "" for No Jamie, nil before Hive
  has answered.
- `jamieOptions(for:)` lists each live org, then No Jamie. An org the tribe
  is linked to that this device no longer pairs is listed too, so the row
  says what is true.

**The picker.** It is `TribeJamieSection` in the Mac's `TribeDetails.swift`
and `TribeJamie` in the iPhone's `ChatDetails.swift`, over one model,
`TribeJamiePicker` (`TribeForms.swift`).
- A pick applies at once.
- Hive's refusal is shown in place.
- The check is always on the real link. The org a call would bring Jamie
  from (`HivePeer.jamie`, the tribe's `app_url` or `second_brain_url`) is
  offered as the one-tap button, `AppModel.jamieSuggestion`, and never shown
  as picked.

**Approving Jamie** (`AppModel+Jamie.swift`, `Engine.approveWaitingMember`).
- It starts on every member request in a tribe this account owns, live or
  from history. It waits until Stadeum says the tribe is linked: the links
  are read again unless read in the last minute, since the tribe may have
  been linked on the other device.
- The request carries only an alias. So the engine asks the tribes server
  who waits and approves the entry whose key is Jamie's, by key.
- It asks up to three times, five seconds apart, in case the server lists
  the request after it arrives.
- A failure shows above the tribe's composer. The owner can still approve
  in Members.

**Deliverables.** Jamie's replies carry `metadata` with
`{ "strut": { workspace, artifacts } }`.
- `Message.strutArtifacts` (`ControlEnvelope.swift`) reads it, and each
  entry is resolved as the call chat resolves Jamie's
  (`AgentArtifact(strutEntry:workspace:)`).
- `ChatRow.rows` puts them on a tribe member's message row
  (`agentArtifacts`). This is a new, narrow rule beside "control lines are
  never shown in a tribe" (`isControlLine`): only deliverables, never your
  own messages, a DM's, or the tool rows beside them.
- Any member can forge the field, so:
  - an entry opens only on one of the viewer's own live orgs, with their
    own token. On the Mac that is `Stadeum.opensFromTribe`; on the iPhone
    `Stadeum.opening` already holds to it. Anything else shows its title
    and "@acme isn't connected here";
  - an app opens only after a confirm ("Open this app from Acme? Anyone in
    the tribe could have sent it.");
  - an https link opens as any link in a message does.

## Choices the plan left open

1. **Preselected.** The plan says the pick is preselected from the tribe's
   `app_url` or `second_brain_url`, as calls are. For a call that is only
   a default. Here a checked org would mean Jamie is in the tribe when it
   is not. So the check is always Hive's link, and the org the tribe's
   pages point to is the one-tap **Add Jamie from …** button.
2. **When links are read.** Not at every unlock: on opening a tribe's
   details, and when a member request needs them.
3. **Both devices may approve.** If the Mac and the iPhone are both open,
   each may send the approval. The second one costs the tribe's price.
4. **The tribe's name** goes to Hive as `tribe.name`, nothing when the
   tribe has none.
5. **A deleted or left tribe** shows no Jamie row (`canManage`), and
   neither does a tribe whose tribes server Peel does not know (no host for
   Jamie to join through).
6. **The text keeps its links.** Hive's post names each deliverable as
   `Title: url` in the text, which everyone sees. Peel leaves the text as
   it is and adds its lines under it, so a member who is not paired with
   the org still has Hive's link.

## Tests

- `HiveTests`: linking, listing and unlinking with the device credential,
  the request shapes, and Hive's refusals in words.
- `StadeumTests`: the links as Hive keeps them, the pick and the options,
  the minute's cache, and that a tribe's deliverable opens only on a
  paired org.
- `ControlRowTests`: a tribe member's deliverables on their row, never
  yours or a DM's.
- `EngineFailureTests`: `approveWaitingMember`'s refusals.

## Not checked

- In the running app, on either device, against a Hive with the routes on.
- The approval against a real tribes server. Its refusals are tested;
  approving a waiting member by key is the same `answerJoinRequest` path
  the Members panel uses.
