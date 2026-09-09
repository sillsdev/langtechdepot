# langtechdepot

Distribution layer for the [LangTechDepot software repository](https://lingtransoft.info/apps/LangTechDepot),
built on [Syncthing](https://syncthing.net/) (open source, no licenses, actively
developed). Replaces Resilio Sync.

How it works: the repository server in California marks every catalog folder
**Send Only** and offers all of them to each registered device. Your Syncthing
client shows the offers — the pending-folder list *is* the subscription
catalog. Accept the folders you want (software packages, training videos, ...)
and they stay current on your machine automatically. Devices holding the same
folders sync from each other too, so machines on one office LAN pull from their
neighbour instead of from California, and everyone's upload bandwidth helps
everyone else — the old btsync swarm, without the licensing.

## Getting access

1. Register at **<https://depot.langtech.cloud>**. You get a token by
   email. It works once, on one machine — register again for a second machine.
2. Run the installer for your platform (below) and paste the token when it asks.

That's the whole handshake. The token goes over HTTPS to the registration
service and never touches your Syncthing configuration, because Syncthing
broadcasts device *names* to every peer in the cluster — a token embedded in
one would be visible to every other field user.

## Install

**Windows** — right-click `client/setup-langtechdepot.ps1` and choose **Run
with PowerShell**. It installs Syncthing through winget; on a machine without
winget, download Syncthing from <https://syncthing.net/downloads/> first and
put `syncthing.exe` next to the script. (The script never downloads the
executable itself — antivirus dropper heuristics flag scripts that fetch a
binary and then register it for startup.)

If the window opens and shuts again without asking for your token, Windows is
blocking the downloaded script. Open PowerShell in that folder and run it
directly:

```powershell
powershell -ExecutionPolicy Bypass -File .\setup-langtechdepot.ps1
```

The installer waits for you to press Enter before closing, so anything that
goes wrong stays on screen — send us that text.

**Linux**

```bash
bash client/install-langtechdepot.sh
```

No admin rights on either platform. The installer sets Syncthing to start
automatically, registers the machine, and opens the web GUI at
<http://127.0.0.1:8384>. Within a minute or two the folder catalog appears as
offers at the top — click **Add** on the ones you want. Files land under
`~/LangTechDepot/` (or `%USERPROFILE%\LangTechDepot\`).

Prefer the command line? `langtechdepot-subscribe.sh` / `langtechdepot-subscribe.ps1`
list the catalog and subscribe by folder ID.

Folders are **receive-only** on your machine: if something local gets edited or
deleted by accident, Syncthing flags it and one click restores it. Nothing you
do locally propagates to anyone else.

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

## Repo layout

```text
client/  setup-langtechdepot.ps1     field installer (Windows)
         install-langtechdepot.sh    field installer (Linux)
         langtechdepot-subscribe.ps1|sh   CLI catalog list / subscribe
server/  SETUP.md                    server standup guide
         register.py                 registration service + admin CLI
         langtechdepot-register.service   systemd unit
         register.env.example        configuration template
         Caddyfile.example           TLS front end
```
