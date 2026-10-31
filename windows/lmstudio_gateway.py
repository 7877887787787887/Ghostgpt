#!/usr/bin/env python3
"""Private loopback gateway for GhostGPT -> LM Studio on this Windows PC."""
from __future__ import annotations
import getpass, hashlib, hmac, http.client, json, logging, os, secrets, shlex, shutil, subprocess, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.request import Request, urlopen
from urllib.parse import urlsplit

HOST, PORT = "127.0.0.1", 8767
UPSTREAM_HOST, UPSTREAM_PORT = "127.0.0.1", 1234
OLLAMA_HOST, OLLAMA_PORT = "127.0.0.1", 11434
LMS_EXE = Path.home() / ".lmstudio" / "bin" / "lms.exe"
LOG_DIR = Path(os.environ.get("PROGRAMDATA", r"C:\ProgramData")) / "GhostGPT"
LOG_DIR.mkdir(parents=True, exist_ok=True)
logging.basicConfig(filename=str(LOG_DIR / "lmstudio-gateway.log"), level=logging.INFO,
                    format="%(asctime)s %(levelname)s %(message)s")
start_lock = threading.Lock()
MAX_BODY_BYTES = 8 * 1024 * 1024
MAX_TERMINAL_BODY_BYTES = 64 * 1024
MAX_TERMINAL_OUTPUT_CHARS = 16 * 1024
PAIR_CODE_FILE = LOG_DIR / "pairing.code"
PAIR_STATE_FILE = LOG_DIR / "pairing.state.json"
pair_lock = threading.Lock()
pair_attempts = {}
IS_WINDOWS = os.name == "nt"

READ_ONLY_COMMANDS = {
    "get-process", "get-service", "get-computerinfo", "get-childitem", "get-content",
    "get-command", "get-nettcpconnection", "test-connection", "get-ciminstance",
    "get-winevent", "get-eventlog", "get-scheduledtask", "get-scheduledtaskinfo",
    "get-executionpolicy", "get-itemproperty", "get-location", "get-date", "get-volume",
    "get-physicaldisk", "get-disk", "get-partition", "get-psdrive", "get-netipconfiguration",
    "get-netadapter", "get-localuser", "get-localgroup", "get-localgroupmember",
    "get-module", "get-filehash", "get-authenticodesignature", "hostname", "whoami",
    "ipconfig", "systeminfo", "tasklist", "netstat", "ping", "where.exe", "ver",
}
BLOCKED_COMMAND_MARKERS = (
    "-encodedcommand", "frombase64string", "invoke-expression", "iex ",
    "scriptblock::create", "downloadstring", "downloadfile", "webclient",
    "invoke-webrequest", "start-bitstransfer", "convertfrom-securestring",
    "get-credential", "credentialmanager", "::",
)
RISKY_COMMAND_MARKERS = (
    "set-", "new-", "remove-", "add-", "clear-", "format-", "restart-", "stop-",
    "start-", "enable-", "disable-", "move-item", "copy-item", "rename-item",
    "out-file", "set-content", "add-content", "reg add", "reg delete", "net user",
    "sc config", "shutdown", "taskkill", "install-", "uninstall-",
)
COMPOUND_COMMAND_MARKERS = (";", "|", "\n", "\r", "&&", "||", "`", "<", ">", "&", "$(", "(", ")", "{", "}", "[", "]")

def powershell_executable():
    if not IS_WINDOWS:
        return ""
    configured = os.environ.get("GHOSTGPT_POWERSHELL_EXE", "powershell.exe").strip() or "powershell.exe"
    candidate = Path(configured)
    if candidate.is_absolute() and candidate.is_file():
        return str(candidate)
    return shutil.which(configured) or ""

def allowed_powershell_hosts():
    # This service executes locally; do not let an environment variable turn it into a remote host runner.
    hosts = {"msi", "localhost", "127.0.0.1"}
    computer_name = os.environ.get("COMPUTERNAME", "").strip().casefold()
    if computer_name:
        hosts.add(computer_name)
    return hosts

def command_is_risky(command):
    lowered = command.casefold()
    return any(marker in lowered for marker in RISKY_COMMAND_MARKERS)

def readonly_ssh_command(command):
    """Return a shell-quoted diagnostic command, or reject executable syntax.

    SSH passes a single command string to the remote shell even with shell=False
    locally. Never forward the caller's unquoted command string.
    """
    if not isinstance(command, str) or not command.strip() or len(command) > 4000:
        raise ValueError("SSH command is empty or exceeds the 4000-character limit.")
    if any(ord(c) < 32 or ord(c) == 127 for c in command) or any(c in command for c in ";|&`<>$"):
        raise ValueError("Shell operators, substitutions, and control characters are blocked for SSH.")
    parts = shlex.split(command, posix=True)
    allowed = {"date", "df", "free", "hostname", "id", "ip", "ls", "nproc", "ps", "pwd", "ss", "uname", "uptime", "whoami"}
    if not parts or parts[0] not in allowed:
        raise ValueError("SSH command is not on the read-only allow-list.")
    args = parts[1:]
    if parts[0] == "date" and any(not (a.startswith("+") or a in {"-u", "--utc", "--universal", "-R", "--rfc-email", "-I", "--iso-8601", "--help", "--version"} or a.startswith(("--iso-8601=", "--rfc-3339="))) for a in args):
        raise ValueError("Only date display flags and output formats are allowed.")
    if parts[0] == "hostname" and any(a not in {"-s", "--short", "-f", "--fqdn", "--long", "-d", "--domain", "-i", "--ip-address", "-I", "--all-ip-addresses", "-a", "--alias", "-A", "--all-fqdns", "--help", "--version"} for a in args):
        raise ValueError("Changing hostname is not allowed.")
    if parts[0] == "ss" and any(not (a in {"--tcp", "--udp", "--listening", "--numeric", "--processes", "--all", "--summary", "--extended", "--info", "--options", "--memory", "--ipv4", "--ipv6", "--unix", "--help", "--version"} or (a.startswith("-") and not a.startswith("--") and len(a) > 1 and all(c in "tulnparseiom46x" for c in a[1:]))) for a in args):
        raise ValueError("Only socket display flags are allowed.")
    if parts[0] == "ip":
        words = [a for a in args if a not in {"-4", "-6", "-br", "-brief", "-s", "-stats", "-statistics", "-o", "-oneline"}]
        if not words or words[0] not in {"a", "addr", "address", "l", "link", "r", "route"} or (len(words) > 1 and words[1] not in {"show", "list", "ls"}):
            raise ValueError("Only IP address, link, and route display is allowed.")
    return shlex.join(parts), parts[0]

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

def create_pairing_code():
    """Create a single-use, 30-minute pairing code stored locally beside gateway state."""
    try:
        state = json.loads(PAIR_STATE_FILE.read_text(encoding="utf-8"))
        if not state.get("used") and time.time() < float(state.get("expires_at", 0)):
            return
    except Exception:
        pass
    code = secrets.token_hex(4).upper()
    state = {"code_hash": hashlib.sha256(code.encode("utf-8")).hexdigest(),
             "expires_at": time.time() + 1800, "used": False}
    PAIR_STATE_FILE.write_text(json.dumps(state), encoding="utf-8")
    PAIR_CODE_FILE.write_text(code + chr(10), encoding="utf-8")
    logging.info("One-time pairing code stored at %s; code value is not logged.", PAIR_CODE_FILE)

def redeem_pairing_code(code, client_ip):
    now = time.monotonic()
    with pair_lock:
        recent = [t for t in pair_attempts.get(client_ip, []) if now - t < 600]
        pair_attempts[client_ip] = recent
        if len(recent) >= 8:
            return False
        recent.append(now)
        try:
            state = json.loads(PAIR_STATE_FILE.read_text(encoding="utf-8"))
        except Exception:
            return False
        if state.get("used") or time.time() > float(state.get("expires_at", 0)):
            return False
        expected = str(state.get("code_hash", ""))
        supplied = hashlib.sha256(code.encode("utf-8")).hexdigest()
        if not expected or not hmac.compare_digest(supplied, expected):
            return False
        state["used"] = True
        state["code_hash"] = ""
        PAIR_STATE_FILE.write_text(json.dumps(state), encoding="utf-8")
        try:
            PAIR_CODE_FILE.unlink(missing_ok=True)
        except OSError:
            logging.warning("Could not remove redeemed pairing code file.")
        return True

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
        if getattr(self, "command", "") != "HEAD":
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

    def do_HEAD(self):
        if not self.authorize_request():
            return
        path = urlsplit(self.path).path
        if path == "/terminal":
            ready = bool(powershell_executable())
            self.send_response(200 if ready else 503)
            self.send_header("Content-Length", "0")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Connection", "close")
            self.end_headers()
            self.close_connection = True
            return
        self.send_response(404)
        self.send_header("Content-Length", "0")
        self.send_header("Connection", "close")
        self.end_headers()
        self.close_connection = True

    def do_GET(self):
        if not self.authorize_request():
            return
        path = urlsplit(self.path).path
        if path == "/terminal/health":
            ready = bool(powershell_executable())
            self.send_json(200 if ready else 503, {
                "ok": ready, "service": "PowerShell on this PC",
                "ready": ready, "modifying_commands_enabled":
                    os.environ.get("GHOSTGPT_ALLOW_MODIFYING_COMMANDS", "").strip() == "1"
            })
            return
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
        if path == "/api/tags":
            self.proxy_to_ollama()
            return
        if path.startswith("/v1/") or path == "/v1":
            self.proxy_to_lmstudio()
            return
        self.send_json(404, {"error": "Not found"})
    def do_POST(self):
        path = urlsplit(self.path).path
        if path == "/pair":
            try:
                raw_length = int(self.headers.get("Content-Length", "0") or "0")
                if raw_length < 0 or raw_length > 4096:
                    self.send_json(400, {"error": "Invalid pairing request"})
                    return
                payload = json.loads(self.rfile.read(raw_length).decode("utf-8")) if raw_length else {}
                code = str(payload.get("code", "")).strip().upper()
            except Exception:
                self.send_json(400, {"error": "Invalid pairing request"})
                return
            if not code or len(code) > 32 or not redeem_pairing_code(code, self.client_address[0]):
                self.send_json(403, {"error": "Pairing code is invalid, expired, already used, or rate-limited"})
                return
            token = load_gateway_token()
            if not token:
                self.send_json(503, {"error": "Gateway authentication is not configured"})
                return
            self.send_json(200, {"ok": True, "token": token, "endpoint": "https://msi.tail28f016.ts.net:10000"})
            logging.info("One-time device pairing completed from %s", self.client_address[0])
            return
        if not self.authorize_request():
            return
        if path == "/control/start":
            try:
                models = ensure_lmstudio()
                self.send_json(200, {"ok": True, "ready": True, "service": "LM Studio on this PC",
                                     "model_count": len(models), "models": models})
            except Exception as exc:
                logging.exception("Unable to start LM Studio")
                self.send_json(503, {"ok": False, "ready": False, "error": str(exc)})
            return
        if path == "/terminal":
            self.handle_terminal()
            return
        if path == "/api/chat":
            self.proxy_to_ollama()
            return
        if path.startswith("/v1/") or path == "/v1":
            self.proxy_to_lmstudio()
            return
        self.send_json(404, {"error": "Not found"})

    def handle_ssh(self, payload):
        """Run a tightly allow-listed, read-only command through Windows OpenSSH."""
        if payload.get("approved") is not True:
            self.send_json(403, {"error": "Explicit user approval is required before SSH command execution."})
            return
        configured_hosts = {item.strip().casefold() for item in os.environ.get("GHOSTGPT_SSH_HOSTS", "").split(",") if item.strip()}
        host = str(payload.get("host", "")).strip()
        if not host or host.casefold() not in configured_hosts:
            self.send_json(403, {"error": "SSH target is not in GHOSTGPT_SSH_HOSTS. Configure exact trusted host aliases on the PC gateway."})
            return
        username = str(payload.get("username", "")).strip()
        if username and (len(username) > 64 or not all(c.isalnum() or c in "._-" for c in username)):
            self.send_json(400, {"error": "Invalid SSH username."})
            return
        command = str(payload.get("command", "")).strip()
        if not command or len(command) > 4000:
            self.send_json(400, {"error": "SSH command is empty or exceeds the 4000-character limit."})
            return
        try:
            safe_command, root = readonly_ssh_command(command)
        except ValueError as exc:
            self.send_json(403, {"error": str(exc)})
            return
        ssh_executable = shutil.which("ssh.exe") or shutil.which("ssh")
        if not ssh_executable:
            self.send_json(503, {"error": "OpenSSH client is unavailable on the gateway PC. Install the Windows OpenSSH Client feature."})
            return
        target = f"{username}@{host}" if username else host
        try:
            result = subprocess.run([ssh_executable, "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "-o", "StrictHostKeyChecking=yes", target, safe_command], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, encoding="utf-8", errors="replace", timeout=25, shell=False, creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
        except subprocess.TimeoutExpired:
            self.send_json(504, {"error": "SSH command exceeded the 25-second execution limit."})
            return
        except Exception:
            logging.exception("Unable to launch SSH client")
            self.send_json(503, {"error": "SSH client could not be started."})
            return
        stdout, stderr = result.stdout or "", result.stderr or ""
        digest = hashlib.sha256(command.encode("utf-8")).hexdigest()[:16]
        logging.info("SSH execution host=%s root=%s exit=%s command_sha256=%s", host, root, result.returncode, digest)
        self.send_json(200, {"ok": result.returncode == 0, "exit_code": result.returncode, "stdout": stdout[:MAX_TERMINAL_OUTPUT_CHARS], "stderr": stderr[:MAX_TERMINAL_OUTPUT_CHARS], "truncated": len(stdout) > MAX_TERMINAL_OUTPUT_CHARS or len(stderr) > MAX_TERMINAL_OUTPUT_CHARS, "risk": "read-only"})
    def read_json_body(self, limit):
        raw_length = self.headers.get("Content-Length", "0") or "0"
        try:
            length = int(raw_length)
        except ValueError:
            self.send_json(400, {"error": "Invalid Content-Length"})
            return None
        if length < 0:
            self.send_json(400, {"error": "Invalid Content-Length"})
            return None
        if length > limit:
            self.send_json(413, {"error": "Request body exceeds the terminal gateway limit"})
            return None
        raw = self.rfile.read(length) if length else b""
        if len(raw) != length:
            self.send_json(400, {"error": "Incomplete request body"})
            return None
        try:
            payload = json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            self.send_json(400, {"error": "Request body must be valid JSON"})
            return None
        if not isinstance(payload, dict):
            self.send_json(400, {"error": "Request body must be a JSON object"})
            return None
        return payload

    def handle_terminal(self):
        payload = self.read_json_body(MAX_TERMINAL_BODY_BYTES)
        if payload is None:
            return
        mode = str(payload.get("mode", "powershell")).casefold()
        if mode == "ssh":
            self.handle_ssh(payload)
            return
        if mode != "powershell":
            self.send_json(400, {"error": "Unsupported terminal mode. Use powershell or ssh."})
            return
        if payload.get("approved") is not True:
            self.send_json(403, {"error": "Explicit user approval is required before command execution."})
            return

        host = str(payload.get("host", "")).strip().casefold()
        if not host or host not in allowed_powershell_hosts():
            self.send_json(403, {"error": "Target host is not in the local PowerShell allow-list."})
            return
        username = str(payload.get("username", "")).strip()
        current_user = (os.environ.get("USERNAME") or getpass.getuser()).casefold()
        if username and username.casefold() != current_user:
            self.send_json(403, {"error": "This gateway cannot impersonate another Windows user."})
            return

        command = str(payload.get("command", "")).strip()
        if not command or len(command) > 12000:
            self.send_json(400, {"error": "Command is empty or exceeds the 12000-character limit."})
            return
        lowered = command.casefold()
        unquoted = lowered.replace("'", "").replace('"', "")
        parameters = [p.lstrip("-").split(":", 1)[0] for p in unquoted.split()[1:] if p.startswith("-")]
        remote_parameters = ("computername", "cimsession", "pssession", "session", "credential")
        if "\\\\" in command or any(p == "cn" or (p and any(name.startswith(p) for name in remote_parameters)) for p in parameters):
            self.send_json(403, {"error": "Remote sessions and UNC paths are not allowed in local PowerShell diagnostics."})
            return
        if any(marker in unquoted for marker in (".token", "pairing.code", "pairing.state", "public-model-pairing", "ghostgpt_gateway_token", "ghostgpt_gateway_token_file", ".ssh", "id_rsa", "id_ed25519", ".env", "login data", "keychain", "\\sam", "\\security")):
            self.send_json(403, {"error": "Credential and gateway-secret paths are blocked in diagnostic commands."})
            return
        if lowered.split(None, 1)[0] == "get-content" and any(c in command for c in "*?["):
            self.send_json(403, {"error": "Read a specific non-secret file; wildcard file reads are not allowed."})
            return
        if any(marker in lowered for marker in BLOCKED_COMMAND_MARKERS):
            self.send_json(403, {"error": "Encoded, obfuscated, credential-oriented, and download/execute commands are blocked."})
            return
        if any(marker in command for marker in COMPOUND_COMMAND_MARKERS):
            self.send_json(403, {"error": "Compound commands, pipelines, redirection, and multiline scripts are blocked by policy."})
            return

        root = command.split(None, 1)[0].casefold()
        risky = command_is_risky(command)
        if risky:
            if payload.get("riskConfirmed") is not True:
                self.send_json(403, {"error": "A second explicit confirmation is required for a modifying command."})
                return
            if os.environ.get("GHOSTGPT_ALLOW_MODIFYING_COMMANDS", "").strip() != "1":
                self.send_json(403, {"error": "Modifying commands are disabled on this gateway. Enable them explicitly in the protected Windows service environment if required."})
                return
        elif root not in READ_ONLY_COMMANDS:
            self.send_json(403, {"error": "Command is not on the read-only allow-list. Modifying commands require explicit confirmation and gateway opt-in."})
            return

        executable = powershell_executable()
        if not executable:
            self.send_json(503, {"error": "PowerShell is unavailable or this gateway is not running on Windows."})
            return

        try:
            result = subprocess.run(
                [executable, "-NoLogo", "-NoProfile", "-NonInteractive", "-Command",
                 "$ErrorActionPreference = 'Stop';\n$OutputEncoding = [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false);\n" + command],
                stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                text=True, encoding="utf-8", errors="replace", timeout=60, shell=False,
                creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
            )
        except subprocess.TimeoutExpired:
            logging.warning("PowerShell command timed out host=%s root=%s risky=%s", host, root, risky)
            self.send_json(504, {"error": "PowerShell command exceeded the 60-second execution limit."})
            return
        except Exception:
            logging.exception("Unable to launch approved PowerShell command")
            self.send_json(503, {"error": "PowerShell could not be started."})
            return

        stdout = result.stdout or ""
        stderr = result.stderr or ""
        truncated = len(stdout) > MAX_TERMINAL_OUTPUT_CHARS or len(stderr) > MAX_TERMINAL_OUTPUT_CHARS
        digest = hashlib.sha256(command.encode("utf-8")).hexdigest()[:16]
        logging.info("PowerShell execution host=%s user=%s root=%s risky=%s exit=%s command_sha256=%s",
                     host, current_user, root, risky, result.returncode, digest)
        self.send_json(200, {
            "ok": result.returncode == 0,
            "exit_code": result.returncode,
            "stdout": stdout[:MAX_TERMINAL_OUTPUT_CHARS],
            "stderr": stderr[:MAX_TERMINAL_OUTPUT_CHARS],
            "truncated": truncated,
            "risk": "changes" if risky else "read-only",
        })

    def proxy_to_ollama(self):
        path = urlsplit(self.path).path
        allowed = (self.command == "GET" and path == "/api/tags") or (self.command == "POST" and path == "/api/chat")
        if not allowed:
            self.send_json(404, {"error": "Only GET /api/tags and POST /api/chat are exposed for Ollama"})
            return
        conn = None
        try:
            body = None
            if self.command == "POST":
                raw_length = self.headers.get("Content-Length", "0") or "0"
                try:
                    length = int(raw_length)
                except ValueError:
                    self.send_json(400, {"error": "Invalid Content-Length"})
                    return
                if length < 0:
                    self.send_json(400, {"error": "Invalid Content-Length"})
                    return
                if length > MAX_BODY_BYTES:
                    self.send_json(413, {"error": "Request body exceeds the gateway limit"})
                    return
                body = self.rfile.read(length) if length else b""
                if len(body) != length:
                    self.send_json(400, {"error": "Incomplete request body"})
                    return
            headers = {name: self.headers[name] for name in ("Content-Type", "Accept") if self.headers.get(name)}
            conn = http.client.HTTPConnection(OLLAMA_HOST, OLLAMA_PORT, timeout=185)
            conn.request(self.command, path, body=body, headers=headers)
            response = conn.getresponse()
            payload = response.read()
            self.send_response(response.status)
            for name, value in response.getheaders():
                if name.lower() not in {"connection", "keep-alive", "proxy-authenticate", "proxy-authorization", "te", "trailer", "transfer-encoding", "upgrade", "content-length"}:
                    self.send_header(name, value)
            self.send_header("Content-Length", str(len(payload)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(payload)
            self.close_connection = True
            logging.info("proxied Ollama %s %s -> %s (%d bytes)", self.command, path, response.status, len(payload))
        except Exception:
            logging.exception("Ollama proxy request failed for %s", path)
            self.send_json(502, {"error": "Ollama on this PC could not be reached"})
        finally:
            if conn:
                conn.close()

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
    create_pairing_code()
    if load_gateway_token():
        logging.info("Gateway bearer token is configured; no secret value will be logged.")
    else:
        logging.error("Gateway bearer token is missing; all authenticated routes will fail closed.")
    logging.info("PowerShell readiness at startup: %s", bool(powershell_executable()))
    logging.info("Starting loopback gateway on %s:%d; LM Studio upstream %s:%d", HOST, PORT, UPSTREAM_HOST, UPSTREAM_PORT)
    ThreadingHTTPServer((HOST, PORT), Handler).serve_forever()
