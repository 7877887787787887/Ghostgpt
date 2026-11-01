"""1,000 deterministic request regressions; never run commands on a real host."""
import json
import shlex
import subprocess
import unittest
from unittest.mock import patch

from test_lmstudio_gateway import FakeHandler, gateway, public_gateway


class Gateway1000Matrix(unittest.TestCase):
    def test_1000_gateway_requests(self):
        count = 0
        token = "matrix-only-test-token"
        env = {"GHOSTGPT_GATEWAY_TOKEN": token, "GHOSTGPT_SSH_HOSTS": "trusted-pi",
               "GHOSTGPT_ALLOW_MODIFYING_COMMANDS": "0"}
        with patch.dict("os.environ", env), patch.object(gateway, "powershell_executable", return_value="powershell.exe"), \
             patch.object(gateway.shutil, "which", return_value="ssh.exe"):
            for family in range(10):
                for i in range(100):
                    with self.subTest(family=family, case=i):
                        payload = {"mode": "powershell", "host": "localhost", "command": "hostname", "approved": True}
                        auth = token
                        expected = 403
                        allowed = False
                        raw = None
                        if family == 0:
                            auth = f"wrong-{i}"
                            expected = 401
                        elif family == 1:
                            payload.update(command=f"Get-Process -Id {i + 1}", approved=False)
                        elif family == 2:
                            payload["command"] = f"Get-Process -Id {i + 1}"
                            allowed = True
                            expected = 200
                        elif family == 3:
                            separator = [";", "|", "&", "\n", "\r", ">", "`", "$(", "(", "{"][i % 10]
                            payload["command"] = f"Get-Date{separator}Write-Output case{i}"
                        elif family == 4:
                            payload["command"] = [
                                f"Get-Content C:\\private\\gateway.token -Tail {i}",
                                f"Get-Content C:\\private\\public-model.to'ken' -Tail {i}",
                                f"Get-Process -ComputerName remote{i}",
                                f"Get-Content \\\\remote{i}\\share\\file.txt",
                                f"Get-Content C:\\logs\\case{i}*.txt",
                                f"Get-Process -c remote{i}",
                                f"Get-Process -Co'mp'uterName remote{i}",
                            ][i % 7]
                        elif family in (5, 6, 7):
                            payload.update(mode="ssh", host="trusted-pi", username="pi")
                            if family == 5:
                                separator = ["\n", "\r", "&", ";", "|", "`", "$", ">", "<", "\x00"][i % 10]
                                payload["command"] = f"hostname{separator}printf case{i}"
                            elif family == 6:
                                payload["command"] = [f"hostname changed{i}", f"date -s @{i}", f"date 10301200{i}",
                                                       f"ss -D /tmp/case{i}", f"ip link set eth{i} down"][i % 5]
                            else:
                                payload["command"] = f"ls -- '/tmp/case {i}'"
                                expected = 200
                                allowed = True
                        elif family == 8:
                            raw = json.dumps([i, "not-an-object"]).encode()
                            expected = 400
                        else:
                            # The public pairing route must reject non-object JSON
                            # without consuming a code or exposing the device token.
                            raw = json.dumps([i, {"code": "invalid"}]).encode()
                            handler = FakeHandler(path="/pair", method="POST", body=raw,
                                headers={"Content-Length": str(len(raw))})
                            with patch.object(public_gateway, "redeem", side_effect=AssertionError("invalid shape reached pairing")), \
                                 patch.object(public_gateway, "token", side_effect=AssertionError("invalid shape accessed token")):
                                public_gateway.Handler.do_POST(handler)
                            self.assertEqual(handler.responses[0][0], 400)
                            count += 1
                            continue

                        body = raw if raw is not None else json.dumps(payload).encode()
                        handler = FakeHandler(path="/terminal", method="POST", body=body,
                            headers={"Authorization": "Bearer " + auth, "Content-Length": str(len(body))})
                        result = subprocess.CompletedProcess([], i % 2, stdout=f"case {i}: caf\u00e9 \u2713\n", stderr="")
                        with patch.object(gateway.subprocess, "run", return_value=result) as execute:
                            gateway.Handler.do_POST(handler)
                        self.assertEqual(handler.responses[0][0], expected)
                        if allowed:
                            execute.assert_called_once()
                            args, kwargs = execute.call_args
                            self.assertFalse(kwargs["shell"])
                            self.assertEqual(kwargs["encoding"], "utf-8")
                            self.assertEqual(handler.responses[0][1]["ok"], result.returncode == 0)
                            self.assertIn("caf\u00e9 \u2713", handler.responses[0][1]["stdout"])
                            if family == 7:
                                self.assertEqual(shlex.split(args[0][-1]), ["ls", "--", f"/tmp/case {i}"])
                                self.assertIn("StrictHostKeyChecking=yes", args[0])
                        else:
                            execute.assert_not_called()
                        count += 1
        self.assertEqual(count, 1000)
        print("Gateway matrix: 1000 cases passed across 10 request families.")


if __name__ == "__main__":
    unittest.main()
