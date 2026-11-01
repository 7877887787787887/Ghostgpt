"""Portable workspace-only file operations. This function also runs over SSH."""


def workspace_operation(payload, root, allow_write=False):
    import contextlib
    import hashlib
    import os
    import pathlib
    import tempfile
    import time

    def fail(status, message):
        return status, {"ok": False, "error": message}

    root = pathlib.Path(root).expanduser().resolve()
    action = payload.get("action")
    relative = payload.get("path", "")
    if not isinstance(relative, str) or len(relative) > 1000 or any(ord(c) < 32 for c in relative):
        return fail(400, "Invalid workspace path")
    relative = relative.replace("\\", "/")
    parts = relative.split("/") if relative else []
    protected = {".git", ".ssh", ".aws", ".azure", ".env", ".npmrc", "gateway.token", "public-model.token", "id_rsa", "id_ed25519", "authorized_keys"}
    if relative.startswith("/") or ":" in relative or any(p in {"..", ".", ""} for p in parts):
        return fail(403, "Use a relative path inside the workspace")
    if any(p.casefold() in protected or p.casefold().startswith((".env.", ".ghostgpt-")) for p in parts):
        return fail(403, "Protected workspace path")
    target = root.joinpath(*parts)
    try:
        target.resolve().relative_to(root)
        current = root
        for part in parts:
            current = current / part
            if current.is_symlink() or getattr(current, "is_junction", lambda: False)():
                return fail(403, "Symlinks and junctions are not workspace file targets")
    except (OSError, ValueError):
        return fail(403, "Path leaves the workspace")

    if action == "list":
        if not target.is_dir():
            return fail(404, "Workspace directory does not exist")
        entries = []
        for item in sorted(target.iterdir(), key=lambda p: p.name.casefold()):
            if item.name.casefold() in protected or item.name.startswith(".ghostgpt-") or item.is_symlink() or getattr(item, "is_junction", lambda: False)():
                continue
            entries.append({"name": item.name, "directory": item.is_dir()})
            if len(entries) == 100:
                break
        return 200, {"ok": True, "path": relative, "entries": entries, "limit": 100}

    if not parts:
        return fail(400, "A file path is required")
    if action not in {"read", "write", "patch"}:
        return fail(400, "Unsupported workspace action")
    if target.exists() and not target.is_file():
        return fail(400, "Target is not a regular file")
    if target.is_file() and target.stat().st_size > 65536:
        return fail(413, "Workspace text files are limited to 64 KiB")

    if action == "read":
        if not target.is_file():
            return 404, {"ok": False, "error": "File does not exist", "sha256": "missing"}
        try:
            raw = target.read_bytes()
            text = raw.decode("utf-8")
        except UnicodeDecodeError:
            return fail(415, "Only UTF-8 text files are supported")
        offset = payload.get("offset", 0)
        limit = payload.get("max_chars", 4000)
        if type(offset) is not int or offset < 0 or type(limit) is not int or not 1 <= limit <= 4000:
            return fail(400, "Invalid read offset or length")
        end = min(len(text), offset + limit)
        return 200, {"ok": True, "path": relative, "content": text[offset:end],
                     "sha256": hashlib.sha256(raw).hexdigest(), "total_chars": len(text),
                     "next_offset": end, "truncated": end < len(text)}

    if not allow_write or payload.get("approved") is not True or payload.get("riskConfirmed") is not True:
        return fail(403, "Workspace writes require gateway opt-in and explicit review approval")
    expected = payload.get("expected_sha256")
    if not isinstance(expected, str) or (expected != "missing" and (len(expected) != 64 or any(c not in "0123456789abcdef" for c in expected))):
        return fail(400, "Supply the current SHA-256 from read, or missing for a new file")
    if action == "write" and not isinstance(payload.get("content"), str):
        return fail(400, "Text content is required")
    if action == "patch" and (not isinstance(payload.get("find"), str) or not payload["find"] or not isinstance(payload.get("replace"), str)):
        return fail(400, "Patch requires a nonempty find string and a replacement")

    @contextlib.contextmanager
    def lock_workspace():
        root.mkdir(parents=True, exist_ok=True)
        with (root / ".ghostgpt-file-lock").open("a+b") as lock:
            if lock.tell() == 0:
                lock.write(b"0")
                lock.flush()
            deadline = time.monotonic() + 5
            while True:
                try:
                    lock.seek(0)
                    if os.name == "nt":
                        import msvcrt
                        msvcrt.locking(lock.fileno(), msvcrt.LK_NBLCK, 1)
                    else:
                        import fcntl
                        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    break
                except OSError:
                    if time.monotonic() >= deadline:
                        raise TimeoutError("Workspace is busy")
                    time.sleep(0.02)
            try:
                yield
            finally:
                lock.seek(0)
                if os.name == "nt":
                    msvcrt.locking(lock.fileno(), msvcrt.LK_UNLCK, 1)
                else:
                    fcntl.flock(lock, fcntl.LOCK_UN)

    temporary = None
    try:
        with lock_workspace():
            # Recheck containment after taking the cross-process write lock.
            target.resolve().relative_to(root)
            if target.is_symlink() or getattr(target, "is_junction", lambda: False)():
                return fail(403, "File target became a link")
            old = target.read_bytes() if target.exists() else None
            actual = hashlib.sha256(old).hexdigest() if old is not None else "missing"
            if actual != expected:
                return 409, {"ok": False, "error": "File changed; read and review again", "sha256": actual}
            if action == "patch":
                if old is None:
                    return fail(404, "Cannot patch a missing file")
                text = old.decode("utf-8")
                if text.count(payload["find"]) != 1:
                    return fail(409, "Patch must match exactly once")
                text = text.replace(payload["find"], payload["replace"], 1)
            else:
                text = payload["content"]
            raw = text.encode("utf-8")
            if len(raw) > 65536:
                return fail(413, "Workspace text files are limited to 64 KiB")
            target.parent.mkdir(parents=True, exist_ok=True)
            target.parent.resolve().relative_to(root)
            with tempfile.NamedTemporaryFile(dir=target.parent, prefix=".ghostgpt-", delete=False) as handle:
                temporary = handle.name
                handle.write(raw)
                handle.flush()
                os.fsync(handle.fileno())
            if old is not None:
                os.chmod(temporary, target.stat().st_mode & 0o777)
            os.replace(temporary, target)
            temporary = None
            return 200, {"ok": True, "path": relative, "sha256": hashlib.sha256(raw).hexdigest(),
                         "bytes": len(raw), "action": action}
    except UnicodeDecodeError:
        return fail(415, "Only UTF-8 text files are supported")
    except TimeoutError:
        return fail(503, "Workspace is busy; retry after rereading the file")
    except (OSError, ValueError):
        return fail(403, "Workspace file could not be accessed safely")
    finally:
        if temporary:
            try:
                os.unlink(temporary)
            except OSError:
                pass
