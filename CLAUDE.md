# LangTechDepot

Distribution layer for the LangTechDepot software repository
(<https://lingtransoft.info/apps/LangTechDepot>), built on Syncthing. It replaces a dead
Resilio Sync setup whose donated licences were tied to a version no longer available.
Audience: ~50 field machines on low-bandwidth links, Windows and Linux, no admin rights.

This repo is **only the thin layer** — client installers, a subscribe CLI, and the
server-side registration service. Syncthing does the syncing; we add no protocol code.
The catalog content lives on the California repository server and is not in here.

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
client/  run-setup-langtechdepot.bat    double-click wrapper for the .ps1 (owns the pause)
         setup-langtechdepot.ps1        Windows installer
         install-langtechdepot.sh       Linux installer
         langtechdepot-subscribe.ps1|sh CLI catalog list / subscribe
server/  register.py                    registration service + admin CLI (stdlib + dotenv)
         test_register.py               end-to-end test against a stub Syncthing
         ltd-sync-admin                 sudo wrapper for `register.py admin`
         token_backup.sh                nightly sqlite .backup, 30-day retention
         SETUP.md                       server standup guide (the real deployment doc)
         langtechdepot-register.service · register.env.example · Caddyfile.example
```

Deploy target is the California repository server. Nothing here is deployed from this
machine — SETUP.md is followed by hand on that box.

## Commands

```bash
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
- Installers are idempotent and re-runnable.
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
- The project was renamed twice — LangTran → LangTechDepot, and the `-sync` suffix dropped.
  Stale `langtran` strings may still surface in older docs and external references.
