"""Tests for opt-in legacy-device SSH identity verification."""
import os
import subprocess
import unittest
from unittest.mock import patch

from test_lmstudio_gateway import FakeHandler, gateway


class LegacyRootSSHTests(unittest.TestCase):
    def setUp(self):
        self.hosts = patch.dict(os.environ, {"GHOSTGPT_SSH_HOSTS": "legacy-iphone"})
        self.hosts.start()
        self.addCleanup(self.hosts.stop)

    @staticmethod
    def check(payload):
        handler = FakeHandler(path="/terminal", method="POST")
        gateway.Handler.handle_ssh(handler, payload)
        return handler

    def test_identity_command_requires_confirmation(self):
        request = {"host": "legacy-iphone", "username": "root", "command": "id -u"}
        handler = self.check(request)
        self.assertEqual(handler.responses[0][0], 403)

    def test_untrusted_host_rejected_before_connecting(self):
        with patch.object(gateway.subprocess, "run") as remote:
            handler = self.check({
                "host": "untrusted-iphone", "username": "root",
                "command": "id -u", "approved": True
            })
        self.assertEqual(handler.responses[0][0], 403)
        remote.assert_not_called()

    def test_ssh_root_identity_is_read_only(self):
        result = subprocess.CompletedProcess(
            args=["ssh", "root@legacy-iphone", "id -u"],
            returncode=0, stdout="0\n", stderr=""
        )
        with patch.object(gateway.shutil, "which", return_value="ssh.exe"), \
                patch.object(gateway.subprocess, "run", return_value=result) as remote:
            handler = self.check({
                "host": "legacy-iphone", "username": "root",
                "command": "id -u", "approved": True, "riskConfirmed": False
            })
        self.assertEqual(handler.responses[0][0], 200)
        self.assertEqual(handler.responses[0][1]["stdout"].strip(), "0")
        self.assertEqual(handler.responses[0][1]["risk"], "read-only")
        self.assertEqual(remote.call_args.args[0][-2:], ["root@legacy-iphone", "id -u"])
        self.assertIn("StrictHostKeyChecking=yes", remote.call_args.args[0])

    def test_arbitrary_root_shell_is_rejected(self):
        with patch.object(gateway.subprocess, "run") as remote:
            handler = self.check({
                "host": "legacy-iphone", "username": "root",
                "command": "sh -c whoami", "approved": True, "riskConfirmed": True
            })
        self.assertEqual(handler.responses[0][0], 403)
        remote.assert_not_called()


if __name__ == "__main__":
    unittest.main()
