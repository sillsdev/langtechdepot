"""End-to-end check of register.py against a stub Syncthing.

No network, no real Syncthing, no state outside a temp dir.

    python3 test_register.py
"""
import json, os, re, shutil, sqlite3, subprocess, sys, tempfile, threading, time, urllib.error, urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
TMP = tempfile.mkdtemp(prefix="langtechdepot-test-")
REPO = HERE
DB = os.path.join(TMP, "register.db")
DEV = "P56IOI7-MZJNU2Y-IQGDREY-DM2MGTI-MGL3BXN-PQ6W5BM-TBBZ4TJ-XZWICQ2"
DEV2 = "ABCDEF2-ABCDEF2-ABCDEF2-ABCDEF2-ABCDEF2-ABCDEF2-ABCDEF2-ABCDEF2"

state = {"devices": [], "folders": [{"id": "software-core", "devices": []},
                                    {"id": "training-videos", "devices": []}],
         "deleted": []}


class Fake(BaseHTTPRequestHandler):
    def log_message(self, *a): pass

    def _j(self, code, obj):
        b = json.dumps(obj).encode()
        self.send_response(code); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)

    def do_GET(self):
        if self.path == "/rest/system/status": self._j(200, {"myID": "SERVER1-SERVER1-SERVER1-SERVER1-SERVER1-SERVER1-SERVER1-SERVER1"})
        elif self.path == "/rest/config/devices": self._j(200, state["devices"])
        elif self.path == "/rest/config/folders": self._j(200, state["folders"])
        else: self._j(404, {})

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        if self.path == "/rest/config/devices":
            state["devices"].append(body); self._j(200, {})
        else: self._j(404, {})

    def do_PATCH(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        m = re.match(r"^/rest/config/folders/(.+)$", self.path)
        if m:
            for f in state["folders"]:
                if f["id"] == m.group(1): f["devices"] = body["devices"]
            self._j(200, {})
        else: self._j(404, {})

    def do_DELETE(self):
        m = re.match(r"^/rest/config/devices/(.+)$", self.path)
        if m:
            state["deleted"].append(m.group(1))
            state["devices"] = [d for d in state["devices"] if d["deviceID"] != m.group(1)]
            self._j(200, {})
        else: self._j(404, {})


def get(url, data=None, ctype="application/json"):
    req = urllib.request.Request(url, data=data, headers={"Content-Type": ctype} if data else {})
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            return r.status, r.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()


fake = ThreadingHTTPServer(("127.0.0.1", 18384), Fake)
threading.Thread(target=fake.serve_forever, daemon=True).start()

if os.path.exists(DB): os.remove(DB)
env = {**os.environ, "SYNCTHING_URL": "http://127.0.0.1:18384", "SYNCTHING_API_KEY": "test",
       "DB_PATH": DB, "LISTEN_PORT": "18385", "AUTO_APPROVE": "true", "SMTP_HOST": "",
       "SERVER_ADDRESS": "tcp://langtechdepot.example.org:22000"}
proc = subprocess.Popen([sys.executable, os.path.join(REPO, "register.py")], env=env,
                        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
B = "http://127.0.0.1:18385"
for _ in range(50):
    try:
        if get(B + "/healthz")[0] == 200: break
    except Exception: pass
    time.sleep(0.2)

fails = []
def check(name, cond, extra=""):
    print(("PASS " if cond else "FAIL ") + name + (f"  {extra}" if extra and not cond else ""))
    if not cond: fails.append(name)

# form renders
code, body = get(B + "/")
check("GET / serves form", code == 200 and "Send me a token" in body)

# ...and under its own name, which is what survives the instructions site
# eventually taking over "/" on this host.
code, body = get(B + "/signup?os=windows")
check("GET /signup serves the same form", code == 200 and "Send me a token" in body)
check("platform carried into the form", 'name="os" value="windows"' in body
      or "name=os value=\"windows\"" in body)

# bad email rejected
code, _ = get(B + "/request", b"person=X&email=notanemail", "application/x-www-form-urlencoded")
check("rejects malformed email", code == 400)

# issue a token
code, body = get(B + "/request",
                 b"person=Field+User&email=user%40sil.org&org=SIL&location=Chad&os=windows",
                 "application/x-www-form-urlencoded")
check("POST /request issues token", code == 200 and "Here is your token" in body)
tok = re.search(r'id=tok>([^<]+)<', body)
check("token shown (no SMTP configured)", tok is not None)
token = tok.group(1) if tok else ""

# The token page is a hand-off, not a dead end: something to copy it with, and
# the way back to step 2 on the platform page they came from.
check("token page offers a copy button", 'data-copy=tok' in body)
check("token page links back to step 2", "windows.html" in body)

conn = sqlite3.connect(DB); conn.row_factory = sqlite3.Row
row = conn.execute("SELECT * FROM tokens WHERE token=?", (token,)).fetchone()
check("token persisted with registrant", row is not None and row["email"] == "user@sil.org")

# malformed device ID rejected
code, body = get(B + "/register", json.dumps({"token": token, "deviceID": "NOPE", "deviceName": "x"}).encode())
check("rejects malformed device ID", code == 400 and "malformed" in body)

# unknown token rejected
code, body = get(B + "/register", json.dumps({"token": "bogus", "deviceID": DEV, "deviceName": "x"}).encode())
check("rejects unknown token", code == 400 and "unknown token" in body)

# real registration
code, body = get(B + "/register", json.dumps({"token": token, "deviceID": DEV, "deviceName": "user-laptop"}).encode())
res = json.loads(body) if code == 200 else {}
check("register succeeds", code == 200 and res.get("ok"), body)
check("returns server device ID", res.get("serverDeviceID", "").startswith("SERVER1"))
check("returns server address", "tcp://langtechdepot.example.org:22000" in res.get("serverAddresses", []))
check("returns both catalog folders", sorted(res.get("folders", [])) == ["software-core", "training-videos"])
check("device added to syncthing", any(d["deviceID"] == DEV for d in state["devices"]))
check("device name carries no token", all(token not in d.get("name", "") for d in state["devices"]))
check("shared on every folder", all(any(d["deviceID"] == DEV for d in f["devices"]) for f in state["folders"]))

# single-use: same token, different machine
code, body = get(B + "/register", json.dumps({"token": token, "deviceID": DEV2, "deviceName": "other"}).encode())
check("token is single-use", code == 400 and "already been used" in body)

# same machine re-running the installer is not punished
code, _ = get(B + "/register", json.dumps({"token": token, "deviceID": DEV, "deviceName": "user-laptop"}).encode())
check("re-run on same machine is idempotent", code == 200)

# a folder added later reaches existing registrants via the reconciler
state["folders"].append({"id": "docs", "devices": []})
conn.close()
subprocess.run([sys.executable, os.path.join(REPO, "register.py"), "admin", "list"], env=env,
               capture_output=True, text=True)
time.sleep(0)  # reconciler runs on its own 60s cadence; exercise the function directly instead
sys.path.insert(0, REPO)
os.environ.update({k: env[k] for k in ("SYNCTHING_URL", "SYNCTHING_API_KEY", "DB_PATH", "SERVER_ADDRESS")})
import register as reg  # noqa: E402
reg.share_catalog_with({DEV})
check("late-added folder gets shared", any(d["deviceID"] == DEV for d in state["folders"][-1]["devices"]))

# admin list
out = subprocess.run([sys.executable, os.path.join(REPO, "register.py"), "admin", "list"],
                     env=env, capture_output=True, text=True).stdout
check("admin list shows the registrant", "user@sil.org" in out and "active" in out, out)

# admin revoke removes the device from syncthing
out = subprocess.run([sys.executable, os.path.join(REPO, "register.py"), "admin", "revoke", "user@sil.org"],
                     env=env, capture_output=True, text=True).stdout
check("admin revoke reports", "revoked user@sil.org" in out, out)
check("revoke deleted device from syncthing", DEV in state["deleted"])

code, body = get(B + "/register", json.dumps({"token": token, "deviceID": DEV, "deviceName": "x"}).encode())
check("revoked token refused", code == 400 and "revoked" in body)

proc.terminate()
shutil.rmtree(TMP, ignore_errors=True)
print()
print(f"{len(fails)} failure(s)" + (": " + ", ".join(fails) if fails else ""))
sys.exit(1 if fails else 0)
