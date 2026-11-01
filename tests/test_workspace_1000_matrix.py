import hashlib
import tempfile
import unittest
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor

from test_lmstudio_gateway import gateway


class WorkspaceRegressionTests(unittest.TestCase):
    def test_1000_real_workspace_operations(self):
        operation = gateway.workspace_files.workspace_operation
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "workspace"
            count = 0
            for i in range(100):
                path = f"project/code-{i}.py"
                original = f"print('caf\u00e9 {i}')\n"
                digest = hashlib.sha256(original.encode()).hexdigest()
                request = {"action": "write", "path": path, "content": original,
                           "expected_sha256": "missing", "approved": True, "riskConfirmed": True}
                with self.subTest(case=i, action="create"):
                    self.assertEqual(operation(request, root, True)[0], 200)
                    count += 1
                with self.subTest(case=i, action="read"):
                    status, data = operation({"action": "read", "path": path}, root)
                    self.assertEqual((status, data["content"], data["sha256"]), (200, original, digest))
                    count += 1
                with self.subTest(case=i, action="stale-write"):
                    self.assertEqual(operation({**request, "content": "wrong", "expected_sha256": "0" * 64}, root, True)[0], 409)
                    self.assertEqual((root / path).read_text(encoding="utf-8"), original)
                    count += 1
                with self.subTest(case=i, action="patch"):
                    patch = {"action": "patch", "path": path, "find": f"caf\u00e9 {i}", "replace": f"updated {i}",
                             "expected_sha256": digest, "approved": True, "riskConfirmed": True}
                    self.assertEqual(operation(patch, root, True)[0], 200)
                    self.assertIn(f"updated {i}", (root / path).read_text())
                    count += 1
                with self.subTest(case=i, action="write-disabled"):
                    self.assertEqual(operation({**request, "path": f"denied-{i}.ps1"}, root, False)[0], 403)
                    self.assertFalse((root / f"denied-{i}.ps1").exists())
                    count += 1
                with self.subTest(case=i, action="traversal"):
                    self.assertEqual(operation({**request, "path": f"../outside-{i}.py"}, root, True)[0], 403)
                    self.assertFalse((root.parent / f"outside-{i}.py").exists())
                    count += 1
                with self.subTest(case=i, action="windows-path"):
                    self.assertEqual(operation({**request, "path": f"C:\\outside-{i}.py"}, root, True)[0], 403)
                    count += 1
                with self.subTest(case=i, action="protected-file"):
                    self.assertEqual(operation({**request, "path": f"project-{i}/.env"}, root, True)[0], 403)
                    count += 1
                with self.subTest(case=i, action="binary-read"):
                    name = f"binary-{i}.dat"
                    (root / name).write_bytes(b"\xff\xfe\x00" + bytes([i]))
                    self.assertEqual(operation({"action": "read", "path": name}, root)[0], 415)
                    count += 1
                with self.subTest(case=i, action="oversize"):
                    self.assertEqual(operation({**request, "path": f"large-{i}.py", "content": "x" * 65537}, root, True)[0], 413)
                    self.assertFalse((root / f"large-{i}.py").exists())
                    count += 1
            self.assertEqual(count, 1000)
        print("Workspace matrix: 1000 actual filesystem operations passed.")

    def test_parallel_stale_writers_cannot_both_replace_a_file(self):
        operation = gateway.workspace_files.workspace_operation
        with tempfile.TemporaryDirectory() as root:
            Path(root, "a.py").write_text("old", encoding="utf-8")
            digest = hashlib.sha256(b"old").hexdigest()
            def write(text):
                return operation({"action": "write", "path": "a.py", "content": text,
                    "expected_sha256": digest, "approved": True, "riskConfirmed": True}, root, True)[0]
            with ThreadPoolExecutor(max_workers=2) as pool:
                results = list(pool.map(write, ["first", "second"]))
            self.assertEqual(sorted(results), [200, 409])

    def test_symlink_cannot_escape_workspace(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory, "workspace")
            root.mkdir()
            outside = Path(directory, "private.txt")
            outside.write_text("do not expose")
            try:
                (root / "alias.py").symlink_to(outside)
            except OSError:
                self.skipTest("Host does not permit symlink creation")
            status, _ = gateway.workspace_files.workspace_operation({"action": "read", "path": "alias.py"}, root)
            self.assertEqual(status, 403)
