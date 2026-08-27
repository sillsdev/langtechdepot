#!/usr/bin/env python3
"""LangTran registration service.

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
import json
import os
import re
import secrets
import smtplib
import sqlite3
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

# Canonical Syncthing device ID: 8 dash-separated groups of 7 base32 chars.
DEVICE_ID_RE = re.compile(r"^[A-Z2-7]{7}(-[A-Z2-7]{7}){7}$")
EMAIL_RE = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")

SYNCTHING_URL = os.environ.get("SYNCTHING_URL", "http://127.0.0.1:8384").rstrip("/")
DB_PATH = os.environ.get("DB_PATH", "/var/lib/langtran/register.db")
LISTEN_HOST = os.environ.get("LISTEN_HOST", "127.0.0.1")
LISTEN_PORT = int(os.environ.get("LISTEN_PORT", "8385"))
PUBLIC_URL = os.environ.get("PUBLIC_URL", "").rstrip("/")
AUTO_APPROVE = os.environ.get("AUTO_APPROVE", "true").lower() not in ("0", "false", "no")
CATALOG_FOLDERS = {f.strip() for f in os.environ.get("CATALOG_FOLDERS", "").split(",") if f.strip()}
ADMIN_EMAIL = os.environ.get("ADMIN_EMAIL", "")
SMTP_HOST = os.environ.get("SMTP_HOST", "")
SMTP_PORT = int(os.environ.get("SMTP_PORT", "587"))
SMTP_USER = os.environ.get("SMTP_USER", "")
SMTP_PASS = os.environ.get("SMTP_PASS", "")
MAIL_FROM = os.environ.get("MAIL_FROM", "langtran@sil.org")

# Registration is cheap but not free: cap attempts per client address so a
# script cannot mint tokens or grind at /register unbounded.
RATE_LIMIT = (10, 3600)  # attempts, seconds
_rate: dict[str, list[float]] = {}
_rate_lock = threading.Lock()


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


def st(method: str, path: str, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(
        SYNCTHING_URL + path, data=data, method=method,
        headers={"X-API-Key": KEY, "Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
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
    return conn


def rate_ok(addr: str) -> bool:
    limit, window = RATE_LIMIT
    cutoff = time.monotonic() - window
    with _rate_lock:
        hits = [t for t in _rate.get(addr, []) if t > cutoff]
        hits.append(time.monotonic())
        _rate[addr] = hits
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
            s.starttls()
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
    """Add device_ids to every catalog folder's device list. PATCH replaces
    child arrays wholesale, so read-modify-write rather than append."""
    touched = []
    for folder in st("GET", "/rest/config/folders") or []:
        if CATALOG_FOLDERS and folder["id"] not in CATALOG_FOLDERS:
            continue
        have = {d["deviceID"] for d in folder.get("devices", [])}
        missing = device_ids - have
        if not missing:
            touched.append(folder["id"])
            continue
        new_devices = folder.get("devices", []) + [{"deviceID": d} for d in sorted(missing)]
        st("PATCH", f"/rest/config/folders/{folder['id']}", {"devices": new_devices})
        touched.append(folder["id"])
    return touched


def register_device(token: str, device_id: str, device_name: str) -> dict:
    """Validate a single-use token and admit the device. Raises ValueError with
    a user-safe message on any rejection."""
    if not DEVICE_ID_RE.match(device_id):
        raise ValueError("malformed device ID")
    device_name = re.sub(r"[^\w .-]", "", device_name)[:64] or "langtran-client"

    conn = db()
    try:
        row = conn.execute("SELECT * FROM tokens WHERE token = ?", (token,)).fetchone()
        if row is None:
            raise ValueError("unknown token")
        if row["revoked_at"]:
            raise ValueError("token has been revoked")
        if not row["approved"]:
            raise ValueError("registration is awaiting approval; you will be emailed")
        if row["used_at"] and row["device_id"] != device_id:
            raise ValueError("token has already been used on another machine")

        existing = {d["deviceID"] for d in st("GET", "/rest/config/devices") or []}
        if device_id not in existing:
            st("POST", "/rest/config/devices", {
                "deviceID": device_id,
                "name": device_name,     # deliberately carries no token: peers see this
                "addresses": ["dynamic"],
            })
        folders = share_catalog_with({device_id})

        conn.execute(
            "UPDATE tokens SET used_at = ?, device_id = ?, device_name = ? WHERE token = ?",
            (now(), device_id, device_name, token),
        )
        conn.commit()
    finally:
        conn.close()

    me = st("GET", "/rest/system/status") or {}
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
        send_mail(ADMIN_EMAIL, "LangTran registration",
                  f"{person or '(no name)'} <{email}>\norg: {org}\nlocation: {location}\n"
                  f"approved: {AUTO_APPROVE}\n")
    if not AUTO_APPROVE:
        return token, False
    emailed = send_mail(
        email, "Your LangTran access token",
        f"Paste this token into the LangTran Sync installer when it asks:\n\n    {token}\n\n"
        "It works once, on one machine. Need another machine? Register again.\n",
    )
    return token, emailed


# --- HTTP ---------------------------------------------------------------------

PAGE = """<!doctype html><meta charset=utf-8>
<meta name=viewport content="width=device-width,initial-scale=1">
<title>LangTran &mdash; register</title>
<style>
 body{{font:16px/1.55 system-ui,sans-serif;max-width:34rem;margin:3rem auto;padding:0 1.25rem;color:#1a1a1a}}
 h1{{font-size:1.5rem;margin:0 0 .35rem}} p.sub{{color:#555;margin:0 0 1.75rem}}
 label{{display:block;margin:1rem 0 .3rem;font-weight:600;font-size:.92rem}}
 input{{width:100%;padding:.55rem .65rem;font:inherit;border:1px solid #bbb;border-radius:6px}}
 button{{margin-top:1.5rem;padding:.6rem 1.4rem;font:inherit;font-weight:600;
   background:#1f5fa9;color:#fff;border:0;border-radius:6px;cursor:pointer}}
 .note{{background:#f4f6f8;border-left:3px solid #1f5fa9;padding:.9rem 1.1rem;margin:1.5rem 0;border-radius:0 6px 6px 0}}
 code{{background:#eef1f4;padding:.15rem .4rem;border-radius:4px;font-size:.95em;word-break:break-all}}
 .tok{{display:block;padding:.9rem;margin:.6rem 0;font-size:1.05rem;text-align:center}}
</style>
{body}
"""

FORM = """<h1>LangTran access</h1>
<p class=sub>Register to sync SIL software and training material to your machine.
We&rsquo;ll issue you a token to paste into the installer.</p>
<form method=post action=/request>
 <label for=person>Your name</label><input id=person name=person required>
 <label for=email>Email</label><input id=email name=email type=email required>
 <label for=org>Organisation / entity</label><input id=org name=org>
 <label for=location>Where you work</label><input id=location name=location
   placeholder="country or region">
 <button type=submit>Request token</button>
</form>
<div class=note>Already have a token? Run the installer from
<a href="https://github.com/sillsdev/langtran-sync">github.com/sillsdev/langtran-sync</a>
and paste it when prompted.</div>"""


class Handler(BaseHTTPRequestHandler):
    server_version = "langtran-register"

    def log_message(self, fmt, *args):
        print(f"[http] {self.address_string()} {fmt % args}", flush=True)

    def _send(self, code: int, body: bytes, ctype: str):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.end_headers()
        self.wfile.write(body)

    def _page(self, code: int, body: str):
        self._send(code, PAGE.format(body=body).encode(), "text/html; charset=utf-8")

    def _json(self, code: int, obj: dict):
        self._send(code, json.dumps(obj).encode(), "application/json")

    def do_GET(self):
        path = urllib.parse.urlparse(self.path).path
        if path == "/healthz":
            self._json(200, {"ok": True})
        elif path == "/":
            self._page(200, FORM)
        else:
            self._page(404, "<h1>Not found</h1>")

    def do_POST(self):
        path = urllib.parse.urlparse(self.path).path
        length = int(self.headers.get("Content-Length") or 0)
        if length > 64_000:
            self._json(413, {"ok": False, "error": "too large"})
            return
        raw = self.rfile.read(length)

        if not rate_ok(self.client_address[0]):
            if path == "/register":
                self._json(429, {"ok": False, "error": "too many attempts; try again later"})
            else:
                self._page(429, "<h1>Too many attempts</h1><p>Try again later.</p>")
            return

        if path == "/register":
            try:
                payload = json.loads(raw)
                result = register_device(
                    str(payload["token"]).strip(),
                    str(payload["deviceID"]).strip().upper(),
                    str(payload.get("deviceName", "")).strip(),
                )
            except (KeyError, ValueError, json.JSONDecodeError) as exc:
                self._json(400, {"ok": False, "error": str(exc)})
            except urllib.error.URLError as exc:
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
            if not EMAIL_RE.match(email):
                self._page(400, "<h1>Check your email address</h1>"
                                "<p><a href=/>Back to the form</a></p>")
                return
            token, emailed = issue_token(email, person, org, location)
            if not AUTO_APPROVE:
                self._page(200, "<h1>Request received</h1><p>An administrator will review it "
                                "and email your token.</p>")
            elif emailed:
                self._page(200, f"<h1>Token sent</h1><p>Check <code>{html.escape(email)}</code>. "
                                "Paste the token into the installer when it asks.</p>")
            else:
                self._page(200, "<h1>Your token</h1><p>Copy this now &mdash; it is shown once, "
                                "works once, on one machine.</p>"
                                f"<code class=tok>{html.escape(token)}</code>")
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
                "WHERE device_id IS NOT NULL AND revoked_at IS NULL"
            ).fetchall()
            conn.close()
            ids = {r["device_id"] for r in rows if r["device_id"]}
            if ids:
                share_catalog_with(ids)
        except Exception as exc:  # noqa: BLE001 - a bad cycle must not kill the thread
            print(f"[reconcile] {exc}", flush=True)


# --- admin --------------------------------------------------------------------

def admin(argv: list[str]) -> None:
    if not argv or argv[0] in ("-h", "--help", "help"):
        print("usage: register.py admin list [--pending]\n"
              "       register.py admin approve <token>\n"
              "       register.py admin revoke <email|device-id|token>")
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
            send_mail(row["email"], "Your LangTran access token",
                      f"Paste this token into the LangTran Sync installer when it asks:\n\n"
                      f"    {rest[0]}\n\nIt works once, on one machine.\n")
            print(f"approved {row['email']}")

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
            for r in rows:
                # Removing the device from Syncthing is what actually cuts access;
                # the DB flag only keeps the reconciler from re-adding it.
                if r["device_id"]:
                    try:
                        st("DELETE", f"/rest/config/devices/{r['device_id']}")
                    except urllib.error.HTTPError as exc:
                        if exc.code != 404:
                            raise
                conn.execute("UPDATE tokens SET revoked_at = ? WHERE token = ?", (now(), r["token"]))
                print(f"revoked {r['email']} {r['device_id'] or '(never used)'}")
            conn.commit()
        else:
            sys.exit(f"unknown admin command: {cmd}")
    finally:
        conn.close()


def main() -> None:
    if len(sys.argv) > 1 and sys.argv[1] == "admin":
        admin(sys.argv[2:])
        return
    db()  # create schema before first request
    threading.Thread(target=reconcile_loop, daemon=True).start()
    srv = ThreadingHTTPServer((LISTEN_HOST, LISTEN_PORT), Handler)
    print(f"[boot] listening on {LISTEN_HOST}:{LISTEN_PORT}  "
          f"auto-approve={AUTO_APPROVE}  smtp={'yes' if SMTP_HOST else 'no'}", flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
