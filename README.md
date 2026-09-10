# langtechdepot

**Setting up a machine? Don't read this page.**
Go to **<https://sillsdev.github.io/langtechdepot/>** — pictures, four steps,
no jargon. This README is for the people who maintain the thing.

---

Distribution layer for the [LangTechDepot software repository](https://lingtransoft.info/apps/LangTechDepot),
built on [Syncthing](https://syncthing.net/) (open source, no licenses, actively
developed). Replaces Resilio Sync.

How it works: the repository server in California marks every catalog folder
**Send Only** and offers all of them to each registered device. The client's
pending-folder list *is* the subscription catalog. Accepted folders stay
current automatically, and devices holding the same folders sync from each
other, so machines on one office LAN pull from their neighbour instead of from
California — the old btsync swarm, without the licensing.

## The four-step journey

A field user crosses between two sites during the install, and they are
designed as one flow rather than two projects:

| Step | What the user does | Where it happens |
| ---- | ------------------ | ---------------- |
| 1 | Fills the form, gets a token | `depot.langtech.cloud` — [server/register.py](server/register.py) |
| 2 | Downloads the installer | the instructions site — [docs/](docs/) |
| 3 | Runs it, pastes the token | the installer — [client/](client/) |
| 4 | Clicks **Add** on the folders they want | Syncthing's own GUI |

The token page hands back to the platform page the user came from (the `?os=`
parameter rides through the form), and the step rail, palette and components
are the same on both sites. Keep it that way: the seam is the part users
notice.

The token goes over HTTPS to the registration service and never touches
Syncthing's configuration, because Syncthing broadcasts device *names* to every
peer in the cluster — a token embedded in one would be visible to every other
field user.

## The instructions site

[docs/](docs/) is plain HTML with one stylesheet and one small script. No
build step, no framework, no web fonts, no bitmap images: the audience is on
slow links and the illustrations are inline SVG.

[.github/workflows/pages.yml](.github/workflows/pages.yml) publishes it on
every push to `main`, packing the Windows installer into
`downloads/langtechdepot-windows.zip` on the way so the site can offer a single
file to download. The zip is built rather than committed — a committed copy is
a second copy of the installers, and the second copy is the one that goes
stale. **One-time setting:** Settings → Pages → Source → *GitHub Actions*.

To look at it locally:

```bash
python3 -m http.server -d docs 8899     # then open http://127.0.0.1:8899/
```

The download buttons 404 in that preview; the workflow is what fills
`downloads/`.

### Editing it

Every link inside the site is relative and the one absolute URL — the `curl`
command on the Linux page — rewrites itself from `window.location`, so the
whole tree can be served from anywhere without edits. `DEPOT` and `SIGNUP` at
the top of [docs/assets/site.js](docs/assets/site.js) are the only two things
that name the registration server, and they are what the merge changes.

The sign-up form is at `/` on that server, not `/signup` — a user cannot be
sent straight to a token, because filling that form in is what produces one.
`/signup` exists as a second address for the same form so that the form still
has somewhere to live once the site takes over `/`.

Two things bite when hand-writing the SVG:

- **Quote every attribute value.** `stroke-width=2/>` parses as
  `stroke-width="2/"` and the tag never closes, so every shape after it
  becomes an invisible child of the first one. The page looks blank and
  nothing errors.
- **`register.py` carries its own copy of the CSS and the copy-button script.**
  It is a single stdlib file that must render correctly when the other site is
  unreachable, so the duplication is deliberate. Change one, change both.

## Install (what the site tells people)

**Windows** — download `langtechdepot-windows.zip`, extract it, double-click
`run-setup-langtechdepot.bat`. It installs Syncthing through winget; on a
machine without winget, `syncthing.exe` goes in the extracted folder by hand.
Nothing here ever downloads the executable itself — antivirus dropper
heuristics flag scripts that fetch a binary and then register it for startup.

The `.bat` is a one-line wrapper around `setup-langtechdepot.ps1`, and it is
there because a stock Windows machine refuses to run a downloaded `.ps1` at
all: right-clicking the script and choosing **Run with PowerShell** fails, and
the window closes before the reason is readable. Either route waits for Enter
before closing, so anything that goes wrong stays on screen.

**Linux**

```bash
bash client/install-langtechdepot.sh
```

No admin rights on either platform. The installer sets Syncthing to start
automatically, registers the machine, and opens the web GUI at
<http://127.0.0.1:8384>. Files land under `~/LangTechDepot/` (or
`%USERPROFILE%\LangTechDepot\`).

`langtechdepot-subscribe.sh` / `.ps1` list the catalog and subscribe by folder
ID for anyone who prefers the command line.

Folders are **receive-only** on the client: local edits and deletions are
flagged and revertible, and nothing local propagates outward.

## Sneakernet

Any synced machine holds a complete plain-files mirror of the folders it
subscribes to — copy the tree to a thumbdrive and carry it. For repeatable
offline updates, install Syncthing portably on the drive itself and let it sync
as its own device whenever the drive visits a connected machine.

## Server

See [server/SETUP.md](server/SETUP.md) — Syncthing standup, the folder catalog,
and the registration service ([server/register.py](server/register.py)) that
serves the form, issues single-use tokens, admits devices, and keeps the
catalog shared. Administration is `register.py admin list|approve|revoke`.

[server/Caddyfile.example](server/Caddyfile.example) carries the recipe for the
end state: the instructions site served from `depot.langtech.cloud` itself,
with the form kept at `/signup` so it still has an address of its own.

```bash
python3 server/test_register.py     # full suite; no network, no real Syncthing
```

## Repo layout

```text
docs/    index.html                  the instructions site: which computer?
         windows.html · linux.html   four steps, with pictures
         help.html                   what normally goes wrong
         assets/site.css · site.js   shared with register.py's pages
client/  run-setup-langtechdepot.bat double-click this on Windows
         setup-langtechdepot.ps1     field installer (Windows)
         install-langtechdepot.sh    field installer (Linux)
         langtechdepot-subscribe.ps1|sh   CLI catalog list / subscribe
         START-HERE.txt              rides along in the Windows zip
server/  SETUP.md                    server standup guide
         register.py                 registration service + admin CLI
         langtechdepot-register.service   systemd unit
         register.env.example        configuration template
         Caddyfile.example           TLS front end, and the merge plan
```
