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

# The folder picker is a yad window. Checked here, before anything is installed
# or a token is spent: missing yad used to surface only at the picker, after
# registration, as "Operation cancelled." and exit 0.
if ! command -v yad >/dev/null 2>&1; then
    cat >&2 <<EOF
This computer is missing yad, which the installer needs to show the list of
folders. Nothing has been installed and your token has not been used.

Whoever looks after this computer can add it (on Ubuntu, Debian or Mint:
sudo apt install yad). Then paste the same command again.

Help: $HELP_URL
EOF
    exit 1
fi

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

SERVER_NAME="LangTechDepot Server"
SERVER_ID=""

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
# What people are shown: same page, but "localhost" reads better than 127.0.0.1.
# The API calls keep using GUI_URL.
GUI_PAGE="${GUI_URL/127.0.0.1/localhost}"

api() { # api METHOD PATH [JSON]
    curl -fsS -X "$1" -H "X-API-Key: $API_KEY" -H 'Content-Type: application/json' \
        ${3:+-d "$3"} "$GUI_URL$2"
}

echo 'Waiting for Syncthing...'
for _ in $(seq 1 30); do api GET /rest/system/status >/dev/null 2>&1 && break; sleep 2; done
api GET /rest/system/status >/dev/null || {
    echo "Syncthing did not answer at $GUI_PAGE within 60s." >&2
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
server_name = sys.argv[3]

try:
    req = urllib.request.Request(f'{gui_url}/rest/config/devices', headers={'X-API-Key': api_key})
    with urllib.request.urlopen(req) as resp:
        devices = json.loads(resp.read().decode('utf-8'))
        for dev in devices:
            # Match specifically on the LangTechDepot Server plain-text name
            if dev.get('name') == server_name:
                print(dev.get('deviceID', ''))
                break
except Exception:
    pass
" "$GUI_URL" "$API_KEY" "$SERVER_NAME")

if [ -n "$EXISTING_SERVER_ID" ]; then
    echo "Already registered with $SERVER_NAME."
    SERVER_ID="$EXISTING_SERVER_ID"
    sleep 3
    echo " "
else
    # Not yet registered with LangTechDepot -> Prompt for token
    echo "No token yet? Register at $REGISTER_URL"
    echo

    RESPONSE=''
    for attempt in 1 2 3; do
        echo "(In a terminal, paste with Ctrl+Shift+V, or right-click and choose Paste.)"
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
      \"name\": \"$SERVER_NAME\",
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

# -----------------------------------------------------------------------------
# Wait for the catalog, then show the folder list
# -----------------------------------------------------------------------------
# Not forever: a first sync that stalls (firewall, captive portal, server
# down) used to hang here silently. Same limit and advice as Windows.
echo "Waiting for catalog file to sync from server..."
CATALOG_WAITED=0
while [ ! -s "$CATALOG_FILE" ]; do
    sleep 2
    CATALOG_WAITED=$((CATALOG_WAITED + 2))
    if [ "$CATALOG_WAITED" -ge 180 ]; then
        echo
        echo "Still waiting for the folder catalog after 180 seconds."
        echo "Syncthing is running, but hasn't finished syncing $AUTO_FOLDER_ID from the server yet."
        echo "Open $GUI_PAGE and check the Folders list and any red or yellow notices there."
        echo "Syncthing will keep running in the background - once $AUTO_FOLDER_ID shows"
        echo "'Up to Date' there, just run this installer again to pick your folders."
        exit 1
    fi
done

# One Python helper does the list's bookkeeping; the shell only drives yad.
#   rows   STATE SHOW_IGNORED     -> yad input: tick, Now, Size, ID, Description
#   state  SELECTIONS MODE        -> STATE file from yad's --print-all output;
#                                    MODE keep | all | none
#   apply  SELECTIONS DATA_ROOT   -> subscribe / ignore / un-ignore in Syncthing
# Rules, the same as the Windows installer:
#  - The list opens as things are: subscribed folders ticked. (It used to open
#    all unticked, and unticked means ignore, so a re-run plus Apply dropped
#    every folder the user had.)
#  - All_Contents_List is not listed: the installer needs it, so it is always
#    kept, and a tick box that does nothing only confused people.
#  - Ignored folders are held back until "Also display ignored folders";
#    ticking one then un-ignores it. Folders never shown are left alone.
#  - Ignoring changes only the server device's ignoredFolders field (PATCH),
#    not the whole device object (GET + PUT), so a concurrent change to the
#    device cannot be overwritten.
PICKER_PY=$(cat <<'PY'
import json, re, sys, urllib.request, urllib.error, datetime

def api(method, path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(GUI + path, data=data, method=method,
                                 headers={'X-API-Key': KEY, 'Content-Type': 'application/json'})
    with urllib.request.urlopen(req) as r:
        raw = r.read()
        return json.loads(raw) if raw.strip() else None

def subscribed():
    return {f['id'] for f in (api('GET', '/rest/config/folders') or []) if f.get('id')}

def ignored_list():
    dev = api('GET', '/rest/config/devices/' + SERVER) or {}
    return [i for i in (dev.get('ignoredFolders') or []) if isinstance(i, dict) and i.get('id')]

def catalog():
    out, inside = [], False
    with open(CATALOG, encoding='utf-8', errors='replace') as f:
        for line in f:
            line = line.strip()
            if 'Folders available, with their sizes' in line:
                inside = True; continue
            if 'Individual files available' in line:
                break
            if not inside or not line:
                continue
            m = re.match(r'^\s*(\S+)\s+(\S+?)\s*"(.*)"\s*$', line)
            if m:
                out.append({'size': m.group(1), 'id': m.group(2), 'desc': m.group(3)})
    if not any(e['id'] == ALWAYS for e in out):
        out.insert(0, {'size': '', 'id': ALWAYS, 'desc': 'A list of all files available'})
    return out

def read_state(path):
    st = {}
    try:
        with open(path, encoding='utf-8') as f:
            for line in f:
                fid, _, val = line.rstrip('\n').partition(' ')
                if fid: st[fid] = (val == 'TRUE')
    except FileNotFoundError:
        pass
    return st

def read_selections(path):
    rows = []
    with open(path, encoding='utf-8') as f:
        for line in f:
            parts = line.rstrip('\n').split('|')
            if len(parts) >= 5 and parts[3]:
                rows.append({'tick': parts[0].upper() == 'TRUE', 'now': parts[1], 'id': parts[3], 'desc': parts[4]})
    return rows

cmd = sys.argv[1]
GUI, KEY, SERVER, CATALOG, ALWAYS = sys.argv[2:7]
args = sys.argv[7:]

if cmd == 'rows':
    state_path, show_ignored = args[0], args[1] == '1'
    state = read_state(state_path)
    subs = subscribed()
    ign = {i['id'] for i in ignored_list()}
    hidden = 0
    for e in catalog():
        fid = e['id']
        if fid == ALWAYS:
            continue   # always kept; not offered as a choice
        now = 'subscribed' if fid in subs else 'ignored' if fid in ign else 'new'
        if now == 'ignored' and not show_ignored:
            hidden += 1; continue
        tick = state.get(fid, fid in subs)
        for v in ('TRUE' if tick else 'FALSE', now, e['size'], fid, e['desc']):
            print(v)
    sys.stderr.write(str(hidden) + '\n')   # how many ignored folders are held back

elif cmd == 'state':
    sel_path, mode, state_path = args[0], args[1], args[2]
    state = read_state(state_path)
    for r in read_selections(sel_path):
        t = r['tick'] if mode == 'keep' else (mode == 'all')
        state[r['id']] = True if r['id'] == ALWAYS else t
    with open(state_path, 'w', encoding='utf-8') as f:
        for fid, t in state.items():
            f.write(f"{fid} {'TRUE' if t else 'FALSE'}\n")

elif cmd == 'apply':
    sel_path, data_root = args[0], args[1]
    try:
        subs = subscribed()
    except Exception as e:
        print(f'Warning: could not fetch the active folders list: {e}'); subs = set()
    failures = 0
    def set_ignored(fid, label, ignore):
        cur = ignored_list()
        has = any(i['id'] == fid for i in cur)
        if ignore and not has:
            now = datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%S.%f')[:-3] + 'Z'
            cur.append({'id': fid, 'label': label, 'time': now})
        elif not ignore and has:
            cur = [i for i in cur if i['id'] != fid]
        else:
            return False
        api('PATCH', '/rest/config/devices/' + SERVER, {'ignoredFolders': cur})
        return True
    for r in read_selections(sel_path):
        fid, desc = r['id'], r['desc']
        if fid == ALWAYS:
            continue   # never listed, but never act on it either
        try:
            if r['tick']:
                if fid in subs:
                    print(f'Already subscribed to: {fid}')
                else:
                    api('POST', '/rest/config/folders', {
                        'id': fid, 'label': desc, 'path': f'{data_root}/{fid}',
                        'type': 'receiveonly', 'rescanIntervalS': 3600, 'fsWatcherEnabled': True,
                        'devices': [{'deviceID': SERVER, 'encryptionPassword': ''}]})
                    print(f'Successfully subscribed to: {fid}')
                if set_ignored(fid, desc, False):
                    print(f'No longer ignoring: {fid}')
            else:
                if fid in subs:
                    api('DELETE', '/rest/config/folders/' + fid)
                    print(f'Removed active subscription for: {fid}')
                if set_ignored(fid, desc, True):
                    print(f'Successfully ignored folder via API: {fid}')
                else:
                    print(f'Folder already marked as ignored: {fid}')
        except Exception as e:
            failures += 1
            print(f'Failed to update {fid}: {e}')
    sys.exit(1 if failures else 0)
PY
)
picker() { python3 -c "$PICKER_PY" "$1" "$GUI_URL" "$API_KEY" "$SERVER_ID" "$CATALOG_FILE" "$AUTO_FOLDER_ID" "${@:2}"; }

YAD_TEMP_INPUT=$(mktemp)
SELECTIONS_FILE=$(mktemp)
PICK_STATE=$(mktemp)
HIDDEN_COUNT_FILE=$(mktemp)
trap 'rm -f "$YAD_TEMP_INPUT" "$SELECTIONS_FILE" "$PICK_STATE" "$HIDDEN_COUNT_FILE"' EXIT
SHOW_IGNORED=0

while true; do
    picker rows "$PICK_STATE" "$SHOW_IGNORED" > "$YAD_TEMP_INPUT" 2> "$HIDDEN_COUNT_FILE"
    HIDDEN=$(tr -dc '0-9' < "$HIDDEN_COUNT_FILE"); HIDDEN=${HIDDEN:-0}

    # The extra button only while there is something for it to show.
    IGNORED_BUTTON=()
    if [ "$SHOW_IGNORED" = 0 ] && [ "$HIDDEN" -gt 0 ]; then
        IGNORED_BUTTON=(--button="Also display ignored folders":14)
    fi

    # Buttons: Select All 10, Clear All 12, Also display ignored 14 - each
    # redraws the list keeping the ticks made so far - Apply 0, Cancel 1.
    # The numbers must be EVEN: yad prints the list only for even exit codes,
    # so an odd one (Clear All was 11) loses the ticks and does nothing.
    set +e
    yad --list \
        --title="LangTechDepot - Available Folders" \
        --text="Check (+) the folders you want to sync. <span foreground='white' background='red'><b> NOTE: All unchecked folders will be IGNORED (-) </b></span>\n(The list of everything available, $AUTO_FOLDER_ID, is always kept.)" \
        --column="Subscribe (+):CHK" \
        --column="Now" \
        --column="Size" \
        --column="Folder ID" \
        --column="Description" \
        --button="Select All":10 \
        --button="Clear All":12 \
        "${IGNORED_BUTTON[@]}" \
        --button="Apply":0 \
        --button="Cancel":1 \
        --width=820 --height=450 \
        --separator="|" \
        --print-all < "$YAD_TEMP_INPUT" > "$SELECTIONS_FILE"
    EXIT_CODE=$?
    set -e

    case "$EXIT_CODE" in
        10) picker state "$SELECTIONS_FILE" all  "$PICK_STATE" ;;
        12) picker state "$SELECTIONS_FILE" none "$PICK_STATE" ;;
        14) picker state "$SELECTIONS_FILE" keep "$PICK_STATE"; SHOW_IGNORED=1 ;;
        0)  break ;;
        *)  echo "Operation cancelled."; exit 0 ;;
    esac
done

if [ ! -s "$SELECTIONS_FILE" ]; then
    echo "Operation cancelled."
    exit 0
fi

picker apply "$SELECTIONS_FILE" "$DATA_ROOT" || echo "Some changes failed - see above."

echo " "
echo "To add more folders later, or take back one you ignored,"
echo "just run this installer again. In the folder list, click"
echo "'Also display ignored folders' to see the ones you ignored."
echo " "
echo "If you ever need to manage Syncthing directly, open $GUI_PAGE."
