import importlib.util
import io
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
TEST_HOME = Path(tempfile.mkdtemp(prefix="ghostgpt-gateway-tests-"))
os.environ["PROGRAMDATA"] = str(TEST_HOME / "programdata")
os.environ["GHOSTGPT_GATEWAY_TOKEN_FILE"] = str(TEST_HOME / "gateway.token")

spec = importlib.util.spec_from_file_location("lmstudio_gateway", ROOT / "windows" / "lmstudio_gateway.py")
gateway = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gateway)


class FakeHandler:
    def __init__(self, path="/", headers=None, method="GET", body=b""):
        self.path = path
        self.command = method
        self.headers = headers or {}
        self.responses = []
        self.rfile = io.BytesIO(body)
        self.wfile = io.BytesIO()
        self.close_connection = False
        self.client_address = ("127.0.0.1", 12345)

    def send_json(self, status, data):
        self.responses.append((status, data))

    def authorize_request(self):
        return gateway.Handler.authorize_request(self)

    def read_json_body(self, limit):
        return gateway.Handler.read_json_body(self, limit)

    def handle_terminal(self):
        return gateway.Handler.handle_terminal(self)

    def proxy_to_lmstudio(self):
        return gateway.Handler.proxy_to_lmstudio(self)

    def proxy_to_ollama(self):
        return gateway.Handler.proxy_to_ollama(self)

    def send_response(self, status, message=None):
        self.status = status

    def send_header(self, name, value):
        pass

    def end_headers(self):
        pass

    def log_message(self, fmt, *args):
        pass


class GatewayAuthenticationTests(unittest.TestCase):
    def setUp(self):
        self.env = patch.dict(os.environ, {
            "GHOSTGPT_GATEWAY_TOKEN": "correct-test-token",
            "GHOSTGPT_GATEWAY_TOKEN_FILE": str(TEST_HOME / "gateway.token"),
        })
        self.env.start()
        self.addCleanup(self.env.stop)
        (TEST_HOME / "gateway.token").unlink(missing_ok=True)

    def test_missing_token_configuration_fails_closed(self):
        with patch.dict(os.environ, {
            "GHOSTGPT_GATEWAY_TOKEN": "",
            "GHOSTGPT_GATEWAY_TOKEN_FILE": str(TEST_HOME / "missing.token"),
        }):
            handler = FakeHandler(path="/health")
            gateway.Handler.do_GET(handler)
        self.assertEqual(handler.responses[0][0], 503)

    def test_wrong_bearer_token_is_rejected_before_model_inventory(self):
        handler = FakeHandler(path="/control/status", headers={"Authorization": "Bearer wrong"})
        with patch.object(gateway, "get_models", side_effect=AssertionError("upstream must not be queried")):
            gateway.Handler.do_GET(handler)
        self.assertEqual(handler.responses[0][0], 401)

    def test_unauthenticated_start_cannot_launch_lm_studio(self):
        handler = FakeHandler(path="/control/start", method="POST")
        with patch.object(gateway, "ensure_lmstudio", side_effect=AssertionError("LM Studio must not start")):
            gateway.Handler.do_POST(handler)
        self.assertEqual(handler.responses[0][0], 401)

    def test_valid_bearer_can_read_authenticated_health(self):
        handler = FakeHandler(path="/health", headers={"Authorization": "Bearer correct-test-token"})
        with patch.object(gateway, "get_models", return_value=["openai/gpt-oss-20b"]):
            gateway.Handler.do_GET(handler)
        self.assertEqual(handler.responses[0][0], 200)
        self.assertEqual(handler.responses[0][1]["model_count"], 1)

    def test_token_file_fallback(self):
        token_file = TEST_HOME / "fallback.token"
        token_file.write_text("file-token\n", encoding="utf-8")
        with patch.dict(os.environ, {
            "GHOSTGPT_GATEWAY_TOKEN": "",
            "GHOSTGPT_GATEWAY_TOKEN_FILE": str(token_file),
        }):
            self.assertEqual(gateway.load_gateway_token(), "file-token")

    def test_oversized_request_is_rejected_before_proxy(self):
        handler = FakeHandler(
            path="/v1/chat/completions",
            method="POST",
            headers={
                "Authorization": "Bearer correct-test-token",
                "Content-Type": "application/json",
                "Content-Length": str(gateway.MAX_BODY_BYTES + 1),
            },
        )
        with patch.object(gateway.http.client, "HTTPConnection") as upstream:
            gateway.Handler.do_POST(handler)
        self.assertEqual(handler.responses[0][0], 413)
        upstream.assert_not_called()

    def test_invalid_content_length_is_rejected(self):
        handler = FakeHandler(
            path="/v1/chat/completions",
            method="POST",
            headers={
                "Authorization": "Bearer correct-test-token",
                "Content-Type": "application/json",
                "Content-Length": "not-a-number",
            },
        )
        with patch.object(gateway.http.client, "HTTPConnection") as upstream:
            gateway.Handler.do_POST(handler)
        self.assertEqual(handler.responses[0][0], 400)
        upstream.assert_not_called()

    def test_gateway_bearer_is_not_forwarded_to_lm_studio(self):
        handler = FakeHandler(
            path="/v1/chat/completions",
            method="POST",
            headers={
                "Authorization": "Bearer correct-test-token",
                "Content-Type": "application/json",
                "Content-Length": "2",
            },
            body=b"{}",
        )

        class FakeResponse:
            status = 200
            def read(self):
                return b'{"ok":true}'
            def getheaders(self):
                return [("Content-Type", "application/json")]

        class FakeConnection:
            def __init__(self, *args, **kwargs):
                self.forwarded_headers = None
            def request(self, method, path, body=None, headers=None):
                self.forwarded_headers = headers or {}
            def getresponse(self):
                return FakeResponse()
            def close(self):
                pass

        connection = FakeConnection()
        with patch.object(gateway.http.client, "HTTPConnection", return_value=connection):
            gateway.Handler.do_POST(handler)
        self.assertEqual(handler.status, 200)
        self.assertNotIn("Authorization", connection.forwarded_headers)


    def _terminal_handler(self, payload, token="correct-test-token"):
        body = __import__("json").dumps(payload).encode("utf-8")
        headers = {"Content-Type": "application/json", "Content-Length": str(len(body))}
        if token:
            headers["Authorization"] = "Bearer " + token
        return FakeHandler(path="/terminal", headers=headers, method="POST", body=body)

    def test_terminal_requires_bearer_and_explicit_approval(self):
        payload = {"mode": "powershell", "host": "msi", "command": "Get-Process", "approved": True}
        handler = self._terminal_handler(payload, token="")
        with patch.object(gateway.subprocess, "run", side_effect=AssertionError("must not execute")):
            gateway.Handler.do_POST(handler)
        self.assertEqual(handler.responses[0][0], 401)

        handler = self._terminal_handler({**payload, "approved": False})
        with patch.object(gateway.subprocess, "run", side_effect=AssertionError("must not execute")):
            gateway.Handler.do_POST(handler)
        self.assertEqual(handler.responses[0][0], 403)

    def test_terminal_runs_allowlisted_read_only_command_only_after_approval(self):
        payload = {"mode": "powershell", "host": "msi", "command": "Get-Process", "approved": True, "riskConfirmed": False}
        handler = self._terminal_handler(payload)
        result = __import__("subprocess").CompletedProcess(["powershell.exe"], 0, "process list", "")
        with patch.object(gateway, "IS_WINDOWS", True), \
             patch.object(gateway, "powershell_executable", return_value="powershell.exe"), \
             patch.object(gateway.subprocess, "run", return_value=result) as run:
            gateway.Handler.do_POST(handler)
        self.assertEqual(handler.responses[0][0], 200)
        self.assertEqual(handler.responses[0][1]["stdout"], "process list")
        self.assertEqual(run.call_count, 1)
        self.assertIn("Get-Process", run.call_args.args[0][-1])

    def test_terminal_rejects_unknown_host_and_compound_commands(self):
        unknown_host = self._terminal_handler({
            "mode": "powershell", "host": "other-machine", "command": "Get-Process", "approved": True
        })
        compound = self._terminal_handler({
            "mode": "powershell", "host": "msi", "command": "Get-Process; Remove-Item C:\\temp", "approved": True
        })
        with patch.object(gateway, "IS_WINDOWS", True), \
             patch.object(gateway, "powershell_executable", return_value="powershell.exe"), \
             patch.object(gateway.subprocess, "run", side_effect=AssertionError("must not execute")):
            gateway.Handler.do_POST(unknown_host)
            gateway.Handler.do_POST(compound)
        self.assertEqual(unknown_host.responses[0][0], 403)
        self.assertEqual(compound.responses[0][0], 403)

    def test_terminal_modifying_command_needs_gateway_opt_in_and_second_confirmation(self):
        base = {"mode": "powershell", "host": "msi", "command": "Restart-Computer", "approved": True}
        no_second_confirmation = self._terminal_handler({**base, "riskConfirmed": False})
        confirmed = self._terminal_handler({**base, "riskConfirmed": True})
        result = __import__("subprocess").CompletedProcess(["powershell.exe"], 0, "", "")
        with patch.object(gateway, "IS_WINDOWS", True), \
             patch.object(gateway, "powershell_executable", return_value="powershell.exe"), \
             patch.dict(os.environ, {"GHOSTGPT_ALLOW_MODIFYING_COMMANDS": ""}), \
             patch.object(gateway.subprocess, "run", side_effect=AssertionError("modifying commands are disabled")):
            gateway.Handler.do_POST(no_second_confirmation)
            gateway.Handler.do_POST(confirmed)
        self.assertEqual(no_second_confirmation.responses[0][0], 403)
        self.assertEqual(confirmed.responses[0][0], 403)

        confirmed = self._terminal_handler({**base, "riskConfirmed": True})
        with patch.object(gateway, "IS_WINDOWS", True), \
             patch.object(gateway, "powershell_executable", return_value="powershell.exe"), \
             patch.dict(os.environ, {"GHOSTGPT_ALLOW_MODIFYING_COMMANDS": "1"}), \
             patch.object(gateway.subprocess, "run", return_value=result) as run:
            gateway.Handler.do_POST(confirmed)
        self.assertEqual(confirmed.responses[0][0], 200)
        run.assert_called_once()

    def test_terminal_head_reports_power_shell_readiness_without_running_a_command(self):
        handler = FakeHandler(path="/terminal", headers={"Authorization": "Bearer correct-test-token"}, method="HEAD")
        with patch.object(gateway, "powershell_executable", return_value="powershell.exe"):
            gateway.Handler.do_HEAD(handler)
        self.assertEqual(handler.status, 200)
        self.assertEqual(handler.wfile.getvalue(), b"")

    def test_terminal_rejects_nested_powershell_expressions(self):
        handler = self._terminal_handler({
            "mode": "powershell", "host": "msi",
            "command": "Get-Process -Name $(Remove-Item C:\\temp)", "approved": True
        })
        with patch.object(gateway, "IS_WINDOWS", True), \
             patch.object(gateway, "powershell_executable", return_value="powershell.exe"), \
             patch.object(gateway.subprocess, "run", side_effect=AssertionError("must not execute")):
            gateway.Handler.do_POST(handler)
        self.assertEqual(handler.responses[0][0], 403)

    def test_terminal_host_allowlist_cannot_be_expanded_by_environment(self):
        handler = self._terminal_handler({
            "mode": "powershell", "host": "evil-host", "command": "Get-Process", "approved": True
        })
        with patch.object(gateway, "IS_WINDOWS", True), \
             patch.object(gateway, "powershell_executable", return_value="powershell.exe"), \
             patch.dict(os.environ, {"GHOSTGPT_POWERSHELL_HOSTS": "evil-host"}), \
             patch.object(gateway.subprocess, "run", side_effect=AssertionError("must not execute")):
            gateway.Handler.do_POST(handler)
        self.assertEqual(handler.responses[0][0], 403)

    def test_terminal_gateway_explicitly_rejects_ssh_mode(self):
        handler = self._terminal_handler({
            "mode": "ssh", "host": "Ghost", "command": "whoami", "approved": True
        })
        with patch.object(gateway.subprocess, "run", side_effect=AssertionError("SSH must not execute here")):
            gateway.Handler.do_POST(handler)
        self.assertEqual(handler.responses[0][0], 501)

    def test_ollama_model_routes_require_auth_and_do_not_forward_bearer(self):
        unauthenticated = FakeHandler(path="/api/tags")
        with patch.object(gateway.http.client, "HTTPConnection") as upstream:
            gateway.Handler.do_GET(unauthenticated)
        self.assertEqual(unauthenticated.responses[0][0], 401)
        upstream.assert_not_called()

        handler = FakeHandler(path="/api/tags", headers={
            "Authorization": "Bearer correct-test-token", "Accept": "application/json"
        })
        class FakeResponse:
            status = 200
            def read(self): return b'{"models":[{"name":"test-model"}]}'
            def getheaders(self): return [("Content-Type", "application/json")]
        class FakeConnection:
            def __init__(self, host, port, timeout=None):
                self.target = (host, port)
                self.forwarded_headers = None
                self.request_path = None
            def request(self, method, path, body=None, headers=None):
                self.forwarded_headers = headers or {}
                self.request_path = path
            def getresponse(self): return FakeResponse()
            def close(self): pass
        created = []
        def connection_factory(host, port, timeout=None):
            conn = FakeConnection(host, port, timeout)
            created.append(conn)
            return conn
        with patch.object(gateway.http.client, "HTTPConnection", side_effect=connection_factory):
            gateway.Handler.do_GET(handler)
        self.assertEqual(handler.status, 200)
        self.assertEqual(created[0].target, (gateway.OLLAMA_HOST, gateway.OLLAMA_PORT))
        self.assertEqual(created[0].request_path, "/api/tags")
        self.assertNotIn("Authorization", created[0].forwarded_headers)

    def test_ollama_chat_proxy_forwards_only_safe_headers_and_bounds_body(self):
        body = b'{"model":"test-model","messages":[],"stream":false}'
        handler = FakeHandler(
            path="/api/chat",
            method="POST",
            headers={
                "Authorization": "Bearer correct-test-token",
                "Content-Type": "application/json",
                "Content-Length": str(len(body)),
            },
            body=body,
        )

        class FakeResponse:
            status = 200
            def read(self): return b'{"message":{"content":"ok"}}'
            def getheaders(self): return [("Content-Type", "application/json")]

        class FakeConnection:
            def __init__(self, host, port, timeout=None):
                self.target = (host, port)
                self.method = None
                self.path = None
                self.body = None
                self.headers = None
            def request(self, method, path, body=None, headers=None):
                self.method, self.path, self.body, self.headers = method, path, body, headers or {}
            def getresponse(self): return FakeResponse()
            def close(self): pass

        created = []
        def connection_factory(host, port, timeout=None):
            conn = FakeConnection(host, port, timeout)
            created.append(conn)
            return conn

        with patch.object(gateway.http.client, "HTTPConnection", side_effect=connection_factory):
            gateway.Handler.do_POST(handler)
        self.assertEqual(handler.status, 200)
        self.assertEqual(created[0].target, (gateway.OLLAMA_HOST, gateway.OLLAMA_PORT))
        self.assertEqual(created[0].method, "POST")
        self.assertEqual(created[0].path, "/api/chat")
        self.assertEqual(created[0].body, body)
        self.assertEqual(created[0].headers.get("Content-Type"), "application/json")
        self.assertNotIn("Authorization", created[0].headers)

        oversized = FakeHandler(
            path="/api/chat",
            method="POST",
            headers={
                "Authorization": "Bearer correct-test-token",
                "Content-Length": str(gateway.MAX_BODY_BYTES + 1),
            },
        )
        with patch.object(gateway.http.client, "HTTPConnection") as upstream:
            gateway.Handler.do_POST(oversized)
        self.assertEqual(oversized.responses[0][0], 413)
        upstream.assert_not_called()

    def test_ollama_proxy_rejects_unapproved_routes(self):
        handler = FakeHandler(path="/api/pull", headers={"Authorization": "Bearer correct-test-token"})
        with patch.object(gateway.http.client, "HTTPConnection") as upstream:
            gateway.Handler.do_GET(handler)
        self.assertEqual(handler.responses[0][0], 404)
        upstream.assert_not_called()

    def test_ios_supports_all_configured_model_providers_without_silent_fallback(self):
        source = (ROOT / "ios-native" / "SceneDelegate.swift").read_text(encoding="utf-8")
        for required in (
            'enum ModelProvider', 'case cloudflare = "Cloudflare"', 'case ollama = "Ollama"',
            'case lmStudio = "LM Studio"', 'cloudflareModelID', 'ollamaModelID', 'lmStudioModelID',
            'cloudflareAPIKey', 'KeychainStore.migratedValue(for: selectedProvider.keychainAccount)',
            'api/tags', 'api/chat', 'v1/models', 'LocalModelClient.chat',
        ):
            self.assertIn(required, source)
        self.assertIn('components.scheme?.lowercased() == "https"', source)
        self.assertIn('Provider changed. Scan the new provider', source)

if __name__ == "__main__":
    unittest.main()
