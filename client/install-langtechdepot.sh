#!/usr/bin/env bash
# LangTechDepot installer (Linux).
#
# Installs Syncthing, registers this machine with the LangTechDepot server using the
# token you were issued, and leaves you at the folder catalog. Idempotent.
# Needs: curl, tar, python3, systemd user session.
#
#   bash install-langtechdepot.sh
#
# No token yet? Register at the URL below and one is emailed to you.

set -euo pipefail

REGISTER_URL='https://depot.langtech.cloud'

DATA_ROOT="$HOME/LangTechDepot"
GUI_URL='http://127.0.0.1:8384'
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

CONFIG_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/syncthing"
# No --no-default-folder: Syncthing 2.0 removed that flag along with the
# "Default Folder" it used to suppress, so passing it is a hard error
# ("unknown flag --no-default-folder") and nothing is left to suppress.
[ -f "$CONFIG_DIR/config.xml" ] || "$BIN" generate >/dev/null

# Per-user unit: no root needed, and lingering keeps it syncing when logged out.
mkdir -p "$HOME/.config/systemd/user"
cat > "$HOME/.config/systemd/user/langtechdepot.service" <<EOF
[Unit]
Description=LangTechDepot (Syncthing)
After=network.target

[Service]
ExecStart=$BIN serve --no-browser
Restart=on-failure

[Install]
WantedBy=default.target
EOF
systemctl --user daemon-reload
systemctl --user enable --now langtechdepot.service
loginctl enable-linger "$USER" 2>/dev/null || true

API_KEY=$(python3 -c "import xml.etree.ElementTree as ET; print(ET.parse('$CONFIG_DIR/config.xml').find('./gui/apikey').text)")

api() { # api METHOD PATH [JSON]
    curl -fsS -X "$1" -H "X-API-Key: $API_KEY" -H 'Content-Type: application/json' \
        ${3:+-d "$3"} "$GUI_URL$2"
}

echo 'Waiting for Syncthing...'
for _ in $(seq 1 30); do api GET /rest/system/status >/dev/null 2>&1 && break; sleep 2; done
api GET /rest/system/status >/dev/null || { echo 'Syncthing did not start.' >&2; exit 1; }

MY_ID=$(api GET /rest/system/status | python3 -c "import json,sys; print(json.load(sys.stdin)['myID'])")
DEVICE_NAME="$USER-$(hostname -s)"

# Name this device for the cluster. It deliberately carries no token: Syncthing
# broadcasts device names to every peer, so a token here would leak to them all.
api PATCH "/rest/config/devices/$MY_ID" "{\"name\": \"$DEVICE_NAME\"}" >/dev/null

echo
echo "This machine's device ID: $MY_ID"
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
    echo "script once you have a working token. Ask for help at $REGISTER_URL"
    exit 1
fi

# The server tells us its own identity, so nothing about it is hardcoded here.
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

# Receive-only: a stray local edit gets flagged and reverted, never propagated.
api PATCH /rest/config/defaults/folder "{\"type\": \"receiveonly\", \"path\": \"$DATA_ROOT\"}" >/dev/null

echo
echo 'Registered.'
echo "Sync data root: $DATA_ROOT"
echo 'The folder catalog will appear within a minute or two.'
echo "Open $GUI_URL and click Add on the folders you want,"
echo 'or run: ./langtechdepot-subscribe.sh            (list what is on offer)'
echo '        ./langtechdepot-subscribe.sh <folder>   (subscribe to one)'
