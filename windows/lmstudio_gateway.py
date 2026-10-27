#!/usr/bin/env python3
"""Private loopback gateway for GhostGPT -> LM Studio on this Windows PC."""
from __future__ import annotations
import hmac, http.client, json, logging, os, subprocess, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.request import Request, urlopen
from urllib.parse import urlsplit

HOST, PORT = "127.0.0.1", 8767
UPSTREAM_HOST, UPSTREAM_PORT = "127.0.0.1", 1234
LMS_EXE = Path.home() / ".lmstudio" / "bin" / "lms.exe"
LOG_DIR = Path(os.environ.get("PROGRAMDATA", r"C:\ProgramData")) / "GhostGPT"
LOG_DIR.mkdir(parents=True, exist_ok=True)
logging.basicConfig(filename=str(LOG_DIR / "lmstudio-gateway.log"), level=logging.INFO,
                    format="%(asctime)s %(levelname)s %(message)s")
start_lock = threading.Lock()
MAX_BODY_BYTES = 8 * 1024 * 1024

def load_gateway_token():
    token = os.environ.get("GHOSTGPT_GATEWAY_TOKEN", "").strip()
    if token:
        return token
    token_path = Path(os.environ.get(
        "GHOSTGPT_GATEWAY_TOKEN_FILE", str(Path(__file__).resolve().with_name("gateway.token"))
    ))
    try:
        return token_path.read_text(encoding="utf-8").strip()
    except OSError:
        return ""

def get_models(timeout=5.0):
    req = Request(f"http://{UPSTREAM_HOST}:{UPSTREAM_PORT}/v1/models",
                  headers={"Accept": "application/json"})
    with urlopen(req, timeout=timeout) as response:
        data = json.loads(response.read().decode("utf-8"))
    return [m.get("id", "") for m in data.get("data", []) if m.get("id")]

def ensure_lmstudio():
    try:
        models = get_models()
        if models:
            return models
    except Exception as exc:
        logging.info("LM Studio API not ready yet: %s", exc)
    with start_lock:
        try:
            models = get_models()
            if models:
                return models
        except Exception:
            pass
        if not LMS_EXE.exists():
            raise RuntimeError(f"LM Studio CLI not found at {LMS_EXE}")
        logging.info("Starting LM Studio with lms server start")
        try:
            result = subprocess.run([str(LMS_EXE), "server", "start"], stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=35,
                creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
            logging.info("lms server start exit=%s output=%s", result.returncode, (result.stdout or "")[-1200:])
        except subprocess.TimeoutExpired:
            logging.warning("lms server start timed out; checking readiness")
        except Exception:
            logging.exception("Failed to invoke lms server start")
        deadline, last_error = time.monotonic() + 65, "LM Studio API did not become ready"
        while time.monotonic() < deadline:
            try:
                models = get_models(timeout=3)
                if models:
                    logging.info("LM Studio API ready with %d model IDs", len(models))
                    return models
            except Exception as exc:
                last_error = str(exc)
            time.sleep(2)
        raise RuntimeError(last_error)

class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "GhostGPTLocalGateway/1.0"
    def log_message(self, fmt, *args):
        logging.info("%s - %s", self.client_address[0], fmt % args)
    def send_json(self, status, data):
        payload = json.dumps(data, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(payload)
        self.close_connection = True
    def authorize_request(self):
        expected = load_gateway_token()
        if not expected:
            logging.error("Rejected request: gateway bearer token is not configured")
            self.send_json(503, {"error": "Gateway authentication is not configured"})
            return False
        authorization = self.headers.get("Authorization", "")
        scheme, separator, supplied = authorization.partition(" ")
        if scheme.lower() != "bearer" or not separator or not hmac.compare_digest(supplied, expected):
            self.send_json(401, {"error": "Unauthorized"})
            return False
        return True

    def do_GET(self):
        if not self.authorize_request():
            return
        path = urlsplit(self.path).path
        if path == "/health":
            try:
                models = get_models(timeout=3)
                self.send_json(200, {"ok": True, "service": "LM Studio on this PC", "model_count": len(models)})
            except Exception as exc:
                self.send_json(503, {"ok": False, "error": str(exc)})
            return
        if path == "/control/status":
            try:
                models = get_models(timeout=3)
                self.send_json(200, {"ok": True, "ready": bool(models), "model_count": len(models), "models": models})
            except Exception as exc:
                self.send_json(503, {"ok": False, "ready": False, "error": str(exc)})
            return
        if path.startswith("/v1/") or path == "/v1":
            self.proxy_to_lmstudio()
            return
        self.send_json(404, {"error": "Not found"})
    def do_POST(self):
        if not self.authorize_request():
            return
        path = urlsplit(self.path).path
        if path == "/control/start":
            try:
                models = ensure_lmstudio()
                self.send_json(200, {"ok": True, "ready": True, "service": "LM Studio on this PC",
                                     "model_count": len(models), "models": models})
            except Exception as exc:
                logging.exception("Unable to start LM Studio")
                self.send_json(503, {"ok": False, "ready": False, "error": str(exc)})
            return
        if path.startswith("/v1/") or path == "/v1":
            self.proxy_to_lmstudio()
            return
        self.send_json(404, {"error": "Not found"})
    def proxy_to_lmstudio(self):
        if not (urlsplit(self.path).path.startswith("/v1/") or urlsplit(self.path).path == "/v1"):
            self.send_json(404, {"error": "Only the /v1 API is proxied"})
            return
        conn = None
        try:
            raw_length = self.headers.get("Content-Length", "0") or "0"
            try:
                n = int(raw_length)
            except ValueError:
                self.send_json(400, {"error": "Invalid Content-Length"})
                return
            if n < 0:
                self.send_json(400, {"error": "Invalid Content-Length"})
                return
            if n > MAX_BODY_BYTES:
                self.send_json(413, {"error": "Request body exceeds the gateway limit"})
                return
            body = self.rfile.read(n) if n > 0 else None
            if n > 0 and len(body) != n:
                self.send_json(400, {"error": "Incomplete request body"})
                return
            # The gateway bearer token authenticates this hop only; never forward it to LM Studio.
            headers = {h: self.headers[h] for h in ("Content-Type", "Accept", "OpenAI-Organization") if self.headers.get(h)}
            conn = http.client.HTTPConnection(UPSTREAM_HOST, UPSTREAM_PORT, timeout=185)
            conn.request(self.command, self.path, body=body, headers=headers)
            response = conn.getresponse()
            payload = response.read()
            self.send_response(response.status)
            for name, value in response.getheaders():
                if name.lower() not in {"connection","keep-alive","proxy-authenticate","proxy-authorization","te","trailer","transfer-encoding","upgrade","content-length"}:
                    self.send_header(name, value)
            self.send_header("Content-Length", str(len(payload)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(payload)
            self.close_connection = True
            logging.info("proxied %s %s -> %s (%d bytes)", self.command, urlsplit(self.path).path, response.status, len(payload))
        except Exception as exc:
            logging.exception("Proxy request failed for %s", self.path)
            self.send_json(502, {"error": "LM Studio on this PC could not be reached", "detail": str(exc)})
        finally:
            if conn:
                conn.close()

if __name__ == "__main__":
    logging.info("Starting loopback gateway on %s:%d; LM Studio upstream %s:%d", HOST, PORT, UPSTREAM_HOST, UPSTREAM_PORT)
    ThreadingHTTPServer((HOST, PORT), Handler).serve_forever()
