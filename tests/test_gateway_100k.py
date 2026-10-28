"""100,000 deterministic regression checks for the GhostGPT gateway."""
import unittest
from unittest.mock import patch

from test_lmstudio_gateway import FakeHandler, gateway


class Gateway100KRegressionTests(unittest.TestCase):
    def test_100000_invalid_auth_requests_are_rejected_before_upstream(self):
        bad_headers = ["", "Basic invalid", "Bearer", "Bearer invalid-extra", "bearer wrong"]
        for i in range(100_000):
            handler = FakeHandler(path="/control/status", headers={"Authorization": bad_headers[i % len(bad_headers)]})
            with patch.object(gateway, "get_models", side_effect=AssertionError("unauthorized request reached upstream")):
                gateway.Handler.do_GET(handler)
            self.assertEqual(handler.responses[0][0], 401, f"iteration {i}")


if __name__ == "__main__":
    unittest.main()
