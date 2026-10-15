#!/usr/bin/env python3
"""Package validated desktop exports and source without the full legacy client."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import struct
import zipfile


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output-dir', required=True, type=Path)
    parser.add_argument('--clean-staging', action='store_true', help='Remove verified, reproducible raw exports after their deliverable ZIP has been checked')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    out = args.output_dir.resolve()
    validation = json.loads((root / 'reports/validation.json').read_text())
    expected_checks = {'library-ui', 'original-assets', 'combat-runtime', 'props-converter', 'protocol-python', 'gameplay-integration', 'scene-controls', 'original-library', 'mission-compiler', 'world-expansion', 'local-save', 'godot-import', 'legacy-ui', 'combat-model', 'expanded-world-data', 'world-importer', 'world-model', 'scene-smoke', 'expanded-game', 'rules-parser', 'quest-parser', 'inventory', 'actor-library', 'protocol-godot', 'original-data-assets', 'flight-model', 'terrain-converter', 'inventory-equipment', 'skills', 'services-data', 'services', 'multiplayer', 'systems-ui', 'systems-integration'}
    if (validation.get('release') != '0.7.0'
            or {row['name'] for row in validation['results']} != expected_checks
            or not all(row['passed'] for row in validation['results'])):
        raise SystemExit('Validation must pass before packaging')
    rendered = json.loads((root / 'reports/render-validation.json').read_text())
    if (rendered.get('release') != '0.7.0'
            or not all(rendered.get(name, False) for name in
                       ['original_assets_rendered', 'gameplay_rendered', 'linux_export_headless', 'linux_export_rendered', 'canonical_captures_verified'])):
        raise SystemExit('Current rendered assets and exported Linux build must pass before packaging')
    for relative in ['build/macos/ACE-Modern.zip', 'build/windows/ACE-Modern.exe', 'build/linux/ACE-Modern.x86_64']:
        if rendered.get('build_sha256', {}).get(relative) != digest(root / relative):
            raise SystemExit('Export differs from the validated build: ' + relative)
    asset_manifest = json.loads((root / 'client/assets/legacy_ui/manifest.json').read_text())
    for entry in asset_manifest['entries']:
        asset = root / 'client' / entry['path'].removeprefix('res://')
        if digest(asset) != entry['sha256'] or entry['source_sha256'] != entry['sha256']:
            raise SystemExit('Asset does not match original payload: ' + entry['name'])
    original_assets = json.loads((root / 'docs/recursos-originais.json').read_text())
    for entry in original_assets['files']:
        asset = root / entry['path']
        if asset.stat().st_size != entry['bytes'] or digest(asset) != entry['sha256']:
            raise SystemExit('Converted asset does not match catalog: ' + entry['path'])

    notices = [root / 'README.txt', *sorted((root / 'third_party').glob('*')),
               root / 'docs/interface-original.txt', root / 'docs/interface-provenance.json',
               root / 'docs/comparacao-layout.txt', root / 'docs/comparacao-layout.json',
               root / 'docs/recursos-originais.txt', root / 'docs/recursos-originais.json',
               root / 'docs/gameplay.txt', root / 'docs/gameplay-status.json',
               root / 'docs/physics-original.txt', root / 'docs/physics-original.json',
               root / 'docs/combate-original.txt', root / 'docs/combate-original.json',
               root / 'docs/world-implementation.txt', root / 'docs/equipment-native.txt', root / 'docs/skills-implementation.json', root / 'docs/services.txt', root / 'docs/multiplayer.txt', root / 'docs/flight-resources.txt', root / 'docs/original-library.txt', root / 'docs/ui-library.txt']

    out.mkdir(parents=True, exist_ok=False)

    def add_notices(archive):
        for path in notices:
            if path.is_file():
                name = 'LEIA-ME.txt' if path.name == 'README.txt' else path.relative_to(root).as_posix()
                archive.write(path, name)

    mac = out / 'ace-modern-systems-macos-v0.7.zip'
    shutil.copy2(root / 'build/macos/ACE-Modern.zip', mac)
    with zipfile.ZipFile(mac, 'a', zipfile.ZIP_DEFLATED) as archive:
        add_notices(archive)
    with zipfile.ZipFile(mac) as archive:
        assert archive.testzip() is None
        executable = next(name for name in archive.namelist() if '.app/Contents/MacOS/' in name and not name.endswith('/'))
        binary = archive.read(executable)
        assert binary[:4] == b'\xca\xfe\xba\xbe'
        count = struct.unpack_from('>I', binary, 4)[0]
        cpus = [struct.unpack_from('>I', binary, 8 + index * 20)[0] for index in range(count)]
        assert {0x1000007, 0x100000c}.issubset(cpus), 'macOS must contain Intel + Apple Silicon'
        assert archive.getinfo(executable).external_attr >> 16 & 0o111
    if args.clean_staging:
        (root / 'build/macos/ACE-Modern.zip').unlink()

    windows_exe = root / 'build/windows/ACE-Modern.exe'
    with windows_exe.open('rb') as stream:
        assert stream.read(2) == b'MZ'
        stream.seek(0x3c)
        pe_offset = struct.unpack('<I', stream.read(4))[0]
        stream.seek(pe_offset)
        assert stream.read(4) == b'PE\0\0'
        assert struct.unpack('<H', stream.read(2))[0] == 0x8664
    windows = out / 'ace-modern-systems-windows-v0.7.zip'
    with zipfile.ZipFile(windows, 'w', zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
        archive.write(windows_exe, 'ACE-Modern.exe')
        add_notices(archive)
    if args.clean_staging:
        with zipfile.ZipFile(windows) as archive:
            assert archive.testzip() is None
        windows_exe.unlink()
        (root / 'build/linux/ACE-Modern.x86_64').unlink()

    manifest = {
        'project': 'ACE Modern — voo, mundo e combate locais com recursos originais',
        'version': '0.7.0', 'engine': 'Godot 4.7.2 stable standard',
        'legacy_base_commit': '7c3e47ac47844e5c415d356a94d6201a0b9a38c4',
        'original_ui_asset_count': len(asset_manifest['entries']),
        'original_3d_scene_count': len([row for row in original_assets['files'] if row['path'].endswith('.glb')]),
        'original_asset_catalog': 'docs/recursos-originais.json',
        'scope': 'Voo e combate locais, serviços e LAN de visita/chat do novo jogo; regras recuperadas e adaptações documentadas; sem conexão ao servidor legado.',
        'gameplay_status': json.loads((root / 'docs/gameplay-status.json').read_text()),
        'official_client_executed': False,
        'tested_execution': ['Linux headless', 'Linux rendered via OpenGL software'],
        'exported_platforms': {
            'macOS': 'universal: arm64 + x86_64; assinatura ad-hoc, sem notarização',
            'Windows': 'x86_64; sem Authenticode',
            'Linux': 'x86_64 export usado na validação'
        },
        'not_tested': ['Execução em macOS/M4', 'Execução em Windows', 'Servidores legados',
                       'Equivalência completa de interface e gameplay com o cliente original'],
        'files': []
    }
    for path in sorted(root.rglob('*')):
        relative = path.relative_to(root)
        if path.is_file() and not any(part in {'.godot', '__pycache__', 'build', 'reports', '.git'} for part in relative.parts):
            manifest['files'].append({'path': relative.as_posix(), 'sha256': digest(path), 'bytes': path.stat().st_size})
    (root / 'reports/artifacts.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2))
    sources = out / 'ace-modern-systems-fontes-v0.7.zip'
    with zipfile.ZipFile(sources, 'w', zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
        for row in manifest['files']:
            archive.write(root / row['path'], 'ace-modern/' + row['path'])
        for path in sorted((root / 'reports').glob('*')):
            if path.is_file() and path.suffix in {'.json', '.log', '.png'}:
                archive.write(path, 'ace-modern/reports/' + path.name)
    for name in ['preview.png', 'inventory.png']:
        shutil.copy2(root / 'reports' / name, out / name)
    comparison = out / 'gameplay.html'
    shutil.copy2(root / 'docs/gameplay.html', comparison)
    resources_note = out / 'gameplay.txt'
    shutil.copy2(root / 'docs/gameplay.txt', resources_note)
    downloads = []
    for path in [mac, windows, sources, out / 'preview.png', out / 'inventory.png', comparison, resources_note]:
        if path.suffix == '.zip':
            with zipfile.ZipFile(path) as archive:
                assert archive.testzip() is None
        downloads.append({'path': str(path), 'bytes': path.stat().st_size, 'sha256': digest(path)})
    (out / 'downloads.json').write_text(json.dumps(downloads, ensure_ascii=False, indent=2))
    print(json.dumps(downloads, ensure_ascii=False))


if __name__ == '__main__':
    main()
