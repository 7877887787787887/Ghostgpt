#!/usr/bin/env python3
"""Public model-only GhostGPT gateway. No terminal or shell routes."""
import http.client, hmac, json, logging, os, secrets, subprocess, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.request import Request, urlopen

HOST, PORT = "127.0.0.1", 8768
UPSTREAM = ("127.0.0.1", 1234)
LMS_EXE = Path.home() / ".lmstudio" / "bin" / "lms.exe"
DATA = Path(os.environ.get("PROGRAMDATA", r"C:\ProgramData")) / "GhostGPT"
DATA.mkdir(parents=True, exist_ok=True)
PAIR_FILE, TOKEN_FILE = DATA / "public-model-pairing.json", DATA / "public-model.token"
logging.basicConfig(filename=str(DATA / "public-model-gateway.log"), level=logging.INFO,
                    format="%(asctime)s %(levelname)s %(message)s")
MAX_BODY, pair_lock, start_lock = 8 * 1024 * 1024, threading.Lock(), threading.Lock()
attempts = {}
def token():
    try: return TOKEN_FILE.read_text(encoding="utf-8").strip()
    except OSError: return ""
def get_models(timeout=4):
    req = Request("http://127.0.0.1:1234/v1/models", headers={"Accept":"application/json"})
    with urlopen(req, timeout=timeout) as r: return [m.get("id","") for m in json.loads(r.read().decode()).get("data",[]) if m.get("id")]
def start_models():
    try:
        found=get_models()
        if found: return found
    except Exception: pass
    with start_lock:
        try:
            found=get_models()
            if found: return found
        except Exception: pass
        if os.name!="nt" or not LMS_EXE.exists(): raise RuntimeError("LM Studio CLI unavailable")
        try: subprocess.run([str(LMS_EXE),"server","start"],stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=35,creationflags=getattr(subprocess,"CREATE_NO_WINDOW",0),check=False)
        except subprocess.TimeoutExpired: pass
        deadline=time.monotonic()+65
        while time.monotonic()<deadline:
            try:
                found=get_models(3)
                if found: return found
            except Exception: pass
            time.sleep(2)
    raise RuntimeError("LM Studio did not become ready")
def redeem(code, ip):
    with pair_lock:
        now=time.monotonic()
        attempts[ip]=[t for t in attempts.get(ip,[]) if now-t<600]
        if len(attempts[ip])>=8: return False
        attempts[ip].append(now)
        try: data=json.loads(PAIR_FILE.read_text(encoding="utf-8"))
        except Exception: return False
        if data.get("used") or time.time()>float(data.get("expires_at",0)): return False
        expected=str(data.get("code",""))
        if not expected or not hmac.compare_digest(code,expected): return False
        data.update({"used":True,"code":""})
        PAIR_FILE.write_text(json.dumps(data),encoding="utf-8")
        return True
class Handler(BaseHTTPRequestHandler):
    protocol_version="HTTP/1.1"
    server_version="GhostGPTModelOnly/1.0"
    def log_message(self,fmt,*args): logging.info("%s - %s",self.client_address[0],fmt%args)
    def send_json(self,status,obj):
        raw=json.dumps(obj).encode()
        self.send_response(status); self.send_header("Content-Type","application/json; charset=utf-8")
        self.send_header("Content-Length",str(len(raw))); self.send_header("Cache-Control","no-store")
        self.send_header("Connection","close"); self.end_headers()
        if self.command!="HEAD": self.wfile.write(raw)
        self.close_connection=True
    def authorized(self):
        scheme,sep,supplied=self.headers.get("Authorization","").partition(" ")
        expected=token()
        return bool(expected and sep and scheme.lower()=="bearer" and hmac.compare_digest(supplied,expected))
    def do_POST(self):
        path=self.path.split("?",1)[0]
        try:
            n=int(self.headers.get("Content-Length","0"))
            if n<0 or n>MAX_BODY: self.send_json(413,{"error":"Request too large"}); return
            raw=self.rfile.read(n) if n else b"{}"
            data=json.loads(raw.decode("utf-8"))
        except Exception: self.send_json(400,{"error":"Invalid JSON"}); return
        if path=="/pair":
            if not redeem(str(data.get("code","")).strip().upper(),self.client_address[0]):
                self.send_json(403,{"error":"Pairing code invalid, expired, already used, or rate-limited"}); return
            secret=token()
            if not secret: self.send_json(503,{"error":"Pairing is not configured"}); return
            logging.info("One-time model pairing redeemed; token value not logged")
            self.send_json(200,{"ok":True,"token":secret,"endpoint":"https://msi.tail28f016.ts.net:10001"}); return
        if not self.authorized(): self.send_json(401,{"error":"Unauthorized"}); return
        if path=="/control/start":
            try:
                found=start_models(); self.send_json(200,{"ok":True,"ready":True,"model_count":len(found),"models":found})
            except Exception:
                logging.exception("LM Studio start failed"); self.send_json(503,{"ok":False,"ready":False,"error":"LM Studio is not ready"})
            return
        if path=="/v1" or path.startswith("/v1/"): self.proxy(path,raw); return
        self.send_json(404,{"error":"Not found"})
    def do_GET(self):
        path=self.path.split("?",1)[0]
        if not self.authorized(): self.send_json(401,{"error":"Unauthorized"}); return
        if path=="/control/status":
            try:
                found=get_models(); self.send_json(200,{"ok":True,"ready":bool(found),"model_count":len(found),"models":found})
            except Exception: self.send_json(503,{"ok":False,"ready":False,"error":"LM Studio is not ready"})
            return
        if path=="/v1" or path.startswith("/v1/"): self.proxy(path,None); return
        self.send_json(404,{"error":"Not found"})
    def do_HEAD(self):
        if not self.authorized(): self.send_json(401,{"error":"Unauthorized"}); return
        if self.path.split("?",1)[0]=="/control/status":
            self.send_response(200); self.send_header("Content-Length","0"); self.send_header("Cache-Control","no-store"); self.end_headers()
        else: self.send_json(404,{"error":"Not found"})
    def proxy(self,path,body):
        conn=None
        try:
            conn=http.client.HTTPConnection(*UPSTREAM,timeout=185)
            headers={k:self.headers[k] for k in ("Content-Type","Accept","OpenAI-Organization") if self.headers.get(k)}
            conn.request(self.command,path,body=body,headers=headers)
            response=conn.getresponse(); payload=response.read(); self.send_response(response.status)
            for k,v in response.getheaders():
                if k.lower() not in {"connection","keep-alive","transfer-encoding","content-length","proxy-authenticate","proxy-authorization"}: self.send_header(k,v)
            self.send_header("Content-Length",str(len(payload))); self.send_header("Cache-Control","no-store"); self.send_header("Connection","close"); self.end_headers()
            if self.command!="HEAD": self.wfile.write(payload)
            self.close_connection=True
        except Exception:
            logging.exception("LM Studio proxy failed")
            try: self.send_json(502,{"error":"LM Studio could not be reached"})
            except Exception: pass
        finally:
            if conn: conn.close()
if __name__=="__main__":
    if not TOKEN_FILE.exists(): TOKEN_FILE.write_text(secrets.token_urlsafe(40),encoding="utf-8")
    try: rec=json.loads(PAIR_FILE.read_text(encoding="utf-8"))
    except Exception: rec={}
    if not rec.get("code") or rec.get("used") or time.time()>float(rec.get("expires_at",0)):
        rec={"code":secrets.token_hex(6).upper(),"created_at":time.time(),"expires_at":time.time()+1800,"used":False}
        PAIR_FILE.write_text(json.dumps(rec),encoding="utf-8")
        logging.info("One-time pairing code generated in protected ProgramData directory")
    logging.info("Starting model-only listener on %s:%d; terminal paths are not implemented",HOST,PORT)
    ThreadingHTTPServer((HOST,PORT),Handler).serve_forever()
