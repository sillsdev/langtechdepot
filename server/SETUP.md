# LangTechDepot Server Setup (California repository server)

One-time standup. Resilio can keep running alongside; the two ignore each other
once the `.stignore` entries below are in place.

## 1. Install Syncthing

```bash
# Debian/Ubuntu — official apt repo
sudo mkdir -p /etc/apt/keyrings
sudo curl -L -o /etc/apt/keyrings/syncthing-archive-keyring.gpg https://syncthing.net/release-key.gpg
echo "deb [signed-by=/etc/apt/keyrings/syncthing-archive-keyring.gpg] https://apt.syncthing.net/ syncthing stable-v2" | sudo tee /etc/apt/sources.list.d/syncthing.list
sudo apt update && sudo apt install syncthing

sudo useradd -r -m -d /home/syncthing syncthing   # if it doesn't exist
sudo systemctl enable --now syncthing@syncthing
```

The GUI stays bound to `127.0.0.1:8384`. Administer over an SSH tunnel:
`ssh -L 8384:127.0.0.1:8384 server`, then browse <http://127.0.0.1:8384>. Set a
GUI username and password on first login.

Open **TCP+UDP 22000** to this host and give it a stable DNS name — clients
receive that address at registration.

You never need to copy the server's device ID anywhere: the registration
service reads it from the running Syncthing and hands it to each client.

## 2. Create the folder catalog

One Syncthing folder per subscription group, pointed at the **existing** repo
directories (no data migration). For each folder in the GUI:

- **Folder ID**: short stable slug (`software-core`, `training-videos`, ...).
  This is what users see and what `langtechdepot-subscribe` takes as an argument.
  Never change an ID once published.
- **Folder Path**: the existing directory.
- **Folder Type**: **Send Only**.
- **File Watcher**: on (default). The existing website-watcher ingest script
  keeps writing into these directories unchanged; Syncthing picks changes up.

Put a `.stignore` in each folder so Resilio droppings never replicate:

```
(?d).sync
(?d).SyncArchive
*.rsls
*.rslsz
*.!sync
```

The first scan hashes everything — for a large media folder, start it
off-hours. Later scans are watcher-driven and cheap.

Folders added *after* people register are picked up automatically: the
registration service re-shares the catalog with every active device once a
minute.

## 3. Install the registration service

This is how field machines join. Nothing else admits a device.

```bash
sudo mkdir -p /opt/langtechdepot-sync /etc/langtechdepot
sudo cp register.py /opt/langtechdepot-sync/
sudo cp register.env.example /etc/langtechdepot/register.env
sudo chmod 600 /etc/langtechdepot/register.env
sudo $EDITOR /etc/langtechdepot/register.env    # API key, SERVER_ADDRESS, PUBLIC_URL, SMTP

sudo cp langtechdepot-register.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now langtechdepot-register
journalctl -u langtechdepot-register -f
```

Without `SMTP_HOST` the form shows the token on screen instead of mailing it —
usable, but set SMTP if you want a working address on file for each registrant.
Set `AUTO_APPROVE=false` to queue requests for manual approval instead.

## 4. Put TLS in front

The service binds to localhost only. Caddy terminates TLS and renews the
certificate on its own:

```bash
sudo apt install caddy
sudo cp Caddyfile.example /etc/caddy/Caddyfile
sudo $EDITOR /etc/caddy/Caddyfile          # set the real hostname
sudo systemctl reload caddy
```

Requires ports **80 and 443** open and the hostname pointed at this box. Visit
`https://<hostname>/` — you should get the registration form. Put that URL into
`REGISTER_URL` at the top of both client installers before publishing them.

## 5. Day-to-day administration

```bash
cd /opt/langtechdepot-sync
sudo -u syncthing python3 register.py admin list              # who registered what
sudo -u syncthing python3 register.py admin list --pending    # awaiting approval
sudo -u syncthing python3 register.py admin approve <token>   # issue + email it
sudo -u syncthing python3 register.py admin revoke <email>    # cut a machine off
```

`revoke` removes the device from Syncthing, which is what actually ends access;
the database flag only stops the reconciler from re-adding it. Accepts an
email, a device ID, or a token.

Tokens are single-use and admit one machine. A user with a laptop and a field
desktop registers twice.

## 6. Optional extras

- **Own relay**: `sudo apt install syncthing-relaysrv` if the public relay pool
  proves unreliable for NATed field clients.
- **Monitoring**: per-device sync completion is on the Syncthing GUI front page;
  `GET /rest/db/completion?device=<id>&folder=<id>` if you want a status page.

## 7. Decommission Resilio (after the parallel-run window)

```bash
sudo systemctl stop resilio-sync && sudo systemctl disable resilio-sync
sudo apt remove resilio-sync
```

The repo directories are untouched — Resilio shared them, it never owned them.
