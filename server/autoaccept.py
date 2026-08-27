#!/usr/bin/env python3
"""LangTran auto-accept poller.

Runs on the repository server next to Syncthing. It works by:
1. Listing devices that have knocked but aren't configured yet
   (GET /rest/cluster/pending/devices).
2. Accepting any device whose advertised name carries the join token
   (POST /rest/config/devices).
3. Sharing every catalog folder with every configured LT- device
   (read-modify-write PATCH, because PATCH replaces child arrays wholesale).

Stdlib only. Run from cron or a systemd timer; each run is idempotent.

Configuration (environment, typically /etc/langtran/autoaccept.env):
  SYNCTHING_URL      default http://127.0.0.1:8384
  SYNCTHING_API_KEY  required unless SYNCTHING_CONFIG points at config.xml
  SYNCTHING_CONFIG   path to config.xml to read the API key from
  JOIN_TOKEN         required; devices must be named LT-<token>-<anything>
  CATALOG_FOLDERS    optional comma-separated folder IDs; default = all folders
"""

import json
import os
import re
import sys
import urllib.request
import xml.etree.ElementTree as ET

BASE = os.environ.get("SYNCTHING_URL", "http://127.0.0.1:8384").rstrip("/")


def api_key() -> str:
    key = os.environ.get("SYNCTHING_API_KEY")
    if key:
        return key
    cfg = os.environ.get("SYNCTHING_CONFIG")
    if cfg and os.path.exists(cfg):
        node = ET.parse(cfg).find("./gui/apikey")
        if node is not None and node.text:
            return node.text
    sys.exit("no API key: set SYNCTHING_API_KEY or SYNCTHING_CONFIG")


KEY = api_key()


def call(method: str, path: str, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(
        BASE + path, data=data, method=method,
        headers={"X-API-Key": KEY, "Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        raw = resp.read()
    return json.loads(raw) if raw else None


def main() -> None:
    token = os.environ.get("JOIN_TOKEN")
    if not token:
        sys.exit("JOIN_TOKEN not set")
    name_ok = re.compile(rf"^LT-{re.escape(token)}-")

    pending = call("GET", "/rest/cluster/pending/devices") or {}
    accepted = []
    for device_id, info in pending.items():
        name = info.get("name", "")
        if not name_ok.match(name):
            print(f"skip {device_id} name={name!r} (no token match)")
            continue
        call("POST", "/rest/config/devices", {
            "deviceID": device_id,
            "name": name,
            "addresses": ["dynamic"],
        })
        accepted.append(device_id)
        print(f"accepted {device_id} name={name!r} from {info.get('address')}")

    # Share catalog folders with every LT- device, not just newly accepted ones,
    # so a device that was accepted by hand in the GUI still gets the catalog.
    devices = call("GET", "/rest/config/devices") or []
    lt_ids = {d["deviceID"] for d in devices if name_ok.match(d.get("name", ""))}
    if not lt_ids:
        return

    catalog = {f.strip() for f in os.environ.get("CATALOG_FOLDERS", "").split(",") if f.strip()}
    for folder in call("GET", "/rest/config/folders") or []:
        if catalog and folder["id"] not in catalog:
            continue
        have = {d["deviceID"] for d in folder.get("devices", [])}
        missing = lt_ids - have
        if not missing:
            continue
        new_devices = folder.get("devices", []) + [{"deviceID": d} for d in sorted(missing)]
        call("PATCH", f"/rest/config/folders/{folder['id']}", {"devices": new_devices})
        print(f"folder {folder['id']}: offered to {len(missing)} device(s)")


if __name__ == "__main__":
    main()
