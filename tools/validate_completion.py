#!/usr/bin/env python3
"""Validate the 0.9 rules and production scenes with Godot 4.7.2.

The model phase uses recovered numeric data. The scene phase additionally needs
the complete source assets and an existing Godot import cache. No public server
or native macOS/Windows execution is implied by these Linux checks.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
SUITES = {
    "models": ["flight", "combat", "inventory", "inventory_equipment", "skills",
               "services", "native_server_data", "native_spawn_data", "item_use", "combat_ledger", "world", "world_expansion", "world_mission_inventory",
               "headless_world", "online_arena", "online_classes", "online_progression", "local_save"],
    "scenes": ["scene_controls", "combat_runtime", "legacy_ui", "library_ui",
               "systems_ui", "online_ui", "online_view", "gameplay",
               "systems_integration", "expanded_game", "completion_scene", "native_spawn_runtime", "item_use_integration"],
}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", type=Path, required=True)
    parser.add_argument("--phase", choices=SUITES, required=True)
    parser.add_argument("--only", nargs="+", help="Run selected names from this phase")
    parser.add_argument("--report", type=Path)
    args = parser.parse_args()
    selected = args.only or SUITES[args.phase]
    if len(selected) != len(set(selected)) or any(name not in SUITES[args.phase] for name in selected):
        parser.error("--only must contain unique suite names from the selected phase")
    executable = args.godot.resolve(strict=True)
    version = subprocess.check_output([str(executable), "--version"], text=True).strip()
    if not version.startswith("4.7.2."):
        raise ValueError("Validation requires the pinned Godot 4.7.2")
    report = args.report or ROOT / "reports" / f"completion-{args.phase}.json"
    report.parent.mkdir(parents=True, exist_ok=True)
    logs = report.parent / (report.stem + "-logs")
    logs.mkdir(exist_ok=True)
    results = []
    with tempfile.TemporaryDirectory(prefix="ace-completion-check-") as temporary:
        environment = os.environ.copy()
        environment.update(GODOT_SILENCE_ROOT_WARNING="1", XDG_DATA_HOME=temporary)
        for name in selected:
            environment["XDG_DATA_HOME"] = str(Path(temporary) / name)
            started = time.monotonic()
            command = [str(executable), "--headless", "--fixed-fps", "120", "--path",
                       str(ROOT / "client"), "--script", f"res://tests/test_{name}.gd"]
            try:
                run = subprocess.run(command, env=environment, capture_output=True,
                                     text=True, timeout=300)
                output = run.stdout + "\n" + run.stderr
                passed = run.returncode == 0 and not any(
                    marker in output for marker in ("ERROR:", "SCRIPT ERROR", "Parse Error:")
                )
                result = {"name": name, "passed": passed, "exit_code": run.returncode,
                          "seconds": round(time.monotonic() - started, 3)}
            except subprocess.TimeoutExpired as error:
                output = str(error)
                result = {"name": name, "passed": False, "error": "timeout"}
            log = logs / f"{name}.log"
            log.write_text(output)
            result["log"] = log.name
            results.append(result)
            document = {"release": "0.9.0", "phase": args.phase, "godot": version,
                        "passed": all(row["passed"] for row in results),
                        "complete": len(results) == len(selected),
                        "selected_suites": selected,
                        "full_phase": selected == SUITES[args.phase],
                        "native_mac_windows_execution": False,
                        "results": results}
            report.write_text(json.dumps(document, indent=2) + "\n")
            print(name + ": " + ("PASS" if result["passed"] else "FAIL"), flush=True)
            if not result["passed"]:
                print(output[-6000:], flush=True)
                return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
