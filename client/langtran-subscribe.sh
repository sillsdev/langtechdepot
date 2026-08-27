#!/usr/bin/env bash
# List the LangTran folder catalog, or subscribe to one folder.
#
#   ./langtran-subscribe.sh              # list folders on offer
#   ./langtran-subscribe.sh <folder-id>  # subscribe (receive-only)

set -euo pipefail
GUI_URL='http://127.0.0.1:8384'
CONFIG_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/syncthing"
API_KEY=$(python3 -c "import xml.etree.ElementTree as ET; print(ET.parse('$CONFIG_DIR/config.xml').find('./gui/apikey').text)")

export GUI_URL API_KEY
python3 - "$@" <<'PY'
import json, os, sys, urllib.request

BASE, KEY = os.environ["GUI_URL"], os.environ["API_KEY"]

def api(method, path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(BASE + path, data=data, method=method,
        headers={"X-API-Key": KEY, "Content-Type": "application/json"})
    raw = urllib.request.urlopen(req, timeout=30).read()
    return json.loads(raw) if raw else None

pending = api("GET", "/rest/cluster/pending/folders") or {}
have = {f["id"] for f in api("GET", "/rest/config/folders") or []}

if len(sys.argv) < 2:
    if not pending and not have:
        print("Nothing on offer yet — give the server a minute after install.")
    for fid, info in sorted(pending.items()):
        label = next(iter(info["offeredBy"].values())).get("label", fid)
        print(f"  {fid:<24} {label}")
    for fid in sorted(have):
        print(f"  {fid:<24} (already subscribed)")
    sys.exit(0)

fid = sys.argv[1]
if fid in have:
    sys.exit(f"already subscribed to {fid}")
if fid not in pending:
    sys.exit(f"{fid} is not on offer (run without arguments to list)")

tpl = api("GET", "/rest/config/defaults/folder")
offer = pending[fid]["offeredBy"]
label = next(iter(offer.values())).get("label") or fid
tpl.update({
    "id": fid,
    "label": label,
    "path": os.path.join(tpl.get("path") or os.path.expanduser("~/LangTran"), fid),
    # share with every device offering it (the server, plus introduced peers)
    "devices": [{"deviceID": d} for d in offer],
})
api("POST", "/rest/config/folders", tpl)
print(f"subscribed to {fid} → {tpl['path']} (receive-only)")
PY
