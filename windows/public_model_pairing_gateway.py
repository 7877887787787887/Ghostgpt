#!/usr/bin/env python3
"""Public, model-only pairing gateway for GhostGPT. Never exposes the terminal API."""
from __future__ import annotations
import hashlib, hmac, json, logging, os, secrets, subprocess, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.request import Request, urlopen
import http.client

HOST, PORT = "127.0.0.1", 8768
UPSTREAM_HOST, UPSTREAM_PORT = "127.0.0.1", 1234
LMS_EXE = Path.home() / ".lmstudio" / "bin" / "lms.exe"
DATA_DIR = Path(os.environ.get("PROGRAMDATA", r"C:\ProgramData")) / "GhostGPT"
DATA_DIR.mkdir(parents=True, exist_ok=True)
PAIR_FILE = DATA_DIR / "public-model-pairing.json"
TOKEN_FILE = DATA_DIR / "public-model.token"
LOG_FILE = DATA_DIR / "public-model-gateway.log"
logging.basicConfig(filename=str(LOG_FILE), level=logging.INFO,
                    format="%(asctime)s %(levelname)s %(message)s")
MAX_BODY = 8 * 1024 * 1024
pair_lock = threading.Lock()
start_lock = threading.Lock()
attempts: dict[str, list[float]] = {}
IS_WINDOWS = os.name == "nt"

def read_token() -> str:
    try: return TOKEN_FILE.read_text(encoding="utf-8").strip()
    except OSError: return ""

def models(timeout=4):
    req = Request(f"http://{UPSTREAM_HOST}:{UPSTREAM_PORT}/v1/models", headers={"Accept":"application/json"})
    with urlopen(req, timeout=timeout) as r: payload = json.loads(r.read().decode("utf-8"))
    return [x.get("id","") for x in payload.get("data",[]) if x.get("id")]

def ensure_server():
    try:
        found = models()
        if found: return found
    except Exception: pass
    with start_lock:
        try:
            found = models()
            if found: return found
        except Exception: pass
        if not IS_WINDOWS or not LMS_EXE.exists():
            raise RuntimeError("LM Studio CLI is unavailable on this PC")
        try:
            subprocess.run([str(LMS_EXE), "server", "start"], stdin=subprocess.DEVNULL,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=35,
                           creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0), check=False)
        except subprocess.TimeoutExpired: pass
        deadline = time.monotonic() + 65
        while time.monotonic() < deadline:
            try:
                found = models(3)
                if found: return found
            except Exception: pass
            time.sleep(2)
    raise RuntimeError("LM Studio did not become ready")

def limited(ip: str) -> bool:
    now = time.monotonic()
    recent = [t for t in attempts.get(ip, []) if now-t < 600]
    attempts[ip] = recent
    return len(recent) >= 8

def consume_pair_code(code: str, ip: str) -> bool:
    with pair_lock:
        if limited(ip): return False
        attempts.setdefault(ip, []).append(time.monotonic())
        try: record = json.loads(PAIR_FILE.read_text(encoding="utf-8"))
        except Exception: return False
        if record.get("used") or time.time() > float(record.get("expires_at", 0)): return False
        expected = str(record.get("code", ""))
        if not expected or not hmac.compare_digest(code, expected): return False
        record["used"] = True
        record["code"] = ""
        PAIR_FILE.write_text(json.dumps(record), encoding="utf-8")
        return True

class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "GhostGPTModelPair/1.0"
    def log_message(self, fmt, *args): logging.info("%s - %s", self.client_address[0], fmt % args)
    def send_json(self, status, obj):
        raw = json.dumps(obj, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header("Content-Type","application/json; charset=utf-8")
        self.send_header("Content-Length",str(len(raw)))
        self.send_header("Cache-Control","no-store")
        self.send_header("Connection","close")
        self.end_headers()
        if self.command != "HEAD": self.wfile.write(raw)
        self.close_connection = True
    def auth(self):
        expected = read_token()
        header = self.headers.get("Authorization","")
        scheme, sep, supplied = header.partition(" ")
        return bool(expected and sep and scheme.lower()=="bearer" and hmac.compare_digest(supplied, expected))
    def do_POST(self):
        path = self.path.split("?",1)[0]
        try:
            n = int(self.headers.get("Content-Length","0"))
            if n < 0 or n > MAX_BODY: self.send_json(413, {"error":"Invalid or oversized request"}); return
            raw = self.rfile.read(n) if n else b"{}"
            data = json.loads(raw.decode("utf-8"))
        except Exception:
            self.send_json(400, {"error":"Invalid JSON request"}); return
        if path == "/pair":
            code = str(data.get("code","")).strip()
            if len(code) > 100 or not consume_pair_code(code, self.client_address[0]):
                self.send_json(403, {"error":"Pairing code is invalid, expired, already used, or rate-limited"}); return
            token = read_token()
            if not token: self.send_json(503, {"error":"Pairing is not configured on the PC"}); return
            logging.info("One-time pairing code redeemed from %s", self.client_address[0])
            self.send_json(200, {"ok":True,"token":token,"endpoint":f"https://msi.tail28f016.ts.net:10001"})
            return
        if not self.auth(): self.send_json(401, {"error":"Unauthorized"}); return
        if path == "/control/start":
            try:
                found = ensure_server()
                self.send_json(200, {"ok":True,"ready":True,"model_count":len(found),"models":found})
            except Exception as exc:
                logging.warning("Model start/readiness failed: %s", exc)
                self.send_json(503, {"ok":False,"ready":False,"error":"LM Studio is not ready"})
            return
        if path.startswith("/v1/") or path == "/v1":
            self.proxy(path, raw); return
        self.send_json(404, {"error":"Not found"})
    def do_GET(self):
        path = self.path.split("?",1)[0]
        if not self.auth(): self.send_json(401, {"error":"Unauthorized"}); return
        if path == "/control/status":
            try:
                found = models()
                self.send_json(200, {"ok":True,"ready":bool(found),"model_count":len(found),"models":found})
            except Exception:
                self.send_json(503, {"ok":False,"ready":False,"error":"LM Studio is not ready"})
            return
        if path.startswith("/v1/") or path == "/v1":
            self.proxy(path, None); return
        self.send_json(404, {"error":"Not found"})
    def proxy(self, path, body):
        conn = None
        try:
            conn = http.client.HTTPConnection(UPSTREAM_HOST, UPSTREAM_PORT, timeout=185)
            headers = {k:self.headers[k] for k in ("Content-Type","Accept","OpenAI-Organization") if self.headers.get(k)}
            conn.request(self.command, path, body=body, headers=headers)
            response = conn.getresponse(); payload = response.read()
            self.send_response(response.status)
            for k,v in response.getheaders():
                if k.lower() not in {"connection","keep-alive","transfer-encoding","content-length","proxy-authenticate","proxy-authorization"}:
                    self.send_header(k,v)
            self.send_header("Content-Length",str(len(payload)))
            self.send_header("Cache-Control","no-store")
            self.send_header("Connection","close")
            self.end_headers()
            if self.command != "HEAD": self.wfile.write(payload)
            self.close_connection = True
        except Exception:
            logging.exception("LM Studio proxy failed")
            try: self.send_json(502, {"error":"LM Studio on this PC could not be reached"})
            except Exception: pass
        finally:
            if conn: conn.close()
    def do_HEAD(self):
        if not self.auth(): self.send_json(401, {"error":"Unauthorized"}); return
        if self.path.split("?",1)[0] == "/control/status":
            self.send_response(200); self.send_header("Content-Length","0"); self.send_header("Cache-Control","no-store"); self.end_headers()
        else: self.send_json(404, {"error":"Not found"})

if __name__ == "__main__":
    if not TOKEN_FILE.exists():
        TOKEN_FILE.write_text(secrets.token_urlsafe(40), encoding="utf-8")
    try:
        record = json.loads(PAIR_FILE.read_text(encoding="utf-8"))
    except Exception:
        record = {}
    if not record.get("code") or record.get("used") or time.time() > float(record.get("expires_at",0)):
        code = secrets.token_hex(4).upper()
        record = {"code":code,"created_at":time.time(),"expires_at":time.time()+1800,"used":False}
        PAIR_FILE.write_text(json.dumps(record), encoding="utf-8")
        logging.info("One-time pairing code created; value is stored only in the protected PC data directory.")
    logging.info("Starting public model-only gateway on %s:%s; terminal routes are not implemented.", HOST, PORT)
    ThreadingHTTPServer((HOST,PORT), Handler).serve_forever()
