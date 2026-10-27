#!/usr/bin/env python3
"""Private loopback gateway for GhostGPT -> LM Studio on this Windows PC."""
from __future__ import annotations
import http.client, json, logging, os, subprocess, threading, time
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
    def do_GET(self):
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
            n = int(self.headers.get("Content-Length", "0") or "0")
            body = self.rfile.read(n) if n > 0 else None
            headers = {h: self.headers[h] for h in ("Content-Type", "Accept", "Authorization", "OpenAI-Organization") if self.headers.get(h)}
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
