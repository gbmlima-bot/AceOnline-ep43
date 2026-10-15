#!/usr/bin/env python3
"""Run an exported desktop pack with the pinned Linux engine and fresh userdata.

This checks packaged resources and startup, not native macOS/Windows execution.
An optional real X11 display adds a rendered startup and screenshot (Pillow).
"""
from __future__ import annotations
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--godot', type=Path, required=True)
    parser.add_argument('--pack', type=Path, required=True)
    parser.add_argument('--platform', choices=['macos', 'windows'], required=True)
    parser.add_argument('--display')
    parser.add_argument('--report', type=Path, required=True)
    args = parser.parse_args()
    engine, pack, report = args.godot.resolve(strict=True), args.pack.resolve(strict=True), args.report.resolve()
    version = subprocess.check_output([str(engine), '--version'], text=True).strip()
    if not version.startswith('4.7.2.'):
        raise ValueError('Pinned Godot 4.7.2 required')
    report.parent.mkdir(parents=True, exist_ok=True)
    logs = []
    capture = report.with_suffix('.png')
    with tempfile.TemporaryDirectory(prefix='ace-desktop-smoke-') as name:
        work = Path(name)
        for rendered in ([False, True] if args.display else [False]):
            environment = dict(os.environ, GODOT_SILENCE_ROOT_WARNING='1',
                               XDG_DATA_HOME=str(work / ('render-user' if rendered else 'headless-user')))
            command = [str(engine), '--path', str(work), '--main-pack', str(pack), '--audio-driver', 'Dummy']
            if rendered:
                from PIL import ImageGrab
                environment.update(DISPLAY=args.display, LIBGL_ALWAYS_SOFTWARE='1')
                command += ['--rendering-method', 'gl_compatibility', '--rendering-driver', 'opengl3',
                            '--max-fps', '30', '--position', '0,0', '--resolution', '1280x800', '--quit-after', '45']
            else:
                command += ['--headless', '--quit-after', '3']
            log = report.with_name(report.stem + ('-rendered.log' if rendered else '-headless.log'))
            with log.open('w') as stream:
                process = subprocess.Popen(command, cwd=work, env=environment, stdout=stream, stderr=subprocess.STDOUT)
                try:
                    if rendered:
                        captured = False
                        deadline = time.monotonic() + 120
                        while time.monotonic() < deadline and process.poll() is None:
                            shot = ImageGrab.grab(bbox=(0, 0, 1280, 800), xdisplay=args.display)
                            colors = shot.crop((0, 600, 1280, 800)).resize((160, 25)).getcolors(maxcolors=256)
                            if colors is None or len(colors) > 80:
                                time.sleep(.3)
                                ImageGrab.grab(bbox=(0, 0, 1280, 800), xdisplay=args.display).save(capture)
                                captured = True
                                break
                            time.sleep(.1)
                        if not captured:
                            raise RuntimeError('Rendered startup did not produce a visible viewport')
                    code = process.wait(timeout=180)
                finally:
                    if process.poll() is None:
                        process.terminate()
                        process.wait(timeout=10)
            output = log.read_text()
            if code != 0 or any(marker in output for marker in ('ERROR:', 'SCRIPT ERROR', 'Parse Error:')):
                raise RuntimeError('Exported pack failed; inspect ' + str(log))
            if rendered and 'OpenGL API' not in output:
                raise RuntimeError('Real OpenGL renderer was not initialized')
            logs.append(log.name)
    result = {'release': '0.9.0', 'passed': True, 'artifact_platform': args.platform,
              'godot': version, 'exported_pack_executed_on_linux': True,
              'native_macos_windows_execution': False, 'fresh_userdata': True,
              'headless_passed': True, 'opengl_passed': bool(args.display), 'logs': logs,
              'pack_bytes': pack.stat().st_size}
    if args.display:
        result['capture'] = {'file': capture.name, 'sha256': hashlib.sha256(capture.read_bytes()).hexdigest()}
    report.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result), flush=True)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
