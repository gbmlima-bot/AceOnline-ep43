#!/usr/bin/env python3
"""Build an isolated data-only server and exercise the production WebSocket/SQL path.

Uses Python's standard library plus the supplied Godot binary. No deployment,
network service outside localhost, client artwork imports or credentials on disk.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile


def stop_group(process: subprocess.Popen[str]) -> None:
    if process.poll() is not None:
        return
    os.killpg(process.pid, signal.SIGTERM)
    try:
        process.communicate(timeout=3)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.communicate()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", type=Path, required=True)
    parser.add_argument("--source", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--report", type=Path)
    args = parser.parse_args()
    source = args.source.resolve()
    executable = args.godot.resolve()
    if not executable.is_file():
        raise ValueError("The supplied Godot executable does not exist")
    with tempfile.TemporaryDirectory(prefix="ace-server-e2e-bundle-") as temporary:
        output = Path(temporary) / "bundle"
        built = subprocess.run(
            [sys.executable, str(source / "tools/build_server_bundle.py"), "--source", str(source),
             "--output", str(output), "--app-only"],
            capture_output=True, text=True, timeout=60, check=False,
        )
        if built.returncode:
            raise RuntimeError("The minimal server fixture could not be built: " + built.stderr[-1500:])
        tests = output / "app/tests"
        tests.mkdir()
        shutil.copyfile(source / "server/tests/test_server_e2e.gd", tests / "test_server_e2e.gd")
        process = subprocess.Popen(
            [str(executable), "--headless", "--path", str(output / "app"),
             "--script", "res://tests/test_server_e2e.gd"],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, start_new_session=True,
        )
        try:
            log, _ = process.communicate(timeout=90)
        except subprocess.TimeoutExpired as error:
            stop_group(process)
            raise RuntimeError("The production server E2E timed out; its private process group was stopped") from error
        finally:
            # The GDScript normally removes this itself. Only this exact process's
            # generated fixture is eligible for cleanup after an interrupted run.
            fixture = Path("/tmp") / f"ace-server-e2e-{process.pid}"
            if fixture.is_dir():
                shutil.rmtree(fixture)
        results = [json.loads(line.removeprefix("SERVER_E2E="))
                   for line in log.splitlines() if line.startswith("SERVER_E2E=")]
        if len(results) != 1:
            raise RuntimeError("Expected one production E2E result; check that the server/test scripts parse")
        result = results[0]
        passed = (process.returncode == 0 and not result.get("failures") and result.get("checks", 0) > 0
                  and result.get("real_server_process") is True
                  and result.get("independent_websocket_clients") == 2
                  and result.get("real_sqlite") is True and result.get("restart_tested") is True
                  and not any(marker in log for marker in ("ERROR:", "SCRIPT ERROR", "Parse Error:")))
        if args.report:
            args.report.parent.mkdir(parents=True, exist_ok=True)
            args.report.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        print("SERVER_E2E=" + json.dumps(result, ensure_ascii=False, sort_keys=True))
        return 0 if passed else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        print(json.dumps({"suite": "server_e2e", "passed": False, "error": str(error)}, ensure_ascii=False), file=sys.stderr)
        raise SystemExit(1)
