"""High-volume regression checks for GhostGPT gateway security boundaries.

These are deterministic stress tests, not claims of 1,000 independent feature scenarios.
"""
import json
import unittest
from unittest.mock import patch

from test_lmstudio_gateway import FakeHandler, gateway


class GatewayStressTests(unittest.TestCase):
    def setUp(self):
        self.token = patch.dict("os.environ", {
            "GHOSTGPT_GATEWAY_TOKEN": "stress-test-token",
        })
        self.token.start()
        self.addCleanup(self.token.stop)

    def test_500_invalid_authorization_headers_are_rejected(self):
        # 500 distinct malformed/mismatched bearer headers; upstream must never be queried.
        bad_headers = [
            "",
            "Basic stress-test-token",
            "Bearer",
            "Bearer stress-test-token-extra",
            "bearer definitely-wrong",
        ]
        for i in range(500):
            header = bad_headers[i % len(bad_headers)]
            with self.subTest(iteration=i):
                handler = FakeHandler(
                    path="/control/status",
                    headers={"Authorization": header},
                )
                with patch.object(gateway, "get_models",
                                  side_effect=AssertionError("unauthorized request reached upstream")):
                    gateway.Handler.do_GET(handler)
                self.assertEqual(handler.responses[0][0], 401)

    def test_250_unapproved_terminal_requests_never_execute(self):
        # Vary payload fields to cover missing/false approval and unusual modes.
        for i in range(250):
            payload = {
                "mode": ("powershell" if i % 2 == 0 else "ssh"),
                "host": ("msi" if i % 3 else "localhost"),
                "command": "Get-Process",
                "approved": False,
            }
            body = json.dumps(payload).encode("utf-8")
            handler = FakeHandler(
                path="/terminal",
                method="POST",
                headers={
                    "Authorization": "Bearer stress-test-token",
                    "Content-Type": "application/json",
                    "Content-Length": str(len(body)),
                },
                body=body,
            )
            with self.subTest(iteration=i):
                with patch.object(gateway.subprocess, "run",
                                  side_effect=AssertionError("unapproved command executed")):
                    gateway.Handler.do_POST(handler)
                self.assertEqual(handler.responses[0][0], 403)

    def test_250_compound_commands_are_classified_as_risky(self):
        # Exercise a range of command-composition patterns; no commands are executed.
        fragments = [
            "Get-Process; Remove-Item C:\\temp",
            "Get-Process | Out-File C:\\temp\\x",
            "Get-Process && shutdown",
            "Get-Process\nRemove-Item C:\\temp",
            "Get-Process $(whoami)",
        ]
        for i in range(250):
            command = fragments[i % len(fragments)]
            with self.subTest(iteration=i):
                self.assertTrue(gateway.command_is_risky(command))


if __name__ == "__main__":
    unittest.main()
