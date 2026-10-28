"""High-volume regression checks for GhostGPT gateway security boundaries."""
import json
import unittest
from unittest.mock import patch

from test_lmstudio_gateway import FakeHandler, gateway


class GatewayStressTests(unittest.TestCase):
    def setUp(self):
        self.token = patch.dict("os.environ", {"GHOSTGPT_GATEWAY_TOKEN": "stress-test-token"})
        self.token.start()
        self.addCleanup(self.token.stop)

    def test_500_invalid_authorization_headers_are_rejected(self):
        bad_headers = ["", "Basic stress-test-token", "Bearer", "Bearer stress-test-token-extra", "bearer definitely-wrong"]
        for i in range(500):
            with self.subTest(iteration=i):
                handler = FakeHandler(path="/control/status", headers={"Authorization": bad_headers[i % len(bad_headers)]})
                with patch.object(gateway, "get_models", side_effect=AssertionError("unauthorized request reached upstream")):
                    gateway.Handler.do_GET(handler)
                self.assertEqual(handler.responses[0][0], 401)

    def test_250_unapproved_terminal_requests_never_execute(self):
        for i in range(250):
            payload = {"mode": "powershell" if i % 2 == 0 else "ssh",
                       "host": "msi" if i % 3 else "localhost",
                       "command": "Get-Process", "approved": False}
            body = json.dumps(payload).encode("utf-8")
            handler = FakeHandler(path="/terminal", method="POST",
                headers={"Authorization": "Bearer stress-test-token",
                         "Content-Type": "application/json", "Content-Length": str(len(body))},
                body=body)
            with self.subTest(iteration=i):
                with patch.object(gateway.subprocess, "run",
                                  side_effect=AssertionError("unapproved request must not execute")):
                    gateway.Handler.do_POST(handler)
                self.assertEqual(handler.responses[0][0], 403)

    def test_250_risky_command_markers_are_classified(self):
        # All cases contain a marker explicitly classified as risky by the gateway.
        commands = [
            "Get-Process; Remove-Item temp",
            "Get-Process | Out-File temp",
            "Get-Process && shutdown",
            "Get-Process\nRemove-Item temp",
            "Get-Process; Stop-Service example",
        ]
        for i in range(250):
            with self.subTest(iteration=i):
                self.assertTrue(gateway.command_is_risky(commands[i % len(commands)]))


if __name__ == "__main__":
    unittest.main()
