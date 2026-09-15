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

The GUI stays bound to `127.0.0.1:8384`. Administer over a remote desktop or an SSH tunnel:
`ssh -L 8384:127.0.0.1:8384 server`, then browse <http://127.0.0.1:8384>. 
On first login, go to Settings/GUI and set a GUI username and password.

In the firewall, open **TCP+UDP 22000** to this host.
Ask the person who manages our DNS to give this server a stable DNS name,
such as depot.langtech.cloud — clients receive that address at registration.

You never need to copy the server's device ID anywhere: the registration
service reads it from the running Syncthing and hands it to each client.

## 2. Prepare folders for sharing

Put a `.stignore` in each folder so Resilio droppings never replicate.
The easy way to do that is to make the file `.stignore` in /data/LT
and then make a symbolic link to it in each folder to be shared.
The `.stignore` folder should contain:

```
(?d).sync
(?d).SyncArchive
*.rsls
*.rslsz
*.!sync
.SyncID
.SyncIgnore
```
(We have to use symbolic links, not hard links, because each folder within the BTSync folder is regarded as a separate filesystem. This comes from the "bind links" that we use to relate the folders within the Groups folder to the folders within BTSync.)

Here are the steps to make the symbolic links:
```
umask 027  # Ensure group read-only access and completely block others
cd /data/LT/BTSync
rm *.txt
for d in *; do ln -fs /data/LT/.stignore $d/.stignore; done
```
So that SyncThing can create `.stfolder` inside the folders to be shared, change the group membership of all the files and folders inside /data/LT/BTSync to *syncthing* with the command
```
cd /data/LT/BTSync
sudo chgrp -R syncthing .* *
```
So that you and the user *ltadmin* can make changes in the files to be shared with syncthing, 
both login accounts need to be listed in the group called *syncthing*, with these commands:
```bash
sudo usermod -aG syncthing ltadmin
sudo usermod -aG syncthing $USER
newgrp syncthing	# start a new shell with your new permissions
```
## 3. Create the folder catalog

One Syncthing folder per subscription group, pointed at the **existing** repo
directories (no data migration). For each folder in the GUI:

- **Folder ID**: short stable slug (`software-core`, `training-videos`, ...).
  This is what users see and what `langtechdepot-subscribe` takes as an argument.
  Never change an ID once published.
- **Folder Path**: the existing directory.
- **Folder Type**: **Send Only**.
- **File Watcher**: on (default). The existing website-watcher ingest script
  keeps writing into these directories unchanged; Syncthing picks changes up.

The first scan hashes everything — for a large media folder, start it
off-hours. Later scans are watcher-driven and cheap.

Folders added *after* people register are picked up automatically: the
registration service re-shares the catalog with every active device once a
minute.

### Give every folder a label

The ID is permanent and therefore terse; the **label** is what the user
actually reads when Syncthing offers them the folder, and it is free to change.
Without one, a field user choosing at step 4 sees `Win_everything_en` and has
no way to tell what is in it or whether it is meant for them.

Labels are set here, not in the GUI - the registration service applies them on
every reconcile pass, so they also reach the ~50 devices that registered before
the label existed:

```bash
sudo install -m 644 -o root -g root \
    /path/to/repo/server/labels.example.json /etc/langtechdepot/labels.json
sudo -e /etc/langtechdepot/labels.json   # then write the real words
```

One entry per folder, `{"folder id": "label"}`. A folder with no entry keeps
whatever label it has, so the file can be filled in a few folders at a time. The
service re-reads it within a minute of it changing - no restart, no downtime -
which is deliberate: a label is something you reword once you have seen it on a
real client.

Keep them scannable. The list is the only thing that ever explains the catalog
to a user, so a label should say who the folder is for, and warn about size
where that matters:

```json
"Win_everything_en": "Windows software, English - the whole shelf (large; take it on a good connection)",
"Win_FldWrk_en":     "Windows software, English - fieldwork essentials (smaller; for slow links)"
```

Labels travel to every device the folder is offered to, exactly as device names
do, so treat them as public.

Check it took:

```bash
journalctl -u langtechdepot-register -f | grep -E '\[labels\]|label '
```

## 4. Install the registration service

This is how field machines join. Nothing else admits a device.

```bash
umask 027  # Ensure group read-only access and completely block others
sudo apt update && sudo apt install -y python3-dotenv
sudo mkdir -p /opt/langtechdepot /etc/langtechdepot
sudo cp register.py /opt/langtechdepot/
sudo cp register.env.example /etc/langtechdepot/register.env
sudo chgrp syncthing !$	  # so register.py can read env
sudo chmod 640 !$
sudo $EDITOR !$    # API key, SERVER_ADDRESS, PUBLIC_URL, SMTP

sudo cp langtechdepot-register.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now langtechdepot-register
journalctl -u langtechdepot-register -f
```

Without `SMTP_HOST` the form shows the token on screen instead of mailing it —
usable, but set SMTP if you want a working address on file for each registrant.
Set `AUTO_APPROVE=false` to queue requests for manual approval instead.

Edit the management script, to make sure it has the right folder,
the place to which you copied register.py,
then enable the script:
``` bash
$EDITOR ltd-sync-admin	# check folder of register.py
chmod ug+x !$
# Make a symbolic link to it in /usr/local/bin
ln -s `pwd`/ltd-sync-admin /usr/local/bin/ltd-sync-admin
```

So that the clients' tokens can be backed up,
make sure that the backup script will put them in the right place.
``` bash
$EDITOR token_backup.sh	# check BACKUP_DIR etc
chmod ug+x !$
# Make a symbolic link to it in /usr/local/bin
ln -s `pwd`/token_backup.sh /usr/local/bin/token_backup.sh
BACKUP_DIR=/data/LT/Backup/ClientsHowto	# or wherever you put it
sudo mkdir -p $BACKUP_DIR
ls -lrt $BACKUP_DIR
token_backup.sh
ls -lrt $BACKUP_DIR
```
You should see a new file like register_yyyy-mm-dd_hhmmss.db

Now add a cron line so the backup script runs at 1:30 AM daily.
Copy this line to the clipboard:
```
30 1 * * * /usr/local/bin/token_backup.sh >/dev/null 2>&1
```
Then edit the crontab file for root and paste at the end.
``` bash
sudo crontab -e
```

## 5. Put TLS in front

The service binds to localhost only. 
Caddy is easier to manage than apache, so we'll turn off apache and use caddy.
Caddy terminates TLS and renews the certificate on its own:

```bash
umask 027  # Ensure group read-only access and completely block others
sudo apt install caddy
sudo cp Caddyfile.example /etc/caddy/Caddyfile
sudo $EDITOR /etc/caddy/Caddyfile          # set the real hostname
caddy validate --config /etc/caddy/Caddyfile # fix any errors
sudo systemctl reload caddy
```

So that the tree of folders can be displayed
as well as sync tokens provided,
the Caddyfile sets up this arrangement:

depot.langtech.cloud *gives out tokens*
depot.langtech.cloud/files *displays folders for gettinga single installer*

Requires ports **80 and 443** open and the hostname pointed at this box. Visit
`https://<hostname>/` — you should get the registration form. Put that URL into
`REGISTER_URL` at the top of both client installers before publishing them.

Stop apache2 and disable it, so it won't start again after a reboot:
``` bash
sudo systemctl stop apache2
sudo systemctl disable apache2
```
## 6. Day-to-day administration

```bash
ltd-sync-admin list              # who registered what
ltd-sync-admin list --pending    # awaiting approval
ltd-sync-admin approve <token>   # issue + email it
ltd-sync-admin revoke <email>    # cut a machine off
```

`revoke` removes the device from Syncthing, which is what actually ends access;
the database flag only stops the reconciler from re-adding it. Accepts an
email, a device ID, or a token.

Tokens are single-use and admit one machine. A user with a laptop and a field
desktop registers twice.

## 7. Optional extras

- **Own relay**: `sudo apt install syncthing-relaysrv` if the public relay pool
  proves unreliable for NATed field clients.
- **Monitoring**: per-device sync completion is on the Syncthing GUI front page;
  `GET /rest/db/completion?device=<id>&folder=<id>` if you want a status page.

## 8. Decommission Resilio (after the parallel-run window)

```bash
sudo systemctl stop resilio-sync && sudo systemctl disable resilio-sync
sudo apt remove resilio-sync
```

The repo directories are untouched — Resilio shared them, it never owned them.

