#!/usr/bin/env python3
"""Run offline tests and import checks, never contact a game server."""
import argparse
import json
from pathlib import Path
import subprocess
import sys
import time


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--godot', required=True, help='Godot 4.7.2 executable')
    parser.add_argument('--original-source', type=Path, default=Path('/workspace/analysis/ace-library/source'), help='Extracted pinned official client; required only for the independent source-provenance gate')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    reports = root / 'reports'
    reports.mkdir(exist_ok=True)
    commands = [
        ('protocol-python', [sys.executable, '-m', 'unittest', 'discover', '-s', 'protocol', '-p', 'test_*.py', '-v']),
        ('terrain-converter', [sys.executable, 'tools/test_convert_original_terrain.py', '-v']),
        ('props-converter', [sys.executable, 'tools/test_convert_original_props.py', '-v']),
        ('rules-parser', [sys.executable, 'tools/test_export_original_rules.py', '-v']),
        ('quest-parser', [sys.executable, 'tools/test_export_original_quests.py', '-v']),
        ('services-data', [sys.executable, 'tools/test_build_services.py', '-v']),
        ('mission-compiler', [sys.executable, 'tools/test_compile_runtime_missions.py', '-v']),
        ('world-importer', [sys.executable, 'tools/test_import_available_worlds.py', '-v']),
        ('actor-library', [sys.executable, 'tools/test_import_original_actors.py', '-v']),
        ('original-library', [sys.executable, 'tools/test_import_original_library.py', '-v']),
        ('expanded-world-data', [sys.executable, 'tools/validate_imported_worlds.py', '--source', str(args.original_source), '--report', str(reports / 'import-worlds-validation.json')]),
        ('original-data-assets', [sys.executable, 'tools/validate_original_data_assets.py', '--client', str(root / 'client'), '--report', str(reports / 'original-data-assets.json')]),
        ('godot-import', [args.godot, '--headless', '--path', str(root / 'client'), '--editor', '--import']),
        ('flight-model', [args.godot, '--headless', '--path', str(root / 'client'), '--script', 'res://tests/test_flight.gd']),
        ('world-model', [args.godot, '--headless', '--path', str(root / 'client'), '--script', 'res://tests/test_world.gd']),
        ('world-expansion', [args.godot, '--headless', '--path', str(root / 'client'), '--script', 'res://tests/test_world_expansion.gd']),
        ('combat-model', [args.godot, '--headless', '--path', str(root / 'client'), '--script', 'res://tests/test_combat.gd']),
        ('combat-runtime', [args.godot, '--headless', '--path', str(root / 'client'), '--script', 'res://tests/test_combat_runtime.gd']),
        ('inventory', [args.godot, '--headless', '--path', str(root / 'client'), '--script', 'res://tests/test_inventory.gd']),
        ('inventory-equipment', [args.godot, '--headless', '--path', str(root / 'client'), '--script', 'res://tests/test_inventory_equipment.gd']),
        ('skills', [args.godot, '--headless', '--path', str(root / 'client'), '--script', 'res://tests/test_skills.gd']),
        ('services', [args.godot, '--headless', '--path', str(root / 'client'), '--script', 'res://tests/test_services.gd']),
        ('multiplayer', [args.godot, '--headless', '--path', str(root / 'client'), '--script', 'res://tests/test_multiplayer.gd']),
        ('protocol-godot', [args.godot, '--headless', '--path', str(root / 'client'), '--script', 'res://tests/test_protocol.gd']),
        ('scene-controls', [args.godot, '--headless', '--fixed-fps', '120', '--path', str(root / 'client'), '--script', 'res://tests/test_scene_controls.gd']),
        ('legacy-ui', [args.godot, '--headless', '--fixed-fps', '120', '--path', str(root / 'client'), '--script', 'res://tests/test_legacy_ui.gd']),
        ('library-ui', [args.godot, '--headless', '--fixed-fps', '120', '--path', str(root / 'client'), '--script', 'res://tests/test_library_ui.gd']),
        ('systems-ui', [args.godot, '--headless', '--fixed-fps', '120', '--path', str(root / 'client'), '--script', 'res://tests/test_systems_ui.gd']),
        ('original-assets', [args.godot, '--headless', '--fixed-fps', '120', '--path', str(root / 'client'), '--script', 'res://tests/test_original_assets.gd']),
        ('gameplay-integration', [args.godot, '--headless', '--fixed-fps', '120', '--path', str(root / 'client'), '--script', 'res://tests/test_gameplay.gd']),
        ('systems-integration', [args.godot, '--headless', '--fixed-fps', '120', '--path', str(root / 'client'), '--script', 'res://tests/test_systems_integration.gd']),
        ('local-save', [args.godot, '--headless', '--path', str(root / 'client'), '--script', 'res://tests/test_local_save.gd']),
        ('expanded-game', [args.godot, '--headless', '--fixed-fps', '120', '--path', str(root / 'client'), '--script', 'res://tests/test_expanded_game.gd']),
        ('scene-smoke', [args.godot, '--headless', '--path', str(root / 'client'), '--quit-after', '120']),
    ]
    results = []
    for name, command in commands:
        started = time.monotonic()
        try:
            run = subprocess.run(command, cwd=root, capture_output=True, text=True, timeout=1800 if name == 'godot-import' else 300)
            log = run.stdout + '\n' + run.stderr
            passed = run.returncode == 0 and not any(marker in log for marker in ('ERROR:', 'Parse Error:'))
            result = {'name': name, 'passed': passed, 'exit_code': run.returncode, 'seconds': round(time.monotonic() - started, 3)}
        except subprocess.TimeoutExpired as error:
            log = str(error)
            result = {'name': name, 'passed': False, 'error': 'timeout'}
        (reports / (name + '.log')).write_text(log)
        results.append(result)
        (reports / 'validation.json').write_text(json.dumps({'release': '0.7.0', 'results': results, 'legacy_server_integration_tested': False}, indent=2))
        print(name + ': ' + ('PASS' if result['passed'] else 'FAIL'))
        if not result['passed']:
            print(log[-5000:])
            return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
