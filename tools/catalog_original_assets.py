#!/usr/bin/env python3
"""Record portable hashes of the original resources and rules shipped in 0.7.

Run after conversion, before packaging. Does not touch client assets or execute
anything from the original game. The full source client is deliberately absent.
"""
import hashlib
import json
from pathlib import Path


def main():
    root = Path(__file__).resolve().parents[1]
    rows = []
    required = ['original_3d', 'original_world', 'original_sky', 'original_props', 'legacy_rules']
    for directory in required:
        if not (root / 'client/assets' / directory).is_dir():
            raise SystemExit('Missing original resource group: ' + directory)
    directories = sorted(path for path in (root / 'client/assets').iterdir()
                         if path.is_dir() and (path.name.startswith('original_') or path.name == 'legacy_rules'))
    for base in directories:
        for path in sorted(base.rglob('*')):
            if not path.is_file() or path.suffix not in {'.glb', '.json', '.f32', '.u8', '.bin', '.png', '.jpg', '.jpeg', '.mp3', '.wav', '.ogg', '.otf'}:
                continue
            with path.open('rb') as stream:
                digest = hashlib.file_digest(stream, 'sha256').hexdigest()
            rows.append({'path': path.relative_to(root).as_posix(), 'bytes': path.stat().st_size, 'sha256': digest})
    catalog = {
        'schema_version': 1,
        'release': '0.7.0',
        'source': {
            'url': 'https://install.masangsoft.com/20250709/ACEonline.7z',
            'archive_bytes': 1923818595,
            'archive_sha256': '8395f1f33dda8165f70f30d2a6ad094c5f64e144403fce98337e5012be795841',
            'original_executables_run': False,
        },
        'resource_groups': {
            'ships': 'client/assets/original_3d/manifest.json',
            'terrain': 'client/assets/original_world/3002_terrain.json',
            'sky_and_clouds': 'client/assets/original_sky/manifest.json',
            'scenery_objects': 'client/assets/original_props/manifest.json',
            'additional_worlds': 'client/assets/original_worlds/manifest.json',
            'enemies_and_weapon_effects': 'client/assets/original_combat/manifest.json',
            'legacy_rules': 'client/assets/legacy_rules/',
            'ui_preserved_from_0_3': 'client/assets/legacy_ui/manifest.json',
        },
        'scope': 'Converted original geometry/textures and bounded original rule records; local Godot runtime and adaptations documented in gameplay-status.json.',
        'limits': [
            'Original game not executed. New runtime ports documented legacy rules, local services and LAN visit/chat. Original MMO server and shared network combat remain unavailable.',
            'Ship static frame transforms retained; original animation tracks omitted.',
            'Original Phong materials adapted to Godot PBR; shaders and lighting are not pixel-equivalent.',
            '217 explorable worlds from238 MAP_INFO records:158 with terrain and59 native non-tile object/sky worlds; static scenery110complete/107partial,21 unavailable, documented per map.',
            'Original placement/collision flags and static native-textured water patches retained. Detail shaders, full water distortion, all VFX and animation states are not fully ported.',
            'Source units retained; physical meter calibration unknown.',
        ],
        'files': rows,
    }
    destination = root / 'docs/recursos-originais.json'
    destination.write_text(json.dumps(catalog, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps({'path': str(destination), 'files': len(rows), 'bytes': sum(row['bytes'] for row in rows)}))


if __name__ == '__main__':
    main()
