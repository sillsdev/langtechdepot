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
sudo chgrp -R syncthing -- * .[!.]*   # not .* : on older bash that matches .. too
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

- **Folder ID**: short stable slug (`Android_apps`, `Win_everything_en`, ...).
  This is what users see and what `modify-langtechdepot` (Windows) and
  `langtechdepot-subscribe` (Linux) take as an argument.
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

**`All_Contents_List` must be one of them** (and in `CATALOG_FOLDERS`, if that
is set). Both installers subscribe to it first and build their folder list
from the `LangTechDepotFiles.txt` inside it; without it both installers give
up after three minutes and send the user to Syncthing's page.
A folder that is missing from that file's *Folders available, with their
sizes* section never appears in the installers' list at all, however it is
shared — so a new folder goes live for users when the file is regenerated, not
when it is shared.

## 4. Install the registration service

This is how field machines join. Nothing else admits a device.

```bash
umask 027  # Ensure group read-only access and completely block others
sudo apt update && sudo apt install -y python3-dotenv sqlite3
sudo mkdir -p /opt/langtechdepot /etc/langtechdepot
sudo cp register.py /opt/langtechdepot/
sudo cp register.env.example /etc/langtechdepot/register.env
sudo chgrp syncthing !$	  # so register.py can read env
sudo chmod 640 !$
sudo $EDITOR !$    # API key (Syncthing GUI: Actions > Settings > API Key), SERVER_ADDRESS, SMTP

sudo cp langtechdepot-register.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now langtechdepot-register
journalctl -u langtechdepot-register -f
```

Requests wait for approval (`AUTO_APPROVE=false`, the default): `ADMIN_EMAIL`
gets each one with the exact `ltd-sync-admin approve <token>` command, and
approving emails the token from `depot@langtech.cloud`. Mail is therefore not
optional — fill in `SMTP_PASS`. Keep approval on while clients use introducer
mode; see "The guard" in §6.

Edit the management script, to make sure it has the right folder,
the place to which you copied register.py,
then enable the script:
``` bash
$EDITOR ltd-sync-admin	# check folder of register.py
# Install a root-owned copy (not a symlink into this checkout: whoever can edit
# the checkout would then choose what runs under your sudo). Re-run after edits.
sudo install -o root -g root -m 755 ltd-sync-admin /usr/local/bin/
```

So that the clients' tokens can be backed up,
make sure that the backup script will put them in the right place.
``` bash
$EDITOR token_backup.sh	# check BACKUP_DIR; the script uses its own value
# Install a root-owned copy in /usr/local/bin. Not a symlink: root's cron runs
# it, so a link into your checkout would let anyone who can edit the checkout
# run commands as root. Re-run this line after every edit to token_backup.sh.
sudo install -o root -g root -m 755 token_backup.sh /usr/local/bin/
BACKUP_DIR=/data/LT/Backups/ClientsHowto	# must match BACKUP_DIR in the script
sudo mkdir -p $BACKUP_DIR
sudo ls -lrt $BACKUP_DIR
sudo token_backup.sh	# cron runs it as root, so test it as root
sudo ls -lrt $BACKUP_DIR
```
You should see a new file like register_yyyy-mm-dd_hhmmss.db

Now add a cron line so the backup script runs at 1:30 AM daily.
Copy this line to the clipboard:
```
30 1 * * * /usr/local/bin/token_backup.sh
```
Then edit the crontab file for root and paste at the end.
``` bash
sudo crontab -e
```
The script logs every run, and every failure, to the journal; check it with
``` bash
journalctl -t token_backup
```

## 5. Put TLS in front

The service binds to localhost only. 
Caddy is easier to manage than apache, so we'll turn off apache and use caddy.
Caddy terminates TLS and renews the certificate on its own.

Stop apache2 first and disable it, so it won't start again after a reboot —
Caddy cannot take ports 80 and 443 while Apache holds them:
``` bash
sudo systemctl stop apache2
sudo systemctl disable apache2
```

Then install Caddy:

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
depot.langtech.cloud/files *displays folders for getting a single installer*

Requires ports **80 and 443** open and the hostname pointed at this box. Visit
`https://<hostname>/` — you should get the registration form. Both client
installers already carry this URL in `REGISTER_URL`; change it there only if
the hostname ever changes.
## 6. Day-to-day administration

```bash
ltd-sync-admin list              # who registered what
ltd-sync-admin list --pending    # awaiting approval
ltd-sync-admin approve <token>   # issue + email it
ltd-sync-admin revoke <email>    # cut a machine off
ltd-sync-admin restore <device>  # re-admit a device the guard cut off
```

Before approving, check the request is a real person: every approved device
is introduced to every field machine.

`revoke` removes the device from Syncthing, which is what actually ends access;
the database flag only stops the reconciler from re-adding it. Accepts an
email, a device ID, or a token.

Tokens are single-use and admit one machine. A user with a laptop and a field
desktop registers twice.

### The guard

Field machines sync from each other as well as from this server (introducer
mode), and a receive-only folder accepts newer files from any device it shares
with. So the registration service watches every catalog folder: since they are
Send Only here, anything the server "needs" was changed by another device. It
cuts that device off — which also removes it from every field machine — makes
the server's copy the newest again (Override), and mails `ADMIN_EMAIL`. Watch
for it with `journalctl -u langtechdepot-register | grep guard`.

If the device was an honest user who switched a folder to Send & Receive, have
them set it back to Receive Only, then `ltd-sync-admin restore <device-id>`.

**Deploy it in report mode first.** `register.env.example` ships
`GUARD_MODE=report`: for a day the guard only logs and mails what it *would*
do. A machine set up by an early installer may still have a Send & Receive
folder; that shows up here instead of being cut off. Sort those out, then set
`GUARD_MODE=enforce` and restart the service.

**Test it once in enforce mode:** on a test field machine, set one folder to
Send & Receive, change a small file in it, and within a minute expect the
guard's mail, the device gone from the server's Remote Devices, and the file
back to the server's version on other machines. Then restore the test machine.

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

