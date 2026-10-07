# LangTechDepot

Distribution layer for the LangTechDepot software repository
(<https://lingtransoft.info/apps/LangTechDepot>), built on Syncthing. It replaces a dead
Resilio Sync setup whose donated licences were tied to a version no longer available.
Audience: ~50 field machines on low-bandwidth links, Windows and Linux, no admin rights.

**Before making design decisions, read [intent.md](intent.md).** It states what the
system is for, which of those goals the code actually meets today, and the rules that
follow from them. This file is the mechanism; that one is the reason.

This repo is **only the thin layer** — client installers, a subscribe CLI, the
server-side registration service, and the instructions site users are pointed at.
Syncthing does the syncing; we add no protocol code. The catalog content lives on the
California repository server and is not in here.

## How a device joins

1. User fills the form at `PUBLIC_URL` → `register.py` mints a single-use token, shows it
   on the page, and emails it when SMTP is configured (it is not yet — see Traps).
2. The installer POSTs `{token, deviceID, deviceName}` to `/register`. An installer re-run
   on a machine the server already knows skips the token.
3. The service adds the device to Syncthing, shares every catalog folder with it, burns the token.
4. A 60-second `reconcile_loop` re-shares the catalog, so folders added later reach
   already-registered devices.
5. The installer subscribes to `All_Contents_List`, waits for `LangTechDepotFiles.txt`
   to arrive in it, and shows a picker built from that file. Ticked folders are added;
   **unticked ones go into the server device's `ignoredFolders`**, so Syncthing stops
   offering them. Re-running the installer (or `modify-langtechdepot add`) brings them back.

Server folders are **Send Only**; clients are receive-only. Every catalog folder is offered
to every registered device. Syncthing's introducer mode lets clients learn each other, so
office LANs sync peer-to-peer.

**The catalog file is an interface.** `LangTechDepotFiles.txt` is generated on the server
by a script outside this repo (LTUse's side), and both installers parse it. The folder
section sits between a line containing `Folders available, with their sizes` and one
containing `Individual files available`, one folder per line as
`<size> <FolderID> "<description>"`. Change that shape and both pickers go blank. The
description becomes the folder's *local* label on the client when it is added; it does
not come from the server's Syncthing label. (PR #24 proposed server-side labels from a
`labels.json`; this file made that a second source for the same words.)

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
client/  setup-langtechdepot.ps1        Windows installer - the one copy; edit this
         setup-langtechdepot.bat.in     CMD launcher the .ps1 is wrapped in (owns the pause)
         build-bat.sh                   .bat.in + .ps1 -> setup-langtechdepot.bat (gitignored)
         version.sh                     the version, from the latest v* git tag
         install-langtechdepot.sh       Linux installer
         langtechdepot-subscribe.sh     CLI catalog list / subscribe (Linux only)
         START-HERE.txt                 rides along inside the Windows zip
server/  register.py                    registration service + admin CLI (stdlib + dotenv)
         test_register.py               end-to-end test against a stub Syncthing
         ltd-sync-admin                 sudo wrapper for `register.py admin`
         token_backup.sh                nightly sqlite .backup, 30-day retention
         SETUP.md                       server standup guide (the real deployment doc)
         langtechdepot-register.service · register.env.example · Caddyfile.example
images/                                 screenshots for intent.md (never served to field users)
.github/workflows/pages.yml            builds the .bat and the zip, publishes docs/ to Pages
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

## Versions and releases

The version number lives in **one place: the git release tag** (`v1.0.1`). Nothing in
the repo holds it. `client/version.sh` reads it; `build-bat.sh` writes it into the one
line `$LTD_VERSION = "dev"` of the built `.bat` (the `.ps1` itself always says `dev`),
and the Pages workflow puts it on the download page (`<!--LTD_VERSION-->` placeholder
in `windows.html`). Users see it in the installer's first line, the folder list's
title, `READ-ME.txt`, and `modify-langtechdepot version`.

If `client/` has changed since the last tag, the label is `1.0.1+dev.<commit>` — a
visible sign that a release was published without being tagged. Website-only changes
keep the plain label, since the installer offered is unchanged.

Numbering is major.minor.patch, each part a plain integer (1.9.0 is followed by 1.10.0):
- **patch** — fixes only; nothing new to learn (config.xml repair, wording).
- **minor** — something new, and existing installs keep working (`modify-langtechdepot`,
  the folder shortcuts).
- **major** — users or helpers must act, or old installs stop working properly
  (registration changes, install location moves, folder ID changes, dropping an OS).

To release, once the change is tested:

```bash
git tag -a v1.0.2 -m "Version 1.0.2: what changed"
git push --follow-tags        # sends the commit and the tag together
```

The workflow checks out with `fetch-depth: 0`, since a shallow clone has no tags. It
does **not** run on tag pushes: `--follow-tags` sends the tag with the commit, so the
normal `main` run already sees it. (A tag trigger was tried in 1.0.x: the tag run
cancelled the `main` run - the workflow's concurrency setting - and was then refused
by the `github-pages` environment, which only lets `main` deploy, so nothing published.)
To relabel after tagging a commit that is already pushed: Actions -> Publish the
instructions site -> Run workflow.

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
- **Line endings are enforced** by `.gitattributes`: `.ps1`, `.bat`, `.bat.in` and `.txt`
  are CRLF, `.sh`/`.py`/`.service` are LF. Don't fight it: CMD misreads a `.bat` with
  LF-only endings, and `build-bat.sh` and the workflow both refuse to ship one.
- **The Windows installer never downloads an executable.** It uses winget
  (`--scope user`) or a `syncthing.exe` hand-placed beside the `.bat`, which reaches the
  script as `-From` because the `.ps1` itself runs from a temporary copy. Antivirus dropper heuristics flag scripts that fetch a binary
  and then register it for startup — this cost us an installer already (see Traps).
- **Folder IDs are permanent.** They are what users see and what
  `modify-langtechdepot` (Windows) and `langtechdepot-subscribe` (Linux) take as an
  argument. Never rename a published one.
- **`modify-langtechdepot` is the Windows installer itself**, not a second program.
  Each run copies the `.bat` it came from to `%LOCALAPPDATA%\Programs\Syncthing\` (beside
  our `syncthing.exe`) as `modify-langtechdepot.bat`, and adds that folder to the user
  PATH (HKCU, no admin). `modify-langtechdepot add|ignore <ids>` / `list` go through
  the same code as the dialog but change only the folders named, with no dialog and no
  pause; with no arguments it is the ordinary installer. Command-line features go into
  `setup-langtechdepot.ps1`; don't bring back a separate Windows subscribe script — two
  programs doing one job drift apart.
- **Syncthing's config PATCH replaces child arrays wholesale**, so `share_catalog_with()`
  does read-modify-write on the device list rather than appending. Preserve that shape.
- **Both installers pin Syncthing's `--home`.** Syncthing resolves its config dir by
  probing — a legacy `~/.config/syncthing/config.xml` wins over the `~/.local/state`
  default — so the path cannot be assumed, and reading `config.xml` from a guessed
  location is how the Linux installer used to die. Pinning also gives the depot its own
  Syncthing instance instead of borrowing the user's personal one, which matters because
  registration PATCHes `defaults/folder` to receive-only and would otherwise rewrite
  *their* defaults. On Linux, don't hardcode the GUI port either — read `gui/address`;
  first start probes for a free one. The Windows installer pins 8384 in the fresh config
  on purpose (see below).
- **Never load `config.xml` with `[xml](Get-Content ...)`.** Use
  `$x = New-Object System.Xml.XmlDocument; $x.PreserveWhitespace = $true; $x.Load($path)`.
  Without `PreserveWhitespace`, `$x.Save()` re-indents the whole file and splits every
  empty element over two lines (`<urUniqueID>`, newline, indent, `</urUniqueID>`);
  Syncthing then stores that whitespace as the value and writes it back as
  `&#xA;        `. This was blamed on Syncthing for a while; it was ours. And Windows
  PowerShell's `Get-Content` reads BOM-less UTF-8 as ANSI, garbling non-ASCII names.
  Raw-text edits go through `[IO.File]::ReadAllText/WriteAllText` with UTF-8, not
  `Get-Content`/`Set-Content`. (The installer still carries a clean-up for configs the
  old helper damaged; see "CLEAN-UP FOR CONFIGS DAMAGED BY EARLIER VERSIONS".)
- **The programs are hidden; the home folder is not.** `syncthing.exe`,
  `modify-langtechdepot.bat` and the config stay in `%LOCALAPPDATA%` (hidden, standard
  for per-user programs, and where antivirus has passed them). What users see is the
  home folder `%USERPROFILE%\LangTechDepot` (`$HOME_BASE`), always in the same place
  and pinned once to Explorer's Quick access. Every run writes `READ-ME.txt`,
  `Change my Assets.lnk` and `Am I up-to-date, and advanced management.url` there, plus
  **`Assets`**: the synced folders' root (`$DATA_ROOT`). By default that is the real
  folder `$HOME_BASE\Assets`; if the user picks somewhere else (another drive, a USB
  disk), the folder made there is called `LangTechDepot` and `Assets` in the home
  folder is a `.lnk` shortcut to it - not a junction, which backup programs follow.
  So the instructions are identical for everyone ("Quick access -> LangTechDepot ->
  Assets"), and the support items survive a USB disk being unplugged. Installs from
  before 1.1 kept the folders directly in the home folder; the installer leaves those
  as they are (no `Assets` item). Not Downloads (gets cleaned out, and a startup program there looks like
  malware), not Documents/Desktop (often OneDrive-synced, so gigabytes would upload).
- **People are told `localhost:8384`; the script uses `127.0.0.1:8384`.** Syncthing
  is bound to 127.0.0.1; "localhost" may resolve to `::1` first. Browsers fall back,
  `Invoke-RestMethod` callers shouldn't have to. `$GUI_PAGE` is for messages and
  shortcuts, `$GUI_URL` for API calls.
- Installers are idempotent and re-runnable.
- **Quote every attribute in the inline SVG.** `stroke-width=2/>` parses as
  `stroke-width="2/"`, the tag never closes, and every following shape becomes an
  invisible child of the first one — a blank illustration with no error anywhere.
- **The Windows `.bat` and zip are built, never committed.** The user downloads one zip
  holding `setup-langtechdepot.bat` (the `.ps1` carried inside it below a marker line)
  and `START-HERE.txt`. Edit only the `.ps1`; run `sh client/build-bat.sh` for a `.bat`
  to test. A committed copy is a second copy, and the second copy goes stale.
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
- The token is **shown on the confirmation page**, and is meant to be emailed as well. A
  field user on a slow link who has to go and find a mail client mid-install is one who
  does not finish, so the page is the delivery and the mail the backup. Mail goes out
  from `depot@langtech.cloud` (Zoho, `smtppro.zoho.com`), which is also the support
  address `docs/help.html` gives and is read in Thunderbird. If SMTP fails, the page
  says it is the only copy — keep that fallback. `register.env.example` ships with
  `SMTP_PASS` blank; copied as-is, every sign-up waits on a failing login.
- **The Linux picker needs `yad`.** The installer checks for it first and exits 1
  before registering. Keep that check above the token prompt: when the dialog fails
  later, the script reports "Operation cancelled." and exits 0, with a token spent and
  nothing subscribed but `All_Contents_List`.
- The project was renamed twice — LangTran → LangTechDepot, and the `-sync` suffix dropped.
  Stale `langtran` strings may still surface in older docs and external references.
