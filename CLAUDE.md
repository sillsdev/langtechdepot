# LangTechDepot

Distribution layer for the LangTechDepot software repository
(<https://lingtransoft.info/apps/LangTechDepot>), built on Syncthing. It replaces a dead
Resilio Sync setup whose donated licences were tied to a version no longer available.
Audience: ~50 field machines on low-bandwidth links, Windows and Linux, no admin rights.

This repo is **only the thin layer** — client installers, a subscribe CLI, the
server-side registration service, and the instructions site users are pointed at.
Syncthing does the syncing; we add no protocol code. The catalog content lives on the
California repository server and is not in here.

## How a device joins

1. User fills the form at `PUBLIC_URL` → `register.py` mints a single-use token, emails it.
2. The installer POSTs `{token, deviceID, deviceName}` to `/register`.
3. The service adds the device to Syncthing, shares every catalog folder with it, burns the token.
4. A 60-second `reconcile_loop` re-shares the catalog, so folders added later reach
   already-registered devices.

Server folders are **Send Only**; clients are receive-only. Every catalog folder is offered
to every registered device — the client's pending-folder list *is* the subscription catalog.
Syncthing's introducer mode lets clients learn each other, so office LANs sync peer-to-peer.

**Why a registration service at all:** a Syncthing device *name* is public — BEP's
ClusterConfig carries it to every peer, and the introducer forwards it. An earlier design
put the token in the device name; that leaked it to every other field user. Tokens now
travel over HTTPS and never enter Syncthing's config. Do not reintroduce
identity-in-device-name.

## Layout

```text
docs/    index.html                     the instructions site: which computer?
         windows.html · linux.html      four steps, with inline-SVG pictures
         help.html                      what normally goes wrong
         assets/site.css · site.js      shared look with register.py's pages
client/  run-setup-langtechdepot.bat    double-click wrapper for the .ps1 (owns the pause)
         setup-langtechdepot.ps1        Windows installer
         install-langtechdepot.sh       Linux installer
         langtechdepot-subscribe.ps1|sh CLI catalog list / subscribe
         START-HERE.txt                 rides along inside the Windows zip
server/  register.py                    registration service + admin CLI (stdlib + dotenv)
         test_register.py               end-to-end test against a stub Syncthing
         ltd-sync-admin                 sudo wrapper for `register.py admin`
         token_backup.sh                nightly sqlite .backup, 30-day retention
         SETUP.md                       server standup guide (the real deployment doc)
         langtechdepot-register.service · register.env.example · Caddyfile.example
.github/workflows/pages.yml            builds the zip, publishes docs/ to Pages
```

Deploy target is the California repository server. Nothing here is deployed from this
machine — SETUP.md is followed by hand on that box.

## The two sites are one journey

Field users are not technical and must never be sent to a GitHub page. The entry point
is the instructions site (`docs/`, published at
<https://sillsdev.github.io/langtechdepot/>); the README is for maintainers and says so
in its first line. Four steps: **1** get a token (on the depot server) → **2** download
→ **3** run it → **4** pick folders. Step 1 lives in `register.py`, the rest on the site,
and the hand-off runs both ways — the platform pages pass `?os=windows|linux` to the
form, and the token page sends the user back to the page they came from.

That is why `register.py` duplicates the palette, the step rail and the copy-button
script from `docs/assets/`: it is one stdlib file that has to render correctly when the
other site is unreachable. **Change one, change both.**

The two are meant to merge onto `depot.langtech.cloud` eventually, so everything is
written to survive it: site links are relative, the Linux `curl` command rewrites itself
from `window.location`, `DEPOT`/`SIGNUP` in `site.js` and `SITE_URL` in `register.env`
are the only absolute names, and the form already answers on `/signup` as well as `/`.
The Caddyfile carries the switch-over recipe.

**Step 1 is the form at `/`, not a token URL.** Nobody can be linked straight to a
token — filling the form in is what mints one. `/signup` is a second address for that
same form, reserved for after the merge; until then the site must link to `/`, because
that is the only path the deployed service answers on.

## Commands

```bash
python3 -m http.server -d docs 8899 # preview the site; downloads/ is CI-built, so 404s
python3 server/test_register.py     # full test suite; no network, no real Syncthing
ltd-sync-admin list [--pending]     # on the server: who registered what
ltd-sync-admin approve <token>      # issue + email
ltd-sync-admin revoke <email|device-id|token>
```

`revoke` removes the device from Syncthing — that is what actually ends access; the DB flag
only stops the reconciler from re-adding it.

## Conventions

- **`register.py` is stdlib-only** apart from `python-dotenv`. Keep it that way; the server
  gets `apt install python3-dotenv` and nothing else. No Flask, no requests.
- **Line endings are enforced** by `.gitattributes`: `.ps1` is CRLF, `.sh`/`.py`/`.service`
  are LF. Don't fight it.
- **The Windows installer never downloads an executable.** It uses winget or a
  hand-placed `syncthing.exe`. Antivirus dropper heuristics flag scripts that fetch a binary
  and then register it for startup — this cost us an installer already (see Traps).
- **Folder IDs are permanent.** They are what users see and what `langtechdepot-subscribe`
  takes as an argument. Never rename a published one.
- **Syncthing's config PATCH replaces child arrays wholesale**, so `share_catalog_with()`
  does read-modify-write on the device list rather than appending. Preserve that shape.
- **Both installers pin Syncthing's `--home`.** Syncthing resolves its config dir by
  probing — a legacy `~/.config/syncthing/config.xml` wins over the `~/.local/state`
  default — so the path cannot be assumed, and reading `config.xml` from a guessed
  location is how the Linux installer used to die. Pinning also gives the depot its own
  Syncthing instance instead of borrowing the user's personal one, which matters because
  registration PATCHes `defaults/folder` to receive-only and would otherwise rewrite
  *their* defaults. Don't hardcode the GUI port either: first start probes for a free one.
- Installers are idempotent and re-runnable.
- **Quote every attribute in the inline SVG.** `stroke-width=2/>` parses as
  `stroke-width="2/"`, the tag never closes, and every following shape becomes an
  invisible child of the first one — a blank illustration with no error anywhere.
- The Windows zip is **built by CI, never committed**: a committed copy of the
  installers is a second copy, and the second copy goes stale.
- Service binds localhost only; Caddy terminates TLS and also serves `/files` as a browsable
  tree of `/data/LT/Groups` for single-installer downloads.

## Traps

- `client/install-langtran-sync.ps1` is a **Bitdefender-quarantined ghost** on the authoring
  machine: unreadable, and ransomware remediation resurrects it on delete. It is gitignored.
  The real Windows installer is `setup-langtechdepot.ps1`. Clear it from the Bitdefender
  console before removing the ignore entry.
- **The hostname is `depot.langtech.cloud`** (settled in #1; `/files` there browses the
  Groups tree). Both installers now carry it — `install-langtechdepot.sh` used to point at
  `langtechdepot.lingtransoft.info`, which was the wrong half of a divergent pair. Don't
  reintroduce the other name.
- **Syncthing 2 has no `generate --no-default-folder`.** The flag *and* the "Default Folder"
  it suppressed were both removed in 2.0, so passing it is a hard error and there is nothing
  left to suppress. It is not an argument-order problem. Don't re-add it (see #7).
- README documents administration as `register.py admin ...`; SETUP.md has moved to the
  `ltd-sync-admin` wrapper. Same underlying command.
- **GitHub Pages needs one manual setting**: Settings → Pages → Source → *GitHub
  Actions*. Without it the workflow runs green and publishes nothing.
- The token is now **shown on the confirmation page as well as emailed**. A field user
  on a slow link who has to go and find a mail client mid-install is one who does not
  finish; the mail copy is the backup, not the delivery.
- The project was renamed twice — LangTran → LangTechDepot, and the `-sync` suffix dropped.
  Stale `langtran` strings may still surface in older docs and external references.
