"""End-to-end check of register.py against a stub Syncthing.

No network, no real Syncthing, no state outside a temp dir.

    python3 test_register.py
"""
import json, os, re, shutil, socket, sqlite3, subprocess, sys, tempfile, threading, time, urllib.error, urllib.parse, urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
TMP = tempfile.mkdtemp(prefix="langtechdepot-test-")
REPO = HERE
DB = os.path.join(TMP, "register.db")
DEV = "P56IOI7-MZJNU2Y-IQGDREY-DM2MGTI-MGL3BXN-PQ6W5BM-TBBZ4TJ-XZWICQ2"
DEV2 = "ABCDEF2-ABCDEF2-ABCDEF2-ABCDEF2-ABCDEF2-ABCDEF2-ABCDEF2-ABCDEF2"
# Fits DEVICE_ID_RE, but the stub Syncthing refuses it, as the real one does a
# device ID whose check digits are wrong.
BADLUHN = "BADBADB-BADBADB-BADBADB-BADBADB-BADBADB-BADBADB-BADBADB-BADBADB"
SERVER = "SERVER1-SERVER1-SERVER1-SERVER1-SERVER1-SERVER1-SERVER1-SERVER1"
DEV3 = "GUARDED-GUARDED-GUARDED-GUARDED-GUARDED-GUARDED-GUARDED-GUARDED"

state = {"devices": [], "folders": [{"id": "software-core", "devices": []},
                                    {"id": "training-videos", "devices": []}],
         "deleted": [], "patches": [],
         # Versions some other device made, per folder: {file: modifiedBy}.
         # On a Send Only folder that is exactly what the server "needs".
         "foreign": {}, "overrides": []}


class Fake(BaseHTTPRequestHandler):
    def log_message(self, *a): pass

    def _j(self, code, obj):
        b = json.dumps(obj).encode()
        self.send_response(code); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)

    def do_GET(self):
        u = urllib.parse.urlparse(self.path)
        q = {k: v[0] for k, v in urllib.parse.parse_qs(u.query).items()}
        foreign = state["foreign"].get(q.get("folder"), {})
        if u.path == "/rest/system/status": self._j(200, {"myID": SERVER, "uptime": 100})
        elif u.path == "/rest/config/devices": self._j(200, state["devices"])
        elif u.path == "/rest/config/folders": self._j(200, state["folders"])
        elif u.path == "/rest/db/status": self._j(200, {"needTotalItems": len(foreign)})
        elif u.path == "/rest/db/need":
            self._j(200, {"progress": [], "queued": [], "rest": [{"name": n} for n in foreign]})
        elif u.path == "/rest/db/file":
            self._j(200, {"global": {"name": q["file"], "modifiedBy": foreign.get(q["file"], "")}})
        elif u.path == "/rest/events":
            time.sleep(1); self._j(200, [])  # a long-poll with nothing to say
        else: self._j(404, {})

    def do_POST(self):
        u = urllib.parse.urlparse(self.path)
        if u.path == "/rest/db/override":
            fid = urllib.parse.parse_qs(u.query)["folder"][0]
            state["overrides"].append(fid); state["foreign"].pop(fid, None)
            self._j(200, {}); return
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        if self.path == "/rest/config/devices" and body.get("deviceID") == BADLUHN:
            b = b"invalid device ID: check character incorrect\n"
            self.send_response(400); self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
        elif self.path == "/rest/config/devices":
            state["devices"].append(body); self._j(200, {})
        else: self._j(404, {})

    def do_PATCH(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        m = re.match(r"^/rest/config/folders/(.+)$", self.path)
        if m:
            # Syncthing merges the keys it is given; only child arrays are
            # replaced wholesale. Applying the whole body is what makes type
            # observable here.
            state["patches"].append((m.group(1), body))
            for f in state["folders"]:
                if f["id"] == m.group(1): f.update(body)
            self._j(200, {})
        else: self._j(404, {})

    def do_DELETE(self):
        m = re.match(r"^/rest/config/devices/(.+)$", self.path)
        if m:
            state["deleted"].append(m.group(1))
            state["devices"] = [d for d in state["devices"] if d["deviceID"] != m.group(1)]
            self._j(200, {})
        else: self._j(404, {})


def fetch(url, data=None, ctype="application/json", headers=None):
    """(status, body, headers) for one request; errors are answers too."""
    h = dict(headers or {})
    if data is not None: h["Content-Type"] = ctype
    req = urllib.request.Request(url, data=data, headers=h)
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            return r.status, r.read().decode(), r.headers
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode(), e.headers


def get(url, data=None, ctype="application/json", headers=None):
    code, body, _ = fetch(url, data, ctype, headers)
    return code, body


def raw_post(path, content_length, body=b""):
    """A POST with a Content-Length urllib would never send, for the cases
    the service has to survive anyway. Returns the status code."""
    with socket.create_connection(("127.0.0.1", 18385), timeout=10) as s:
        s.sendall(f"POST {path} HTTP/1.1\r\nHost: x\r\nContent-Type: application/json\r\n"
                  f"Content-Length: {content_length}\r\nConnection: close\r\n\r\n".encode() + body)
        line = s.makefile("rb").readline().decode()
    return int(line.split()[1])


def new_token(xff):
    """Fill the form in as a client at address xff, return the token."""
    _, body = get(B + "/request", b"person=T&email=t%40sil.org", "application/x-www-form-urlencoded",
                  {"X-Forwarded-For": xff})
    m = re.search(r'id=tok>([^<]+)<', body)
    return m.group(1) if m else ""


def register(tok, dev, xff="198.51.100.1"):
    return get(B + "/register", json.dumps({"token": tok, "deviceID": dev, "deviceName": "t"}).encode(),
               headers={"X-Forwarded-For": xff})


fake = ThreadingHTTPServer(("127.0.0.1", 18384), Fake)
threading.Thread(target=fake.serve_forever, daemon=True).start()

if os.path.exists(DB): os.remove(DB)
# Run on the depot server, register.py would otherwise read the live
# /etc/langtechdepot/register.env (CATALOG_FOLDERS, SMTP, ...). Point it at a
# file that does not exist, and pin every setting the tests depend on as
# well: set variables win over the file.
ISOLATE = {"REGISTER_ENV": os.path.join(TMP, "no-such.env"),
           "SYNCTHING_URL": "http://127.0.0.1:18384", "SYNCTHING_API_KEY": "test",
           "SYNCTHING_CONFIG": "", "DB_PATH": DB, "LISTEN_HOST": "127.0.0.1",
           "LISTEN_PORT": "18385", "AUTO_APPROVE": "true", "CATALOG_FOLDERS": "",
           "SMTP_HOST": "", "ADMIN_EMAIL": "", "PUBLIC_URL": "",
           "SITE_URL": "https://depot.langtech.cloud",
           "SERVER_ADDRESS": "tcp://langtechdepot.example.org:22000",
           # The service's own guard sweeps once at boot, then waits on events
           # (the stub has none); the tests call guard_folder() themselves.
           "GUARD_SWEEP": "3600"}
env = {**os.environ, **ISOLATE}
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
check("GET / serves form", code == 200 and "Get my token" in body)

# ...and under its own name, which is what survives the instructions site
# eventually taking over "/" on this host.
code, body = get(B + "/signup?os=windows")
check("GET /signup serves the same form", code == 200 and "Get my token" in body)
check("platform carried into the form", 'name="os" value="windows"' in body
      or "name=os value=\"windows\"" in body)

# bad email rejected
code, _ = get(B + "/request", b"person=X&email=notanemail", "application/x-www-form-urlencoded")
check("rejects malformed email", code == 400)

# issue a token
code, body, hdrs = fetch(B + "/request",
                         b"person=Field+User&email=user%40sil.org&org=SIL&location=Chad&os=windows",
                         "application/x-www-form-urlencoded")
check("POST /request issues token", code == 200 and "Here is your token" in body)
check("token page is not cached", "no-store" in (hdrs.get("Cache-Control") or ""), hdrs.get("Cache-Control"))
check("token page refuses to be framed", hdrs.get("X-Frame-Options") == "DENY"
      and "frame-ancestors 'none'" in (hdrs.get("Content-Security-Policy") or ""))
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

# Bodies the service must refuse rather than hang on or crash over.
check("negative Content-Length is a 400", raw_post("/register", "-5") == 400)
check("non-integer Content-Length is a 400", raw_post("/register", "abc") == 400)
check("JSON array body is a 400, not a crash", raw_post("/register", 6, b"[1, 2]") == 400)
check("JSON string body is a 400, not a crash", raw_post("/register", 5, b'"abc"') == 400)

# Syncthing refusing the device (an ID that fits the pattern but fails its
# check digits) is not "busy": say so, and leave the token usable.
t_bad = new_token("198.51.100.10")
code, body = register(t_bad, BADLUHN)
check("syncthing refusal is reported as such, not as busy",
      code == 502 and "will not help" in body and "busy" not in body, f"{code} {body}")
OTHER = "QRSTUVW-QRSTUVW-QRSTUVW-QRSTUVW-QRSTUVW-QRSTUVW-QRSTUVW-QRSTUVW"
code, body = register(t_bad, OTHER)
check("token released after syncthing refused, so a retry works", code == 200, f"{code} {body}")

# Two installers racing one unused token: exactly one may win.
t_race = new_token("198.51.100.11")
racers = ["-".join([c * 7] * 8) for c in "CDEFGHIJ"]
results, gate = {}, threading.Barrier(len(racers))
def race(dev):
    gate.wait()
    results[dev] = register(t_race, dev, "198.51.100.12")
threads = [threading.Thread(target=race, args=(d,)) for d in racers]
for t in threads: t.start()
for t in threads: t.join()
wins = [d for d, (c, _) in results.items() if c == 200]
losses = [b for c, b in results.values() if c != 200]
check("one token, racing machines: exactly one admitted", len(wins) == 1, f"{len(wins)} admitted")
check("the losers are told it was already used",
      len(losses) == len(racers) - 1 and all("already been used" in b for b in losses), losses)

# a folder added later reaches existing registrants via the reconciler
state["folders"].append({"id": "docs", "devices": []})
conn.close()
subprocess.run([sys.executable, os.path.join(REPO, "register.py"), "admin", "list"], env=env,
               capture_output=True, text=True)
time.sleep(0)  # reconciler runs on its own 60s cadence; exercise the function directly instead
sys.path.insert(0, REPO)
os.environ.update(ISOLATE)
import register as reg  # noqa: E402
reg.share_catalog_with({DEV})
check("late-added folder gets shared", any(d["deviceID"] == DEV for d in state["folders"][-1]["devices"]))
check("catalog folders are forced Send Only", all(f.get("type") == "sendonly" for f in state["folders"]))

# Steady state must be free: the reconciler runs every 60s forever.
before = len(state["patches"])
reg.share_catalog_with({DEV})
check("nothing to change means nothing is written", len(state["patches"]) == before,
      f"{len(state['patches']) - before} write(s)")

# Adding a device to a folder that is already Send Only must not resend the
# type, so the journal never claims a flip that did not happen.
before = len(state["patches"])
reg.share_catalog_with({DEV, DEV2})
sent = state["patches"][before:]
check("adding a device to a Send Only folder sends only the device list",
      sent and all(set(body) == {"devices"} for _, body in sent),
      [sorted(body) for _, body in sent])

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

# A fresh token from the form must not bring a revoked machine back.
t_new = new_token("198.51.100.13")
code, body = register(t_new, DEV)
check("revoked device refused even with a fresh token", code == 400 and "revoked" in body, body)
check("revoked device not re-added to syncthing", all(d["deviceID"] != DEV for d in state["devices"]))

# The guard: introducer mode lets any registered device reach every field
# machine, so a change to a catalog folder by anything but the server must
# cost that device its access and be undone.
t3 = new_token("198.51.100.20")
# Report mode: names the culprit, touches nothing.
reg.GUARD_MODE = "report"
state["foreign"]["software-core"] = {"x.txt": "P56IOI7"}
before = (len(state["overrides"]), len(state["deleted"]))
check("guard in report mode changes nothing",
      reg.guard_folder("software-core") == [] and
      (len(state["overrides"]), len(state["deleted"])) == before and state["foreign"]["software-core"])
reg.GUARD_MODE = "enforce"
del state["foreign"]["software-core"]
check("guard test device registers", register(t3, DEV3, "198.51.100.20")[0] == 200)
state["foreign"]["software-core"] = {"setup.exe": "GUARDED", "README.txt": "GUARDED"}
cut = reg.guard_folder("software-core")
check("guard names the device that changed a catalog folder", cut == [DEV3], cut)
check("guard removes that device from syncthing",
      DEV3 in state["deleted"] and all(d["deviceID"] != DEV3 for d in state["devices"]))
check("guard puts the server's copy back (override)",
      "software-core" in state["overrides"] and "software-core" not in state["foreign"])
code, body = register(new_token("198.51.100.21"), DEV3, "198.51.100.21")
check("a device the guard cut off cannot come back with a fresh token",
      code == 400 and "revoked" in body, body)

before = len(state["overrides"])
check("guard does nothing when nothing foreign is there",
      reg.guard_folder("software-core") == [] and len(state["overrides"]) == before)
state["foreign"]["training-videos"] = {"a.txt": SERVER.split("-")[0]}
check("guard never cuts off the server itself, but still overrides",
      reg.guard_folder("training-videos") == [] and "training-videos" in state["overrides"])

out = subprocess.run([sys.executable, os.path.join(REPO, "register.py"), "admin", "restore", DEV3],
                     env=env, capture_output=True, text=True)
check("admin restore re-admits a device the guard cut off",
      "restored" in out.stdout and any(d["deviceID"] == DEV3 for d in state["devices"]),
      out.stdout + out.stderr)
check("a restored device can re-run the installer with its old token",
      register(t3, DEV3, "198.51.100.22")[0] == 200)

# Approval mode (the launch setting): a request waits for a person.
reg.AUTO_APPROVE = False
t4, mailed = reg.issue_token("wait@sil.org", "W", "", "")
check("with approval on, a request mints no usable token yet", t4 and not mailed)
check("the form says a person checks it", "check each request by hand" in reg.form_page("windows"))
code, body = register(t4, DEV2, "198.51.100.23")
check("an unapproved token is refused", code == 400 and "awaiting approval" in body, body)
out = subprocess.run([sys.executable, os.path.join(REPO, "register.py"), "admin", "approve", t4],
                     env=env, capture_output=True, text=True).stdout
check("approve says when the mail could not go", "send them" in out and t4 in out, out)
check("an approved token works", register(t4, DEV2, "198.51.100.23")[0] == 200)
reg.AUTO_APPROVE = True

# Behind Caddy every peer is 127.0.0.1; the bucket is the last X-Forwarded-For.
def form_from(xff):
    return get(B + "/request", b"person=X&email=bad", "application/x-www-form-urlencoded",
               {"X-Forwarded-For": xff})[0]
codes = [form_from("203.0.113.5") for _ in range(10)]
check("form allows ten attempts per client", all(c == 400 for c in codes), codes)
check("eleventh form attempt from the same client is refused", form_from("203.0.113.5") == 429)
check("a different client is not in that bucket", form_from("203.0.113.6") == 400)
check("only the last X-Forwarded-For entry counts",
      form_from("203.0.113.5, 203.0.113.7") == 400 and form_from("203.0.113.7, 203.0.113.5") == 429)
check("the installer's bucket is separate from the form's",
      register("bogus", DEV2, "203.0.113.5")[0] == 400)

proc.terminate()
shutil.rmtree(TMP, ignore_errors=True)
print()
print(f"{len(fails)} failure(s)" + (": " + ", ".join(fails) if fails else ""))
sys.exit(1 if fails else 0)
