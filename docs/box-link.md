# Peel linked to a strut box

Status (2026-11-18): **built**, Mac and iPhone. Strut's side is
stakwork/strut#737 (`plans/people-and-hosts.md` §2.1, ruling 9, decisions
12–14; `specs/API.md` §13.6). Evan ruled on 2026-11-18 that Peel is the
client going forward ("we dont need to support old Sphinx apps. Peel is the
new way forward"), and that Peel links to a self-hosted Stadeum box the way
it links to Hive, which will go away in time.

## What it is

A member signed in to a box (any strut with #737) opens the Jamie app's
Connect → **Link Peel**. The box shows a one-time link challenge naming
them, as a QR code and an **Open in Peel** link:

    peel://strut/link?url=<the box's base, mount path included>&challenge=strut-link.<claims>.<hmac>

Peel shows the box and the name and asks **"Link Peel to `<host>` as
`<name>`?"**. On the person's click or tap it signs the challenge with the
account's own key and posts it; the box links that key to the member and
answers a seven-day person token. Then:

- a tribe mention from that key runs as the member (strut's `actorOf`);
- Peel opens the box's own strut UI as the member, where its apps are
  listed and opened.

The key is the lasting credential: there is no device flow and no device
record. Peel renews the token by signing again; removing the link in
Connect ends the token at once.

## Built

**PeelCore**, `BoxLink.swift`:

- `PeelLink.values`: every `peel://` link's values read one way (moved from
  PeelAgent's Peel Home link so the iPhone reads them the same way too).
- `BoxChallenge`: `strut-link.<base64url JSON { host, actor?, name?, nonce,
  exp(ms) }>.<hmac>`, read through `StrutClaims` (shared with the visitor
  challenge), never verified: the HMAC is the box's.
- `BoxLinkOffer`: the link (`init?(peelLink:)`), the box's base as strut
  names one (`Seller.base`: https, or http to this machine), and
  `problem(at:allowsLoopback:)`: Peel refuses a challenge for another host
  than the link's address, one run out, one naming nobody (a renewal's), and
  an address on this machine outside a development profile.
- `BoxLink`: what is kept, `{ url, actor, name?, token, exp, linkedAt,
  renewedAt }`, several at once, never described with its token; `due`
  (a day since the last renewal, or the token within a day of its end);
  `read`/`write` of the list.
- `BoxClient`: `POST /people/link`, `GET /people/challenge` +
  `POST /people/token` (`renew`: `.renewed` or `.unlinked` on `403
  not_linked`), and `accepts` (a token's check on use, `GET /apps`: 401 is
  "no longer held"). Refusals in words: 401 ran out or used, 409 linked to
  someone else, 413, 429, strut's own words for the rest.
- `Engine.signBoxLink`: the challenge's UTF-8 bytes as a Lightning signed
  message with the account key (child 0), the visitor `sign_in`'s `.root`
  path (`signWithAccountKey`, which both now share), with the account's
  Sphinx address when it has one.
- `Profile.boxes`: a new item beside `Profile.hive`, Keychain
  `dev.peel.boxes` (after first unlock, this device only) for an app
  profile, a `boxes` file for a development one. Removed with the account
  (`Profile.delete`): the links are that key's. **`Profile.hive` is not
  touched**: no Keychain migration, Hive pairing exactly as it was. A Peel
  without this feature never reads the new item; a box without #737 never
  makes a link.

**PeelUI**, `Boxes.swift` (`AppModel.boxes`, opened with the account in
`attach`, closed in `resetAccountState`):

- `take` holds a link for the person's yes (`asking`), or says why Peel
  won't sign it (`problem`); `decline`; `accept` signs and posts, keeps the
  answer (`linking` while it runs).
- Renewal: an hourly look while the account is open; each due box renewed.
  `403 not_linked` lets the box go and says so once (`notice`); any other
  failure is said and tried again within the hour.
- `home(of:)` / `page(of:)`: the box's strut UI as its member
  (`BoxLink.home`, an `OrgPageRequest`): the token checked first; a 401 is
  renewed once, and a box whose renewal says the link is gone (or that
  still refuses a fresh token) is let go.
- `BoxWords`: the question and its words, shared by both apps.

**Mac**: `openPeelLink` takes `peel://strut/link`; the question is a card
over the main window (`BoxLinkConfirm`, like the call-device question),
shown once unlocked; Account › Connections › Stadeum servers (`BoxesSection`) lists
each box as its member with Open and Forget (an in-place confirm). Open
shows the box in the web pane (`WebPane.open(box:)`): a web view of its own
on a store that keeps nothing, the token as the first request's bearer and
handed to `sessionStorage["strut/apiKey"]` before the page's script
(`OrgPageRequest.handOver`), only that strut's UI folder, a link out only on
the person's own click, another of the box's apps opened in place, and
Reload loads it again with its bearer (`StrutPage.policy`, the rules Peel's
own strut's pages keep, on the box's `serves`). The page ends when its box
is forgotten or let go.

**iPhone**: `router.open(peelLink:)` takes it (the system camera scanning
the QR opens the same link) and goes to You; an alert asks the question
once unlocked (Link or Cancel, nothing else shuts it); You › Stadeum servers
(`BoxesSection`) lists each box, a tap opens it in `OrgPageSheet` as an
org's page opens, a swipe or long press forgets it. The sheet closes when
its box goes.

A box's own Jamie answers in the tribes its people add there as places:
the tribe's Jamie row offers each linked box beside Stadeum's orgs
(`docs/hive-tribes.md`, "From a box").

## Decided

- **Opening a box's apps: the box's own strut UI, as the member.** Open
  loads the UI's folder (`<base>/`), which lists the box's apps and opens
  them in place; Peel does not list them itself. This is the simplest path
  that is the same on both devices: treating a box as a Stadeum org peer
  would put it into `Stadeum.live`, which Hive's calls, tribe Jamie links,
  Talk and the Mac's strut peers all read, and on the Mac the org apps list
  is read through Peel's own strut, which speaks for one Hive actor. A box
  is not an org; it stays beside Stadeum, not in it.
- **"A 401 on use"** is checked at Open (`GET /apps` with the token): the
  only place Peel uses the token outside the web view. A page already open
  that the box stops answering is not watched; the next Open renews. strut
  has no lighter read for a person token, so the check reads the app list.
- **A renewal's challenge is not checked for its end**: it lives a minute,
  and a device clock off by more would block every renewal; strut checks
  it. Its host is checked, so Peel signs only for the box it renews. A
  link's challenge (ten minutes) is checked, to say so before asking.
- **Boxes that cannot be read are never written over**: until they are read
  again (Peel reopened), a new link is refused rather than kept in place of
  every box kept.
- **On the iPhone the boxes close with the lock**, as Stadeum does, and open
  again with the account.
- **Forget is local.** Peel has no route to remove its own link (strut's
  `account/unlink` is for the box's own app); the words say to remove it in
  Connect there too.
- **No app wallet on a box's page on the Mac**: the Mac's wallet handler is
  for Peel's own strut's pages (`StrutWalletBridge`). On the iPhone a box's
  page gets the wallet keyed `org:box:<url>`, as an org's page does.
- **One link per box address.** Linking again (as another member) replaces
  the kept one.

## Tests

- `Tests/PeelCoreTests/BoxLinkTests`: the link as strut writes it (a mount
  path, a port), what is not a box's link, what Peel won't sign; the
  engine's signature, a vector checked with strut's own `ln-message`
  verifier (`VERIFIERS["ln-message"]`, the one `POST /people/link` runs);
  the list kept beside Hive's pairing, which it never touches, and removed
  with the account; never described with its token; due; the three routes
  on a stand-in: the post's body and no credential, the refusals in words,
  renewal signing only a fresh challenge for the box's own host, `403` as
  unlinked.
- `Tests/PeelUITests/BoxesTests`: nothing signed or sent without the yes;
  the yes keeps the box; another host's link never asked; a due box renewed
  and an unlinked one let go as the account opens; a refused token renewed
  once before the box opens, and a box whose link is gone let go.
- Fixtures shared in `Tests/PeelTestSupport/BoxFixtures.swift`.

## End to end (2026-11-18)

Against a local strut on #737's branch (35fbefc0, its own checkout, port
3410, a clean environment with only `STRUT_API_KEY`), and the Mac app
offscreen (`scripts/check-app.sh`) on a new development profile whose
server is unreachable (signing needs only the words). The drive steps
`box-link`, `box-open` and `box-forget` stand in for the clicks.

1. The Jamie app as `alice` (strut's UI with its key and `actor=alice`):
   Connect → Link Peel showed the QR, Open in Peel and "Waiting for Peel".
   The link Peel opened was minted by the same `account/link` step, called
   from that page as alice.
2. The `link` step (as macOS hands Peel a link): the card "Link Peel to
   127.0.0.1 as alice?" over the main window.
3. Link: `POST /people/link 200`; Account › Connections › Boxes lists
   "127.0.0.1, As Evan on Peel" (strut's name for alice, who has none,
   falls back to the account's alias Peel sent). Connect turned to Linked:
   "Evan on Peel", the key, linked 11/18/2026.
4. Open: Peel's check `GET /apps 200`, then the web pane loaded `GET /` with
   the token, and strut's UI ran as alice: its assets, `/apps`,
   `/workflows`, `/peers`, and `GET /people?actor=alice 403`, the answer a
   person token gets (the admin key's would be 200). The offscreen snapshot
   does not draw the web view's content, so the page itself was not seen.
5. Remove in Connect, then Open again: `GET /apps 401`, `GET
   /people/challenge 200`, `POST /people/token 403`; Peel let the box go,
   said "127.0.0.1 removed Peel's link, so Peel let it go", and the web pane
   ended the box's page.

After the review's fixes the same drive ran again, ending with Forget: the
card's buttons in a row, the box linked, opened (`POST /people/link 200`,
`GET /apps 200`, `GET / 200`), forgotten, and its page ended.

A first run's link was broken on the way in (an `&` lost in the drive
file): Peel said "That link to a box doesn't work" and asked nothing.

## Open

- The iPhone path was built for the device, not run on one here.
- A box's app opened from strut's UI inside Peel was not seen drawn (the
  offscreen snapshot leaves web views blank); strut's log shows the UI
  running as the member.
- Strut's "Open in Peel" from its host page (`ui/open-link`) was not seen to
  open Peel on a device: strut's note says the same.
