# langtran-sync

Distribution layer for the [LangTran software repository](https://lingtransoft.info/apps/langtran),
built on [Syncthing](https://syncthing.net/) (open source, no licenses, actively developed).
Replaces Resilio Sync.

How it works: the repository server in California marks every catalog folder
**Send Only** and offers all of them to each approved device. Your Syncthing
client shows the offers — the pending-folder list *is* the subscription
catalog. Accept the folders you want (software packages, training videos, ...)
and they stay current on your machine automatically. Devices that hold the
same folders sync from each other too — machines on one office LAN pull from
their neighbor instead of from California, and everyone's upload bandwidth
helps everyone else, exactly like the old btsync swarm.

## Install (field machines)

Get the installer for your platform from this repo, open it, and fill in the
three values at the top (server device ID, server address, join token — your
LangTran contact supplies these), then:

**Windows** — right-click `setup-langtran-sync.ps1` and choose **Run with
PowerShell**. The script installs Syncthing through winget; on a machine
without winget, download Syncthing from https://syncthing.net/downloads/
first and put `syncthing.exe` next to the script. (Syncthing is installed
through winget or by hand rather than downloaded by the script itself —
antivirus dropper heuristics flag scripts that download and persist
executables.)

**Linux**

```bash
bash install-langtran-sync.sh
```

No admin rights needed on either platform. The installer sets Syncthing to
start automatically, connects it to the LangTran server, and opens
the web GUI at http://127.0.0.1:8384. Within a minute or two the folder
catalog appears as offers at the top of the GUI — click **Add** on the ones
you want. Files land under `~/LangTran/` (or `%USERPROFILE%\LangTran\`).

Prefer the command line? `langtran-subscribe.sh` / `langtran-subscribe.ps1`
list the catalog and subscribe by folder ID.

Folders are **receive-only** on your machine: if something local gets edited
or deleted by accident, Syncthing flags it and one click restores it; nothing
you do locally propagates to anyone else.

## Sneakernet

Any synced machine holds a complete plain-files mirror of the folders it
subscribes to — copy the folder tree to a thumbdrive and carry it. For
repeatable offline updates, install Syncthing portably on the drive itself and
let it sync as a device whenever the drive visits a connected machine.

## Server

See [server/SETUP.md](server/SETUP.md) — Syncthing standup on the repository
server, the folder catalog, and the auto-accept poller
([server/autoaccept.py](server/autoaccept.py)) that admits devices carrying
the join token and offers them the catalog.

## Repo layout

```
client/  setup-langtran-sync.ps1        one-shot field installer (Windows)
         install-langtran-sync.sh       one-shot field installer (Linux)
         langtran-subscribe.ps1|sh      CLI catalog list / subscribe
server/  SETUP.md                       server standup guide
         autoaccept.py                  device admission + catalog offers
         langtran-autoaccept.service|timer, autoaccept.env.example
```
