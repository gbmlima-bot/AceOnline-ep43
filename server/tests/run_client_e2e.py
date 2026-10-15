#!/usr/bin/env python3
"""Run the production Godot client against an isolated production server process.

Requires previously imported client assets. Invitations are created by SQLiteStore
inside a fixture server; their0600 temporary handoff is deleted by the client before
connecting. No token is passed through arguments, environment variables or logs.
"""
from __future__ import annotations

import argparse
import hashlib
import http.client
import json
import os
from pathlib import Path
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time

FIXTURE_SERVER = '''extends SceneTree
const Store=preload("res://sqlite_store.gd")
func _initialize() -> void:
    _run.call_deferred()
func _run() -> void:
    var store=Store.new()
    if not store.open(OS.get_environment("ACE_DATA_DIR").path_join("ace-online.sqlite")):
        quit(2)
        return
    var pilots:Array[Dictionary]=[]
    for label:String in ["Client E2E Alpha","Client E2E Beta"]:
        var pilot:Dictionary=store.issue_pilot(label)
        if pilot.is_empty():
            quit(2)
            return
        pilots.append(pilot)
    store.close()
    var server=(load("res://server.tscn") as PackedScene).instantiate()
    root.add_child(server)
    if not server._initialized:
        quit(2)
        return
    var path=OS.get_environment("ACE_CLIENT_FIXTURE")
    var file=FileAccess.open(path,FileAccess.WRITE)
    if file==null:
        quit(2)
        return
    FileAccess.set_unix_permissions(path,384)
    file.store_string(JSON.stringify({"url":"ws://127.0.0.1:"+OS.get_environment("ACE_PORT")+"/play","pilots":pilots}))
    file.close()
'''


def free_port() -> int:
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


def stop_group(process: subprocess.Popen[str]) -> None:
    if process.poll() is not None:
        return
    os.killpg(process.pid, signal.SIGTERM)
    try:
        process.wait(timeout=3)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait()


def contains_secret(path: Path, invitations: list[str]) -> bool:
    needles = [token.encode("ascii") for token in invitations]
    tail = b""
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(65536), b""):
            data = tail + block
            if any(token in data for token in needles):
                return True
            tail = data[-63:]
    return False


def print_client_diagnostics(client_log: str) -> None:
    """Keep the first fault visible even when rendering shutdown emits many leaks."""
    lines = client_log.splitlines()
    selected: list[str] = []
    for index, line in enumerate(lines):
        if line.startswith("ONLINE_SCENE_DIAGNOSTIC=") or any(
            marker in line for marker in ("SCRIPT ERROR", "Parse Error:")
        ):
            selected.extend(lines[max(0, index - 1):index + 5])
    if selected:
        print("\n".join(selected)[:12000], file=sys.stderr)
    print(client_log[-4000:], file=sys.stderr)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", type=Path, required=True)
    parser.add_argument("--source", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--client-pack", type=Path, help="Test the exported PCK using the Linux engine")
    parser.add_argument("--display", help="Optional real X11 display, for example:91")
    parser.add_argument("--capture", type=Path)
    parser.add_argument("--report", type=Path)
    args = parser.parse_args()
    source = args.source.resolve()
    executable = args.godot.resolve()
    if not executable.is_file() or not (source / "client/.godot/imported").is_dir():
        raise ValueError("A valid Godot executable and previously imported client assets are required")
    if args.client_pack and not args.client_pack.is_file():
        raise ValueError("An existing exported pack is required")
    if args.capture and not args.display:
        raise ValueError("Viewport capture requires --display with an actual OpenGL display")
    with tempfile.TemporaryDirectory(prefix="ace-client-e2e-") as temporary:
        workspace = Path(temporary)
        output = workspace / "bundle"
        built = subprocess.run(
            [sys.executable, str(source / "tools/build_server_bundle.py"), "--source", str(source),
             "--output", str(output), "--app-only"],
            capture_output=True, text=True, timeout=60, check=False,
        )
        if built.returncode:
            raise RuntimeError("Cannot build isolated production server context")
        tests = output / "app/tests"
        tests.mkdir()
        (tests / "fixture_client_server.gd").write_text(FIXTURE_SERVER, encoding="utf-8")
        credential_file = workspace / "invitation-handoff.json"
        shutdown = workspace / "shutdown.flag"
        server_log = workspace / "server.log"
        data = workspace / "data"
        environment = dict(os.environ)
        port, health = free_port(), free_port()
        while health == port:
            health = free_port()
        environment.update(ACE_DATA_DIR=str(data), ACE_BIND_ADDRESS="127.0.0.1", ACE_PORT=str(port),
                           ACE_HEALTH_PORT=str(health), ACE_MAX_PLAYERS="2", ACE_SHUTDOWN_FILE=str(shutdown),
                           ACE_CLIENT_FIXTURE=str(credential_file))
        invitations: list[str] = []
        client: subprocess.Popen[str] | None = None
        with server_log.open("w", encoding="utf-8") as log_file:
            server = subprocess.Popen(
                [str(executable), "--headless", "--audio-driver", "Dummy", "--path", str(output / "app"),
                 "--script", "res://tests/fixture_client_server.gd"],
                stdout=log_file, stderr=subprocess.STDOUT, text=True, env=environment, start_new_session=True,
            )
            try:
                deadline = time.monotonic() + 20
                while not credential_file.is_file() and time.monotonic() < deadline and server.poll() is None:
                    time.sleep(0.05)
                if not credential_file.is_file():
                    raise RuntimeError("The production fixture server failed to reach readiness")
                if credential_file.stat().st_mode & 0o777 != 0o600:
                    raise RuntimeError("Invitation handoff permissions are not0600")
                fixture = json.loads(credential_file.read_text(encoding="utf-8"))
                invitations = [row["token"] for row in fixture["pilots"]]
                client_environment = dict(os.environ)
                # Main._ready runs during add_child. Isolate user:// before the
                # engine starts, independently of any later test save-path guard.
                client_environment.update(XDG_DATA_HOME=str(workspace / "client-user-data"),
                                          XDG_CACHE_HOME=str(workspace / "client-cache"))
                client_path = source / "client"
                if args.client_pack:
                    client_path = workspace / "packed-client"
                    client_path.mkdir()
                command = [str(executable), "--path", str(client_path), "--audio-driver", "Dummy", "--max-fps", "60"]
                if args.client_pack:
                    command += ["--main-pack", str(args.client_pack.resolve())]
                if args.display:
                    client_environment.update(DISPLAY=args.display, LIBGL_ALWAYS_SOFTWARE="1")
                    command += ["--rendering-method", "gl_compatibility", "--rendering-driver", "opengl3"]
                else:
                    command += ["--headless"]
                test_script = str(source / "client/tests/test_online_scene.gd") if args.client_pack else "res://tests/test_online_scene.gd"
                command += ["--script", test_script, "--", "--fixture=" + str(credential_file)]
                if args.capture:
                    args.capture.parent.mkdir(parents=True, exist_ok=True)
                    command += ["--capture=" + str(args.capture.resolve())]
                client = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                          text=True, env=client_environment, start_new_session=True)
                try:
                    client_log, _ = client.communicate(timeout=150)
                except subprocess.TimeoutExpired as error:
                    stop_group(client)
                    raise RuntimeError("Production client E2E timed out; its process group was stopped") from error
                if any(token in client_log for token in invitations):
                    raise RuntimeError("Production client log leaked a fixture invitation; log withheld")
                results = [json.loads(line.removeprefix("ONLINE_SCENE_E2E=")) for line in client_log.splitlines()
                           if line.startswith("ONLINE_SCENE_E2E=")]
                if len(results) != 1:
                    print_client_diagnostics(client_log)
                    raise RuntimeError("Expected one production online-scene E2E result (client exit " + str(client.returncode) + ")")
                result = results[0]
                result["exported_pack_executed_on_linux"] = args.client_pack is not None
                result["native_macos_windows_execution"] = False
                passed = (client.returncode == 0 and not result.get("failures") and result.get("checks", 0) > 0
                          and result.get("real_server") is True and result.get("production_main") is True
                          and result.get("online_state_not_injected") is True
                          and not any(marker in client_log for marker in ("ERROR:", "SCRIPT ERROR", "Parse Error:")))
                if not passed:
                    print_client_diagnostics(client_log)
                    try:
                        probe = http.client.HTTPConnection("127.0.0.1", health, timeout=2)
                        probe.request("GET", "/metrics")
                        response = probe.getresponse()
                        diagnostics = json.loads(response.read())
                        probe.close()
                        print("ONLINE_SCENE_SERVER_DIAGNOSTIC=" + json.dumps(diagnostics, sort_keys=True), file=sys.stderr)
                    except (OSError, ValueError):
                        print("ONLINE_SCENE_SERVER_DIAGNOSTIC=unavailable", file=sys.stderr)
                result["private_fixture_deleted_before_connection"] = not credential_file.exists()
                passed = passed and result["private_fixture_deleted_before_connection"]
            finally:
                if client is not None and client.poll() is None:
                    stop_group(client)
                if server.poll() is None:
                    shutdown.touch()
                    try:
                        server.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        stop_group(server)
            if invitations and contains_secret(server_log, invitations):
                raise RuntimeError("Production server log leaked a fixture invitation; log withheld")
            server_text = server_log.read_text(encoding="utf-8")
            if server.returncode != 0 or any(marker in server_text for marker in ("ERROR:", "SCRIPT ERROR", "Parse Error:")):
                passed = False
                print(server_text[-3000:], file=sys.stderr)
            for path in data.glob("ace-online.sqlite*"):
                if invitations and contains_secret(path, invitations):
                    raise RuntimeError("SQLite/WAL contains a plaintext invitation")
            if args.capture and args.capture.is_file():
                result["capture"] = {"file": args.capture.name, "sha256": hashlib.sha256(args.capture.read_bytes()).hexdigest(),
                                     "bytes": args.capture.stat().st_size}
            result["passed"] = passed
            if args.report:
                args.report.parent.mkdir(parents=True, exist_ok=True)
                args.report.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
            print("ONLINE_SCENE_E2E=" + json.dumps(result, ensure_ascii=False, sort_keys=True))
            return 0 if passed else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        print(json.dumps({"suite": "online_scene_e2e", "passed": False, "error": str(error)}, ensure_ascii=False), file=sys.stderr)
        raise SystemExit(1)
