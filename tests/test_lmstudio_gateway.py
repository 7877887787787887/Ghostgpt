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

    def proxy_to_lmstudio(self):
        return gateway.Handler.proxy_to_lmstudio(self)

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


    def test_ios_ai_routes_only_to_local_lm_studio(self):
        source = (ROOT / "ios-native" / "SceneDelegate.swift").read_text(encoding="utf-8")
        self.assertIn("enum LocalModelClient", source)
        self.assertGreaterEqual(source.count("LocalModelClient.chat("), 3)
        for forbidden in (
            "ghostgpt-ai.conman31115.workers.dev",
            "Cloudflare",
            "Ollama",
            "modelProvider",
            "cloudflareEnabled",
        ):
            self.assertNotIn(forbidden, source)

if __name__ == "__main__":
    unittest.main()
