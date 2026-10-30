# Apps: a sidebar entry and a browser

Status: PR 1 built, 2026-10-26. Tom chose layout A (grid) and personal
pinned apps under the Apps row; opening an app stays `WorkspaceAppView`.

## What's there now

Evan's #368 added an **Apps** section at the bottom of the sidebar, below
every chat. It lists the apps each paired Stadeum workspace *pinned as a
tab* (`AutomationsClient.pinnedApps(of:)`, `GET /peers/<id>/apps` through
Peel's strut, filtered to `pinned`). Opening one shows strut's UI with that
page alone (`WorkspaceAppView`). The sidebar search filters the section.

Why it won't hold up:

- It sits under all the chats, so you scroll to the bottom to reach it, and it
  gets longer with every app a workspace pins.
- Only workspace-pinned apps show. Strut already lists every app
  (`GET /apps`: name, title, description, icon, owner, versions, `pinned`,
  `live`), and Peel throws the rest away.
- The apps on your own strut never show at all (strut's own UI lists them).
- There's no way to make an app, change one, or manage one from Peel.

## Proposal

### Sidebar

- **Apps becomes a nav row**, like Automations. The nav rows go A–Z:
  **Apps, Automations, Mentions, Payments, Threads**. Your two options give
  the same order ("Apps and Automations first, the rest A–Z" or "everything
  A–Z"), so there's nothing to choose between. The only real change is that
  Threads moves from second to last.
- **Apps you pin sit under the Apps row**, A–Z. Pins are yours and stay
  in Peel (in `sidebarLayout`). None are pinned until you pin one.
- **The bottom Apps section goes away.**
- The sidebar search keeps matching apps. While searching, matching apps
  show under the Apps row, so the arrow keys and Return still reach them.

### The Apps browser (`.apps`, in the detail column)

- **Header:** Apps, the count, and **New app**.
- **Search** over the title, description and workspace.
- **Workspace filter** as buttons: All, Yours, then one for each workspace
  (`@stakwork`, `@acme`), each with its count. This is one view with a
  filter, not a tab per workspace.
- **Sort:** Recent (the order you opened them in, kept by Peel) or A–Z.
- **Layout A, a grid (recommended):** each card shows the icon (the
  manifest's lucide `icon`), the title, two lines of description, and the
  workspace and when it was updated. A pin button sits in the card's
  corner. Icon tiles are neutral, not a colour per app.
  - B (a dense list with the metadata in aligned columns) and C (a Recent
    strip, then the apps grouped by workspace) are on the canvas for
    comparison. B is better past about 50 apps; C is best when people
    mostly reopen the same few. A grid with Recent sort covers both until
    then.
- **No results** says so, and offers "Ask Peel to build it" with the search
  text filled in.

### One app (today's `WorkspaceAppView`, with a header)

- **Header:** "‹ Apps", the icon and title, then `@workspace · vN ·
  updated …`.
- **Actions:** Pin to sidebar, Change with Peel, Reload.
- **The ⋯ menu:**
  - Copy link.
  - Versions.
  - Open in Stadeum (a workspace's app only).
  - For an app of yours, Delete…; for a workspace's, Hide from Apps.

### Making and changing apps

The builder writes apps (strut `plans/apps.md` §8). Peel doesn't need its
own authoring UI. Your chat with Peel is the way in:

- **New app** opens a popover next to the button with two fields: "What
  should it do?" and "Lives in" (Yours, or a workspace). Build sends that to
  the agent DM, and the orchestrator starts the builder
  (`job/start { workflow: builder, peer? }`).
- **While it builds**, a dashed "Building…" card sits first in the grid,
  and the sidebar's Apps row says "1 building". The card opens the chat.
  When the publish lands, it becomes the real app.
- **Change with Peel** opens the agent DM with the app attached. This is
  Peel's version of the page's `ui/message`, which strut leaves unwired
  for a page shown alone.

## What each part needs

| Part | Peel | strut |
| --- | --- | --- |
| Nav row, A–Z, browser over today's list | Sidebar, `.apps` destination, `AppsView` | none |
| Every workspace app, not only pinned | `pinnedApps` → `apps(of:)`, keep `pinned` as the seed | none (`GET /peers/<id>/apps` returns them all) |
| Yours | read `GET /apps` on Peel's own strut | none |
| Personal pins and Recent | a Peel-local store, keyed by `WorkspaceApp.id` | none |
| "Updated …" | show it | **add `updatedAt` to `AppListEntry`** (the active version's `createdAt`); the listing has no time today |
| Delete, versions (yours) | ⋯ menu | exists: `DELETE /apps/:name`, `PUT /apps/:name/active`, `GET /apps/:name/versions` |
| Versions, delete (a workspace's) | read-only "Open in Stadeum" | not through the read-through, by design (they're the peer's) |
| New app, yours | agent DM → builder | exists |
| New app in a workspace | agent DM → builder on the peer | **open on strut's side**: §7.4 lists a builder job on the peer as "not in this slice" |
| Building card | agent turn → placeholder until the publish | a way to know a builder job is making app X (the job's deliverable `{ kind: "app" }`) |

## Built: PR 1 (2026-10-26)

- The sidebar's top rows A–Z: Apps, Automations, Mentions, Payments,
  Threads; the arrow keys move through them in that order, Automations
  now among them (it had been left out).
- Pinned apps under Apps, A–Z, with no icon so their titles sit under
  Apps'. While the sidebar search has text, every app matching it shows
  there instead. The open app shows there too while it is open, pinned
  or not, as a closed section keeps the open chat.
- The pins: `ChatSections.Layout.pinnedApps`, kept with the account like
  the rest of the layout. None until the person pins one (Tom, 2026-10-26,
  after trying it with his workspaces' apps): the row starts empty and
  Apps is where they are found.
- `AppsView`: every listed app as a card, A–Z (icon, title, two lines of
  what it is for, `@workspace` when there are several), a pin in its
  corner; a search over the title, description and `@workspace`; a choice
  of workspace when there are several. Empty states for no workspaces
  (Open Account), none pinned yet, a home server, and no matches.
- The app's header gains the same pin.
- Cards v1 (Tom, 2026-10-26, the canvas's "App cards v1"): only what
  strut's list carries. The manifest's lucide `icon` drawn as that
  lucide icon (PeelUI's `WorkspaceAppIcon`, over the `lucide-swift`
  package's vector shapes; any lucide name, its old aliases too, through
  `LucideNames.resolve`; the grid, lucide's `layout-grid`, only for no icon
  or a name lucide does not have); titles on two lines, descriptions on three; at the foot
  `@workspace · v14` (`activeVersion`; the workspace only when there are several) and at most one status
  (`AppStatus`): "2 problems" in the attention colour while `warnings`
  (strut's usage monitor, on the live version) is above 0, else "Release r3" while a release is held (`live`). The
  app's header shows the same. Not shown: `owner` (an id, not a name),
  `publisher`, grants, and time (not in the list). `warnings` is the
  workspace's strut's (the list is read through as it is), so it shows
  wherever that strut counts them, whatever strut Peel ships.
- Not yet: Recent sort (needs an open history), counts on the workspace choice, Yours
  and apps no workspace pinned (PR 2). Ids of apps no longer listed stay
  in `pinnedApps`, so one that comes back is still pinned.
- Checked: `ChatSectionsTests` (an older layout has no pins; pins are
  kept). Offscreen with `scripts/check-app.sh`
  on a development profile, the apps seeded in memory (`apps-seed`, through the listing's own parse): the
  grid, the workspace choice, pinning and unpinning from the header (kept
  across a restart), Apps selected on an unpinned app, the sidebar search
  listing a matching app under Apps, dark and narrow.

## Built: Yours (2026-10-26)

- The person's own apps, on Peel's strut (the agent's builder publishes
  them there), listed beside the workspaces': `AutomationsClient.ownApps`
  reads `GET /apps` and keeps every one but those strut seeds
  (`publisher: strut`, its `strut/views` component library; a deny-list:
  a `source: seed` in strut's listing would be the firmer contract). Such an app
  has no peer: its key is its name, so it opens as `?app=<name>&solo=1`,
  which strut's single-app view already serves.
- One read for both (`refreshApps`), with no workspaces too; opening Apps
  reads again, so an app just built shows. A home server still lists
  none.
- "Yours" is a source like `@workspace`: in the choice (first), on a
  card's foot, in the header and beside a pinned row, by the same rule
  (only when the apps come from several). Pins, search, icon, version and
  status as for any app.
- Checked: `HiveTests.yourOwnAppsAreAllListedAndOpenByName`; offscreen,
  a sample app of yours beside two workspaces' (choice, foot, header,
  pinned row, its page asked of strut by name), and the development
  profile's own strut listing nothing once its `strut/views` is left out.

## Built: versions and releases (2026-10-28)

Which version of one of your own apps everyone opens (strut's
plans/app-releases.md, `GET /apps/:name/versions` and `PUT
/apps/:name/active`; Tom's design board, "Strut App Versions"):

- The app's header: a chip with the live version (a lock while held at a
  release), opening its menu; beside it **Make vN live** while a newer
  version waits or another is previewed, asked once in a panel. The menu
  lists the newest six versions (waiting, live, when); a pick shows that
  version in this window only (`?app=name@vN`), under a bar that says
  everyone else opens the live one. History lists the releases to roll back
  to, and what the live release locked that has moved on ("Use these with
  v7"). Follow latest makes every publish live again. Rolling back, taking
  the new workflows and following latest each ask for a second click.
- A card and the iPhone's row say "v9 waiting" while one of yours is held
  behind a newer version (`WorkspaceApp.waiting`, from `GET /apps`).
- The sidebar: the pinned apps sit under the Apps row behind a hairline,
  indented as shadcn's sub-menu, each with its own icon and title only
  (where it comes from is on its card and header); the row's chevron folds them,
  keeping the open one (`ChatSections.Layout.appsOpen`).
- Not built: a workspace's versions (its own to change, still the `Release
  rN` chip); the locks a promote would take, before it (strut has no dry
  run); Undo in the toast (Peel's toasts have no action).
- Checked: `AppVersionsTests`, `HiveTests.yourOwnAppsVersionsAreReadAndMadeLiveByName`;
  offscreen against a development profile's own strut holding an app at v2
  with v3 built (card, header, menu, History, the fold, Make live moving it
  to v3), and the sidebar's nesting open and folded. Not driven: a preview's
  pick and the confirm panel's button (no click step), the page itself in
  the frame.
- Review findings not applied, and why:
  - Strut, not Peel, should say which versions wait (`waiting` on `GET
    /apps` and per version on `/versions`): a strut change, next. Peel's
    rule (`AppVersions.isNewer`) is kept in one place until then.
  - The offscreen steps build the versions menu and call `makeLive`
    themselves rather than open the header's chip and panel: the driver has
    no click step, and a model-level request only for it would be a
    test-only seam.
  - The chip re-states `MenuButton`'s trigger (anchor, lit, gone) with a
    `Chip` label; making `MenuButton` generic over its label reaches past
    this change.
  - Make live keeps its panel rather than `InlineConfirm`: Tom chose the
    panel on the board.
  - Previewing a version a release already names offers a new release of it
    (today's workflows), not a roll back to that release; History has the
    roll back.
  - A publish to an app that follows latest does not reload an open page
    (as before): only a change made in its window, Reload, or a preview does.

## Built: deep links (2026-10-29)

strut's app deep links (strut's plans/apps.md §7.1, stakwork/strut#357;
hive's half is stakwork/hive#5649): a link to an app is
`?app=<name>&input=<the app's own query>`, and the page is opened with that
input as its `tool-input`. strut's page alone already follows a link to its
own app in place, the address following (`?input=`); one to another app it
hands to its host as a new window, which WebKit lets the page's script open
only after the person's click (checked with a probe: a click forwarded from
the sandboxed frame by `postMessage` and two awaits reaches
`createWebViewWith` with `javaScriptCanOpenWindowsAutomatically` off; with
no gesture, nothing does). Before this, Peel dropped that window (the
app view), downloaded strut's UI page as a file (the web pane) or loaded
strut's whole UI without the token (the iPhone).

- **The address.** `StrutUI.page` takes `input`, encoded so strut's UI
  reads it back exactly; `StrutUI.page(_:input:)` moves a page to another
  view, the rest of its address (the key) kept as written.
- **The link.** `StrutAppLink` reads a page's link as strut's UI reads its
  own address (`URLSearchParams`: `+` a space), only in strut's UI folder,
  the app name by strut's rules, an input at most 2 KB of UTF-8; an `app`
  or `input` given twice or that does not decode is no link (strut keeps
  the last of a name, `URLSearchParams.get` the first). A page names apps
  where it lives (`StrutAppLink.Source`): a workspace page's bare name is
  that workspace's (strut's `peerAppLink`), and a workspace's own peers'
  apps are the workspace's to open, from Peel's strut and on the iPhone
  alike. Only an app's page links to apps: a file (the DM's report, its
  markdown an org's or a model's words) opens none, so a file from an org
  cannot open one of yours at a view it chose.
- **The Mac.** `StrutPage.newWindow` hands a link to another app, on the
  person's click, to `AppModel.open(_ link:)`, which the DM's Open uses
  too: an app the Apps list has opens where its sidebar row does, at the
  link's view (a page made again there); any other, its page alone in the
  web pane. Each app's view is kept on the model (`AppPlace`), told by the
  web view's address as strut moves the page in place, so Reload, a page
  closed by the keep-alive and shown again, a preview and a crash all open
  where the app was. Cleared with the account.
- **The iPhone.** `OrgPageSheet` opens a link to another app as that app's
  page alone in place (Back returns), with the token, on the person's tap;
  the title is the workspace's while it shows another app. Reload and a
  crash load strut's UI where the page went, with the token, and Try again
  the page that failed; a file opened in place reloads as before. Back
  sends no request: in three WebKit probes (a plain page, one with an
  `unload` handler, one holding requests open) Back was answered from
  WebKit's cache, so it needs no token.
- **Not here.** A link from a page to a run, a job or a workflow (Peel has
  no view of them; still nothing). A link Peel is handed from outside
  (hive's `/w/<slug>/apps/<name>?input=` as a universal link, or a
  `peel://` one): `peel://` takes only home links. A link the agent's DM
  carries with a view (strut's `kind: "app"` deliverable has no `input`).
- **Checked.** `StrutAppLinkTests` (a link read as the kit makes it and
  opened at its view; a workspace's bare name; `+`; no link for a run, an
  empty or bad name, another path, a peer's own peer, a name given twice
  or not decoding, an input past 2 KB in bytes; a page moved to another
  view with its key's escapes kept),
  `HiveTests.aPagesLinkToAnotherAppOpensAloneOnPeelsOwnStrut` (and none
  from a file's page),
  `StadeumTests.aLinkToAnotherAppOpensItAloneOnTheOrgsStrutWithTheToken`.
  An independent review found a file's links opening your own apps, the
  iPhone following an org's peer's app, repeated names, the limit in
  characters and Try again going to the first page: all fixed above.
  `swift test`: all pass but `BundledBridgeTests.theStagedRunnerExitsWhenPeelsPipeCloses`,
  which needs a fresh bridge stage. The Mac and iPhone (simulator) apps
  build. Not driven: the click itself in the app (no click step in
  `check-app.sh`).

## PRs, in order

1. **Sidebar and browser (Peel only).** The nav row in A–Z order, the
   bottom section removed, and `AppsView` (grid, search, workspace filter,
   A–Z sort) over `hive.apps`. You can ship this on its own; it fixes the
   scrolling today.
2. **Yours (built), then Recent.** Your own strut's apps are listed
   (above); still open: apps a workspace has not pinned, and Recent sort.
3. **strut: `updatedAt` on `GET /apps`**, then Peel shows it on cards and
   in the app header.
4. **New app and Change with Peel.** The popover → agent DM → builder, and
   the header action. Yours first; a workspace's once strut's builder-on-peer
   lands.
5. **Manage.** The ⋯ menu: versions and delete for yours, hide and "Open in
   Stadeum" for a workspace's.

The iPhone stays out (no strut of its own). `PhoneRouter` gets the Apps row
once a phone can reach a strut.

## Questions for Tom

- A list (B) as a toggle later, or the grid only? (Tom chose the grid for
  PR 1.)
- Is "Hide from Apps" enough for a workspace's app you don't want, or does it
  need to be per workspace ("hide all from @acme")?
