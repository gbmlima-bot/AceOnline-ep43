#!/usr/bin/env python3
"""Build the v0.8 online kit, or apply its verified client/server source overlay.

The generated apply-update.py is this same standalone, standard-library program.
A ZIP SHA256 published separately is the authenticity check; manifests detect
corruption and pin the preserved v0.7 source, rather than signing this kit.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import stat
import sys
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]
RELEASE = "0.8.0"
BASE_RELEASE = "0.7.0"
KIT_DIR = "ace-online-kit-v0.8"
BASE_ZIP = Path("/workspace/shared/ace-modern-systems/ace-modern-systems-fontes-v0.7.zip")
BASE_SHA256 = "bc5d9a6755e14f44a59bb307d7b75a1b881a60be5334a425314f7c48667705e8"
GODOT_SHA256 = "8d106cbe6144c2dc7e881d61d2429c1a8a76e6b22ef48bd5e48dcf934953f71e"
TEXT_CLIENT = {".gd", ".godot", ".tscn", ".tres", ".cfg", ".ini", ".gdshader", ".gdshaderinc", ".uid"}
SKIP_PARTS = {".git", ".godot", "__pycache__", ".online-update-backups", "userdata", "user_data", "saves", "backups"}
SQLITE_ROOT = "server/addons/godot-sqlite/"
SQLITE_NATIVE = {SQLITE_ROOT + "bin/libgdsqlite.linux.template_" + build + ".x86_64.so" for build in ("debug", "release")}
SQLITE_TEXT = {SQLITE_ROOT + name for name in ("LICENSE.md", "gdsqlite.gdextension", "gdsqlite.gdextension.uid", "godot-sqlite.gd", "godot-sqlite.gd.uid", "plugin.cfg")}
DEPLOY_TOP = {".dockerignore", ".env.example", "Caddyfile", "Dockerfile", "OPERACAO.txt", "compose.local.yaml", "compose.yaml", "images.lock.json"}
THIRD_PARTY = {"third_party/" + name for name in ("GODOT-SQLITE.json", "Godot-LICENSE.txt", "Godot-COPYRIGHT.txt", "godot-provenance.json")}
ERROR_LOG = re.compile(r"SCRIPT ERROR:|(?:^|\n)\s*ERROR:|Parse Error:", re.I)


def digest(path: Path) -> str:
    result = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            result.update(chunk)
    return result.hexdigest()


def json_bytes(data: object) -> bytes:
    return (json.dumps(data, ensure_ascii=False, sort_keys=True, indent=2) + "\n").encode("utf-8")


def safe_name(value: str) -> str:
    if not isinstance(value, str) or not value or "\\" in value or ":" in value:
        raise ValueError(f"Unsafe relative path: {value!r}")
    parts = value.split("/")
    if any(p in {"", ".", ".."} or p.endswith((" ", ".")) or any(ord(c) < 32 for c in p) for p in parts):
        raise ValueError(f"Unsafe relative path: {value!r}")
    if PurePosixPath(value).is_absolute():
        raise ValueError(f"Absolute path: {value}")
    return value


def checked_file(root: Path, name: str) -> Path:
    name = safe_name(name)
    path = root
    for part in name.split("/"):
        path = path / part
        if path.is_symlink():
            raise ValueError(f"Symlink is forbidden: {name}")
    if not path.is_file():
        raise ValueError(f"Missing regular file: {name}")
    return path


def rows_index(rows: list) -> dict[str, dict]:
    if not isinstance(rows, list) or not rows:
        raise ValueError("Empty or invalid file manifest")
    result: dict[str, dict] = {}
    folded: set[str] = set()
    for row in rows:
        name = safe_name(row["path"])
        if name.casefold() in folded:
            raise ValueError(f"Duplicate/case-colliding manifest path: {name}")
        if type(row.get("bytes")) is not int or row["bytes"] < 0 or not re.fullmatch(r"[0-9a-f]{64}", row.get("sha256", "")):
            raise ValueError(f"Invalid file size/hash: {name}")
        result[name] = row
        folded.add(name.casefold())
    return result


def row_for(path: Path, name: str) -> dict:
    return {"path": safe_name(name), "bytes": path.stat().st_size, "sha256": digest(path),
            "executable": bool(path.stat().st_mode & 0o111)}


def matches(path: Path, row: dict) -> bool:
    return path.is_file() and not path.is_symlink() and path.stat().st_size == row["bytes"] and digest(path) == row["sha256"]


def check_rows(root: Path, rows: list) -> dict[str, dict]:
    index = rows_index(rows)
    for name, row in index.items():
        if not matches(checked_file(root, name), row):
            raise ValueError(f"File checksum/size mismatch: {name}")
    return index


def project_version(path: Path) -> str:
    text = path.read_text(encoding="utf-8")
    if not re.search(r'^config/name="ACE Modern"\s*$', text, re.M):
        raise ValueError("Destination is not the ACE Modern project")
    found = re.search(r'^config/version="([^"]+)"\s*$', text, re.M)
    if not found:
        raise ValueError("Project version is absent")
    return found.group(1)


def validation_gate(source: Path, report_path: Path) -> dict:
    if not report_path.is_absolute():
        report_path = source / report_path
    report = json.loads(report_path.read_text(encoding="utf-8"))
    results = report.get("results")
    if report.get("release") != RELEASE or not isinstance(results, list) or not results:
        raise ValueError("Validation report must have release 0.8.0 and nonempty results")
    logs = []
    for result in results:
        if result.get("passed") is not True or not result.get("name"):
            raise ValueError(f"Validation failed or unnamed: {result.get('name')}")
        if result.get("log"):
            raw_path = Path(result["log"])
            log = raw_path if raw_path.is_absolute() else source / raw_path
            if not log.resolve().is_relative_to(source.resolve()) or log.is_symlink() or not log.is_file():
                raise ValueError(f"Invalid validation log: {raw_path}")
            if ERROR_LOG.search(log.read_text(encoding="utf-8", errors="replace")):
                raise ValueError(f"Engine/script error in validation log: {raw_path}")
            logs.append(row_for(log, log.relative_to(source).as_posix()))
    return {"report": report, "report_sha256": digest(report_path), "logs": logs}


def base_manifest(archive: Path, expected_sha256: str = BASE_SHA256) -> dict:
    if digest(archive) != expected_sha256:
        raise ValueError("Official v0.7 source ZIP SHA256 mismatch")
    with zipfile.ZipFile(archive) as zipped:
        names = [item.filename for item in zipped.infolist() if not item.is_dir()]
        for name in names:
            safe_name(name)
        if len(names) != len(set(n.casefold() for n in names)):
            raise ValueError("Duplicate/case-colliding base ZIP entry")
        payload = zipped.read("ace-modern/reports/artifacts.json")
        manifest = json.loads(payload)
        if manifest.get("version") != BASE_RELEASE:
            raise ValueError("Base source manifest is not version 0.7.0")
        index = rows_index(manifest["files"])
        archived_names = set(names)
        if any("ace-modern/" + name not in archived_names for name in index):
            raise ValueError("Base source ZIP is incomplete")
    rows = list(index.values())
    if "reports/artifacts.json" not in index:
        rows.append({"path": "reports/artifacts.json", "bytes": len(payload), "sha256": hashlib.sha256(payload).hexdigest()})
    return {"schema_version": 1, "release": BASE_RELEASE, "source_zip": archive.name,
            "source_zip_sha256": expected_sha256, "files": sorted(rows, key=lambda r: r["path"])}


def overlay_kind(name: str) -> str | None:
    """Shared writer/builder whitelist. Only the two reviewed SQLite SOs are binary."""
    path = PurePosixPath(safe_name(name))
    if any(part in SKIP_PARTS for part in path.parts) or path.name == ".env":
        return None
    if name in SQLITE_NATIVE:
        return "native"
    if name in {"README.md", "README.txt", ".gitignore"} or name in THIRD_PARTY or name in SQLITE_TEXT:
        return "text"
    if path.parts[0] == "client" and path.suffix in TEXT_CLIENT:
        return "text"
    if path.parts[0] == "server" and "addons" not in path.parts and path.suffix in {".gd", ".godot", ".tscn", ".uid", ".py"}:
        return "text"
    if path.parts[0] == "deploy":
        if name.removeprefix("deploy/") in DEPLOY_TOP or (len(path.parts) >= 3 and path.parts[1] in {"scripts", "tests"} and path.suffix in {".py", ".sh"}):
            return "text"
    if path.parts[0] == "docs" and path.suffix in {".md", ".txt", ".json"}:
        return "text"
    if path.parts[0] == "tools" and path.suffix == ".py":
        return "text"
    return None


def validate_sqlite_provenance(root: Path, names: set[str]) -> None:
    native = names & SQLITE_NATIVE
    if not native:
        return
    expected_names = SQLITE_NATIVE | SQLITE_TEXT
    if not expected_names.issubset(names) or "third_party/GODOT-SQLITE.json" not in names:
        raise ValueError("SQLite source overlay is incomplete or lacks provenance")
    report = json.loads(checked_file(root, "third_party/GODOT-SQLITE.json").read_text(encoding="utf-8"))
    index = rows_index(report["files"])
    if set(index) != expected_names:
        raise ValueError("SQLite provenance differs from the reviewed source whitelist")
    for name, row in index.items():
        if not matches(checked_file(root, name), row):
            raise ValueError(f"SQLite source provenance mismatch: {name}")


def overlay_files(source: Path) -> dict[str, Path]:
    files = {}
    for directory in ("client", "server", "deploy", "third_party", "docs", "tools"):
        for path in sorted((source / directory).rglob("*")):
            relative = path.relative_to(source).as_posix()
            kind = overlay_kind(relative)
            if kind is None or not path.is_file():
                continue
            checked_file(source, relative)
            if kind == "text":
                data = path.read_bytes()
                if b"\0" in data:
                    raise ValueError(f"Binary in source overlay: {relative}")
                data.decode("utf-8")
            files[relative] = path
    for name in ("README.md", "README.txt"):
        files[name] = checked_file(source, name)
    if (source / ".gitignore").is_file():
        files[".gitignore"] = checked_file(source, ".gitignore")
    if project_version(checked_file(source, "client/project.godot")) != RELEASE:
        raise ValueError("Client source must be version 0.8.0 before packaging")
    validate_sqlite_provenance(source, set(files))
    rows_index([row_for(path, name) for name, path in files.items()])
    return files


def bundle_files(bundle: Path, source: Path) -> dict[str, Path]:
    # Reuse the standalone builder's whitelist, including native-data provenance.
    import importlib.util
    spec = importlib.util.spec_from_file_location("ace_server_bundle", source / "tools/build_server_bundle.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    report = json.loads(checked_file(bundle, "bundle-manifest.json").read_text(encoding="utf-8"))
    app_files = module.application_files(bundle / "src")
    expected = rows_index(report["files"])
    if set(app_files) != set(expected):
        raise ValueError("Standalone bundle whitelist differs from its manifest")
    for name, path in app_files.items():
        if not matches(path, expected[name]):
            raise ValueError(f"Stale/corrupt standalone app: {name}")
        # Freeze gate: a freshly staged bundle must match current source too.
        source_path = source / path.relative_to(bundle / "src")
        if not matches(source_path, expected[name]):
            raise ValueError(f"Bundle differs from current source: {name}; rebuild it")
    engine = checked_file(bundle, "runtime/godot")
    if report.get("engine", {}).get("sha256") != GODOT_SHA256 or digest(engine) != GODOT_SHA256:
        raise ValueError("Standalone engine must match pinned Godot 4.7.2 Linux x86_64")
    permitted = {path.relative_to(bundle).as_posix() for path in app_files.values()}
    permitted.update({"runtime/godot", "tools/build_server_bundle.py", "bundle-manifest.json"})
    for path in (source / "deploy").rglob("*"):
        if not path.is_file() or path.is_symlink() or "tests" in path.parts or "__pycache__" in path.parts or path.name == ".env":
            continue
        if path.suffix in {".py", ".sh", ".yaml", ".json", ".txt", ".example"} or path.name in {"Dockerfile", "Caddyfile", ".dockerignore"}:
            permitted.add(path.relative_to(source / "deploy").as_posix())
    for name in ("Godot-LICENSE.txt", "Godot-COPYRIGHT.txt", "GODOT-SQLITE.json", "godot-provenance.json"):
        if (source / "third_party" / name).is_file():
            permitted.add("third_party/" + name)
            if name == "GODOT-SQLITE.json":
                permitted.add("src/third_party/" + name)
    if (source / module.WORLD_MANIFEST).is_file():
        permitted.add("src/" + module.WORLD_MANIFEST)
    result = {}
    for path in sorted(bundle.rglob("*")):
        if path.is_symlink():
            raise ValueError(f"Symlink in server bundle: {path}")
        if not path.is_file():
            continue
        name = path.relative_to(bundle).as_posix()
        safe_name(name)
        if path.name == ".env" or any(part in {".git", ".godot", "__pycache__", "backups", "userdata"} for part in path.relative_to(bundle).parts):
            raise ValueError(f"Private/generated file in server bundle: {name}")
        if name not in permitted:
            raise ValueError(f"Unexpected server bundle file: {name}")
        if name not in {"bundle-manifest.json", "runtime/godot"}:
            original = source / name.removeprefix("src/") if name.startswith(("src/", "tools/", "third_party/")) else source / "deploy" / name
            if not original.is_file() or digest(original) != digest(path):
                raise ValueError(f"Bundle differs from current source: {name}; rebuild it")
        result[name] = path
    if set(result) != permitted:
        raise ValueError(f"Standalone bundle is incomplete: {sorted(permitted - set(result))}")
    return result


def zip_info(name: str, executable: bool = False) -> zipfile.ZipInfo:
    info = zipfile.ZipInfo(safe_name(name), date_time=(1980, 1, 1, 0, 0, 0))
    info.compress_type = zipfile.ZIP_DEFLATED
    info.create_system = 3
    info.external_attr = (stat.S_IFREG | (0o755 if executable else 0o644)) << 16
    return info


def write_archive(output: Path, files: dict[str, Path | bytes], force: bool = False) -> dict:
    if output.suffix.lower() != ".zip":
        raise ValueError("Output must have the .zip extension")
    if output.is_symlink():
        raise ValueError("Output must not be a symlink")
    if output.exists() and not force:
        raise ValueError("Output already exists; choose another path or use --force")
    rows = []
    for name, value in sorted(files.items()):
        if isinstance(value, bytes):
            rows.append({"path": name, "bytes": len(value), "sha256": hashlib.sha256(value).hexdigest(), "executable": name == "apply-update.py"})
        else:
            rows.append(row_for(value, name))
    rows_index(rows)
    manifest = {"schema_version": 1, "release": RELEASE, "files": rows}
    files = dict(files)
    files["kit-manifest.json"] = json_bytes(manifest)
    modes = {r["path"]: r.get("executable", False) for r in rows}
    output.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary_name = tempfile.mkstemp(prefix=".ace-kit-", suffix=".zip", dir=output.parent)
    os.close(fd)
    temporary = Path(temporary_name)
    try:
        with zipfile.ZipFile(temporary, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=6, allowZip64=True) as zipped:
            for name, value in sorted(files.items()):
                with zipped.open(zip_info(KIT_DIR + "/" + name, modes.get(name, False)), "w", force_zip64=True) as target:
                    if isinstance(value, bytes):
                        target.write(value)
                    else:
                        with value.open("rb") as original:
                            shutil.copyfileobj(original, target, 1024 * 1024)
        with zipfile.ZipFile(temporary) as zipped:
            if zipped.testzip() is not None:
                raise ValueError("Generated ZIP failed CRC validation")
            for row in rows:
                h = hashlib.sha256()
                with zipped.open(KIT_DIR + "/" + row["path"]) as stream:
                    for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                        h.update(chunk)
                if h.hexdigest() != row["sha256"] or zipped.getinfo(KIT_DIR + "/" + row["path"]).file_size != row["bytes"]:
                    raise ValueError(f"Source changed while packaging: {row['path']}")
        os.replace(temporary, output)
    finally:
        temporary.unlink(missing_ok=True)
    return {"release": RELEASE, "files": len(rows), "uncompressed_bytes": sum(r["bytes"] for r in rows),
            "zip_bytes": output.stat().st_size, "sha256": digest(output), "output": str(output)}


def package(source: Path, bundle: Path, archive: Path, validation: Path, output: Path, force: bool = False) -> dict:
    source = source.resolve()
    if output.resolve().is_relative_to(bundle.resolve()) or output.resolve() == archive.resolve():
        raise ValueError("Output must not replace the base ZIP or enter the server bundle")
    evidence = validation_gate(source, validation)
    baseline = base_manifest(archive)
    overlay = overlay_files(source)
    server = bundle_files(bundle, source)
    rows = [row_for(path, name) for name, path in sorted(overlay.items())]
    files: dict[str, Path | bytes] = {"server-bundle/" + name: path for name, path in server.items()}
    files.update({"client-source-overlay/" + name: path for name, path in overlay.items()})
    files.update({"apply-update.py": Path(__file__).resolve(), "base-manifest.json": json_bytes(baseline),
                  "overlay-manifest.json": json_bytes({"schema_version": 1, "release": RELEASE, "files": rows}),
                  "validation.json": json_bytes(evidence), "ONLINE-PVE.md": checked_file(source, "docs/ONLINE-PVE.md"),
                  "LEIA-ME.txt": INSTRUCTIONS.encode("utf-8")})
    # Ship only the evidence explicitly approved by the validation gate. Keep it
    # outside the source overlay: applying an update must not overwrite reports.
    copied_evidence = set()
    for row in evidence["logs"]:
        name = row["path"]
        data = checked_file(source, name).read_bytes()
        if name in files and name not in copied_evidence:
            raise ValueError(f"Validation evidence collides with a reserved kit path: {name}")
        if len(data) != row["bytes"] or hashlib.sha256(data).hexdigest() != row["sha256"]:
            raise ValueError(f"Validation evidence changed after the gate: {name}")
        # Freeze these small approved logs/JSONs so validation.json's recorded
        # hash cannot drift if a test log changes while the ZIP is being written.
        files[name] = data
        copied_evidence.add(name)
    return write_archive(output, files, force)


def load_json(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def destination_path(base: Path, name: str) -> Path:
    safe_name(name)
    path = base
    for part in name.split("/"):
        path /= part
        if path.is_symlink():
            raise ValueError(f"Destination symlink is forbidden: {name}")
        if path.exists() and path != base / name and not path.is_dir():
            raise ValueError(f"Destination parent is not a directory: {name}")
    return path


def atomic_write(path: Path, data: bytes, executable: bool = False) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix=".ace-update-", dir=path.parent)
    temporary = Path(name)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        temporary.chmod(0o755 if executable else 0o644)
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def apply_update(kit: Path, base: Path, dry_run: bool = False, source_zip: Path | None = None) -> dict:
    if kit.is_symlink() or base.is_symlink() or not base.is_dir():
        raise ValueError("Kit/base must be real directories, not symlinks")
    kit, base = kit.resolve(), base.resolve()
    if kit == base or kit.is_relative_to(base) or base.is_relative_to(kit):
        raise ValueError("Extract the kit and v0.7 project into separate directories")
    outer = load_json(checked_file(kit, "kit-manifest.json"))
    if outer.get("release") != RELEASE:
        raise ValueError("Kit release mismatch")
    payload = check_rows(kit, outer["files"])
    actual = set()
    for path in kit.rglob("*"):
        if path.is_symlink():
            raise ValueError(f"Symlink in kit: {path}")
        if path.is_file():
            actual.add(path.relative_to(kit).as_posix())
    if actual != set(payload) | {"kit-manifest.json"}:
        raise ValueError("Kit has missing or unexpected files")
    baseline = load_json(checked_file(kit, "base-manifest.json"))
    overlay_manifest = load_json(checked_file(kit, "overlay-manifest.json"))
    if baseline.get("release") != BASE_RELEASE or overlay_manifest.get("release") != RELEASE:
        raise ValueError("Base/overlay release mismatch")
    originals = rows_index(baseline["files"])
    overlay = check_rows(kit / "client-source-overlay", overlay_manifest["files"])
    if {"client-source-overlay/" + name for name in overlay} != {name for name in payload if name.startswith("client-source-overlay/")}:
        raise ValueError("Overlay manifest differs from kit manifest")
    # Only source paths and the pinned native SQLite extension can be written.
    for name in overlay:
        kind = overlay_kind(name)
        if kind is None:
            raise ValueError(f"Non-source destination in overlay: {name}")
        if kind == "text":
            data = checked_file(kit / "client-source-overlay", name).read_bytes()
            if b"\0" in data:
                raise ValueError(f"Binary source overlay: {name}")
            data.decode("utf-8")
    validate_sqlite_provenance(kit / "client-source-overlay", set(overlay))
    if "client/project.godot" not in overlay:
        raise ValueError("Overlay must include project.godot")
    if project_version(checked_file(kit / "client-source-overlay", "client/project.godot")) != RELEASE:
        raise ValueError("Overlay project version mismatch")
    version = project_version(checked_file(base, "client/project.godot"))
    if version not in {BASE_RELEASE, RELEASE}:
        raise ValueError(f"Expected base version 0.7.0, found {version}")
    if source_zip is not None and digest(source_zip) != baseline["source_zip_sha256"]:
        raise ValueError("Optional original source ZIP SHA256 mismatch")
    for name, row in originals.items():
        target = destination_path(base, name)
        if not matches(target, row) and not (name in overlay and matches(target, overlay[name])):
            raise ValueError(f"Base file changed or missing: {name}; use a fresh v0.7 source extraction")
    changed = []
    for name, row in overlay.items():
        target = destination_path(base, name)
        if matches(target, row):
            continue
        if name not in originals and target.exists():
            raise ValueError(f"New source file conflicts with an existing file: {name}")
        changed.append(name)
    if version == RELEASE and changed:
        raise ValueError("Project says 0.8.0 but overlay is incomplete; restore source backup before retrying")
    result = {"release": RELEASE, "base_files_verified": len(originals), "changed_files": len(changed),
              "dry_run": dry_run, "already_applied": not changed}
    if dry_run or not changed:
        return result
    # The version marker is committed last. Backups contain overwritten source files only.
    changed.sort(key=lambda name: (name == "client/project.godot", name))
    backup_parent = destination_path(base, ".online-update-backups/placeholder").parent
    backup_parent.mkdir(exist_ok=True)
    backup = Path(tempfile.mkdtemp(prefix="v0.8-", dir=backup_parent))
    old = {}
    for name in changed:
        path = destination_path(base, name)
        old[name] = (path.read_bytes(), bool(path.stat().st_mode & 0o111)) if path.exists() else None
        if old[name] is not None:
            atomic_write(backup / name, old[name][0], old[name][1])
    written = []
    try:
        for name in changed:
            target = destination_path(base, name)
            data = checked_file(kit / "client-source-overlay", name).read_bytes()
            if hashlib.sha256(data).hexdigest() != overlay[name]["sha256"]:
                raise ValueError(f"Overlay changed while applying: {name}")
            atomic_write(target, data, overlay[name].get("executable", False))
            written.append(name)
        atomic_write(backup / "update-receipt.json", json_bytes({**result, "changed_paths": changed}))
    except Exception:
        for name in reversed(written):
            target = destination_path(base, name)
            if old[name] is None:
                target.unlink(missing_ok=True)
            else:
                atomic_write(target, old[name][0], old[name][1])
        raise
    result["source_backup"] = str(backup)
    return result


INSTRUCTIONS = """ACE Modern — kit Online PvE 0.8.0

server-bundle/ é independente: leia ONLINE-PVE.md e server-bundle/OPERACAO.txt.
Ele contém o runtime Linux x86_64; não contém o cliente gráfico nem assets de arte.
Apps macOS universal e Windows x64 compatíveis 0.8 são distribuídos separadamente.

Atualizar fontes do cliente e servidor sem baixar de novo os assets:
1. Preserve ace-modern-systems-fontes-v0.7.zip e confira seu SHA256 publicado.
2. Extraia a base 0.7 para uma pasta nova. Não use a pasta do seu desenvolvimento.
3. Extraia este kit em OUTRA pasta e abra um terminal na pasta do kit.
4. Verifique sem alterar:
   python3 apply-update.py --base /caminho/ace-modern --dry-run
5. Aplique:
   python3 apply-update.py --base /caminho/ace-modern
   Opcional: --base-source-zip /caminho/ace-modern-systems-fontes-v0.7.zip
6. Abra /caminho/ace-modern/client/project.godot com Godot 4.7.2.

São conferidos versão, projeto e hashes da base inteira e do overlay.
Arquivos alterados pelo usuário causam recusa; extraia outra cópia da base.
O overlay inclui client/, server/, deploy/, ferramentas e a extensãoSQLite
Linux verificada por proveniência. Permite reconstruir o servidor a partir
das fontes atualizadas. O updater escreve cada arquivo de modo atômico e
guarda os anteriores em .online-update-backups. Não apaga assets, perfis ou userdata.
Feche o editor durante a atualização. A primeira abertura pode reimportar assets.
Não há download de dados antigos pelo updater. O cliente 0.7 não tem Online PvE.
Manifestos detectam corrupção; confira também o SHA256 do ZIP por canal confiável.
"""


def main() -> None:
    applying = Path(__file__).name == "apply-update.py"
    parser = argparse.ArgumentParser(description=__doc__)
    if applying:
        parser.add_argument("--base", type=Path, required=True)
        parser.add_argument("--base-source-zip", type=Path)
        parser.add_argument("--dry-run", action="store_true")
    else:
        parser.add_argument("--source", type=Path, default=ROOT)
        parser.add_argument("--server-bundle", type=Path)
        parser.add_argument("--base-source-zip", type=Path, default=BASE_ZIP)
        parser.add_argument("--validation-report", type=Path, default=Path("reports/online-validation-v08.json"))
        parser.add_argument("--output", type=Path, required=True)
        parser.add_argument("--force", action="store_true")
    args = parser.parse_args()
    try:
        if applying:
            result = apply_update(Path(__file__).resolve().parent, args.base, args.dry_run, args.base_source_zip)
        else:
            result = package(args.source, args.server_bundle or args.source / "build/server-bundle", args.base_source_zip,
                             args.validation_report, args.output, args.force)
    except (ValueError, OSError, KeyError, zipfile.BadZipFile, UnicodeError) as exc:
        parser.exit(1, f"Refused: {exc}\n")
    print(json.dumps({"ok": True, **result}, ensure_ascii=False))


if __name__ == "__main__":
    main()
