#!/usr/bin/env python3
"""LangTechDepot registration service.

Runs on the repository server beside Syncthing. It is the only way a field
machine joins the cluster, and it exists because a Syncthing device name is
public: BEP's ClusterConfig carries a `name` for every device, so the
introducer hands each client the names of all its peers. A per-user token
embedded in a device name would therefore leak to every other field user.
Here the token travels over HTTPS to this service instead and never enters
Syncthing's config at all.

Flow:
1. A user fills the web form; we mint a single-use token and mail it to them
   (or display it, if no SMTP is configured).
2. Their installer posts {token, deviceID, deviceName} to /register.
3. We validate the token, add the device to Syncthing, share every catalog
   folder with it, and burn the token.
4. A background thread re-runs step 3's share for folders added later, so a
   new catalog folder reaches everyone already registered.

Stdlib only. Serves plain HTTP on localhost; put Caddy or nginx in front for
TLS (see Caddyfile.example).

Run:  python3 register.py                 # the service
      python3 register.py admin ...       # list / approve / revoke
"""

import html
import ipaddress
import json
import os
import re
import secrets
import smtplib
import sqlite3
import ssl
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from datetime import datetime, timezone
from email.message import EmailMessage
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from dotenv import load_dotenv

# Load the file directly if it exists (ignores it if it doesn't). Variables
# already in the environment win. REGISTER_ENV exists so the test suite can
# point this somewhere empty when it runs on the server itself.
load_dotenv(os.environ.get("REGISTER_ENV", "/etc/langtechdepot/register.env"))

# Canonical Syncthing device ID: 8 dash-separated groups of 7 base32 chars.
DEVICE_ID_RE = re.compile(r"^[A-Z2-7]{7}(-[A-Z2-7]{7}){7}$")
EMAIL_RE = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")

SYNCTHING_URL = os.environ.get("SYNCTHING_URL", "http://127.0.0.1:8384").rstrip("/")
DB_PATH = os.environ.get("DB_PATH", "/var/lib/langtechdepot/register.db")
LISTEN_HOST = os.environ.get("LISTEN_HOST", "127.0.0.1")
LISTEN_PORT = int(os.environ.get("LISTEN_PORT", "8385"))
PUBLIC_URL = os.environ.get("PUBLIC_URL", "").rstrip("/")
# The instructions site. It owns steps 2-4 of the journey and this service owns
# step 1, so every page here links back to it and it links here. One variable
# because the two are meant to merge: when the site is served from this host,
# point this at that path and nothing else changes.
SITE_URL = os.environ.get("SITE_URL", "https://sillsdev.github.io/langtechdepot").rstrip("/")
# Off unless asked for: with introducer mode on, every approved device can
# reach every field machine (see the guard below), so a person checks first.
AUTO_APPROVE = os.environ.get("AUTO_APPROVE", "false").lower() not in ("0", "false", "no")
CATALOG_FOLDERS = {f.strip() for f in os.environ.get("CATALOG_FOLDERS", "").split(",") if f.strip()}
ADMIN_EMAIL = os.environ.get("ADMIN_EMAIL", "")
SMTP_HOST = os.environ.get("SMTP_HOST", "")
SMTP_PORT = int(os.environ.get("SMTP_PORT", "587"))
SMTP_USER = os.environ.get("SMTP_USER", "")
SMTP_PASS = os.environ.get("SMTP_PASS", "")
MAIL_FROM = os.environ.get("MAIL_FROM", "langtechdepot@sil.org")

# Registration is cheap but not free: cap attempts per client address so a
# script cannot mint tokens or grind at /register unbounded. The form mints a
# token and sends mail, so it is the tighter bucket; the installer may retry
# (the Linux one POSTs twice per failed attempt to read the reason).
RATE_LIMITS = {"request": (10, 3600), "register": (30, 3600)}  # attempts, seconds
_rate: dict[tuple[str, str], list[float]] = {}
_rate_lock = threading.Lock()
_rate_pruned = 0.0

# Syncthing's config PATCH is read-modify-write on the device list, and both
# the request threads and the reconciler do it. Serialise them, or two
# concurrent writers each drop the other's device.
_share_lock = threading.Lock()


def now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


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


def st(method: str, path: str, body=None, timeout: float = 30):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(
        SYNCTHING_URL + path, data=data, method=method,
        headers={"X-API-Key": KEY, "Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        raw = resp.read()
    return json.loads(raw) if raw else None


def db() -> sqlite3.Connection:
    os.makedirs(os.path.dirname(DB_PATH) or ".", exist_ok=True)
    conn = sqlite3.connect(DB_PATH, timeout=30)
    conn.row_factory = sqlite3.Row
    conn.execute("""CREATE TABLE IF NOT EXISTS tokens (
        token       TEXT PRIMARY KEY,
        email       TEXT NOT NULL,
        person      TEXT,
        org         TEXT,
        location    TEXT,
        issued_at   TEXT NOT NULL,
        approved    INTEGER NOT NULL DEFAULT 0,
        used_at     TEXT,
        device_id   TEXT,
        device_name TEXT,
        revoked_at  TEXT
    )""")
    conn.commit()
    # Set permissions on DB_PATH to 640, so not readable by Others. Only the
    # owner may chmod: if root created the file (`sudo ltd-sync-admin` before
    # the service's first start) the service must still come up.
    try:
        os.chmod(DB_PATH, 0o640)
    except OSError:
        pass
    return conn


def rate_ok(bucket: str, addr: str) -> bool:
    global _rate_pruned
    limit, window = RATE_LIMITS[bucket]
    t = time.monotonic()
    cutoff = t - window
    with _rate_lock:
        # Drop addresses with no recent hits, so the table does not grow for
        # as long as the service runs.
        if t - _rate_pruned > 300:
            for k in [k for k, v in _rate.items() if not v or v[-1] <= cutoff]:
                del _rate[k]
            _rate_pruned = t
        hits = [h for h in _rate.get((bucket, addr), []) if h > cutoff]
        hits.append(t)
        _rate[(bucket, addr)] = hits
        return len(hits) <= limit


def send_mail(to: str, subject: str, body: str) -> bool:
    """Returns False when SMTP is unconfigured or refuses; callers fall back
    to showing the token on screen rather than stranding the user."""
    if not SMTP_HOST:
        return False
    msg = EmailMessage()
    msg["From"] = MAIL_FROM
    msg["To"] = to
    msg["Subject"] = subject
    msg.set_content(body)
    try:
        with smtplib.SMTP(SMTP_HOST, SMTP_PORT, timeout=30) as s:
            s.starttls(context=ssl.create_default_context())
            if SMTP_USER:
                s.login(SMTP_USER, SMTP_PASS)
            s.send_message(msg)
        return True
    except Exception as exc:  # noqa: BLE001 - any mail failure degrades the same way
        print(f"[mail] send to {to} failed: {exc}", flush=True)
        return False


def catalog_folder_ids() -> list[str]:
    folders = st("GET", "/rest/config/folders") or []
    return [f["id"] for f in folders if not CATALOG_FOLDERS or f["id"] in CATALOG_FOLDERS]


def share_catalog_with(device_ids: set[str]) -> list[str]:
    """Add device_ids to every catalog folder's device list, and make sure
    each folder is Send Only. PATCH replaces child arrays wholesale, so the
    device list is read-modify-write rather than append. Only the keys that
    are actually wrong go into the payload, and the journal line says which,
    so "flipped to sendonly" is never reported for a folder that already was.
    Holds _share_lock throughout, so the read and the write cannot interleave
    with another thread's."""
    with _share_lock:
        return _share_catalog_with(device_ids)


def _share_catalog_with(device_ids: set[str]) -> list[str]:
    touched = []
    for folder in st("GET", "/rest/config/folders") or []:
        fid = folder["id"]
        if CATALOG_FOLDERS and fid not in CATALOG_FOLDERS:
            continue
        touched.append(fid)

        patch: dict = {}
        changed: list[str] = []

        missing = device_ids - {d["deviceID"] for d in folder.get("devices", [])}
        if missing:
            patch["devices"] = folder.get("devices", []) + [
                {"deviceID": d} for d in sorted(missing)
            ]
            changed.append(f"shared with {len(missing)} more device(s)")

        was = folder.get("type", "")
        if was != "sendonly":
            patch["type"] = "sendonly"
            changed.append(f"type {was or 'unset'} -> sendonly")

        if not patch:
            continue

        st("PATCH", f"/rest/config/folders/{urllib.parse.quote(fid, safe='')}", patch)
        print(f"[reconcile] {fid}: {', '.join(changed)}", flush=True)
    return touched


def register_device(token: str, device_id: str, device_name: str) -> dict:
    """Validate a single-use token and admit the device. Raises ValueError with
    a user-safe message on any rejection."""
    if not DEVICE_ID_RE.match(device_id):
        raise ValueError("malformed device ID")
    device_name = re.sub(r"[^\w .-]", "", device_name)[:64] or "langtechdepot-client"

    conn = db()
    try:
        # Revoking deletes the device from Syncthing; without this check a
        # fresh token from the form would put it straight back.
        if conn.execute("SELECT 1 FROM tokens WHERE device_id = ? AND revoked_at IS NOT NULL "
                        "LIMIT 1", (device_id,)).fetchone():
            raise ValueError("access for this machine has been revoked")
        row = conn.execute("SELECT * FROM tokens WHERE token = ?", (token,)).fetchone()
        if row is None:
            raise ValueError("unknown token")
        if row["revoked_at"]:
            raise ValueError("token has been revoked")
        if not row["approved"]:
            raise ValueError("registration is awaiting approval; you will be emailed")
        if row["used_at"] and row["device_id"] != device_id:
            raise ValueError("token has already been used on another machine")

        # Claim the token before touching Syncthing, atomically: the checks
        # above are a read, and two installers racing on one token would both
        # pass them. Only one UPDATE can win. A fresh claim is released again
        # if Syncthing then fails, so the user can retry with the same token;
        # the same device re-running the installer is accepted as before.
        claim = ("UPDATE tokens SET used_at = ?, device_id = ?, device_name = ? "
                 "WHERE token = ? AND revoked_at IS NULL AND approved = 1 AND ")
        fresh = conn.execute(claim + "used_at IS NULL",
                             (now(), device_id, device_name, token)).rowcount == 1
        if not fresh and conn.execute(claim + "device_id = ?",
                                      (now(), device_id, device_name, token, device_id)
                                      ).rowcount != 1:
            conn.rollback()
            raise ValueError("token has already been used on another machine")
        conn.commit()

        try:
            existing = {d["deviceID"] for d in st("GET", "/rest/config/devices") or []}
            if device_id not in existing:
                st("POST", "/rest/config/devices", {
                    "deviceID": device_id,
                    "name": device_name,     # deliberately carries no token: peers see this
                    "addresses": ["dynamic"],
                })
            folders = share_catalog_with({device_id})
            me = st("GET", "/rest/system/status") or {}
        except BaseException:
            if fresh:
                conn.execute("UPDATE tokens SET used_at = NULL, device_id = NULL, "
                             "device_name = NULL WHERE token = ? AND device_id = ?",
                             (token, device_id))
                conn.commit()
            raise
    finally:
        conn.close()

    server_id = me.get("myID", "")
    addresses = ["dynamic"]
    extra = os.environ.get("SERVER_ADDRESS", "")
    if extra:
        addresses.append(extra)
    print(f"[register] {device_name} {device_id} -> {len(folders)} folder(s)", flush=True)
    return {"ok": True, "serverDeviceID": server_id, "serverAddresses": addresses, "folders": folders}


def issue_token(email: str, person: str, org: str, location: str) -> tuple[str, bool]:
    """Mint a token. Returns (token, emailed)."""
    token = secrets.token_urlsafe(16)
    conn = db()
    try:
        conn.execute(
            "INSERT INTO tokens (token, email, person, org, location, issued_at, approved) "
            "VALUES (?,?,?,?,?,?,?)",
            (token, email, person, org, location, now(), 1 if AUTO_APPROVE else 0),
        )
        conn.commit()
    finally:
        conn.close()

    if ADMIN_EMAIL:
        who = f"{person or '(no name)'} <{email}>\norg: {org}\nlocation: {location}\n"
        if AUTO_APPROVE:
            send_mail(ADMIN_EMAIL, "LangTechDepot registration", who + "approved: True\n")
        else:
            # The token is useless until approved, and approving mails it to
            # the applicant anyway; carrying it here saves a `list` lookup.
            send_mail(ADMIN_EMAIL, f"LangTechDepot: approve {email}?",
                      who + "\nEvery approved device can reach every field machine, so check\n"
                      "this is a real person before approving. On the server:\n\n"
                      f"    ltd-sync-admin approve {token}\n\n"
                      "That emails the token to them. To refuse, do nothing.\n")
    if not AUTO_APPROVE:
        return token, False
    emailed = send_mail(email, "Your LangTechDepot access token", token_mail(token))
    return token, emailed


def token_mail(token: str) -> str:
    return (f"Paste this token into the LangTechDepot installer when it asks:\n\n    {token}\n\n"
            "It works once, on one machine. Need another machine? Register again.\n\n"
            f"Step-by-step instructions, with pictures:\n\n    {SITE_URL}/\n\n"
            "Stuck? Reply to this message.\n")


# --- HTTP ---------------------------------------------------------------------

# This page is step 1 of a four-step journey whose other three steps live on
# the instructions site (docs/ in this repo). A field user crosses between the
# two mid-install, so the chrome here - masthead, step rail, buttons, the copy
# row - is deliberately the same as docs/assets/site.css. Change one, change
# both. It is duplicated rather than linked because this service is a single
# stdlib file that must keep working when the other site is unreachable.
#
# Markers are @@NAME@@ rather than str.format fields: the page carries CSS and
# JavaScript, and doubling every brace in them is how this file grows bugs.

PAGE = """<!doctype html>
<html lang=en>
<meta charset=utf-8>
<meta name=viewport content="width=device-width,initial-scale=1">
<title>LangTechDepot &mdash; @@TITLE@@</title>
<style>
:root{--brand:#1f5fa9;--brand-dark:#17497f;--brand-soft:#e8f0fa;--ink:#16202b;
 --ink-soft:#55636f;--line:#d8dee5;--paper:#fff;--ground:#f4f6f8;--ok:#1e7a46;
 --shadow:0 1px 2px rgba(22,32,43,.06),0 8px 24px rgba(22,32,43,.07)}
@media(prefers-color-scheme:dark){:root{--brand:#6fa8e8;--brand-dark:#9cc6f2;
 --brand-soft:#17273a;--ink:#e8edf2;--ink-soft:#a3b1bf;--line:#2c3742;
 --paper:#131a22;--ground:#0d131a;--ok:#5cc189;
 --shadow:0 1px 2px rgba(0,0,0,.4),0 8px 24px rgba(0,0,0,.35)}}
*{box-sizing:border-box}
body{margin:0;background:var(--ground);color:var(--ink);
 font:17px/1.6 system-ui,-apple-system,"Segoe UI",Roboto,sans-serif}
.wrap{max-width:40rem;margin:0 auto;padding:0 1.25rem 4rem}
.masthead{background:var(--paper);border-bottom:1px solid var(--line)}
.masthead .wrap{display:flex;align-items:center;gap:.7rem;padding:1rem 1.25rem}
.masthead a{display:flex;align-items:center;gap:.7rem;text-decoration:none;color:inherit}
.masthead .name{font-weight:700;font-size:1.1rem;letter-spacing:-.01em}
h1{font-size:clamp(1.6rem,5vw,2.1rem);line-height:1.15;letter-spacing:-.02em;margin:2rem 0 .5rem}
.lede{font-size:1.1rem;color:var(--ink-soft);margin:0 0 1.8rem}
a{color:var(--brand)}
.rail{display:flex;gap:.4rem;list-style:none;margin:1.4rem 0 2rem;padding:0;
 font-size:.8rem;font-weight:600}
.rail li{flex:1;padding:.45rem .3rem .5rem;text-align:center;color:var(--ink-soft);
 border-top:4px solid var(--line);border-radius:2px}
.rail li.done{color:var(--ok);border-top-color:var(--ok)}
.rail li.now{color:var(--brand);border-top-color:var(--brand)}
.rail .n{display:block;font-size:.72rem;opacity:.8;font-weight:700}
.card{background:var(--paper);border:1px solid var(--line);border-radius:12px;
 box-shadow:var(--shadow);padding:1.6rem}
label{display:block;margin:1.1rem 0 .3rem;font-weight:600;font-size:.95rem}
label .opt{font-weight:400;color:var(--ink-soft)}
input{width:100%;padding:.7rem .75rem;font:inherit;color:var(--ink);
 background:var(--ground);border:1px solid var(--line);border-radius:8px}
input:focus{outline:2px solid var(--brand);outline-offset:1px}
.btn,button[type=submit]{display:inline-flex;align-items:center;gap:.55rem;
 background:var(--brand);color:#fff;text-decoration:none;font:inherit;font-weight:700;
 border:0;cursor:pointer;padding:.85rem 1.5rem;border-radius:9px;margin:1.4rem 0 .2rem}
.btn:hover,button[type=submit]:hover{background:var(--brand-dark)}
.btn.big{font-size:1.15rem}
@media(prefers-color-scheme:dark){.btn,button[type=submit],.copybtn{color:#0d131a}}
.sub-btn{display:block;font-size:.9rem;color:var(--ink-soft)}
.copyrow{display:flex;gap:.5rem;align-items:stretch;margin:1rem 0;flex-wrap:wrap}
.copyrow .val{flex:1 1 14rem;min-width:0;font:700 1.15rem/1.4 ui-monospace,
 SFMono-Regular,Consolas,monospace;background:var(--brand-soft);color:var(--ink);
 border:1px solid var(--line);border-radius:9px;padding:.9rem;overflow-wrap:anywhere;
 user-select:all;text-align:center}
.copybtn{flex:none;font:inherit;font-weight:700;cursor:pointer;background:var(--brand);
 color:#fff;border:0;border-radius:9px;padding:.9rem 1.3rem;min-width:7rem}
.copybtn:hover{background:var(--brand-dark)}
.copybtn.done{background:var(--ok)}
.note{background:var(--paper);border:1px solid var(--line);border-left:4px solid var(--brand);
 border-radius:0 9px 9px 0;padding:.9rem 1.1rem;margin:1.4rem 0;font-size:.96rem}
.note>strong:first-child{display:block;margin-bottom:.2rem}
code{background:var(--brand-soft);padding:.15rem .4rem;border-radius:4px;
 font-size:.93em;overflow-wrap:anywhere}
.foot{margin-top:2.5rem;padding-top:1.2rem;border-top:1px solid var(--line);
 font-size:.92rem;color:var(--ink-soft)}
.foot a{color:var(--ink-soft)}
</style>

<header class=masthead><div class=wrap>
 <a href="@@SITE@@/">
  <svg width=28 height=28 viewBox="0 0 32 32" aria-hidden=true>
   <path d="M4 11 16 5l12 6-12 6z" fill="var(--brand)"/>
   <path d="M4 11v10l12 6V17z" fill="var(--brand)" opacity=".65"/>
   <path d="M28 11v10l-12 6V17z" fill="var(--brand)" opacity=".4"/>
  </svg>
  <span class=name>LangTechDepot</span>
 </a>
</div></header>

<main class=wrap>
@@BODY@@
</main>

<script>
/* Kept in step with docs/assets/site.js. navigator.clipboard needs a secure
   context, so the textarea fallback stays: nobody should have to retype a
   token by hand because the page was reached over plain http. */
function ltdCopy(btn){
 var src=document.getElementById(btn.getAttribute('data-copy'));
 if(!src){return;}
 var text=(src.textContent||'').trim();
 var done=function(ok){
  btn.classList.toggle('done',ok);
  btn.textContent=ok?'Copied':'Press Ctrl+C';
  if(ok){setTimeout(function(){btn.classList.remove('done');btn.textContent='Copy';},2500);}
 };
 var fallback=function(){
  var ta=document.createElement('textarea');
  ta.value=text;ta.setAttribute('readonly','');
  ta.style.position='fixed';ta.style.opacity='0';
  document.body.appendChild(ta);ta.select();
  var ok=false;
  try{ok=document.execCommand('copy');}catch(e){ok=false;}
  document.body.removeChild(ta);
  if(!ok&&window.getSelection){
   var r=document.createRange();r.selectNodeContents(src);
   window.getSelection().removeAllRanges();window.getSelection().addRange(r);
  }
  done(ok);
 };
 if(navigator.clipboard&&navigator.clipboard.writeText){
  navigator.clipboard.writeText(text).then(function(){done(true);},fallback);
 }else{fallback();}
}
document.addEventListener('click',function(ev){
 var btn=ev.target.closest?ev.target.closest('[data-copy]'):null;
 if(btn){ltdCopy(btn);}
});
</script>
</html>
"""

# Step rails. The one on the form says "you are at step 1"; the one on the
# token page says "step 1 is behind you, go back for step 2". They are the
# same four steps the instructions site shows, so the hand-off in either
# direction lands the reader where they expect.
RAIL_FORM = """<ol class=rail>
 <li class=now><span class=n>Step 1</span>Get your token</li>
 <li><span class=n>Step 2</span>Download</li>
 <li><span class=n>Step 3</span>Run it</li>
 <li><span class=n>Step 4</span>Pick your folders</li>
</ol>"""

RAIL_DONE = """<ol class=rail>
 <li class=done><span class=n>Step 1</span>Token issued</li>
 <li class=now><span class=n>Step 2</span>Download</li>
 <li><span class=n>Step 3</span>Run it</li>
 <li><span class=n>Step 4</span>Pick your folders</li>
</ol>"""


def next_step_url(osname: str) -> str:
    """Back to the instructions site, at the page for the user's platform."""
    page = {"windows": "windows.html", "linux": "linux.html"}.get(osname, "index.html")
    return f"{SITE_URL}/{page}"


def form_page(osname: str) -> str:
    if AUTO_APPROVE:
        lede = ("One short form. The next page gives you a token &mdash; a password that "
                "works once, on one machine &mdash; and we email you a copy. You paste it "
                "into the installer.")
    else:
        lede = ("One short form. We check each request by hand, then email you a token "
                "&mdash; a password that works once, on one machine &mdash; to paste into "
                "the installer.")
    return f"""<h1>Get your token</h1>
<p class=lede>{lede}</p>
{RAIL_FORM}
<form method=post action=/request class=card>
 <input type=hidden name=os value="{html.escape(osname)}">
 <label for=person>Your name</label><input id=person name=person required autofocus>
 <label for=email>Email</label><input id=email name=email type=email required>
 <label for=org>Organisation <span class=opt>&mdash; optional</span></label>
 <input id=org name=org>
 <label for=location>Where you work <span class=opt>&mdash; optional</span></label>
 <input id=location name=location placeholder="country or region">
 <button type=submit>Get my token</button>
</form>
<div class=note><strong>Setting up a second machine?</strong>
Fill this in again. Each machine needs its own token.</div>
<div class=note><strong>Not sure what this is?</strong>
<a href="{next_step_url(osname)}">The instructions page</a> walks through all
four steps with pictures.</div>"""


def token_page(token: str, osname: str, email: str, emailed: bool) -> str:
    """The token, big, with a copy button and the way back to step 2.

    The token is shown even when it was also emailed. A field user on a slow
    link who has to go and find a mail client mid-install is a user who does
    not finish, and the person reading this page is the same person who filled
    in the form a second ago - the mail copy is the backup, not the delivery.
    """
    if emailed:
        mail_line = (f"<p>A copy is on its way to <code>{html.escape(email)}</code>, "
                     "which is handy if you are installing on a different machine from this one.</p>")
    else:
        mail_line = ("<p>This page is the only copy of your token. Copy it now, "
                     "before you leave the page.</p>")
    return f"""<h1>Here is your token</h1>
<p class=lede>It works once, on one machine. Copy it now &mdash; then go back and
run the installer.</p>
{RAIL_DONE}
<div class=card>
 <div class=copyrow>
  <code class=val id=tok>{html.escape(token)}</code>
  <button class=copybtn type=button data-copy=tok>Copy</button>
 </div>
 {mail_line}
</div>
<a class="btn big" href="{next_step_url(osname)}">Next: {"open a terminal" if osname == "linux" else "download the installer"} &rarr;</a>
<span class=sub-btn>Leave this page open until the installer has asked you for
the token.</span>
<div class=note><strong>Keep it to yourself.</strong>
A token admits one machine to the library. It stops working the moment it is
used, so there is nothing to undo &mdash; but do not paste it into a group
chat on the way.</div>"""


def pick_os(value: str) -> str:
    """Which platform page sent them here, so we can send them back to it."""
    value = value.strip().lower()
    return value if value in ("windows", "linux") else ""


class Handler(BaseHTTPRequestHandler):
    server_version = "langtechdepot-register"
    # Socket timeout per read/write: a client that opens a connection and then
    # trickles (or never sends) its body releases its thread after this long.
    timeout = 20

    def client_ip(self) -> str:
        """The address to rate-limit and log. Behind Caddy every peer is
        loopback, so then the real client is the last X-Forwarded-For entry:
        the one Caddy itself appended. Anything earlier in the header came
        from the client and is not trusted. The service binds localhost only,
        so a loopback peer is always the proxy (or someone on this box)."""
        peer = self.client_address[0]
        try:
            loopback = ipaddress.ip_address(peer).is_loopback
        except ValueError:
            loopback = False
        headers = getattr(self, "headers", None)
        if loopback and headers is not None:
            last = (headers.get("X-Forwarded-For") or "").split(",")[-1].strip()
            try:
                return str(ipaddress.ip_address(last))
            except ValueError:
                pass
        return peer

    def log_message(self, fmt, *args):
        print(f"[http] {self.client_ip()} {fmt % args}", flush=True)

    def _send(self, code: int, body: bytes, ctype: str):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        # The token page must not sit in a browser or proxy cache, and no page
        # here has any business inside someone else's frame.
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Content-Security-Policy",
                         "frame-ancestors 'none'; base-uri 'none'; form-action 'self'")
        self.end_headers()
        self.wfile.write(body)

    def _fail(self, path: str, code: int, message: str):
        """An error in the shape the caller reads: JSON for the installer,
        a page for a browser."""
        if path == "/register":
            self._json(code, {"ok": False, "error": message})
        else:
            self._page(code, f"<h1>{html.escape(message)}</h1>")

    def _page(self, code: int, body: str, title: str = "register"):
        page = (PAGE.replace("@@TITLE@@", title)
                    .replace("@@SITE@@", SITE_URL)
                    .replace("@@BODY@@", body))
        self._send(code, page.encode(), "text/html; charset=utf-8")

    def _json(self, code: int, obj: dict):
        self._send(code, json.dumps(obj).encode(), "application/json")

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path
        if path == "/healthz":
            self._json(200, {"ok": True})
        # Nobody can be sent straight to a token: the token is what this form
        # gives back. /signup is the same form under a name of its own, so the
        # instructions site can take over this host's "/" later without the
        # form losing its address.
        elif path in ("/", "/signup"):
            query = urllib.parse.parse_qs(parsed.query)
            osname = pick_os(query.get("os", [""])[0])
            self._page(200, form_page(osname), "get your token")
        else:
            self._page(404, "<h1>Not found</h1>"
                            f'<p><a href="{SITE_URL}/">Back to the instructions</a></p>')

    def do_POST(self):
        path = urllib.parse.urlparse(self.path).path
        # An unread body would be parsed as the next request on a kept-alive
        # connection, so every early rejection below also closes it.
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            length = -1
        if length < 0:
            self.close_connection = True
            self._fail(path, 400, "bad Content-Length")
            return
        if length > 64_000:
            self.close_connection = True
            self._fail(path, 413, "too large")
            return
        raw = self.rfile.read(length)

        bucket = "register" if path == "/register" else "request"
        if not rate_ok(bucket, self.client_ip()):
            if path == "/register":
                self._json(429, {"ok": False, "error": "too many attempts; try again later"})
            else:
                self._page(429, "<h1>Too many attempts</h1><p>Try again later.</p>")
            return

        if path == "/register":
            try:
                payload = json.loads(raw)
                if not isinstance(payload, dict):
                    raise ValueError("expected a JSON object")
                result = register_device(
                    str(payload["token"]).strip(),
                    str(payload["deviceID"]).strip().upper(),
                    str(payload.get("deviceName", "")).strip(),
                )
            except KeyError as exc:
                self._json(400, {"ok": False, "error": f"missing field {exc}"})
            except ValueError as exc:  # includes JSONDecodeError, UnicodeDecodeError
                self._json(400, {"ok": False, "error": str(exc)})
            except urllib.error.HTTPError as exc:
                # Syncthing answered and said no - typically a device ID that
                # fits the pattern but fails its check digits. Retrying the
                # same thing will not help, so do not say "busy".
                detail = ""
                try:
                    detail = exc.read(300).decode("utf-8", "replace").strip().splitlines()[0]
                except Exception:  # noqa: BLE001 - the detail is a courtesy
                    pass
                print(f"[register] syncthing refused: HTTP {exc.code} {detail}", flush=True)
                self._json(502, {"ok": False, "error":
                                 "the depot server could not add this machine"
                                 + (f" (Syncthing said: {detail})" if detail else "")
                                 + ". Check the device ID; trying again will not help."})
            except OSError as exc:  # URLError, timeouts, refused connections
                print(f"[register] syncthing unreachable: {exc}", flush=True)
                self._json(503, {"ok": False, "error": "server busy; try again shortly"})
            else:
                self._json(200, result)
            return

        if path == "/request":
            form = urllib.parse.parse_qs(raw.decode("utf-8", "replace"))
            email = (form.get("email", [""])[0]).strip()
            person = (form.get("person", [""])[0]).strip()[:120]
            org = (form.get("org", [""])[0]).strip()[:120]
            location = (form.get("location", [""])[0]).strip()[:120]
            osname = pick_os(form.get("os", [""])[0])
            if not EMAIL_RE.match(email):
                self._page(400, "<h1>Check your email address</h1>"
                                f'<p><a href="/?os={osname}">Back to the form</a></p>',
                           "check your email address")
                return
            token, emailed = issue_token(email, person, org, location)
            if not AUTO_APPROVE:
                self._page(200, "<h1>Request received</h1>"
                                "<p class=lede>We check each request by hand, then email "
                                f"your token to <code>{html.escape(email)}</code>.</p>"
                                "<div class=card><p>It comes from <code>depot@langtech.cloud</code>. "
                                "If it has not arrived, look in your spam or junk folder before "
                                "asking.</p></div>"
                                f'<a class="btn big" href="{next_step_url(osname)}">'
                                "While you wait: back to the instructions &rarr;</a>"
                                "<span class=sub-btn>You can download the installer now. It "
                                "asks for the token when it needs it.</span>",
                           "request received")
            else:
                self._page(200, token_page(token, osname, email, emailed), "your token")
            return

        self._page(404, "<h1>Not found</h1>")


def reconcile_loop():
    """A folder added to the catalog after people registered is shared with
    nobody until something re-runs the share. That something is this."""
    while True:
        time.sleep(60)
        try:
            conn = db()
            rows = conn.execute(
                "SELECT DISTINCT device_id FROM tokens "
                "WHERE device_id IS NOT NULL AND revoked_at IS NULL "
                # A device revoked under any token stays out, even if
                # another of its tokens was never revoked.
                "AND device_id NOT IN (SELECT device_id FROM tokens "
                "WHERE revoked_at IS NOT NULL AND device_id IS NOT NULL)"
            ).fetchall()
            conn.close()
            ids = {r["device_id"] for r in rows if r["device_id"]}
            if ids:
                share_catalog_with(ids)
        except Exception as exc:  # noqa: BLE001 - a bad cycle must not kill the thread
            print(f"[reconcile] {exc}", flush=True)


# --- guard --------------------------------------------------------------------
#
# Introducer mode is what lets an office LAN share one download, and it means
# every registered device is introduced to every field machine. A receive-only
# folder accepts newer files from *any* device it shares with, not only from
# this server, so one registrant whose own copy is Send & Receive - malicious,
# or a user who clicked the wrong option - could push a changed file to the
# whole cluster. Syncthing cannot be told "accept only the server's versions".
#
# What it does give us: on this server every catalog folder is Send Only, so
# the only way the server can "need" anything is a version that some *other*
# device made, and each version records who made it (modifiedBy). Honest
# clients never make one - receive-only changes are not announced. So: any
# need on a catalog folder names its culprit. Cut that device off (the
# introducer then removes it from every client) and Override, which makes
# this server's copy the newest again so the clients pull it back.

GUARD_SWEEP = int(os.environ.get("GUARD_SWEEP", "300"))  # full check, seconds
# report = log and mail what it would do, change nothing. For the first run
# after deploying, when old, honest clients may already have changes pending.
GUARD_MODE = os.environ.get("GUARD_MODE", "enforce").strip().lower()


def _q(s: str) -> str:
    return urllib.parse.quote(s, safe="")


def cut_off(device_id: str, reason: str) -> None:
    """Revoke a device the guard caught. Flag first, as `admin revoke` does,
    so neither the reconciler nor a fresh token can bring it straight back.
    A device with no row of ours still gets one, for the same reason."""
    conn = db()
    try:
        stamp = now()
        if conn.execute("UPDATE tokens SET revoked_at = COALESCE(revoked_at, ?) "
                        "WHERE device_id = ?", (stamp, device_id)).rowcount == 0:
            conn.execute("INSERT OR IGNORE INTO tokens (token, email, person, issued_at, "
                         "approved, device_id, revoked_at) VALUES (?, '(guard)', ?, ?, 0, ?, ?)",
                         ("guard:" + device_id, reason[:200], stamp, device_id, stamp))
        conn.commit()
    finally:
        conn.close()
    try:
        st("DELETE", "/rest/config/devices/" + _q(device_id))
    except urllib.error.HTTPError as exc:
        if exc.code != 404:
            raise


def guard_folder(fid: str) -> list[str]:
    """If anything but this server has changed catalog folder `fid`, cut the
    changer off and put the server's copy back. Returns the device IDs cut off."""
    status = st("GET", f"/rest/db/status?folder={_q(fid)}") or {}
    if not status.get("needTotalItems"):
        return []

    names: list[str] = []
    need = st("GET", f"/rest/db/need?folder={_q(fid)}&perpage=200") or {}
    for key in ("progress", "queued", "rest"):
        names += [f.get("name", "") for f in need.get(key) or []]
    names = [n for n in names if n]

    my_id = (st("GET", "/rest/system/status") or {}).get("myID", "")
    devices = [my_id] + [d["deviceID"] for d in st("GET", "/rest/config/devices") or []]
    culprits: set[str] = set()
    ours = False
    for name in names[:200]:
        info = st("GET", f"/rest/db/file?folder={_q(fid)}&file={_q(name)}") or {}
        by = ((info.get("global") or {}).get("modifiedBy") or "").upper()
        if not by:
            continue
        # modifiedBy is the short form: the first group of the device ID.
        dev = next((d for d in devices if d == by or d.split("-")[0] == by), "")
        if dev and dev != my_id:
            culprits.add(dev)
        ours = ours or dev == my_id

    files = ", ".join(names[:5]) + (f" and {len(names) - 5} more" if len(names) > 5 else "")
    if GUARD_MODE == "report":
        who = ", ".join(sorted(culprits)) or ("this server" if ours else "unknown")
        print(f"[guard] REPORT ONLY {fid}: {len(names)} item(s) changed by {who}; "
              f"would cut off and override ({files})", flush=True)
        if ADMIN_EMAIL and culprits:
            send_mail(ADMIN_EMAIL, f"LangTechDepot guard (report only): {fid}",
                      f"Folder {fid} has changes from: {who}\nItems: {files}\n\n"
                      "GUARD_MODE=report, so nothing was done. In enforce mode these\n"
                      "devices would be cut off and the folder overridden.\n")
        return []

    for dev in sorted(culprits):
        cut_off(dev, f"changed {fid}")
    # Cut off before Override: the other way round, the culprit could answer
    # the override with yet another newer version.
    st("POST", f"/rest/db/override?folder={_q(fid)}")

    who = (", ".join(sorted(culprits)) + "; cut off" if culprits else
           "this server's own older index" if ours else "a device no longer known")
    print(f"[guard] {fid}: {len(names)} item(s) changed by {who}; overridden ({files})",
          flush=True)
    if ADMIN_EMAIL and culprits:
        send_mail(ADMIN_EMAIL, f"LangTechDepot: foreign change to {fid} undone",
                  f"Folder {fid} was changed by a device other than the depot server.\n\n"
                  f"Device(s) cut off: {who}\nItems: {files}\n\n"
                  "The server's copy has been made the newest again (Override), so field\n"
                  "machines will pull it back. `ltd-sync-admin list` shows whose device it\n"
                  "was. If it was an honest mistake - someone switched the folder to\n"
                  "Send & Receive - have them set it back to Receive Only, then run\n"
                  "`ltd-sync-admin restore <device-id>`.\n")
    return sorted(culprits)


def guard_all() -> None:
    for fid in catalog_folder_ids():
        try:
            guard_folder(fid)
        except Exception as exc:  # noqa: BLE001 - one bad folder must not hide the rest
            print(f"[guard] {fid}: {exc}", flush=True)


def guard_loop():
    """React within seconds via Syncthing's event stream (FolderSummary follows
    every index change), and sweep everything every GUARD_SWEEP seconds in case
    an event was missed - e.g. Syncthing restarted and its event IDs began
    again from 1."""
    since, sweep_due, last_uptime = 0, 0.0, -1
    while True:
        try:
            if time.monotonic() >= sweep_due:
                uptime = (st("GET", "/rest/system/status") or {}).get("uptime", 0)
                if uptime < last_uptime:
                    since = 0
                last_uptime = uptime
                guard_all()
                sweep_due = time.monotonic() + GUARD_SWEEP
            events = st("GET", f"/rest/events?events=FolderSummary&since={since}&timeout=60",
                        timeout=90) or []
            catalog = set(catalog_folder_ids()) if events else set()
            for ev in events:
                since = max(since, ev.get("id", 0))
                data = ev.get("data") or {}
                if (data.get("folder") in catalog
                        and (data.get("summary") or {}).get("needTotalItems")):
                    guard_folder(data["folder"])
        except Exception as exc:  # noqa: BLE001 - the guard must outlive any one error
            print(f"[guard] {exc}", flush=True)
            time.sleep(10)


# --- admin --------------------------------------------------------------------

def admin(argv: list[str]) -> None:
    if not argv or argv[0] in ("-h", "--help", "help"):
        print("usage: register.py admin list [--pending]\n"
              "       register.py admin approve <token>\n"
              "       register.py admin revoke <email|device-id|token>\n"
              "       register.py admin restore <device-id>")
        return

    cmd, rest = argv[0], argv[1:]
    conn = db()
    try:
        if cmd == "list":
            q = "SELECT * FROM tokens"
            if "--pending" in rest:
                q += " WHERE approved = 0"
            for r in conn.execute(q + " ORDER BY issued_at DESC"):
                state = ("revoked" if r["revoked_at"] else
                         "active" if r["used_at"] else
                         "unused" if r["approved"] else "pending")
                print(f"{r['issued_at'][:10]}  {state:8}  {r['email']:<32} "
                      f"{r['device_name'] or '-':<24} {r['device_id'] or ''}")

        elif cmd == "approve":
            if not rest:
                sys.exit("approve needs a token")
            row = conn.execute("SELECT * FROM tokens WHERE token = ?", (rest[0],)).fetchone()
            if not row:
                sys.exit("no such token")
            conn.execute("UPDATE tokens SET approved = 1 WHERE token = ?", (rest[0],))
            conn.commit()
            if send_mail(row["email"], "Your LangTechDepot access token", token_mail(rest[0])):
                print(f"approved {row['email']}; token emailed")
            else:
                print(f"approved {row['email']}, but the mail did not go: send them "
                      f"{rest[0]} yourself")

        elif cmd == "revoke":
            if not rest:
                sys.exit("revoke needs an email, device ID, or token")
            key = rest[0]
            rows = conn.execute(
                "SELECT * FROM tokens WHERE email = ? OR device_id = ? OR token = ?",
                (key, key.upper(), key),
            ).fetchall()
            if not rows:
                sys.exit("nothing matched")
            # Flag first and commit, then delete from Syncthing. The other way
            # round, the reconciler (every 60 s) or a re-register could re-add
            # the device between the delete and the flag. The flag also makes
            # register_device refuse this device ID from now on, whatever token
            # it brings.
            stamp = now()
            for r in rows:
                conn.execute("UPDATE tokens SET revoked_at = COALESCE(revoked_at, ?) "
                             "WHERE token = ?", (stamp, r["token"]))
            conn.commit()
            for r in rows:
                # Removing the device from Syncthing is what actually cuts access.
                if r["device_id"]:
                    try:
                        st("DELETE", "/rest/config/devices/"
                                     + urllib.parse.quote(r["device_id"], safe=""))
                    except urllib.error.HTTPError as exc:
                        if exc.code != 404:
                            raise
                print(f"revoked {r['email']} {r['device_id'] or '(never used)'}")

        elif cmd == "restore":
            # For the honest mistake the guard catches: a folder switched to
            # Send & Receive. Fix that on the machine first, or the guard will
            # cut it off again at its next change. A re-run of the installer
            # cannot do this part: it finds the server already known and never
            # calls /register, so the device is re-added here.
            if not rest:
                sys.exit("restore needs a device ID")
            dev = rest[0].upper()
            rows = conn.execute("SELECT * FROM tokens WHERE device_id = ? "
                                "AND revoked_at IS NOT NULL", (dev,)).fetchall()
            if not rows:
                sys.exit("no revoked device with that ID")
            conn.execute("DELETE FROM tokens WHERE device_id = ? AND token LIKE 'guard:%'", (dev,))
            conn.execute("UPDATE tokens SET revoked_at = NULL WHERE device_id = ?", (dev,))
            conn.commit()
            name = next((r["device_name"] for r in rows if r["device_name"]), "") \
                or "langtechdepot-client"
            if dev not in {d["deviceID"] for d in st("GET", "/rest/config/devices") or []}:
                st("POST", "/rest/config/devices",
                   {"deviceID": dev, "name": name, "addresses": ["dynamic"]})
            share_catalog_with({dev})
            print(f"restored {dev} ({name})")
        else:
            sys.exit(f"unknown admin command: {cmd}")
    finally:
        conn.close()


def main() -> None:
    os.umask(0o027)	# user can have rwx, group can have rx, others have nothing.
    if len(sys.argv) > 1 and sys.argv[1] == "admin":
        admin(sys.argv[2:])
        return
    db()  # create schema before first request
    threading.Thread(target=reconcile_loop, daemon=True).start()
    threading.Thread(target=guard_loop, daemon=True).start()
    srv = ThreadingHTTPServer((LISTEN_HOST, LISTEN_PORT), Handler)
    print(f"[boot] listening on {LISTEN_HOST}:{LISTEN_PORT}  "
          f"auto-approve={AUTO_APPROVE}  smtp={'yes' if SMTP_HOST else 'no'}", flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
