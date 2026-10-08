#!/usr/bin/env bash
# LangTechDepot folders from the command line (Linux) - the counterpart of
# `modify-langtechdepot` on Windows. Works from the same catalog file and makes
# the same changes as the installer's folder list.
#
#   ./langtechdepot-subscribe.sh                  # list the catalog, and what you have
#   ./langtechdepot-subscribe.sh list             # the same
#   ./langtechdepot-subscribe.sh <id>...          # subscribe (receive-only)
#   ./langtechdepot-subscribe.sh add <id>...      # the same
#   ./langtechdepot-subscribe.sh ignore <id>...   # stop syncing it, and stop it being offered
#
# Subscribing to a folder you ignored earlier takes it back off the ignore list.

set -euo pipefail

HELP_URL='https://depot.langtech.cloud/help.html'
DATA_ROOT="$HOME/LangTechDepot"

# The Syncthing the installer set up, found exactly as install-langtechdepot.sh
# pins it with --home - not Syncthing's own default, and not port 8384, which
# may belong to a personal Syncthing on this machine.
STATE_HOME="$HOME/.local/state"
case "${XDG_STATE_HOME:-}" in /*) STATE_HOME="$XDG_STATE_HOME";; esac  # Syncthing ignores a relative one
CONFIG_DIR="$STATE_HOME/langtechdepot"

if [ ! -f "$CONFIG_DIR/config.xml" ]; then
    cat >&2 <<EOF
LangTechDepot is not set up for you on this computer yet
(nothing at $CONFIG_DIR).
Run the installer first: install-langtechdepot.sh

Help: $HELP_URL
EOF
    exit 1
fi

# Paths go in as arguments, never into the Python source.
python3 - "$CONFIG_DIR/config.xml" "$DATA_ROOT" "$HELP_URL" "$@" <<'PY'
import datetime, json, os, re, sys, urllib.request, urllib.error
import xml.etree.ElementTree as ET

CONFIG, DATA_ROOT, HELP = sys.argv[1:4]
args = sys.argv[4:]
SERVER_NAME = 'LangTechDepot Server'
ALWAYS = 'All_Contents_List'

def fail(msg):
    sys.exit(f'{msg}\nHelp: {HELP}')

gui = ET.parse(CONFIG).find('./gui')
KEY = gui.find('apikey').text
GUI = 'http://' + gui.find('address').text

def api(method, path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(GUI + path, data=data, method=method,
                                 headers={'X-API-Key': KEY, 'Content-Type': 'application/json'})
    with urllib.request.urlopen(req, timeout=60) as r:
        raw = r.read()
        return json.loads(raw) if raw.strip() else None

try:
    folders = api('GET', '/rest/config/folders') or []
    devices = api('GET', '/rest/config/devices') or []
except (urllib.error.URLError, OSError) as e:
    fail(f'LangTechDepot\'s Syncthing is not answering at {GUI} ({e}).\n'
         'Start it with: systemctl --user start langtechdepot.service')

SERVER = next((d['deviceID'] for d in devices if d.get('name') == SERVER_NAME), '')
if not SERVER:
    fail('This computer is not registered with the LangTechDepot server yet.\n'
         'Run the installer first: install-langtechdepot.sh')

subs = {f['id'] for f in folders if f.get('id')}
contents = next((f for f in folders if f.get('id') == ALWAYS), None)
CATALOG = os.path.join(contents['path'] if contents and contents.get('path')
                       else os.path.join(DATA_ROOT, ALWAYS), 'LangTechDepotFiles.txt')

def ignored_list():
    dev = api('GET', '/rest/config/devices/' + SERVER) or {}
    return [i for i in (dev.get('ignoredFolders') or []) if isinstance(i, dict) and i.get('id')]

# Same parser as the installer's folder list (PICKER_PY in install-langtechdepot.sh).
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
    return out

try:
    cat = catalog()
except FileNotFoundError:
    fail(f'The folder catalog has not arrived yet ({CATALOG}).\n'
         'Give Syncthing a few minutes to sync All_Contents_List, then try again.')
if not cat:
    fail(f'No folders found in the catalog ({CATALOG}).')

cmd = 'list'
if args and args[0] in ('list', 'add', 'ignore'):
    cmd, args = args[0], args[1:]
elif args:
    cmd = 'add'   # the original form: langtechdepot-subscribe.sh <id>...

if cmd == 'list':
    ign = {i['id'] for i in ignored_list()}
    for e in cat:
        fid = e['id']
        if fid == ALWAYS:
            continue   # always kept; not a choice
        now = 'subscribed' if fid in subs else 'ignored' if fid in ign else 'available'
        print(f"  {now:<11} {e['size']:>8}  {fid:<24} {e['desc']}")
    print()
    print('Subscribe:  langtechdepot-subscribe.sh <folder-id>...')
    print('Ignore:     langtechdepot-subscribe.sh ignore <folder-id>...')
    sys.exit(0)

if not args:
    fail(f'Name at least one folder ID after "{cmd}". Run with no arguments to list them.')

by_id = {e['id']: e for e in cat}

def set_ignored(fid, label, ignore):
    # PATCH replaces the array wholesale: read, modify, write the whole list.
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

failures = 0
for fid in args:
    if cmd == 'ignore' and fid == ALWAYS:
        print(f'{fid} is always kept: the installer needs it.')
        continue
    e = by_id.get(fid)
    if e is None:
        print(f'{fid} is not in the catalog (run with no arguments to list folders).')
        failures += 1; continue
    desc = e['desc']
    try:
        if cmd == 'add':
            if fid in subs:
                print(f'Already subscribed to: {fid}')
            else:
                path = os.path.join(DATA_ROOT, fid)
                api('POST', '/rest/config/folders', {
                    'id': fid, 'label': desc, 'path': path,
                    'type': 'receiveonly', 'rescanIntervalS': 3600, 'fsWatcherEnabled': True,
                    'devices': [{'deviceID': SERVER, 'encryptionPassword': ''}]})
                subs.add(fid)
                print(f'Subscribed to: {fid} -> {path} (receive-only)')
            if set_ignored(fid, desc, False):
                print(f'No longer ignoring: {fid}')
        else:  # ignore
            if fid in subs:
                api('DELETE', '/rest/config/folders/' + fid)
                subs.discard(fid)
                print(f'Stopped syncing: {fid} (files already downloaded are left in place)')
            if set_ignored(fid, desc, True):
                print(f'Ignored: {fid}')
            else:
                print(f'Already ignored: {fid}')
    except (urllib.error.URLError, OSError) as err:
        failures += 1
        print(f'Failed to update {fid}: {err}')
if failures:
    print(f'Help: {HELP}')
sys.exit(1 if failures else 0)
PY
