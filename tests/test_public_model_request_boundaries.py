"""Request-shape and pairing-safety regression tests for the public model gateway."""
import json
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import patch

from test_lmstudio_gateway import FakeHandler, public_gateway


class PublicModelGatewayRequestTests(unittest.TestCase):
    def post(self, body, declared_length=None, path="/pair"):
        handler = FakeHandler(
            path=path,
            method="POST",
            headers={"Content-Length": str(len(body) if declared_length is None else declared_length)},
            body=body,
        )
        public_gateway.Handler.do_POST(handler)
        return handler

    def test_json_array_is_rejected_with_400(self):
        handler = self.post(b"[]")
        self.assertEqual(handler.responses[0][0], 400)
        self.assertIn("JSON object", handler.responses[0][1]["error"])

    def test_json_number_is_rejected_with_400(self):
        handler = self.post(b"42")
        self.assertEqual(handler.responses[0][0], 400)
        self.assertIn("JSON object", handler.responses[0][1]["error"])

    def test_incomplete_body_is_rejected_before_pairing(self):
        handler = self.post(b'{"code":"ABC"}', declared_length=100)
        self.assertEqual(handler.responses[0][0], 400)
        self.assertIn("Incomplete", handler.responses[0][1]["error"])

    def test_invalid_json_is_rejected_with_400(self):
        handler = self.post(b"{")
        self.assertEqual(handler.responses[0][0], 400)

    def test_missing_token_does_not_consume_pairing_code(self):
        with tempfile.TemporaryDirectory() as td:
            pairing_state = Path(td) / "pairing.json"
            pairing_state.write_text(json.dumps({
                "code": "TEST-CODE",
                "expires_at": time.time() + 600,
                "used": False,
            }), encoding="utf-8")
            with patch.object(public_gateway, "PAIR_FILE", pairing_state), \
                    patch.object(public_gateway, "token", return_value=""):
                handler = self.post(b'{"code":"TEST-CODE"}')
            self.assertEqual(handler.responses[0][0], 503)
            self.assertFalse(json.loads(pairing_state.read_text(encoding="utf-8"))["used"])


if __name__ == "__main__":
    unittest.main()
