# Jamie in tribes from Peel

Status: Peel's side built 2026-10-29. It waits for Hive's routes to be
switched on (`JAMIE_SERVICE_TOKEN`, `JAMIE_SPHINX_PUBKEY`) and for Jamie's
account to run. Not yet checked in the running app. Who is asking
(below): Peel's side built 2026-11-02 on sphinx-rs v0.8.41; it needs a
tribes server with sphinx#419 and Hive with #5688, and is safe without
either.

A tribe's owner links the tribe to one of the orgs Peel is paired with
(Stadeum). From then on anyone in the tribe can write `@jamie …`, and
Jamie, that org's orchestrator, answers in the tribe with its
deliverables. A turn runs as the person who asked when the tribe tells
Jamie who is speaking and Stadeum knows them; otherwise as the owner
("Who is asking", below; built 2026-11-02).

- The design is Hive's `docs/plans/jamie-in-tribes.md`.
- Hive's routes are stakwork/hive#5667.
- Jamie is one ordinary Sphinx account in every linked tribe, run by
  stakwork/sphinx `wasm/daemon` (#401).
- Who is asking is stakwork/sphinx `docs/tribe-sender-identity.md`:
  sphinx#419 (the tribes server's `ShowSenders` and `SentBy`, sphinx-rs
  v0.8.41's `showSenders`) and hive#5688 (the turn as the asker, and
  `POST /api/strut-devices/sphinx`).
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
| `POST /api/strut-devices/sphinx` with `{ pubkey, token }` | `{ linked: true }`; 400 a token that does not verify; 409 `{ error }` the key is another Hive user's, or the person has another |
| `GET /api/strut-devices/peers` (the daily renewal) | carries `sphinx`: whether Hive knows the person's Sphinx key |

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
- A DELETE that Hive answers 404 "Tribe not linked" is unlinked already,
  from the person's other device. Any other 404 (a proxy's, a Hive without
  the route) is a failure.

**Stadeum** (`Sources/PeelUI/Stadeum.swift`) keeps what Hive last said:
- `jamieLinks`, read by `readJamieLinks`. It is read each time a tribe's
  details open and each time an approval needs it, so the person's Mac and
  iPhone show the same pick. It is never kept on disk.
- `setJamie(_:for:)` links or unlinks. A read Hive answers after a link or
  unlink made here does not overwrite it, and the next read asks again.
- A pairing made again, perhaps as another person, forgets them.
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
  from history. It needs Stadeum to say this person linked the tribe. The
  links are read again unless read in the last minute, and again when that
  minute's read does not name the tribe, since it may have been linked on
  the other device just now.
- A request that arrives while a check of the same tribe is under way is
  looked at again once that check ends.
- Each approval goes at most once a session: another would cost the
  tribe's price again.
- The request carries only an alias. So the engine asks the tribes server
  who waits and approves the entry whose key is Jamie's, by key.
- It asks up to three times, five seconds apart, in case the server lists
  the request after it arrives.
- A failure shows above the tribe's composer. The owner can still approve
  in Members.
- **Someone else's Jamie.** Hive gives a tribe to whoever links it first,
  and cannot tell who owns it. So Jamie may ask to join, or sit in a public
  tribe, for an org the owner did not pick. Peel never approves that one.
  It says so above the composer when the request comes, and the Jamie row
  says it too (`AppModel.othersJamie`, from Jamie's key on the tribes
  server's list): approving or keeping it sends what is said in the tribe
  to that org.

**Who is asking.** The tribes server rewrites every message it forwards
as the tribe's, so Jamie sees an alias. Since sphinx#419 it tells a member
the owner marks, and no one else, who sent each one (a type-38 `SentBy`
after it), and Hive runs that person's `@jamie` as them when it knows their
Sphinx key and they are in the linked workspace (hive#5688): their actor,
their delegation, their access. Anyone else asks with the owner's, as before.
- **Identified.** Peel tells Stadeum the account's Sphinx key
  (`HiveClient.registerSphinx`, through `Stadeum.identify`) after a
  pairing, once each launch, and after each renewal while Stadeum says it
  does not know it (`sphinx: false`). The proof is the token the Sphinx apps
  sign for Hive's own Sphinx sign-in, made by the core's `signedTimestamp`
  with the account key (`Engine.sphinxProof`, signed half a minute back so a
  clock a little ahead of Hive's still passes). Linked, the link is kept as
  `identified` and Account › Connections (the iPhone's You › Stadeum) says
  so. A Hive without the route (404, or its middleware's 401) is asked again
  next time, as is one that fails. A 409 (the key is another Stadeum user's,
  or the person has another) is said once, in Hive's words, and that key is
  not asked about again on this pairing (`HiveLink.sphinxRefused`). Never in
  the pairing's way.
- **The mark.** Linking marks Jamie (`AppModel.setJamie`, `markJamie`):
  once the tribes server lists Jamie in, confirmed (a public tribe a few
  seconds after the link, a private one once approved; the list is asked
  for every five seconds, a minute at most, and again after the approval),
  the owner's Peel sends `ShowSenders(tribe, Jamie, on)`
  (`Engine.showSenders`, sphinx-rs's `showSenders`, over the tribes
  server's topic like the owner's other commands) and waits for the member
  list, which says it per member (`sees_senders`, `TribeMember.seesSenders`;
  absent is false). Unlinking sends it off first, not waiting: the server
  drops the mark with the member anyway once Jamie leaves.
- **Tribes linked before.** As the account opens, once a run of Peel, the
  tribes this person linked and owns are looked at (`markLinkedJamies`,
  `Engine.markSendersOnce`): one this device has not settled
  (`Setting.sendersMarked`, per tribe and Jamie key) gets its member list
  read; Jamie confirmed and unmarked is marked, marked already is settled.
  So the first launch after updating marks every tribe linked by an older
  Peel, and later launches send nothing. Hive is asked for the links only
  when the account owns a tribe.
- **An older tribes server** knows no `ShowSenders` and answers nothing;
  nor does one whose broker takes no commands, or one asked about someone
  not in the tribe. After 15 seconds that is `sendersNotShown`: the Jamie row
  says "This tribe's server can't tell Jamie who is speaking yet, so everyone
  here asks with your access." The link stands, nothing is settled, and the
  next launch asks again.
- **The row.** Once Jamie is in, the owner's Jamie row says "Jamie knows
  who is speaking here" in its line when the list says so, and has a switch,
  Knows who is speaking (`TribeJamiePicker.showSenders`). The switch shows
  the list, never the settled flag. Only the owner sees the row: a
  member's Peel cannot read the list (the server gives it to the owner
  alone), so it shows nothing of the mark, nor do the official apps.
- **Types 35–38.** An upgraded tribes server sends its signed record (35)
  on a join and on every change, and a marked member `SentBy` (38); 36 and
  37 are commands and answers as onions. Each is stored as every type is,
  so the read marker (`Engine.markRead`, the highest stored index) and
  `isBehind` reach past it: the server's marker is what the official apps
  and the mixer's push count read, and one left behind a record would
  count the tribe unread there. The type lists keep them out of every
  reader: no line (`shownInChats`), no unread or notification
  (`unreadTypes`), no preview, search or mention (`content`). Peel reads
  none of them yet (the record and link v3 are the sovereign tribes work).

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
  - an app opens only after a confirm that names the app and version its
    link opens, never the title its sender wrote ("Open the app “board” v3
    from Acme? Anyone in the tribe could have sent this link.");
  - an https link opens as any link in a message does.

## Proposals in a tribe

Status: Peel's side built 2026-10-31 (PR #464, with the proposal cards of
the agent chat). It waits for Hive's half: the proposal in Jamie's post
and the decision from the owner's reply (its PR number goes here once it
is open). Checked against stand-in posts on the local stack, not a Hive.
The stub (strut's `plans/proposal-links.md`, stakwork/strut#406): Peel's
side built 2026-11-01; a member's read of another person's proposal needs
strut#407 on the org's swarm.

A `@jamie` turn in a tribe runs as the person who asked when the tribe
told Jamie and Stadeum knows them, else as the owner ("Who is asking"), so
what it proposes (a `package/install`, an `app/grant`, a delete: strut's
proposals, docs/agent-on-strut.md, "Built: proposal cards") is that
person's to decide. They decide it in the tribe, on Jamie's post, and
everyone there sees the card and how it ended.

**The carrier.** Hive's post "Waiting for <owner> to approve: <title>"
names each proposal in `metadata.strut`, beside the deliverables, as a
stub: a reference, about 150 bytes, never the card (a tribe envelope
carries references only):

```
"strut": { "workspace": "<slug>", "artifacts": [ … ],
           "proposals": [ { "id", "step", "title", "status", "url": "/proposals/<id>" } ] }
```

A Hive from before the stub sends the whole brief instead: `summary`,
`card` (strut's card exactly as in #464, `{ v: 1, title, summary?, fields,
actions, full }`), `rationale` and `createdAt` beside the stub's keys;
such a post is drawn as it came and never read (below). A swarm whose
strut is older than `c23756a` sends no card, and the card is built from
the title and the summary (`ProposalCard.generic`). `url` is
strut-relative and marks a proposal the post made, against a reply's
outcome, which has none. Unknown keys are ignored, as are entries Peel
cannot read; up to ten per post (`StrutProposals.most`).
`Message.strutProposals` reads it (`StrutProposals`, PeelCore
`Proposal.swift`); `ChatRow.rows` puts it on a member's row in a tribe,
beside the deliverables, never on your own, and on the row that stands for
the post once replies fold it into its thread (the owner's own answer is
such a reply: the card must not fold away with it; `takeStrutEntries`).

**The card.** `TribeProposalCards` (Mac, `ProposalCardViews.swift`) draws
each as `ProposalCardView` under the post, shut to its title, the
workspace and step, and its badge until a click on the title opens the
rest, as in the agent chat: the summary, the fields (a `danger` one tinted
as a loss), the model's reason apart, "Not everything is shown" when the
fields do not cover the input. A stub's card, read from the org's strut
(below), has the input, so "Show the full input" opens it; a post from an
older Hive carries the card and never the input, so a field strut cut ends
in "…" (`Field.shownValue`, not strut's "(see full input)", which is no
link) and the line says the rest wasn't sent; shut, the card takes no key.
Whose buttons they are is `TribeDecider`'s (`ProposalWatch.tribeDecider`,
PeelCore `Storage+Proposals.swift`): strut's record, once read, names the
person the turn ran as (`by.actor`), and the viewer whose Stadeum actor
(`HiveLink.actor`) it is gets the card's own two buttons, and Return and
Escape as in the agent chat, the owner or not. With no record of strut's
read (a stub not read yet, or one strut would not show; a post that carried
its card), the tribe's owner gets them (`Tribe.canManage`, the list's
`isOwner`), as before. Everyone else sees the card, its badge, and whose
it is: "tom's to decide." (the actor's GitHub login, the part of Hive's
`<login>-<id>` before the id), "The person who asked decides this." for an
actor with no login, or "The tribe's owner decides this." with no record
read. So the owner gets no buttons on a card strut says is a member's: Hive
would answer their reply "<name>'s to decide." Not on the iPhone yet, as
#464 left it.

**Reading the card.** A stub's card (`ProposalRecord.isStub`: no card, no
input) is the org's strut's record, read with the person's own token for
that workspace, `GET /proposals/:id` through `HivePeer.proposal`:
strut#407 lets a person token read any proposal on its strut by id (the
lists stay the person's own, and deciding stays the proposer's), so any
member paired with the org reads it, the owner and everyone else alike.
`ProposalWatch.fillCard` reads it only when this Peel holds a Stadeum
pairing for the envelope's `workspace`, and only at three moments: the
post is taken up (live, from history, or as the watch opens; a copy of it
coming round again reads only what strut has not answered here); the card
is opened while it is still the stub (`ProposalWatch.opened`, from the
title's click); and Jamie's outcome reply for it arrives, for the decision
and the result. Never on a timer. strut's record fills the card (fields,
words, input, reason, who proposed it) and its status wins, but a read
never takes a card back behind the posts, from running to pending or from
over to open (`KeptProposal.take(read:)`); the card stays under its post,
on the posts' clock, and the tribe's outcome posts still move it
(`KeptProposal.cardFromStrut` marks a card that came as a stub; a post's
own `by`, which any member could write, is never read, so a post's card is
never taken for strut's). In a tribe a 404 or a 403 from that read means
"not readable here", never gone or not yours: the card stays the post's
title, open, the owner's buttons still there, and says "This card opens
for members of <org>." (`ProposalWatch.tribeNote`). A member who is not
paired with the org (or paired with another one only) reads nothing and
sees the same: the title from the post, its badge, and that line, which is
all the post's text says anyway. A read that does not answer is tried
again a few times, longer apart, then left until the next moment; it never
ends the card. A post that carries a card is drawn as it came and never
read.

**Deciding.** The click sends a plain reply in the tribe to Jamie's post
(`Engine.sendText(_:to:replyTo:)`, `ProposalWatch.answerInTribe` through
`sendReply`, installed by `AppModel`) whose text is the card's own word
(`actions.accept` or `actions.reject`, else Accept and Reject). Nothing
else goes with it: the daemon forwards a reply to a Jamie post with its
`replyTo`, `owner` and, from a tribes server that names senders, `sender`,
and Hive matches the text against the card's words and decides on the
org's strut as the person the turn ran as, when the reply is theirs. The
reply itself, arriving like any message of yours (sent here, or from your
other device), is the answer (`ProposalWatch.answered(byOwn:)`: a reply of
yours in the post's thread whose text is a card's own word; kept as
`KeptProposal.answeredAt` and `answer`, so a restart shows it still): the
card shows Accepting… or Rejecting…, the buttons gone, on every device of
yours. Peel never decides a tribe's proposal with the person token, though
the person holds one: one path, through Hive, so the outcome is in the
tribe for everyone. After ten minutes with no word
from Jamie (`KeptProposal.answerPatience`) the card says "No answer yet:
the reply may not have reached Jamie" and offers the buttons again; a
second answer is another reply.

**The outcome.** Hive replies under the same post with a readable line
("Applied: <title>", "Rejected: <title>", "Failed: <title> — <error>")
carrying `metadata.strut.proposals: [{ id, status, title, step, error? }]`,
no card. Peel takes it only from the same member (by alias, which the
tribes server keeps unique in a tribe) in the thread of the post whose
card it is (any member can write the field, as with a deliverable): the
card moves to Applied, Rejected or Failed with the error. The posts may
come in any order (history pages do): the later post has the last word
on the status, so a copy of the carrier coming round again never reopens
a decided card, and an outcome that comes before its post is kept as
ended on the post its reply answers (`KeptProposal.take`). A reply with
no proposals in its metadata is a normal turn, nothing for the card.

**Kept.** Each is kept per (workspace, id) in the `proposal` table of #464
with its post (`tribe`, `post`, `poster`) and the answer, so a restart
redraws it; a tribe's is never forgotten with a workspace's old ones (its
card stays on its post). Where a proposal's truth comes from is one rule,
`KeptProposal.fromStrut`: strut's record, read with the person's token,
for Peel's own strut's and a workspace's; the tribe's posts for one on a
post, with its card (and, at its moments, its status) from strut's record
when the post sent a stub. So the owner's `ProposalWatch`, which lists the
same proposal on the org's strut by person token, never shows one on a
post at the end of the agent chat too, never reads it on a timer, and
leaves it alone in the list once it is on a post (a list read just before
a decision must not reopen a card its outcome ended, nor put the Mac's
clock where the posts' dates go: a record listed first takes the posts'
clock from its post on). Posts that came while nothing watched (before
this build, or to the CLI on the profile) are taken up as the watch opens,
from where its last look got to (`Storage.proposalPosts(after:)`,
`Setting.proposalPostsScan`), so a later open reads nothing twice. The
look reads only the tribes' rows, so its posts are taken up without asking
which chats are tribes: the watch opens before the account has listed
them. A new `Storage.proposalPostsVersion` reads every row again once;
version 2 does, because the first watch asked, was told none, and took
none of the posts.

**Tests.** `ProposalTests` (a post's proposals and a reply's outcomes
read, what is skipped, the posts in any order, the stale answer, the
store, a stub's card taken from strut's record, never behind the posts,
and a post's `by` never read), `ProposalWatchTests` (kept from the post,
never a workspace's card, the owner's reply with the card's word, ended by
Jamie's word in the thread and by no one else's, a reply that could not
go, a reopen; a stub read when taken up and when Jamie's word comes and at
no other time, a 404 or 403 leaving the title and the line rather than
gone (and a copy of the post not asking again), a silent strut never given
up on, no read with no pairing or for a post that carries a card), the
journey `Journeys/Tribes/aProposalOnJamiesPostIsAnsweredByTheOwnersReply`
(through the real core: Bob posts as Jamie with the metadata, Alice's
answer reaches him as a reply to his post with the card's word, his
outcome ends her card, Carol gets the post too), and the offscreen check
in `docs/testing.md`, "Proposal cards in a tribe".

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
   Within one device it goes once a session. The engine names the request
   by the newest one with Jamie's alias (`answerJoinRequest(.member…)`), so
   someone asking just after Jamie under the same alias gets their card
   marked as answered while Jamie's stays open.
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
  the request shapes, and Hive's refusals in words; the Sphinx key told to
  Hive and each of its answers, the renewal's `sphinx`, and the proof as a
  vector Hive's own `verifySphinxToken` takes.
- `StadeumTests`: the links as Hive keeps them, the pick and the options,
  the minute's cache, a read answered after a link not taking it back, and
  that a tribe's deliverable opens only on a paired org; the Sphinx key
  told after a pairing, once a launch and after a renewal while Stadeum
  does not know it, a 404 asked again, a 409 said once and never asked
  again for that key, nothing once a renewal says Stadeum knows it.
- `TribeSendersTests` (in `TribeTests.swift`, against a stand-in tribes
  server on the transport): Jamie marked once listed in, public (absent
  first) or private (pending first), and not before; the lists with and
  without `sees_senders`; a tribe linked before marked once and not at the
  next launch, one marked already settled with no command, an unlink
  unsettling it; a server from before the command leaving it unmarked,
  `sendersNotShown`, and the next launch asking again.
- `SenderTests`: types 35 and 38 stored, live or from history, yet no line,
  no unread and no preview, the texts beside them all three; the read
  marker reaching past the record.
- `ProposalWatchTests`: whose a tribe's card is, by strut's record (the
  member's own, the linker's, an actor with no login) or with none read
  the owner's, and the line everyone else reads.
- `ControlRowTests`: a tribe member's deliverables on their row, never
  yours or a DM's; an app's confirm names what it opens.
- `EngineFailureTests`: `approveWaitingMember`'s refusals.

## Not checked

- In the running app, on either device, against a Hive with the routes on.
- The approval against a real tribes server. Its refusals are tested;
  approving a waiting member by key is the same `answerJoinRequest` path
  the Members panel uses.
- Who is asking, live: a tribe on a tribes server with sphinx#419 and a
  Hive with #5688, a member paired with the org asking `@jamie` as
  themself and answering their own card, another member refused; the mark
  at linking and at the first launch after updating; an older tribes
  server's line. `AppModel`'s part (`setJamie`, `markJamie`,
  `markLinkedJamies`, `Stadeum.opened`) has no test of its own; the engine
  and Stadeum parts it calls do.
- The iPhone's Jamie row and You › Stadeum line were not compiled here (the
  iOS slices of the core were not built).
