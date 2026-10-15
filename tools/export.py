#!/usr/bin/env python3
"""Export desktop builds using Godot templates already installed by the user."""
import argparse
from pathlib import Path
import subprocess


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--godot', required=True)
    parser.add_argument('--target', choices=['macOS', 'Windows', 'Linux Test', 'all'], default='all')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    targets = {'macOS': 'macos/ACE-Modern.zip', 'Windows': 'windows/ACE-Modern.exe', 'Linux Test': 'linux/ACE-Modern.x86_64'}
    selected = targets if args.target == 'all' else {args.target: targets[args.target]}
    for name, relative in selected.items():
        output = root / 'build' / relative
        output.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run([args.godot, '--headless', '--path', str(root / 'client'), '--export-release', name, str(output)], check=True)
        print(name + ': ' + str(output))


if __name__ == '__main__':
    main()
