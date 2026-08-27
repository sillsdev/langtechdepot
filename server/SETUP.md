# LangTran Server Setup (California repository server)

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

GUI stays bound to `127.0.0.1:8384`. Administer over an SSH tunnel:
`ssh -L 8384:127.0.0.1:8384 server` then browse http://127.0.0.1:8384.
Set a GUI username/password on first login.

Record the server **Device ID** (Actions → Show ID) — it goes into the client
installer scripts.

Open/forward **TCP+UDP 22000** to this host so field clients can dial in
directly, and give it a stable DNS name (the `SERVER_ADDRESS` in the clients).

## 2. Create the folder catalog

One Syncthing folder per subscription group, pointed at the **existing** repo
directories (no data migration). For each folder in the GUI:

- Folder ID: short stable slug (`software-core`, `training-videos`, ...) —
  this is what users see and what `langtran-subscribe` takes as an argument.
  Never change an ID once published.
- Folder Path: the existing directory.
- Folder Type: **Send Only**.
- File Watcher: on (default). The existing website-watcher ingest script keeps
  writing into these directories unchanged; Syncthing picks changes up.

Put a `.stignore` in each folder so Resilio droppings never replicate:

```
(?d).sync
(?d).SyncArchive
*.rsls
*.rslsz
*.!sync
```

The first scan hashes everything — for a large media folder start it
off-hours; later scans are watcher-driven and cheap.

## 3. Install the auto-accept poller

```bash
sudo mkdir -p /opt/langtran-sync /etc/langtran
sudo cp autoaccept.py /opt/langtran-sync/
sudo cp autoaccept.env.example /etc/langtran/autoaccept.env
sudo chmod 600 /etc/langtran/autoaccept.env
sudo $EDITOR /etc/langtran/autoaccept.env    # set JOIN_TOKEN + API key/config path

sudo cp langtran-autoaccept.service langtran-autoaccept.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now langtran-autoaccept.timer
journalctl -u langtran-autoaccept.service -f   # watch accepts happen
```

The poller accepts any knocking device named `LT-<JOIN_TOKEN>-…` and offers it
every catalog folder. Devices without the token stay pending — approve or
ignore them by hand in the GUI. To onboard by hand instead, just don't start
the timer; at <50 devices that works too.

## 4. Optional hardening / extras

- **Own relay**: `sudo apt install syncthing-relaysrv` on this host if the
  public relay pool ever proves unreliable for NATed field clients.
- **Token rotation**: change `JOIN_TOKEN` in the env file and in the published
  installer; existing devices are unaffected (the token only gates admission).
- **Pruning**: remove a device in the GUI; it immediately stops receiving.
- **Monitoring**: per-device sync completion is on the GUI front page;
  `GET /rest/db/completion?device=<id>&folder=<id>` if a status page is wanted
  later.

## 5. Decommission Resilio (after the parallel-run window)

```bash
sudo systemctl stop resilio-sync && sudo systemctl disable resilio-sync
sudo apt remove resilio-sync
```

The repo directories are untouched — they were shared, not owned, by Resilio.
