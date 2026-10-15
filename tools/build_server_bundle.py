#!/usr/bin/env python3
"""Build a deterministic, explicit data-only ACE dedicated-server context.

No original executables, artwork, cached profiles, credentials or save data enter
the bundle. The same whitelist is used by the Docker builder's --app-only step.
"""
from __future__ import annotations

import argparse
import gzip
import hashlib
import json
import os
from pathlib import Path
import shutil
import tarfile

ROOT = Path(__file__).resolve().parents[1]
GODOT_SHA256 = "8d106cbe6144c2dc7e881d61d2429c1a8a76e6b22ef48bd5e48dcf934953f71e"
GODOT_VERSION = "4.7.2.stable.official.ed1daf0bf"
CORE_SCRIPTS = (
    "flight_model.gd", "combat_model.gd", "inventory_model.gd",
    "native_equipment.gd", "skill_model.gd", "service_model.gd", "world_model.gd", "native_server_data.gd",
)
ONLINE_SCRIPTS = ("json_wire.gd", "ws_server.gd", "headless_world.gd", "arena_model.gd")
DATA_FILES = (
    "assets/legacy_rules/engines.json", "assets/legacy_rules/weapons.json",
    "assets/legacy_rules/monsters.json", "assets/legacy_rules/combat.json",
    "assets/local_encounter.json", "assets/local_services/economy.json",
    "assets/original_library/catalogs/items.json",
    "assets/original_library/catalogs/skills.json",
    "assets/original_library/catalogs/omi-native.bin",
    "assets/original_library/catalogs/level_experience.json",
    "assets/original_library/catalogs/level_stat_values.json",
    "assets/native_server/manifest.json", "assets/native_server/ti_Monster.json",
    "assets/native_server/ti_Item.json", "assets/legacy_rules/server_item_compatibility.json",
)
WORLD_MANIFEST = "docs/headless-world-assets.json"
WORLD_FILES = (
    "assets/original_world/3002_terrain.json",
    "assets/original_world/3002_heights.f32",
    "assets/original_world/3002_water_flags.u8",
    "assets/original_world/3002_landing_flags.u8",
    "assets/original_props/placements.json",
) + tuple(f"assets/original_props/{code}_collision.json" for code in (
    "03001700", "03001800", "03002000", "03002600", "03002700",
    "03002800", "03002900", "03003000", "03003500", "03003800",
))
APP_SUFFIXES = {".gd", ".godot", ".tscn", ".gdextension", ".so", ".json", ".bin", ".f32", ".u8"}


def sha256(path: Path) -> str:
    result = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            result.update(chunk)
    return result.hexdigest()


def regular_file(root: Path, relative: str) -> Path:
    path = root / relative
    if path.is_symlink() or not path.is_file() or not path.resolve().is_relative_to(root.resolve()):
        raise ValueError(f"Missing, symlinked or outside-root required file: {relative}")
    return path


def application_files(source: Path) -> dict[str, Path]:
    files: dict[str, Path] = {}
    for name in ("project.godot", "main.gd", "admin.gd", "server.tscn"):
        files[name] = regular_file(source, f"server/{name}")
    for path in sorted((source / "server").glob("*.gd")):
        files[path.name] = regular_file(source, path.relative_to(source).as_posix())
    for name in CORE_SCRIPTS:
        files[f"scripts/{name}"] = regular_file(source, f"client/scripts/{name}")
    for name in ONLINE_SCRIPTS:
        files[f"scripts/online/{name}"] = regular_file(source, f"client/scripts/online/{name}")
    for name in DATA_FILES + WORLD_FILES:
        files[name] = regular_file(source, f"client/{name}")
    if (source / WORLD_MANIFEST).is_file():
        world = json.loads((source / WORLD_MANIFEST).read_text(encoding="utf-8"))
        expected = {row["path"]: row for row in world["files"]}
        if set(expected) != set(WORLD_FILES):
            raise ValueError("Headless world whitelist differs from the reviewed map3002 manifest")
        for name in WORLD_FILES:
            if files[name].stat().st_size != expected[name]["bytes"] or sha256(files[name]) != expected[name]["sha256"]:
                raise ValueError(f"Headless world provenance mismatch: {name}")
    addon = source / "server/addons/godot-sqlite"
    extensions = sorted(addon.rglob("*.gdextension"))
    libraries = [path for path in sorted(addon.rglob("*.so")) if "linux" in path.name.lower() and ("x86_64" in path.name or "x64" in path.name)]
    if len(extensions) != 1 or not libraries:
        raise ValueError("Pinned godot-sqlite Linux x86_64 GDExtension is incomplete")
    for path in extensions + libraries:
        relative = path.relative_to(source / "server").as_posix()
        files[relative] = regular_file(source, f"server/{relative}")
    provenance = source / "third_party/GODOT-SQLITE.json"
    if provenance.is_file():
        addon_rows = json.loads(provenance.read_text(encoding="utf-8"))["files"]
        expected_addon = {row["path"]: row for row in addon_rows}
        for path in extensions + libraries:
            name = path.relative_to(source).as_posix()
            expected = expected_addon.get(name, {})
            if path.stat().st_size != expected.get("bytes") or sha256(path) != expected.get("sha256"):
                raise ValueError(f"godot-sqlite provenance mismatch: {name}")
    for path in sorted(addon.rglob("*")):
        if path.is_file() and path.name.lower() in {"license", "license.md", "license.txt", "copyright"}:
            files[path.relative_to(source / "server").as_posix()] = regular_file(source, path.relative_to(source).as_posix())
    if any(Path(name).suffix not in APP_SUFFIXES and "license" not in name.lower() and "copyright" not in name.lower() for name in files):
        raise ValueError("A non-whitelisted application file entered the bundle")
    return files


def write_json(path: Path, data: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, ensure_ascii=False, sort_keys=True, indent=2) + "\n", encoding="utf-8")
    path.chmod(0o644)


def copy_file(source: Path, target: Path, executable: bool = False) -> None:
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source, target)
    target.chmod(0o755 if executable else 0o644)


def manifest(files: dict[str, Path]) -> dict:
    return {"schema_version": 1, "scope": "dedicated_3002_data_only_no_original_executable_or_artwork", "files": [
        {"path": name, "bytes": path.stat().st_size, "sha256": sha256(path)}
        for name, path in sorted(files.items())
    ]}


def safe_output(output: Path, force: bool) -> None:
    if output.exists() and any(output.iterdir()):
        if not force or not (output / "bundle-manifest.json").is_file():
            raise ValueError("Output exists; --force only replaces a marked generated server bundle")
        if (output / ".env").exists() or any(output.rglob("*.sqlite")) or any(output.rglob("*.sqlite3")):
            raise ValueError("Output contains operator configuration/database backups; move them before replacing this generated bundle")
        shutil.rmtree(output)
    output.mkdir(parents=True, exist_ok=True)


def archive_bundle(output: Path, archive: Path) -> None:
    if archive.resolve().is_relative_to(output.resolve()):
        raise ValueError("Archive must be outside the bundle directory")
    archive.parent.mkdir(parents=True, exist_ok=True)
    with archive.open("wb") as raw, gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0) as zipped, tarfile.open(fileobj=zipped, mode="w") as tar:
        for path in sorted(output.rglob("*")):
            if not path.is_file():
                continue
            info = tar.gettarinfo(str(path), arcname="ace-server/" + path.relative_to(output).as_posix())
            info.uid = info.gid = info.mtime = 0
            info.uname = info.gname = ""
            with path.open("rb") as stream:
                tar.addfile(info, stream)


def build(source: Path, output: Path, godot: Path | None, app_only: bool = False, force: bool = False) -> dict:
    source = source.resolve()
    output = output.resolve()
    if output == source or source.is_relative_to(output):
        raise ValueError("Output must not contain or replace the source project")
    files = application_files(source)
    report = manifest(files)
    if not app_only and (godot is None or not godot.is_file() or sha256(godot) != GODOT_SHA256):
        raise ValueError("The required official Godot4.7.2 Linux x86_64 binary checksum does not match")
    safe_output(output, force)
    if app_only:
        for name, path in sorted(files.items()):
            copy_file(path, output / "app" / name)
    else:
        # Keep only whitelisted source paths so Docker can reproduce this app.
        for name, path in sorted(files.items()):
            original = path.relative_to(source)
            copy_file(path, output / "src" / original)
        tool = regular_file(source, "tools/build_server_bundle.py")
        copy_file(tool, output / "tools/build_server_bundle.py")
        copy_file(godot, output / "runtime/godot", executable=True)
        for path in sorted((source / "deploy").rglob("*")):
            if not path.is_file() or path.is_symlink() or "tests" in path.parts or "__pycache__" in path.parts or path.name == ".env":
                continue
            relative = path.relative_to(source / "deploy")
            if path.suffix not in {".py", ".sh", ".yaml", ".json", ".txt", ".example"} and path.name not in {"Dockerfile", "Caddyfile", ".dockerignore"}:
                continue
            copy_file(path, output / relative, executable=path.suffix == ".sh")
        for name in ("Godot-LICENSE.txt", "Godot-COPYRIGHT.txt", "GODOT-SQLITE.json", "godot-provenance.json"):
            path = source / "third_party" / name
            if path.is_file():
                copy_file(path, output / "third_party" / name)
                if name == "GODOT-SQLITE.json":
                    copy_file(path, output / "src/third_party" / name)
        if (source / WORLD_MANIFEST).is_file():
            copy_file(source / WORLD_MANIFEST, output / "src" / WORLD_MANIFEST)
        report["engine"] = {"version": GODOT_VERSION, "sha256": GODOT_SHA256, "architecture": "linux_x86_64"}
    write_json(output / "bundle-manifest.json", report)
    return report


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=ROOT)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--godot", type=Path)
    parser.add_argument("--app-only", action="store_true")
    parser.add_argument("--force", action="store_true")
    parser.add_argument("--archive", type=Path)
    args = parser.parse_args()
    report = build(args.source, args.output, args.godot, args.app_only, args.force)
    if args.archive:
        archive_bundle(args.output, args.archive)
    print(json.dumps({"ok": True, "files": len(report["files"]), "application_bytes": sum(row["bytes"] for row in report["files"]), "output": str(args.output)}))


if __name__ == "__main__":
    main()
