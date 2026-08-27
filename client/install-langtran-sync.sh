#!/usr/bin/env bash
# LangTran Sync installer (Linux).
#
# Installs Syncthing, runs it as a per-user systemd service, connects it to
# the LangTran server, and prints the GUI URL so the user can pick folders.
# Idempotent: safe to re-run. Needs: curl, tar, python3, systemd (user session).
#
#   bash install-langtran-sync.sh

set -euo pipefail

# ---- Fill these in after the server is stood up ------------------------------
SERVER_DEVICE_ID='REPLACE-WITH-SERVER-DEVICE-ID'
SERVER_ADDRESS='tcp://sync.lingtransoft.info:22000'
JOIN_TOKEN='REPLACE-WITH-JOIN-TOKEN'
# ------------------------------------------------------------------------------

DATA_ROOT="$HOME/LangTran"
GUI_URL='http://127.0.0.1:8384'
BIN="$HOME/.local/bin/syncthing"

case "$SERVER_DEVICE_ID$JOIN_TOKEN" in *REPLACE-*)
    echo 'Edit SERVER_DEVICE_ID / JOIN_TOKEN at the top of this script first.' >&2; exit 1;;
esac

mkdir -p "$DATA_ROOT" "$HOME/.local/bin"

if ! [ -x "$BIN" ]; then
    echo 'Downloading latest Syncthing release...'
    arch=$(uname -m); case "$arch" in x86_64) st_arch=amd64;; aarch64) st_arch=arm64;; armv7l) st_arch=arm;; *) echo "unsupported arch $arch" >&2; exit 1;; esac
    url=$(curl -fsSL https://api.github.com/repos/syncthing/syncthing/releases/latest |
        python3 -c "import json,sys; print(next(a['browser_download_url'] for a in json.load(sys.stdin)['assets'] if 'linux-$st_arch-' in a['name'] and a['name'].endswith('.tar.gz')))")
    tmp=$(mktemp -d)
    curl -fsSL "$url" | tar -xz -C "$tmp"
    cp "$tmp"/syncthing-*/syncthing "$BIN"
    rm -rf "$tmp"
fi

CONFIG_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/syncthing"
[ -f "$CONFIG_DIR/config.xml" ] || "$BIN" generate --no-default-folder >/dev/null

# Per-user systemd unit so no root is needed and it survives logout.
mkdir -p "$HOME/.config/systemd/user"
cat > "$HOME/.config/systemd/user/langtran-sync.service" <<EOF
[Unit]
Description=LangTran Sync (Syncthing)
After=network.target

[Service]
ExecStart=$BIN serve --no-browser
Restart=on-failure

[Install]
WantedBy=default.target
EOF
systemctl --user daemon-reload
systemctl --user enable --now langtran-sync.service
loginctl enable-linger "$USER" 2>/dev/null || true  # keep syncing when logged out

API_KEY=$(python3 -c "import xml.etree.ElementTree as ET; print(ET.parse('$CONFIG_DIR/config.xml').find('./gui/apikey').text)")

api() { # api METHOD PATH [JSON]
    curl -fsS -X "$1" -H "X-API-Key: $API_KEY" -H 'Content-Type: application/json' \
        ${3:+-d "$3"} "$GUI_URL$2"
}

echo 'Waiting for Syncthing API...'
for i in $(seq 1 30); do api GET /rest/system/status >/dev/null 2>&1 && break; sleep 2; done

MY_ID=$(api GET /rest/system/status | python3 -c "import json,sys; print(json.load(sys.stdin)['myID'])")

# Name embeds the join token — the server's auto-accept poller keys on it.
api PATCH "/rest/config/devices/$MY_ID" "{\"name\": \"LT-$JOIN_TOKEN-$USER-$(hostname -s)\"}" >/dev/null

# Server device: introducer=true makes this client auto-learn its peers → swarm.
api POST /rest/config/devices "{
  \"deviceID\": \"$SERVER_DEVICE_ID\",
  \"name\": \"LangTran Server\",
  \"addresses\": [\"dynamic\", \"$SERVER_ADDRESS\"],
  \"introducer\": true
}" >/dev/null

# Folders accepted later default to receive-only under the LangTran data root.
api PATCH /rest/config/defaults/folder "{\"type\": \"receiveonly\", \"path\": \"$DATA_ROOT\"}" >/dev/null

echo
echo "Installed. Device ID: $MY_ID"
echo "Sync data root: $DATA_ROOT"
echo 'Within a minute or two the server will offer the folder catalog.'
echo "Open $GUI_URL and accept the folders you want,"
echo 'or run: ./langtran-subscribe.sh            (list what is on offer)'
echo '        ./langtran-subscribe.sh <folder>   (subscribe to one)'
