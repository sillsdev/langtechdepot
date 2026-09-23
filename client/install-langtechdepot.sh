#!/usr/bin/env bash
# LangTechDepot installer (Linux).
#
# Installs Syncthing, registers this machine with the LangTechDepot server 
# using the token you were issued, auto-subscribes to All_Contents_List, 
# and lets you choose folders to install or ignore. 
# Idempotent.
# Needs: curl, tar, python3, yad and systemd user session.
#
#   bash install-langtechdepot.sh
#
# No token yet? Register at the URL below and one is emailed to you.

set -euo pipefail

# Path definitions
REGISTER_URL='https://depot.langtech.cloud'
# Where a stuck user is sent. The registration form answers "I have no token";
# it does not answer "it failed", and those are different people.
HELP_URL='https://sillsdev.github.io/langtechdepot/help.html'

DATA_ROOT="$HOME/LangTechDepot"
BIN="$HOME/.local/bin/syncthing"

mkdir -p "$DATA_ROOT" "$HOME/.local/bin"

# Prefer a packaged Syncthing if the machine already has one.
if command -v syncthing >/dev/null 2>&1; then
    BIN=$(command -v syncthing)
elif ! [ -x "$BIN" ]; then
    echo 'Downloading Syncthing...'
    arch=$(uname -m)
    case "$arch" in
        x86_64) st_arch=amd64;; aarch64) st_arch=arm64;; armv7l) st_arch=arm;;
        *) echo "unsupported architecture: $arch" >&2; exit 1;;
    esac
    url=$(curl -fsSL https://api.github.com/repos/syncthing/syncthing/releases/latest |
        python3 -c "import json,sys; print(next(a['browser_download_url'] for a in json.load(sys.stdin)['assets'] if 'linux-$st_arch-' in a['name'] and a['name'].endswith('.tar.gz')))")
    tmp=$(mktemp -d)
    curl -fsSL "$url" | tar -xz -C "$tmp"
    cp "$tmp"/syncthing-*/syncthing "$BIN"
    rm -rf "$tmp"
fi
echo "Using Syncthing at $BIN"

# Pinned with --home rather than left to Syncthing's default, which is not a
# fixed path: Syncthing uses $XDG_CONFIG_HOME/syncthing or ~/.config/syncthing
# when a config.xml already exists in either, and only otherwise falls back to
# the state dir this used to assume. So any machine that has run Syncthing
# before keeps its config where this script would not look, and builds before
# 1.27 (Debian 12 packages 1.23) use ~/.config/syncthing even when fresh -
# either way the API key read below died on a missing file. setup-langtechdepot.ps1
# passes --home on Windows for the same reason.
STATE_HOME="$HOME/.local/state"
case "${XDG_STATE_HOME:-}" in /*) STATE_HOME="$XDG_STATE_HOME";; esac  # Syncthing ignores a relative one
CONFIG_DIR="$STATE_HOME/langtechdepot"

# No --no-default-folder: Syncthing 2.0 removed that flag along with the
# "Default Folder" it used to suppress, so passing it is a hard error
# ("unknown flag --no-default-folder") and nothing is left to suppress.
[ -f "$CONFIG_DIR/config.xml" ] || "$BIN" generate --home "$CONFIG_DIR" >/dev/null

# Syncthing API connection details (adjust GUI_URL and API_KEY if needed)
GUI_URL="http://127.0.0.1:8384"
API_KEY=$(xmlstarlet sel -t -v "//configuration/gui/apikey" "$HOME/.config/syncthing/config.xml" 2>/dev/null || echo "")
SERVER_ID="LangTechDepot Server"

mkdir -p "$CONFIG_DIR"

# Per-user unit: no root needed, and lingering keeps it syncing when logged out.
mkdir -p "$HOME/.config/systemd/user"
cat > "$HOME/.config/systemd/user/langtechdepot.service" <<EOF
[Unit]
Description=LangTechDepot (Syncthing)
After=network.target

[Service]
ExecStart="$BIN" serve --no-browser --home "$CONFIG_DIR"
Restart=on-failure

[Install]
WantedBy=default.target
EOF
systemctl --user daemon-reload
systemctl --user enable --now langtechdepot.service
loginctl enable-linger "$USER" 2>/dev/null || true

# Path passed as an argument, not interpolated into the Python source: it now
# derives from XDG_STATE_HOME, and a backslash or quote in there would
# otherwise be read as Python rather than as a path.
xmlget() { python3 -c "import sys,xml.etree.ElementTree as ET; print(ET.parse(sys.argv[1]).find(sys.argv[2]).text)" "$CONFIG_DIR/config.xml" "$1"; }

API_KEY=$(xmlget ./gui/apikey)

# Syncthing probes for a free port on first start, so the GUI is not always on
# 8384 - a machine already running its own Syncthing pushes ours to another
# port. Read where it actually is instead of assuming, or we would end up
# talking to the other instance.
GUI_URL="http://$(xmlget ./gui/address)"

api() { # api METHOD PATH [JSON]
    curl -fsS -X "$1" -H "X-API-Key: $API_KEY" -H 'Content-Type: application/json' \
        ${3:+-d "$3"} "$GUI_URL$2"
}

echo 'Waiting for Syncthing...'
for _ in $(seq 1 30); do api GET /rest/system/status >/dev/null 2>&1 && break; sleep 2; done
api GET /rest/system/status >/dev/null || {
    echo "Syncthing did not answer at $GUI_URL within 60s." >&2
    echo 'Check: systemctl --user status langtechdepot.service' >&2
    exit 1
}

MY_ID=$(api GET /rest/system/status | python3 -c "import json,sys; print(json.load(sys.stdin)['myID'])")
DEVICE_NAME="$USER-$(hostname -s)"

# Name this device for the cluster. It deliberately carries no token: Syncthing
# broadcasts device names to every peer, so a token here would leak to them all.
api PATCH "/rest/config/devices/$MY_ID" "{\"name\": \"$DEVICE_NAME\"}" >/dev/null

echo
echo "This machine's device ID: $MY_ID"

# -----------------------------------------------------------------------------
# Check if registered specifically with the LangTechDepot Server
# -----------------------------------------------------------------------------
EXISTING_SERVER_ID=$(python3 -c "
import sys, json, urllib.request

gui_url = sys.argv[1]
api_key = sys.argv[2]

try:
    req = urllib.request.Request(f'{gui_url}/rest/config/devices', headers={'X-API-Key': api_key})
    with urllib.request.urlopen(req) as resp:
        devices = json.loads(resp.read().decode('utf-8'))
        for dev in devices:
            # Match specifically on the LangTechDepot Server name
            if dev.get('name') == 'LangTechDepot Server':
                print(dev.get('deviceID', ''))
                break
except Exception:
    pass
" "$GUI_URL" "$API_KEY")

if [ -n "$EXISTING_SERVER_ID" ]; then
    echo "Already registered with LangTechDepot Server."
    SERVER_ID="$EXISTING_SERVER_ID"
else
    # Not yet registered with LangTechDepot -> Prompt for token
    echo "No token yet? Register at $REGISTER_URL"
    echo

    RESPONSE=''
    for attempt in 1 2 3; do
	read -r -p 'Paste your LangTechDepot token: ' TOKEN
	TOKEN=$(printf '%s' "$TOKEN" | tr -d '[:space:]')
	[ -n "$TOKEN" ] || { echo 'Nothing entered.'; continue; }

	if RESPONSE=$(curl -fsS -X POST -H 'Content-Type: application/json' \
	    -d "{\"token\":\"$TOKEN\",\"deviceID\":\"$MY_ID\",\"deviceName\":\"$DEVICE_NAME\"}" \
	    "$REGISTER_URL/register" 2>/dev/null); then
	    echo
	    echo 'Registered.'
	    break
	fi

	# curl -f swallows the body on 4xx, so ask again without it for the reason.
	REASON=$(curl -sS -X POST -H 'Content-Type: application/json' \
	    -d "{\"token\":\"$TOKEN\",\"deviceID\":\"$MY_ID\",\"deviceName\":\"$DEVICE_NAME\"}" \
	    "$REGISTER_URL/register" 2>/dev/null |
	    python3 -c "import json,sys; print(json.load(sys.stdin).get('error','registration failed'))" 2>/dev/null || echo 'could not reach the registration server')
	echo "Registration failed: $REASON"
	RESPONSE=''
	[ "$attempt" -lt 3 ] && echo 'Try again.'
    done

    if [ -z "$RESPONSE" ]; then
	echo
	echo "Giving up after 3 attempts. Syncthing is installed and running; re-run this"
	echo "script once you have a working token. Ask for help at $HELP_URL"
	exit 1
    fi

    # The server tells us its own identity, so nothing about it is hardcoded here.
    # Extract server ID and register the server device in Syncthing
    SERVER_ID=$(printf '%s' "$RESPONSE" | python3 -c "import json,sys; print(json.load(sys.stdin)['serverDeviceID'])")
    SERVER_ADDRS=$(printf '%s' "$RESPONSE" | python3 -c "import json,sys; print(json.dumps(json.load(sys.stdin)['serverAddresses']))")

    # introducer=true: the server introduces us to other field machines, so they
    # swarm with each other instead of every download crossing the ocean.
    api POST /rest/config/devices "{
      \"deviceID\": \"$SERVER_ID\",
      \"name\": \"LangTechDepot Server\",
      \"addresses\": $SERVER_ADDRS,
      \"introducer\": true
    }" >/dev/null 2>&1 || true
fi

# Receive-only: a stray local edit gets flagged and reverted, never propagated.
api PATCH /rest/config/defaults/folder "{\"type\": \"receiveonly\", \"path\": \"$DATA_ROOT\"}" >/dev/null

# -----------------------------------------------------------------------------
# AUTO-SUBSCRIBE: All_Contents_List
# -----------------------------------------------------------------------------
#
# Variables for the repo contents list that we auto-install
#
AUTO_FOLDER_ID="All_Contents_List"
AUTO_FOLDER_PATH="$DATA_ROOT/$AUTO_FOLDER_ID"
CATALOG_FILE="$AUTO_FOLDER_PATH/LangTechDepotFiles.txt"

echo "Subscribing to $AUTO_FOLDER_ID, which contains a list"
echo "of all the files available in the Depot"
echo "and the size of each folder you can subscribe to ..."
echo " "
sleep 4
mkdir -p "$AUTO_FOLDER_PATH"

api POST /rest/config/folders "{
  \"id\": \"$AUTO_FOLDER_ID\",
  \"label\": \"All_Contents_List -- a list of all files available\",
  \"path\": \"$AUTO_FOLDER_PATH\",
  \"type\": \"receiveonly\",
  \"rescanIntervalS\": 3600,
  \"fsWatcherEnabled\": true,
  \"devices\": [{\"deviceID\": \"$SERVER_ID\"}]
}" >/dev/null 2>&1 || true

echo "Sync data root: $DATA_ROOT"
echo "Automatically subscribed to: $AUTO_FOLDER_ID"
echo 'The folder catalog will appear within a minute or two.'
echo " "
sleep 4

# Now to display the folders available, with checkboxes.
# Clicking a checkbox will subscribe to that folder, while
# leaving one unchecked will ignore that folder.
# (Ignored folders can be unignored later, using the SyncThing GUI.)

echo "Waiting for catalog file to sync from server..."
while [ ! -s "$CATALOG_FILE" ]; do
    sleep 2
done

# Filters out header/footer text, blank lines, and previously ignored folders
# Extract folder lines using Python (Single Checkbox, Default: FALSE)
# Generates EXACTLY 4 items per folder row for YAD
#
YAD_INPUT=$(python3 -c "
import re, sys, json, urllib.request

catalog_path = sys.argv[1]
gui_url = sys.argv[2]
api_key = sys.argv[3]
server_id = sys.argv[4]

# Fetch Syncthing's live ignored folders straight from the running instance
ignored = set()
try:
    # Fetch device configuration for the remote server
    req = urllib.request.Request(
        f'{gui_url}/rest/config/devices/{server_id}',
        headers={'X-API-Key': api_key}
    )
    with urllib.request.urlopen(req) as resp:
        dev_cfg = json.loads(resp.read().decode('utf-8'))
        for item in dev_cfg.get('ignoredFolders', []):
            if isinstance(item, dict) and 'id' in item:
                ignored.add(item['id'])
except Exception:
    pass

in_folders_section = False

with open(catalog_path, 'r') as f:
    for line in f:
        line = line.strip()

        if 'Folders available, with their sizes' in line:
            in_folders_section = True
            continue

        if 'Individual files available' in line:
            break

        if not in_folders_section or not line:
            continue

        # Match Size, Folder_ID, and Description in double quotes
        match = re.match(r'^\s*(\S+)\s+(\S+)\s+\"(.*)\"\s*$', line)
        if match:
            size, fid, desc = match.groups()
            # Only display folders that are NOT currently in Syncthing's live ignore list
            if fid not in ignored:
                print('FALSE')   # Subscribe (+) Checkbox, Default unchecked (-)
                print(size)      # Size column
                print(fid)       # Folder ID column
                print(desc)      # Description column
" "$CATALOG_FILE" "$GUI_URL" "$API_KEY" "$SERVER_ID")

if [ -z "$YAD_INPUT" ]; then
    echo "No new folders available to display."
    exit 0
fi

# Temp file to reliably store YAD output across multi-line selections
SELECTIONS_FILE=$(mktemp)

# Display YAD table with a single Subscribe (+) checkbox
# and with high-visibility warning banner
# Render YAD with --print-all to capture EVERY row state cleanly
echo "$YAD_INPUT" | yad --list \
    --title="LangTechDepot - Available Folders" \
    --text="Check (+) the folders you want to sync. <span foreground='white' background='red'><b> NOTE: All unchecked folders will be IGNORED (-) </b></span>" \
    --column="Subscribe (+):CHK" \
    --column="Size" \
    --column="Folder ID" \
    --column="Description" \
    --button="Apply:0" \
    --button="Cancel:1" \
    --width=780 --height=450 \
    --separator="|" \
    --print-all > "$SELECTIONS_FILE" || true

# If user cancels or closes window without selections, exit cleanly
if [ ! -s "$SELECTIONS_FILE" ]; then
    rm -f "$SELECTIONS_FILE"
    echo "Operation cancelled."
    exit 0
fi

# Process the results via file reading to prevent shell variable truncation
# Process choices: Checked = Subscribe, Unchecked = Ignore
python3 -c "
import sys, json, urllib.request, datetime

selections_file = sys.argv[1]
data_root = sys.argv[2]
server_id = sys.argv[3]
gui_url = sys.argv[4]
api_key = sys.argv[5]

with open(selections_file, 'r') as f:
    lines = [line.strip() for line in f if line.strip()]

for line in lines:
    parts = line.split('|')
    if len(parts) >= 4:
        sub_check = parts[0].upper()
        size = parts[1]
        fid = parts[2]
        desc = parts[3]

        # -------------------------------------------------------------
        # 1. SUBSCRIBE (+): Replicates clicking "Add" in the Web GUI
        # -------------------------------------------------------------
        if sub_check == 'TRUE':
            folder_path = f'{data_root}/{fid}'
            folder_payload = json.dumps({
                'id': fid,
                'label': desc,
                'path': folder_path,
                'type': 'receiveonly',
                'rescanIntervalS': 3600,
                'fsWatcherEnabled': True,
                'devices': [{'deviceID': server_id}]
            }).encode('utf-8')

            req = urllib.request.Request(
                f'{gui_url}/rest/config/folders',
                data=folder_payload,
                headers={'X-API-Key': api_key, 'Content-Type': 'application/json'},
                method='POST'
            )
            try:
                urllib.request.urlopen(req)
                print(f'Successfully subscribed to: {fid}')
            except Exception as e:
                print(f'Failed to subscribe to {fid}: {e}')

        # -------------------------------------------------------------
        # 2. IGNORE (-): Attach ignoredFolder to the remote device object
        # 		 Replicates clicking "Ignore" in the Web GUI
        # -------------------------------------------------------------
        else:
            # 2. Update Syncthing ignored-folders array via /rest/config
            try:
                # 1. Fetch current device configuration
                dev_req = urllib.request.Request(
                    f'{gui_url}/rest/config/devices/{server_id}',
                    headers={'X-API-Key': api_key}
                )
                with urllib.request.urlopen(dev_req) as resp:
                    dev_config = json.loads(resp.read().decode('utf-8'))

                # Ensure defaults and ignoredFolders structures exist
                defaults = dev_config.get('defaults', {})
                cur_ignores = dev_config.get('ignoredFolders', [])

                already_exists = any(
                    item.get('id') == fid for item in cur_ignores if isinstance(item, dict)
                )

                if not already_exists:
                    now_str = datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%S.%f')[:-3] + 'Z'
                    cur_ignores.append({
                        'id': fid,
                        'label': desc,
                        'time': now_str
                    })

                    dev_config['ignoredFolders'] = cur_ignores

                    # 2. PUT updated device config back to Syncthing
                    put_req = urllib.request.Request(
                        f'{gui_url}/rest/config/devices/{server_id}',
                        data=json.dumps(dev_config).encode('utf-8'),
                        headers={'X-API-Key': api_key, 'Content-Type': 'application/json'},
                        method='PUT'
                    )
                    urllib.request.urlopen(put_req)
                    print(f'Successfully ignored folder via API: {fid}')
                else:
                    print(f'Folder already marked as ignored: {fid}')

            except Exception as e:
                print(f'Warning: Could not ignore {fid} via API: {e}')
" "$SELECTIONS_FILE" "$DATA_ROOT" "$SERVER_ID" "$GUI_URL" "$API_KEY"

rm -f "$SELECTIONS_FILE"

echo " "
echo "If you later need to manage the SyncThing system directly,"
echo "open $GUI_URL."
echo "Then if you want to unignore a folder,"
echo "open the Actions menu at the top-right, click Settings"
echo "and then Ignored Folders."
echo "Then you can click Add on any additional folders you want."

# echo 'or run: ./langtechdepot-subscribe.sh            (list what is on offer)'
# echo '        ./langtechdepot-subscribe.sh <folder>   (subscribe to one)'
