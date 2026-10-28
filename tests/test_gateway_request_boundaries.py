"""Additional adversarial request-shape tests for the GhostGPT gateway."""
import json
import unittest
from unittest.mock import patch

from test_lmstudio_gateway import FakeHandler, gateway


class GatewayRequestBoundaryTests(unittest.TestCase):
    def setUp(self):
        self.token = patch.dict("os.environ", {"GHOSTGPT_GATEWAY_TOKEN": "boundary-test-token"})
        self.token.start()
        self.addCleanup(self.token.stop)

    def post_terminal(self, payload, body_override=None):
        body = body_override if body_override is not None else json.dumps(payload).encode("utf-8")
        handler = FakeHandler(
            path="/terminal",
            method="POST",
            headers={
                "Authorization": "Bearer boundary-test-token",
                "Content-Type": "application/json",
                "Content-Length": str(len(body)),
            },
            body=body,
        )
        gateway.Handler.do_POST(handler)
        return handler

    def test_invalid_json_is_rejected(self):
        handler = self.post_terminal({}, body_override=b"{")
        self.assertEqual(handler.responses[0][0], 400)

    def test_json_array_is_rejected_as_non_object(self):
        handler = self.post_terminal({}, body_override=b"[]")
        self.assertEqual(handler.responses[0][0], 400)
        self.assertIn("JSON object", handler.responses[0][1]["error"])

    def test_unknown_terminal_mode_is_rejected(self):
        handler = self.post_terminal({"mode": "cmd", "approved": True})
        self.assertEqual(handler.responses[0][0], 400)

    def test_encoded_powershell_command_is_blocked_before_execution(self):
        handler = self.post_terminal({
            "mode": "powershell",
            "host": "localhost",
            "command": "powershell -EncodedCommand ZQBjAGgAbwA=",
            "approved": True,
        })
        self.assertEqual(handler.responses[0][0], 403)

    def test_ssh_target_not_in_allowlist_is_rejected_before_execution(self):
        handler = self.post_terminal({
            "mode": "ssh",
            "host": "untrusted.example",
            "command": "hostname",
            "approved": True,
        })
        self.assertEqual(handler.responses[0][0], 403)


if __name__ == "__main__":
    unittest.main()
