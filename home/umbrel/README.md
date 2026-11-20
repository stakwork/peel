# Peel Home for Umbrel

An Umbrel community app store with one app, Peel Home: [`../`](../README.md)'s
Compose file, wrapped. This folder is the store's whole repo
(`stakwork/umbrel-apps`, to be made): umbrelOS clones a store's default
branch and reads `umbrel-app-store.yml` and `*/umbrel-app.yml` at its root,
so a store can't be a subfolder of this repo.

```
umbrel-app-store.yml       the store: id "peel", so every app id starts with "peel-"
peel-home/
├── umbrel-app.yml         the listing; port 3780 is the tile
├── docker-compose.yml     each service extends home/'s, plus Umbrel's parts and the tile
├── exports.sh             home/'s settings for Umbrel: ports and address
├── hooks/home/            copies of home/'s docker-compose.yml, setup.sh, gate.sh, Caddyfile
├── hooks/tile/            the tile: start.sh (its server) and cgi-bin/index.cgi (its page)
└── data/                  the folders the services mount, empty; data/page is the tile's
```

## The pieces

| Port | What | Who uses it |
|---|---|---|
| 3780 | The tile: the app's page, behind Umbrel's login | You, from Umbrel's home screen |
| 3781 | setup (`strut move serve`), only while a move is under way | The Mac's Peel, for the move. Not behind Umbrel's login: Peel can't log in to Umbrel |
| 3782 | The peer port (Caddy, TLS, an allowlist) | The Mac's strut, for the memory sync |

home/'s defaults, 8090 and 8443, are taken by other Umbrel apps (urbit,
mattermost), so `exports.sh` sets `HOME_SETUP_PORT` and `HOME_PEER_PORT`, and
`HOME_SETUP_HOST=umbrel.local:3781` (`DEVICE_DOMAIN_NAME`), the address both
links name. The peer record names the address the move came in on, and its
certificate is for the fixed name `peel-home`, which the Mac's strut checks
whatever the address: nothing else changes for umbrel.local.

**The tile** is a busybox `httpd` with one CGI script. It runs as its own
user (1000) and sees only `data/page`, not setup's folders or strut's keys.
setup's relay (`SETUP_PAGE`, in setup.sh) writes `setup.sh status` there
every 2 s, and runs the one request the page leaves in `data/page/ask`,
through setup.sh's own `send-back` and `cancel`. It shows:

| `setup.sh status` | The page |
|---|---|
| `empty` | Move Peel Home to this Umbrel, with Open in Peel (the receive link). No QR code: only the Mac makes the move |
| `starting`, `here` | Peel Home is starting, then running here, with Send Peel Home back |
| `sending` | Packing, with Cancel; then the send-back link as Open in Peel, with Keep Peel Home here (`cancel --force`, after a confirm: the Mac may have it already) |
| `stopped` | A send-back cut short: Send Peel Home back again, or Keep Peel Home here |
| `incomplete` | A move in cut short; clearing it needs a shell (home/README.md, "When something is stuck") |
| `failing` | setup's last try ended in an error; it tries again, and the app's logs say why |

The page reloads itself while something can change without it (every 3 s
during a send-back, 10 s while waiting for a move), and not while a
question it asked is open.

Once a send-back link is out, whoever uses it gets Peel Home, keys and all,
so only someone logged in to Umbrel may see the link or start a send-back:
- **Only umbreld's gateway gets an answer.** umbrelOS 2.0's app gateway runs
  inside umbreld, on the host, so its requests reach the tile from the
  Docker network's gateway address; another app's container on Umbrel's
  network comes from an address of its own and gets a 403 (`start.sh` tells
  httpd, and the page checks `REMOTE_ADDR` too). umbreld adds no header
  another container couldn't send, so the address is the mark. This needs
  umbrelOS 2.0 (`manifestVersion: 2.0`): before it, app_proxy was a
  container with an address of its own.
- **Its forms carry a per-install token** (`exports.sh`), so another site's
  page, in a browser logged in to Umbrel, can't post them.
- **Each request carries the state it was shown for**, and setup drops it if
  that has changed, so a stale tab can't act on a later send-back.

### Why it is built this way

- **The tile is its own small service**, not part of setup: setup's port is
  `strut move serve`, strut's own server, which listens only during a move,
  so a tile pointed at it would land on a dead port. A page over setup.sh's
  commands reuses the move and its state as they are, with no second server
  to keep in step.
- **`extends`**: home/'s Compose file stays the product. The
  wrapper repeats only what Umbrel can't take from it: each `image:` (umbreld
  pulls what the file it reads says, before variables are filled in) and each
  mount, under `${APP_DATA_DIR}` (data/ where Umbrel can move it).
- **home/'s files under `hooks/`**: an app update copies only
  `docker-compose.yml`, `*.template`, `exports.sh`, `torrc` and `hooks/` into
  the installed app (umbreld's `app-script`), so anything else would stay at
  its first install's version. umbrelOS runs only hooks with fixed names
  (`pre-start`, …), none of which are here.

## Keeping it in step with home/

`hooks/home/` holds copies, since the store repo has only this folder, and
`docker-compose.yml` writes out home/'s image pins (the Mac and the box must
run the same strut). `scripts/check-umbrel.sh` fails when either has drifted;
CI and `scripts/risk.sh` run it. After a change to home/:

```sh
cp home/docker-compose.yml home/setup.sh home/gate.sh home/Caddyfile home/umbrel/peel-home/hooks/home/
```

and copy any new pin into `docker-compose.yml`.

## Publishing

The store is a public GitHub repo, `stakwork/umbrel-apps`, holding this
folder's contents at its root (umbrelOS clones it without credentials):

```sh
rsync -a --delete --exclude .git home/umbrel/ <stakwork/umbrel-apps checkout>/
```

Then bump `version` in `peel-home/umbrel-app.yml`: umbrelOS offers an update
when it changes.

## Adding the store to an Umbrel

1. In Umbrel, open the App Store, then its menu (top right) › Community App
   Stores › Manage.
2. Paste `https://github.com/stakwork/umbrel-apps` and click Add, then Open.
3. Install Peel Home.
4. On the Mac that runs Peel, open Peel Home from Umbrel's home screen and
   click Open in Peel.
