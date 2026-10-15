#!/usr/bin/env python3
"""Translate container TERM into the room's private graceful-shutdown request."""
from __future__ import annotations

import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time


def supervise(command: list[str], request: Path, grace_seconds: float = 27.0) -> int:
    if not request.is_absolute() or not request.parent.resolve().is_relative_to(Path("/tmp")):
        raise ValueError("Shutdown request must use an absolute path under /tmp")
    request.unlink(missing_ok=True)
    process = subprocess.Popen(command, start_new_session=True)
    deadline = None

    def stop(_signum, _frame):
        nonlocal deadline
        if deadline is not None:
            return
        deadline = time.monotonic() + grace_seconds
        try:
            descriptor = os.open(request, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
            os.close(descriptor)
            print(json.dumps({"event": "supervisor_shutdown_requested"}), flush=True)
        except OSError:
            process.terminate()

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    try:
        while True:
            try:
                result = process.wait(timeout=0.2)
                return result if result >= 0 else 128 - result
            except subprocess.TimeoutExpired:
                if deadline is not None and time.monotonic() >= deadline:
                    print(json.dumps({"event": "supervisor_shutdown_timeout"}), flush=True)
                    process.terminate()
                    try:
                        process.wait(timeout=1.0)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait()
                    return 1
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()
        request.unlink(missing_ok=True)


if __name__ == "__main__":
    os.umask(0o077)
    command = ["/usr/local/bin/godot", "--headless", "--path", "/opt/ace/app", "--log-file", "/dev/null", *sys.argv[1:]]
    request = Path(os.environ.get("ACE_SHUTDOWN_FILE", "/tmp/ace-shutdown.request"))
    sys.exit(supervise(command, request))
